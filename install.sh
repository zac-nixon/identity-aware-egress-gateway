#!/usr/bin/env bash
#
# install.sh — bring up the full agentic mesh walkthrough stack on an EKS cluster, end to end:
#   0. Agent images: built from agents/ and pushed to ECR (agents/build-images.sh; local docker
#      buildx if available, else AWS CodeBuild). Skipped when the content-hash tag already exists.
#   1. Istio in ambient mode, at a PINNED version (istioctl downloaded + checksum-verified if needed)
#   2. Gateway API standard CRDs (each missing CRD installed; existing/EKS-managed ones left alone)
#   3. Agent Gateway CRDs + control plane (Helm, OCI charts)
#   4. Two agent namespaces enrolled in the ambient mesh
#   5. Bedrock IAM + EKS Pod Identity: the gateway's own role, two per-agent Bedrock roles, and the
#      Pod Identity association for the gateway proxy's ServiceAccount (bedrock/setup-pod-identity.sh)
#   6. The Agent Gateway `Gateway` (HTTP :80 + HBONE :15008) and its AgentgatewayParameters
#   7. GitHub MCP egress config: per-agent credential Secrets (from WRITER_PAT / REVIEWER_PAT),
#      per-agent Backends + BackendTLSPolicy, shared catch-all ServiceEntry (transparent :80
#      capture), HTTPRoute (identity routing) + PreRouting identity stamp, and the frontend identity
#      gate. Plus Bedrock LLM egress, which carries NO Secret — it signs as a per-agent IAM role via
#      the association created in stage 5.
#   8. Rate limit infrastructure: an external Envoy rate limit service backed by Redis, with a
#      ConfigMap of rate limit rules (reached by the gateway over the Rate Limit gRPC protocol)
#   9. The agent workloads + the egress lockdown, then a SMOKE TEST: one GitHub MCP call and one
#      Bedrock call (both LLM paths) through the gateway as EACH agent identity, which must all 200.
#
# WHY POD IDENTITY IS SET UP BEFORE THE GATEWAY (stage 5 before stage 6): a Pod Identity association
# is just a (cluster, namespace, serviceAccount) -> role mapping and does not require the
# ServiceAccount to exist yet. Creating it first means the gateway proxy pod picks up AWS credentials
# on its FIRST start, so no `rollout restart` is needed afterwards.
#
# Usage:
#   WRITER_PAT=ghp_... REVIEWER_PAT=ghp_... GITHUB_OWNER=me GITHUB_REPO=playground ./install.sh
#   ./install.sh --validate      # client-side dry-run every manifest; apply nothing
#   ./install.sh --uninstall     # tear down what this script created (incl. IAM roles)
#
# Re-running is safe: images are not rebuilt for unchanged source, Istio is not reinstalled at the
# same version, and if WRITER_PAT / REVIEWER_PAT / GITHUB_OWNER / GITHUB_REPO are omitted on a re-run,
# the values already in the cluster are kept (never replaced with placeholders).
#
# Required inputs (env) on a first install:
#   WRITER_PAT, REVIEWER_PAT  GitHub tokens the gateway injects for each agent. Use two DIFFERENT
#                             tokens — per-agent credentials are the point of the demo. GITHUB_PAT
#                             sets both at once (with a warning).
#   GITHUB_OWNER, GITHUB_REPO The repository the agents work in.
#
# Optional config (env):
#   KUBE_CONTEXT          kube-context to install into          (default: the current context)
#   ISTIO_VERSION         Istio/istioctl version                 (default: 1.32.0-rc.0 — see below)
#   ISTIO_UPGRADE         Set to 1 to let istioctl change an EXISTING Istio install (version/profile)
#   GATEWAY_API_VERSION   Gateway API release for missing CRDs   (default: v1.6.1)
#   AGW_VERSION           Agent Gateway chart version            (default: v1.7.0)
#   WRITER_IMAGE, REVIEWER_IMAGE  Use these images instead of building (both or neither)
#   IMAGE_PLATFORM        Image platform                         (default: linux/amd64)
#   IMAGE_BUILDER         docker | codebuild                     (default: docker if usable, else codebuild)
#   CLUSTER_DNS_IP        Resolver IP for the egress lockdown    (default: derived from the cluster)
#   AWS_ACCOUNT_ID        Account that owns the roles + images   (default: from the kube-context / `aws sts`)
#   CLUSTER_NAME          EKS cluster name                       (default: from the kube-context ARN)
#   AWS_REGION            Region for EKS + ECR                   (default: from the kube-context ARN, else us-east-1)
#   AWS_ENDPOINT_URL_EKS  EKS API endpoint for every `aws eks` call (default: the AWS CLI's)
#   POD_IDENTITY_EXTRA_PRINCIPALS  Extra service principals for the gateway role's Pod Identity
#                         trust policy, space-separated (see bedrock/setup-pod-identity.sh)
#   SKIP_POD_IDENTITY     Set to 1 to skip stage 5 AND the Bedrock manifests entirely (GitHub-MCP-only
#                         install). This is the ONLY way to opt out — see below.
#   SKIP_SMOKE_TEST       Set to 1 to skip the end-to-end smoke test
#   PURGE_IMAGES          With --uninstall: also delete the ECR repos + CodeBuild resources
#
# WHY ISTIO IS PINNED: the 0.0.0.0/0 catch-all ServiceEntry (gateway/service-entry.yaml) resolves to
# a stale, endpoint-less entry in ztunnel ("no healthy upstream") on Istio 1.30.4 through 1.31.x
# (istio/ztunnel#2086). The script refuses those versions unless ISTIO_ALLOW_ZTUNNEL_BUG=1.
#
# POD IDENTITY IS SET UP EXPLICITLY AND FAIL-CLOSED.
# Bedrock here has no credential Secret — the gateway signs with SigV4 as a per-agent IAM role — so
# Pod Identity is not optional decoration, it is the credential mechanism. Therefore:
#   * Stage 5 always runs unless you set SKIP_POD_IDENTITY=1.
#   * A missing prerequisite (no aws CLI, no credentials, no CLUSTER_NAME) is a HARD FAILURE with
#     remediation, not a silent downgrade.
#   * Stage 5 asserts the association actually exists afterwards; "the script exited 0" is not proof.
#   * After the Gateway provisions, assert_proxy_credentials verifies the proxy really received
#     AWS_CONTAINER_CREDENTIALS_FULL_URI, restarts it once if not, and fails the install if it still
#     has not. The webhook only injects at pod creation, so a proxy that predates the association
#     silently has no credentials — a failure that would otherwise surface much later as an opaque
#     runtime error.
#
# Namespaces (writer-agent, reviewer-agent, agentgateway-system) and the Gateway name
# (egress) are hardcoded here and in the manifests — change them in both places if needed.
#
set -euo pipefail

# Directory holding this script and its companion manifest files.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Chart versions are overridable; namespaces/gateway names are hardcoded to match the manifests.
GATEWAY_API_VERSION="${GATEWAY_API_VERSION:-v1.6.1}"
AGW_VERSION="${AGW_VERSION:-v1.7.0}"
AGW_NS="agentgateway-system"
# NOTE: must NOT be "agentgateway" — that is the Helm release/controller Deployment name, and the
# proxy Deployment is derived from the Gateway name (a collision makes provisioning fail with an
# immutable spec.selector error). See gateway.yaml.
GATEWAY_NAME="egress"
AGENT_NS_1="writer-agent"
AGENT_NS_2="reviewer-agent"
AGENT_DEPLOYMENTS=(
  "$AGENT_NS_1/writer-agent-cooperative" "$AGENT_NS_1/writer-agent-transparent"
  "$AGENT_NS_2/reviewer-agent-cooperative" "$AGENT_NS_2/reviewer-agent-transparent"
)

# ---- Istio --------------------------------------------------------------------------------------
# Pinned; see "WHY ISTIO IS PINNED" above. istioctl installs the control plane at its own version.
ISTIO_VERSION="${ISTIO_VERSION:-1.32.0-rc.0}"
ISTIO_UPGRADE="${ISTIO_UPGRADE:-}"
ISTIOCTL=""   # set by ensure_istioctl

# ---- Inputs the manifests are rendered with (see render) ----------------------------------------
KUBE_CONTEXT="${KUBE_CONTEXT:-}"
GITHUB_OWNER="${GITHUB_OWNER:-}"
GITHUB_REPO="${GITHUB_REPO:-}"
WRITER_PAT="${WRITER_PAT:-${GITHUB_PAT:-}}"
REVIEWER_PAT="${REVIEWER_PAT:-${GITHUB_PAT:-}}"
WRITER_IMAGE="${WRITER_IMAGE:-}"
REVIEWER_IMAGE="${REVIEWER_IMAGE:-}"
IMAGE_PLATFORM="${IMAGE_PLATFORM:-linux/amd64}"
IMAGE_ARCH="${IMAGE_PLATFORM#*/}"
CLUSTER_DNS_IP="${CLUSTER_DNS_IP:-}"
SKIP_SMOKE_TEST="${SKIP_SMOKE_TEST:-}"
PURGE_IMAGES="${PURGE_IMAGES:-}"
GITHUB_SECRET_WRITER="github-mcp-writer-credential"
GITHUB_SECRET_REVIEWER="github-mcp-reviewer-credential"

# ---- Bedrock / EKS Pod Identity ---------------------------------------------------------------
# Bedrock has NO credential Secret. The gateway signs with SigV4 as a per-agent IAM role:
#   gateway pod (Pod Identity) -> role/agentgateway-egress   [no Bedrock permissions]
#     -> sts:AssumeRole -> role/agentgateway-bedrock-writer   -> SigV4 -> Bedrock
#     -> sts:AssumeRole -> role/agentgateway-bedrock-reviewer -> SigV4 -> Bedrock
# All three values may be auto-derived in resolve_aws_context(). SKIP_POD_IDENTITY=1 turns off the
# IAM stage AND the Bedrock manifests together — they are useless apart, because the backends name
# roles that the IAM stage creates.
SKIP_POD_IDENTITY="${SKIP_POD_IDENTITY:-}"
AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID:-}"
CLUSTER_NAME="${CLUSTER_NAME:-}"
# TWO INDEPENDENT REGIONS — see the header of bedrock/setup-pod-identity.sh.
#   AWS_REGION      where the EKS CLUSTER lives (every `aws eks` call)
#   BEDROCK_REGION  where the GATEWAY CALLS BEDROCK (only the inference-profile ARN in the IAM policy)
# BEDROCK_REGION is derived from the backend manifests below so the IAM policy and the backends cannot
# drift apart. There is no reason for the two to be equal.
AWS_REGION="${AWS_REGION:-}"
BEDROCK_REGION="${BEDROCK_REGION:-}"
# Set by resolve_aws_context(); consulted by the Bedrock stage and by uninstall.
BEDROCK_ENABLED="false"
POD_IDENTITY_SCRIPT="bedrock/setup-pod-identity.sh"

# Shared, Gateway-wide egress policy applied before any route (gateway/): the coarse frontend
# identity gate + the SPIFFE identity stamp (PreRouting) that the GitHub MCP and Bedrock routes both
# match on — plus the catch-all ServiceEntry that captures all agent :80 egress to the gateway. Apply
# first so the gate is in place and those header matches work.
SHARED_MANIFESTS=(
  gateway/service-entry.yaml
  gateway/frontend-authz.yaml
  gateway/identity-header.yaml
)
# GitHub MCP egress config (github/), in dependency order (backend -> route). The credential Secrets
# come first, from create_github_secrets — github/github-mcp-secret.yaml is reference-only. Capture
# comes from the shared ServiceEntry in SHARED_MANIFESTS.
GITHUB_MCP_MANIFESTS=(
  github/github-mcp-backend.yaml
  github/github-mcp-route.yaml
)
# Bedrock LLM egress config (bedrock/). NO credential Secret — the gateway signs with SigV4 as a
# per-agent IAM role (EKS Pod Identity + assumeRole; see bedrock/setup-pod-identity.sh). Two egress
# models:
#   * cooperative: the gateway is an OpenAI-compatible LLM router (model steering).
#   * transparent: the agent calls the real Bedrock API; the gateway transparently signs.
BEDROCK_MANIFESTS=(
  bedrock/bedrock-cooperative-backend.yaml
  bedrock/bedrock-cooperative-route.yaml
  bedrock/bedrock-failover-policy.yaml    # model fallback: health-eviction + retry on the cooperative path
  bedrock/bedrock-transparent-backend.yaml
  bedrock/bedrock-transparent-route.yaml
)
# Rate limit infrastructure (ratelimit/): an external Envoy rate limit service backed by Redis,
# reached by the gateway over the Rate Limit gRPC protocol. Order matters: namespace first, then
# Redis (backing store) and the rules ConfigMap, then the service that consumes both.
RATELIMIT_MANIFESTS=(
  ratelimit/namespace.yaml
  ratelimit/redis.yaml
  ratelimit/ratelimit-config.yaml
  ratelimit/ratelimit.yaml
  ratelimit/llm-token-limit.yaml   # AgentgatewayPolicy: per-identity LLM token budget on the LLM routes
  ratelimit/request-rate-limit.yaml  # AgentgatewayPolicy: per-identity request count on the GitHub MCP route
)
# Agent workloads (agents/): each agent's ServiceAccount + its two app versions (cooperative and transparent).
# The writer turns issues into poem PRs; the reviewer reviews those PRs and merges the good ones.
# They run as distinct ServiceAccounts (distinct SPIFFE identities) so the gateway vends each a
# different credential and (forward-looking) scopes which MCP tools each may call.
AGENT_MANIFESTS=(
  agents/writer-agent-sa.yaml
  agents/writer-agent-cooperative.yaml
  agents/writer-agent-transparent.yaml
  agents/reviewer-agent-sa.yaml
  agents/reviewer-agent-cooperative.yaml
  agents/reviewer-agent-transparent.yaml
  # Egress lockdown LAST, deliberately. It is validated and always applied, but it is a backstop
  # rather than a prerequisite: applying it after the workloads means a problem with the policy cannot
  # prevent the agents from being created.
  agents/appnetworkpolicy.yaml
)
# The agent egress lockdown (agents/appnetworkpolicy.yaml) is part of AGENT_MANIFESTS above and is
# always applied. Its eBPF-vs-ztunnel-redirect behaviour is validated on-cluster: the pod-veth policy
# observes ztunnel's HBONE hop to the gateway pods on :15008, which is what the rules allow.

info() { printf '\033[1;34m----\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m OK \033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARN\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31mFAIL\033[0m %s\n' "$*" >&2; }
die()  { err "$*"; exit 1; }

require() { command -v "$1" >/dev/null 2>&1 || die "$1 not found on PATH ($2)"; }

# render FILE — print a companion manifest with every <PLACEHOLDER> substituted.
#
# Rendered through a pipe rather than sed-ing the tracked file in place, so a run never dirties your
# working tree and the manifests stay committable with their placeholders intact.
#
# PLACEHOLDER GUARD: refuses to emit anything that still contains an <ANGLE_BRACKET> placeholder.
# bedrock/bedrock-*-backend.yaml carries <ACCOUNT_ID> in a roleArn, and the CRD validates that field
# against ^arn:aws[a-z-]*:iam::[0-9]{12}:role/.+$. Applying it unsubstituted is rejected by the API
# server, which under `set -e` would abort this script mid-run and leave the cluster half-configured
# (routes applied, agents not). Fail here with a clear message instead.
#
# RENDER_DUMMY=1 fills unresolved values with syntactically valid dummies (for --validate and
# --uninstall, which need parseable objects but not real values).
RENDER_DUMMY=""
render() {
  local file="${SCRIPT_DIR}/$1"
  [ -f "$file" ] || die "manifest not found: $file"
  # Placeholders inside comments are documentation; only the YAML body has to be substituted.
  local ph name val subst=()
  for ph in $(sed 's/#.*//' "$file" | grep -oE '<[A-Z_]+>' | sort -u); do
    name="${ph#<}"; name="${name%>}"
    case "$name" in
      ACCOUNT_ID)     val="$AWS_ACCOUNT_ID";  [ -n "$RENDER_DUMMY" ] && val="${val:-000000000000}" ;;
      WRITER_IMAGE)   val="$WRITER_IMAGE";    [ -n "$RENDER_DUMMY" ] && val="${val:-example.invalid/writer-agent:dummy}" ;;
      REVIEWER_IMAGE) val="$REVIEWER_IMAGE";  [ -n "$RENDER_DUMMY" ] && val="${val:-example.invalid/reviewer-agent:dummy}" ;;
      GITHUB_OWNER)   val="$GITHUB_OWNER";    [ -n "$RENDER_DUMMY" ] && val="${val:-dummy}" ;;
      GITHUB_REPO)    val="$GITHUB_REPO";     [ -n "$RENDER_DUMMY" ] && val="${val:-dummy}" ;;
      CLUSTER_DNS_IP) val="$CLUSTER_DNS_IP";  [ -n "$RENDER_DUMMY" ] && val="${val:-10.100.0.10}" ;;
      IMAGE_ARCH)     val="$IMAGE_ARCH" ;;
      *) die "$1 has an unknown placeholder $ph" ;;
    esac
    [ -n "$val" ] || die "cannot render $1: $ph has no value (an input was not resolved)"
    subst+=(-e "s|${ph}|${val}|g")
  done
  if [ "${#subst[@]}" -eq 0 ]; then cat "$file"; else sed "${subst[@]}" "$file"; fi
}

# apply_manifest FILE — render and apply a companion manifest.
apply_manifest() {
  local rendered; rendered="$(render "$1")" || exit 1
  kubectl apply -f - <<<"$rendered" >/dev/null
}

# delete_manifest FILE — delete (best-effort; used by --uninstall).
delete_manifest() {
  local rendered; rendered="$(RENDER_DUMMY=1 render "$1" 2>/dev/null)" || return 0
  kubectl delete --ignore-not-found -f - <<<"$rendered" >/dev/null 2>&1 || true
}

# use_kube_context — pin every kubectl/helm/istioctl call to KUBE_CONTEXT without touching your
# kubeconfig's current-context: a minified, flattened copy holding only that context.
use_kube_context() {
  [ -n "$KUBE_CONTEXT" ] || return 0
  local kc; kc="$(mktemp "${TMPDIR:-/tmp}/agw-kubeconfig.XXXXXX")"
  # shellcheck disable=SC2064
  trap "rm -f '$kc'" EXIT
  kubectl config view --minify --flatten --context "$KUBE_CONTEXT" >"$kc" 2>/dev/null \
    || die "kube-context '$KUBE_CONTEXT' not found (kubectl config get-contexts)"
  chmod 600 "$kc"
  export KUBECONFIG="$kc"
  ok "using kube-context $KUBE_CONTEXT"
}

preflight() {
  require kubectl  "needed to apply manifests"
  require helm     "needed to install the Agent Gateway charts"
  require jq       "needed to read backend status"
  require python3  "needed to split the Gateway API bundle"
  require curl     "needed to download istioctl and the Gateway API CRDs"
  require tar      "needed to unpack istioctl"
  command -v shasum >/dev/null 2>&1 || command -v sha256sum >/dev/null 2>&1 \
    || die "shasum or sha256sum not found on PATH (needed to verify the istioctl download)"
  kubectl cluster-info >/dev/null 2>&1 || die "kubectl cannot reach a cluster; check your kube-context"

  [ -z "${AWS_ENDPOINT_URL_EKS:-}" ] || ok "using EKS API endpoint $AWS_ENDPOINT_URL_EKS"
  ok "preflight passed (tools present; cluster reachable)"
}

# secret_token NAME — the token currently in a GitHub credential Secret ("" if absent/placeholder).
secret_token() {
  local v
  v="$(kubectl -n "$AGW_NS" get secret "$1" -o jsonpath='{.data.Authorization}' 2>/dev/null | base64 -d 2>/dev/null || true)"
  v="${v#Bearer }"
  case "$v" in ""|REPLACE_WITH_*|"<"*) echo "" ;; *) echo "$v" ;; esac
}

# deploy_env DEPLOY NAME — an env value from an existing agent Deployment ("" if absent/placeholder).
deploy_env() {
  local v
  v="$(kubectl -n "${1%%/*}" get deploy "${1##*/}" \
    -o jsonpath="{.spec.template.spec.containers[0].env[?(@.name==\"$2\")].value}" 2>/dev/null || true)"
  case "$v" in ""|REPLACE_WITH_*|"<"*) echo "" ;; *) echo "$v" ;; esac
}

# resolve_inputs — everything the manifests are rendered with, resolved and checked BEFORE anything
# is changed, so a missing input fails in seconds instead of after Istio is installed.
resolve_inputs() {
  # Repository: env, else what a previous install put in the writer Deployment.
  [ -n "$GITHUB_OWNER" ] || GITHUB_OWNER="$(deploy_env "${AGENT_DEPLOYMENTS[0]}" GITHUB_OWNER)"
  [ -n "$GITHUB_REPO" ]  || GITHUB_REPO="$(deploy_env "${AGENT_DEPLOYMENTS[0]}" GITHUB_REPO)"
  if [ -z "$GITHUB_OWNER" ] || [ -z "$GITHUB_REPO" ]; then
    die "set GITHUB_OWNER and GITHUB_REPO to the repository the agents should work in, e.g.
         GITHUB_OWNER=my-user GITHUB_REPO=my-repo ./install.sh"
  fi
  [[ "$GITHUB_OWNER/$GITHUB_REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] \
    || die "GITHUB_OWNER/GITHUB_REPO='$GITHUB_OWNER/$GITHUB_REPO' is not a valid owner/repo"
  ok "agents will work in $GITHUB_OWNER/$GITHUB_REPO"

  # Tokens: env, else the ones already in the cluster. Never fall back to a placeholder — the gateway
  # would inject it and every GitHub call would fail far from the cause.
  local w="$WRITER_PAT" r="$REVIEWER_PAT"
  [ -n "$w" ] || w="$(secret_token "$GITHUB_SECRET_WRITER")"
  [ -n "$r" ] || r="$(secret_token "$GITHUB_SECRET_REVIEWER")"
  if [ -z "$w" ] || [ -z "$r" ]; then
    die "set WRITER_PAT and REVIEWER_PAT (GitHub tokens the gateway injects for each agent), e.g.
         WRITER_PAT=ghp_... REVIEWER_PAT=ghp_... ./install.sh
       They are stored only as Secrets in $AGW_NS, never in a file."
  fi
  [ -n "$WRITER_PAT" ]   && ok "writer GitHub token: from WRITER_PAT"   || ok "writer GitHub token: keeping the one in the cluster"
  [ -n "$REVIEWER_PAT" ] && ok "reviewer GitHub token: from REVIEWER_PAT" || ok "reviewer GitHub token: keeping the one in the cluster"
  if [ "$w" = "$r" ]; then
    warn "the writer and reviewer use the SAME GitHub token — the gateway still routes by identity, but"
    warn "  both agents act as one GitHub user, so per-agent credentials are not actually demonstrated"
  fi

  # Images: both or neither.
  if { [ -n "$WRITER_IMAGE" ] && [ -z "$REVIEWER_IMAGE" ]; } || { [ -z "$WRITER_IMAGE" ] && [ -n "$REVIEWER_IMAGE" ]; }; then
    die "set both WRITER_IMAGE and REVIEWER_IMAGE, or neither (to build them)"
  fi
  case "$IMAGE_ARCH" in amd64|arm64) ;; *) die "IMAGE_PLATFORM=$IMAGE_PLATFORM: expected linux/amd64 or linux/arm64" ;; esac

  # Resolver for the egress lockdown's DNS rule. Getting this wrong blocks ALL agent DNS.
  if [ -z "$CLUSTER_DNS_IP" ]; then
    CLUSTER_DNS_IP="$(kubectl -n kube-system get svc kube-dns -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)"
  fi
  if [ -z "$CLUSTER_DNS_IP" ]; then
    # EKS Auto Mode has no kube-dns Service; its resolver is the service CIDR's .10, like kube-dns.
    local api; api="$(kubectl -n default get svc kubernetes -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)"
    [[ "$api" =~ ^([0-9]+\.[0-9]+\.[0-9]+)\.[0-9]+$ ]] && CLUSTER_DNS_IP="${BASH_REMATCH[1]}.10"
  fi
  [[ "$CLUSTER_DNS_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || die "could not determine the cluster DNS resolver IP (IPv6 clusters need it set explicitly).
       Set CLUSTER_DNS_IP to the nameserver in a pod's /etc/resolv.conf."
  ok "cluster DNS resolver for the egress lockdown: $CLUSTER_DNS_IP"
}

# ensure_istioctl — an istioctl at exactly ISTIO_VERSION: $ISTIOCTL_PATH, else the one on PATH if it
# matches, else downloaded from the Istio GitHub release and verified against its published sha256.
ensure_istioctl() {
  local major minor patch
  IFS=. read -r major minor patch <<<"${ISTIO_VERSION%%-*}"
  if [ -z "${ISTIO_ALLOW_ZTUNNEL_BUG:-}" ] && [ "$major" = 1 ] \
     && { { [ "$minor" = 30 ] && [ "${patch:-0}" -ge 4 ]; } || [ "$minor" = 31 ]; }; then
    die "ISTIO_VERSION=$ISTIO_VERSION has the ztunnel catch-all ServiceEntry bug (istio/ztunnel#2086):
       egress fails with 'no healthy upstream'. Use 1.32.0-rc.0 or later (or <= 1.30.3), or set
       ISTIO_ALLOW_ZTUNNEL_BUG=1 to proceed anyway."
  fi
  local cand
  for cand in "${ISTIOCTL_PATH:-}" "$(command -v istioctl 2>/dev/null || true)"; do
    [ -n "$cand" ] && [ -x "$cand" ] || continue
    if [ "$("$cand" version --remote=false 2>/dev/null | sed -n 's/^client version: //p' | head -1)" = "$ISTIO_VERSION" ]; then
      ISTIOCTL="$cand"; ok "istioctl $ISTIO_VERSION: $cand"; return 0
    fi
  done

  local os arch asset dir
  case "$(uname -s)" in Darwin) os=osx ;; Linux) os=linux ;; *) die "unsupported OS $(uname -s) for istioctl download" ;; esac
  case "$(uname -m)" in arm64|aarch64) arch=arm64 ;; x86_64|amd64) arch=amd64 ;; *) die "unsupported arch $(uname -m)" ;; esac
  if [ "$os" = osx ] && [ "$arch" = amd64 ]; then asset="istioctl-${ISTIO_VERSION}-osx.tar.gz"
  else asset="istioctl-${ISTIO_VERSION}-${os}-${arch}.tar.gz"; fi
  dir="${XDG_CACHE_HOME:-$HOME/.cache}/agentgateway-egress/istioctl-${ISTIO_VERSION}-${os}-${arch}"
  if [ ! -x "$dir/istioctl" ]; then
    info "downloading istioctl $ISTIO_VERSION ($os/$arch)"
    local tmp; tmp="$(mktemp -d)"
    local url="https://github.com/istio/istio/releases/download/${ISTIO_VERSION}/${asset}"
    curl -fsSL -o "$tmp/$asset" "$url" || { rm -rf "$tmp"; die "download failed: $url"; }
    curl -fsSL -o "$tmp/$asset.sha256" "$url.sha256" || { rm -rf "$tmp"; die "download failed: $url.sha256"; }
    local want got
    want="$(awk '{print $1}' "$tmp/$asset.sha256")"
    if command -v shasum >/dev/null 2>&1; then got="$(shasum -a 256 "$tmp/$asset" | awk '{print $1}')"
    else got="$(sha256sum "$tmp/$asset" | awk '{print $1}')"; fi
    [ -n "$want" ] && [ "$want" = "$got" ] \
      || { rm -rf "$tmp"; die "istioctl checksum mismatch for $asset (want $want, got $got)"; }
    mkdir -p "$dir"
    tar -xzf "$tmp/$asset" -C "$dir" istioctl
    rm -rf "$tmp"
  fi
  ISTIOCTL="$dir/istioctl"
  ok "istioctl $ISTIO_VERSION: $ISTIOCTL (checksum verified)"
}

# build_images — stage 0. WRITER_IMAGE/REVIEWER_IMAGE if given, else agents/build-images.sh, which
# pushes content-hash-tagged images to ECR in the cluster's account and region (so nodes pull them
# in-region with their default ECR read permissions).
build_images() {
  if [ -n "$WRITER_IMAGE" ]; then
    info "0/9 agent images: using WRITER_IMAGE / REVIEWER_IMAGE"
    ok "writer:   $WRITER_IMAGE"; ok "reviewer: $REVIEWER_IMAGE"
    return 0
  fi
  info "0/9 building + pushing agent images (agents/build-images.sh)"
  command -v aws >/dev/null 2>&1 || die "building images needs the aws CLI — or set WRITER_IMAGE and REVIEWER_IMAGE"
  [ -n "$AWS_ACCOUNT_ID" ] || AWS_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text 2>/dev/null || true)"
  [[ "$AWS_ACCOUNT_ID" =~ ^[0-9]{12}$ ]] \
    || die "no usable AWS credentials to push images — authenticate, or set WRITER_IMAGE and REVIEWER_IMAGE"
  local out
  out="$(AWS_ACCOUNT_ID="$AWS_ACCOUNT_ID" IMAGE_REGION="${AWS_REGION:-us-east-1}" IMAGE_PLATFORM="$IMAGE_PLATFORM" \
         "${SCRIPT_DIR}/agents/build-images.sh")" || die "agent image build failed (see above)"
  WRITER_IMAGE="$(sed -n 's/^WRITER_IMAGE=//p' <<<"$out")"
  REVIEWER_IMAGE="$(sed -n 's/^REVIEWER_IMAGE=//p' <<<"$out")"
  [ -n "$WRITER_IMAGE" ] && [ -n "$REVIEWER_IMAGE" ] || die "build-images.sh did not report the image URIs"
  ok "writer:   $WRITER_IMAGE"; ok "reviewer: $REVIEWER_IMAGE"
}

# resolve_aws_context — decide whether the Bedrock path can be installed, filling in whatever the
# caller did not supply. Sets BEDROCK_ENABLED.
#
# This deliberately DOES NOT fail the run when AWS is unavailable. Bedrock is one of two egress
# providers here; the GitHub MCP path needs no AWS at all. A missing account ID or a non-EKS cluster
# downgrades to a GitHub-MCP-only install with a loud warning rather than blocking everything.
#
# Auto-derivation:
#   AWS_ACCOUNT_ID  <- the EKS kube-context ARN, else `aws sts get-caller-identity`
#   CLUSTER_NAME    <- the EKS kube-context ARN (arn:aws:eks:<region>:<acct>:cluster/<name>)
#   AWS_REGION      <- the same ARN, else us-east-1
resolve_aws_context() {
  # EXPLICIT BY DEFAULT. Pod Identity is a required part of this install: the Bedrock backends sign
  # with SigV4 as a per-agent IAM role and there is no credential Secret to fall back on. So a missing
  # prerequisite is a HARD FAILURE with remediation, never a silent downgrade.
  # Silently continuing without Bedrock would let the install "succeed" and surface the failure later
  # as an opaque runtime credential error, so opting out is something you have to say out loud.
  if [ -n "$SKIP_POD_IDENTITY" ]; then
    warn "SKIP_POD_IDENTITY=1 — Bedrock IAM/Pod Identity AND the Bedrock manifests are being skipped"
    warn "  this is an EXPLICIT opt-out. The GitHub MCP egress path is unaffected."
    return 0
  fi
  if ! command -v aws >/dev/null 2>&1; then
    die "aws CLI not found on PATH, but Pod Identity setup is required.
       Install the AWS CLI, or opt out explicitly with:  SKIP_POD_IDENTITY=1 ./install.sh"
  fi

  local ctx; ctx="$(kubectl config current-context 2>/dev/null || true)"
  if [[ "$ctx" =~ ^arn:aws[a-z-]*:eks:([a-z0-9-]+):([0-9]{12}):cluster/(.+)$ ]]; then
    [ -n "$AWS_REGION" ]     || AWS_REGION="${BASH_REMATCH[1]}"
    [ -n "$AWS_ACCOUNT_ID" ] || AWS_ACCOUNT_ID="${BASH_REMATCH[2]}"
    [ -n "$CLUSTER_NAME" ]   || CLUSTER_NAME="${BASH_REMATCH[3]}"
    ok "derived from kube-context: cluster=$CLUSTER_NAME region=$AWS_REGION account=$AWS_ACCOUNT_ID"
  fi
  [ -n "$AWS_REGION" ] || AWS_REGION="us-east-1"

  # Derive the BEDROCK region from the backend manifests, so the IAM inference-profile ARN always
  # matches the region the gateway actually calls. Hardcoding or reusing AWS_REGION here is the bug
  # that grants a profile ARN in the cluster's region while the gateway invokes another, producing an
  # AccessDenied long after setup appears to have succeeded.
  if [ -z "$BEDROCK_REGION" ]; then
    BEDROCK_REGION="$(grep -hoE '^[[:space:]]*region:[[:space:]]*"?[a-z0-9-]+' \
      "${SCRIPT_DIR}/bedrock/bedrock-cooperative-backend.yaml" \
      "${SCRIPT_DIR}/bedrock/bedrock-transparent-backend.yaml" 2>/dev/null \
      | grep -oE '[a-z]{2}-[a-z]+-[0-9]+' | sort -u | head -1)"
  fi
  [ -n "$BEDROCK_REGION" ] || BEDROCK_REGION="us-east-1"
  # If the manifests disagree with each other, the IAM policy can only match one of them.
  local distinct
  distinct="$(grep -hoE '^[[:space:]]*region:[[:space:]]*"?[a-z0-9-]+' \
    "${SCRIPT_DIR}/bedrock/bedrock-cooperative-backend.yaml" \
    "${SCRIPT_DIR}/bedrock/bedrock-transparent-backend.yaml" 2>/dev/null \
    | grep -oE '[a-z]{2}-[a-z]+-[0-9]+' | sort -u | wc -l | tr -d ' ')"
  if [ "${distinct:-1}" -gt 1 ]; then
    die "the Bedrock backends name more than one region. The IAM inference-profile ARN can only cover
       one, so pick a single region in bedrock-cooperative-backend.yaml and bedrock-transparent-backend.yaml,
       or set BEDROCK_REGION explicitly."
  fi
  ok "bedrock region (from the backend manifests): $BEDROCK_REGION"

  if [ -z "$AWS_ACCOUNT_ID" ]; then
    AWS_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text 2>/dev/null || true)"
    [ -n "$AWS_ACCOUNT_ID" ] && [ "$AWS_ACCOUNT_ID" != "None" ] \
      && ok "account $AWS_ACCOUNT_ID resolved via aws sts"
  fi

  if [ -z "$AWS_ACCOUNT_ID" ] || [ "$AWS_ACCOUNT_ID" = "None" ]; then
    die "no usable AWS credentials — cannot create the Bedrock IAM roles or the Pod Identity association.
       Authenticate to AWS (e.g. 'aws sso login') and re-run, or opt out explicitly with:
         SKIP_POD_IDENTITY=1 ./install.sh"
  fi
  # The roleArn regex requires exactly 12 digits; catch a malformed value before it reaches the API.
  if ! [[ "$AWS_ACCOUNT_ID" =~ ^[0-9]{12}$ ]]; then
    die "AWS_ACCOUNT_ID='$AWS_ACCOUNT_ID' is not 12 digits — the CRD's roleArn pattern would reject it"
  fi
  if [ -z "$CLUSTER_NAME" ]; then
    die "CLUSTER_NAME could not be derived (the kube-context is not an EKS cluster ARN).
       Pod Identity needs the EKS cluster name. Set it and re-run:
         CLUSTER_NAME=<your-eks-cluster> ./install.sh
       Or opt out explicitly with:  SKIP_POD_IDENTITY=1 ./install.sh"
  fi
  # A mismatch here would create roles in one account and reference them from another.
  local caller; caller="$(aws sts get-caller-identity --query Account --output text 2>/dev/null || true)"
  if [ -n "$caller" ] && [ "$caller" != "None" ] && [ "$caller" != "$AWS_ACCOUNT_ID" ]; then
    die "AWS_ACCOUNT_ID=$AWS_ACCOUNT_ID but current credentials are for $caller — refusing to create roles in one account and reference them from another"
  fi
  [ -x "${SCRIPT_DIR}/${POD_IDENTITY_SCRIPT}" ] \
    || die "${POD_IDENTITY_SCRIPT} missing or not executable (chmod +x it)"

  BEDROCK_ENABLED="true"
  ok "Bedrock enabled: account=$AWS_ACCOUNT_ID cluster=$CLUSTER_NAME region=$AWS_REGION"
}

# validate_manifests — client-side dry-run EVERY manifest before applying ANY of them.
#
# Why this exists: the script runs under `set -e`, and manifests are applied in dependency order in
# eight stages. A single malformed or schema-invalid file would abort the run mid-way, leaving a
# HALF-CONFIGURED cluster — routes applied but agents not, or a network policy applied but its fix
# not. That failure is confusing to debug because the symptom (agents cannot resolve DNS, connections
# time out) shows up far from the cause.
#
# A client-side dry run catches YAML errors (including duplicate mapping keys, which kubectl rejects)
# without needing the CRDs to exist yet. It does NOT catch CRD schema violations — those need
# --dry-run=server, which requires the CRDs to be installed, so the per-stage applies remain the real
# gate for those. Run `./install.sh --validate` any time to check the manifests alone.
validate_manifests() {
  info "validating all manifests (client-side dry run)"
  local all=( "${SHARED_MANIFESTS[@]}" "${GITHUB_MCP_MANIFESTS[@]}" "${BEDROCK_MANIFESTS[@]}" \
              "${RATELIMIT_MANIFESTS[@]}" "${AGENT_MANIFESTS[@]}" \
              gateway/agentgateway-parameters.yaml gateway/gateway.yaml gateway/namespaces.yaml )
  local m failed=0 deferred=0 rendered errf
  errf="$(mktemp)"
  for m in "${all[@]}"; do
    local file="${SCRIPT_DIR}/$m"
    if [ ! -f "$file" ]; then
      err "missing manifest: $m"; failed=$((failed+1)); continue
    fi
    # Rendered with the real inputs where already resolved; dummies for the rest (the images, for
    # one, are not built until stage 0), so the placeholders themselves never fail parsing.
    if ! rendered="$(RENDER_DUMMY=1 render "$m" 2>"$errf")"; then
      err "$m"; sed 's/^/       /' "$errf" >&2; failed=$((failed+1)); continue
    fi
    if ! kubectl apply --dry-run=client -f - <<<"$rendered" >/dev/null 2>"$errf"; then
      # Client-side dry run still needs API discovery for each kind, so on a fresh cluster every
      # Istio / Agent Gateway kind fails with "no matches for kind" — the CRDs are installed by stages
      # 1-3, after this check. If that is the ONLY error, defer to the per-stage apply rather than
      # blocking the install forever.
      if ! grep -vE 'no matches for kind|ensure CRDs are installed first|^[[:space:]]*$' "$errf" \
           | grep -q .; then
        deferred=$((deferred+1)); continue
      fi
      err "$m"
      sed 's/^/       /' "$errf" >&2
      failed=$((failed+1))
    fi
  done
  rm -f "$errf"
  if [ "$failed" -ne 0 ]; then
    die "$failed manifest(s) failed validation — fix them before installing (nothing was applied)"
  fi
  if [ "$deferred" -ne 0 ]; then
    warn "$deferred manifest(s) use CRDs not installed yet — validated by their per-stage apply instead"
  fi
  ok "all ${#all[@]} manifests parse and validate client-side"
}

install_istio() {
  info "1/9 installing Istio $ISTIO_VERSION (ambient profile)"
  # Never silently reconfigure someone else's mesh: an existing istiod at another version, or one
  # without ztunnel (not ambient), is only changed with ISTIO_UPGRADE=1.
  local image have=""
  image="$(kubectl -n istio-system get deploy istiod -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)"
  if [ -n "$image" ]; then
    have="${image##*:}"; have="${have%-distroless}"
    local ambient=""
    kubectl -n istio-system get ds ztunnel >/dev/null 2>&1 && ambient=1
    if [ "$have" = "$ISTIO_VERSION" ] && [ -n "$ambient" ]; then
      ok "Istio $have (ambient) already installed — skipping"
      return 0
    fi
    if [ -z "$ISTIO_UPGRADE" ]; then
      die "this cluster already runs Istio ${have:-<unknown>}$([ -n "$ambient" ] || echo ' WITHOUT ambient/ztunnel').
       Installing $ISTIO_VERSION in ambient mode would change it. Re-run with ISTIO_UPGRADE=1 to
       proceed, or ISTIO_VERSION=$have if that version is acceptable (see 'WHY ISTIO IS PINNED')."
    fi
    warn "ISTIO_UPGRADE=1 — changing the existing Istio ${have:-<unknown>} to $ISTIO_VERSION (ambient)"
  fi
  "$ISTIOCTL" install --set profile=ambient --skip-confirmation
  ok "Istio $ISTIO_VERSION ambient installed"
}

# install_gateway_api — make sure EVERY CRD in the Gateway API standard bundle exists.
#
# Checking for `gateways` alone is not enough: EKS can manage a SUBSET of the Gateway API CRDs (seen
# without BackendTLSPolicy, which github/github-mcp-backend.yaml needs), and stage 7 would then fail.
# Only the missing CRDs are applied, so existing — possibly EKS-managed — CRDs are never modified.
install_gateway_api() {
  info "2/9 ensuring Gateway API CRDs ($GATEWAY_API_VERSION standard)"
  local url="https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"
  if ! kubectl get crd gateways.gateway.networking.k8s.io >/dev/null 2>&1; then
    kubectl apply --server-side -f "$url" >/dev/null
    ok "Gateway API CRDs installed (full bundle)"
    return 0
  fi
  local tmp; tmp="$(mktemp -d)"
  curl -fsSL -o "$tmp/bundle.yaml" "$url" || { rm -rf "$tmp"; die "download failed: $url"; }
  local names missing=() n
  names="$(sed -n 's/^  name: \([a-z]*\.gateway\.networking\.k8s\.io\)$/\1/p' "$tmp/bundle.yaml" | sort -u)"
  for n in $names; do
    kubectl get crd "$n" >/dev/null 2>&1 || missing+=("$n")
  done
  if [ "${#missing[@]}" -eq 0 ]; then
    ok "all Gateway API standard CRDs already present — skipping"
    rm -rf "$tmp"; return 0
  fi
  # Extract just the missing CRDs from the multi-document bundle.
  python3 -I -c '
import sys
docs = open(sys.argv[1]).read().split("\n---\n")
want = set(sys.argv[2:])
out = [d for d in docs if "kind: CustomResourceDefinition" in d
       and any(f"\n  name: {n}\n" in d + "\n" for n in want)]
sys.stdout.write("\n---\n".join(out) + "\n")
' "$tmp/bundle.yaml" "${missing[@]}" >"$tmp/missing.yaml"
  kubectl apply --server-side -f "$tmp/missing.yaml" >/dev/null
  for n in "${missing[@]}"; do
    kubectl wait --for=condition=Established "crd/$n" --timeout=60s >/dev/null
  done
  rm -rf "$tmp"
  ok "installed missing Gateway API CRDs: ${missing[*]} (existing CRDs left untouched)"
}

install_agentgateway() {
  info "3/9 installing Agent Gateway CRDs (Helm)"
  helm upgrade -i agentgateway-crds oci://cr.agentgateway.dev/charts/agentgateway-crds \
    --create-namespace --namespace "$AGW_NS" \
    --version "$AGW_VERSION" \
    --set controller.image.pullPolicy=Always
  ok "Agent Gateway CRDs installed"

  info "installing Agent Gateway control plane (Helm)"
  helm upgrade -i agentgateway oci://cr.agentgateway.dev/charts/agentgateway \
    --namespace "$AGW_NS" \
    --version "$AGW_VERSION" \
    --set controller.image.pullPolicy=Always \
    --wait
  ok "Agent Gateway control plane installed"
}

enroll_namespaces() {
  info "4/9 creating agent namespaces enrolled in the ambient mesh ($AGENT_NS_1, $AGENT_NS_2)"
  apply_manifest gateway/namespaces.yaml
  ok "namespaces $AGENT_NS_1, $AGENT_NS_2 created and ambient-enrolled"
}

# install_pod_identity — stage 5. Delegates to bedrock/setup-pod-identity.sh, which owns all the IAM
# detail (trust policies, model ARNs, the eks-pod-identity-agent addon) and is independently runnable
# and idempotent.
#
# WHY BEFORE THE GATEWAY (stage 5 before stage 6): a Pod Identity association is just a
# (cluster, namespace, serviceAccount) -> role mapping and does not require the ServiceAccount to
# exist. Creating it first means the gateway proxy pod picks up AWS credentials on its FIRST start,
# so no `rollout restart` is needed afterwards.
install_pod_identity() {
  if [ "$BEDROCK_ENABLED" != "true" ]; then
    info "5/9 Bedrock IAM + Pod Identity SKIPPED (explicit SKIP_POD_IDENTITY opt-out)"
    return 0
  fi
  info "5/9 creating Bedrock IAM roles + EKS Pod Identity association"
  AWS_ACCOUNT_ID="$AWS_ACCOUNT_ID" \
  CLUSTER_NAME="$CLUSTER_NAME" \
  AWS_REGION="$AWS_REGION" \
  BEDROCK_REGION="$BEDROCK_REGION" \
  GATEWAY_SA="$GATEWAY_NAME" AGW_INSTALL_SH=1 \
    "${SCRIPT_DIR}/${POD_IDENTITY_SCRIPT}" setup \
    || die "Pod Identity setup failed. Diagnose with:
       CLUSTER_NAME=$CLUSTER_NAME AWS_REGION=$AWS_REGION ./bedrock/setup-pod-identity.sh --diagnose"

  # ASSERT the association exists. setup-pod-identity.sh is deliberately non-fatal about the agent
  # addon (Auto Mode provides it built-in), so "the script exited 0" is not proof the association was
  # created. Check the thing that actually matters.
  # NOTE: list-pod-identity-associations returns PodIdentityAssociationSummary, which DOES NOT include
  # roleArn — AWS explicitly strips it from the summary. Querying associations[0].roleArn therefore
  # returns "None" even when the association exists, which made this assertion fail 100% of the time
  # against a perfectly good setup. Use associationId (which IS in the summary) to test existence, then
  # describe it if you want the role.
  local assoc_id assoc_role
  assoc_id="$(aws eks list-pod-identity-associations \
    --cluster-name "$CLUSTER_NAME" --namespace "$AGW_NS" --service-account "$GATEWAY_NAME" \
    --region "$AWS_REGION" --query 'associations[0].associationId' --output text 2>/dev/null || echo None)"
  [ "$assoc_id" != "None" ] && [ -n "$assoc_id" ] \
    || die "Pod Identity association for ${AGW_NS}/${GATEWAY_NAME} does not exist after setup.
       Without it the proxy gets no AWS credentials and every Bedrock call fails with
       'an error occurred while loading credentials'. Diagnose with:
         CLUSTER_NAME=$CLUSTER_NAME AWS_REGION=$AWS_REGION ./bedrock/setup-pod-identity.sh --diagnose"
  # roleArn requires describe, not list.
  assoc_role="$(aws eks describe-pod-identity-association \
    --cluster-name "$CLUSTER_NAME" --association-id "$assoc_id" --region "$AWS_REGION" \
    --query 'association.roleArn' --output text 2>/dev/null || echo '<unknown>')"
  ok "association verified: ${AGW_NS}/${GATEWAY_NAME} -> ${assoc_role} (${assoc_id})"
}

# assert_proxy_credentials — the gate that would have caught this session's failure.
#
# Creating the association is not enough. The EKS Pod Identity webhook injects
# AWS_CONTAINER_CREDENTIALS_FULL_URI only at POD CREATION, so a proxy that started before the
# association existed never receives credentials — and nothing about the running system looks wrong
# until a request needs to sign. On EKS Auto Mode there is no fallback either, because Auto Mode nodes
# launch with IMDS hop limit = 1, so the credential chain simply times out (~1s) and returns
# "an error occurred while loading credentials".
#
# So: wait for the proxy, verify the ServiceAccount matches, verify the env vars landed, restart once
# if they did not, and FAIL THE INSTALL if they still have not. Explicit beats hopeful.
# proxy_aws_env — the AWS_* env var NAMES on the gateway proxy pods, one per line.
proxy_aws_env() {
  kubectl -n "$AGW_NS" get pods -l app=agentgateway-egress \
    -o jsonpath='{.items[*].spec.containers[*].env[*].name}' 2>/dev/null \
    | tr ' ' '\n' | grep -E '^AWS_' | sort -u || true
}

assert_proxy_credentials() {
  [ "$BEDROCK_ENABLED" = "true" ] || return 0
  info "verifying the proxy received Pod Identity credentials"

  # 1. Wait for the controller to provision the proxy Deployment.
  local i actual_sa=""
  for i in $(seq 1 24); do
    actual_sa="$(kubectl -n "$AGW_NS" get deploy "$GATEWAY_NAME" \
      -o jsonpath='{.spec.template.spec.serviceAccountName}' 2>/dev/null || true)"
    [ -n "$actual_sa" ] && break
    sleep 5
  done
  [ -n "$actual_sa" ] || die "deploy/${GATEWAY_NAME} never appeared in $AGW_NS — the Gateway did not provision.
       Check: kubectl -n $AGW_NS get gateway $GATEWAY_NAME -o yaml"

  # 2. The association targets a ServiceAccount name we derived from the Gateway name. If the
  #    controller used a different one, credentials can never arrive — that is fatal, not a warning.
  if [ "$actual_sa" != "$GATEWAY_NAME" ]; then
    die "the proxy runs as ServiceAccount '${actual_sa}' but the Pod Identity association targets
       '${GATEWAY_NAME}'. Credentials will never be injected. Recreate the association:
         GATEWAY_SA=${actual_sa} CLUSTER_NAME=$CLUSTER_NAME AWS_REGION=$AWS_REGION \\
           ./bedrock/setup-pod-identity.sh setup
         kubectl -n $AGW_NS rollout restart deploy/${GATEWAY_NAME}"
  fi
  ok "proxy ServiceAccount '${actual_sa}' matches the association"

  # 3. Wait for a pod, then look for the injected variables. Retry once with a restart.
  local attempt envs
  for attempt in 1 2; do
    kubectl -n "$AGW_NS" rollout status deploy/"$GATEWAY_NAME" --timeout=120s >/dev/null 2>&1 || true
    envs="$(proxy_aws_env)"
    if grep -q AWS_CONTAINER_CREDENTIALS_FULL_URI <<<"$envs"; then
      ok "Pod Identity credentials injected into the proxy:"
      printf '       %s\n' $envs
      return 0
    fi
    if [ "$attempt" -eq 1 ]; then
      warn "no AWS_CONTAINER_CREDENTIALS_FULL_URI on the proxy — it likely started before the"
      warn "  association existed. Restarting it once (the webhook only injects at pod creation)."
      kubectl -n "$AGW_NS" rollout restart deploy/"$GATEWAY_NAME" >/dev/null 2>&1 || true
    fi
  done

  die "the proxy still has no Pod Identity credentials after a restart.
       Every Bedrock call will fail with 'an error occurred while loading credentials'.
       On EKS Auto Mode there is no IMDS fallback (hop limit = 1), so this fails hard.
       Diagnose with:
         CLUSTER_NAME=$CLUSTER_NAME AWS_REGION=$AWS_REGION ./bedrock/setup-pod-identity.sh --diagnose"
}

PROXY_EXISTED=""
install_gateway() {
  kubectl -n "$AGW_NS" get deploy "$GATEWAY_NAME" >/dev/null 2>&1 && PROXY_EXISTED=1
  info "6/9 applying AgentgatewayParameters + Gateway in $AGW_NS"
  # Parameters first: the Gateway's infrastructure.parametersRef points at this object.
  apply_manifest gateway/agentgateway-parameters.yaml
  ok "AgentgatewayParameters applied"
  apply_manifest gateway/gateway.yaml
  ok "Gateway ${GATEWAY_NAME} applied (HTTP :80 + HBONE :15008)"

  # Stage 5 created the association before the Gateway existed, so the proxy's first pod should come
  # up already holding credentials. Prove it rather than assume it — this gate is fail-closed.
  assert_proxy_credentials
}

# create_github_secrets — the per-agent GitHub credential Secrets, from WRITER_PAT / REVIEWER_PAT.
#
# The token goes to kubectl through a file descriptor, not argv, so it never shows up in `ps`. An
# unset PAT keeps the token already in the cluster (resolve_inputs refused to continue without one).
# Returns 0 if a Secret actually changed, so the caller can restart the proxy to pick it up.
GITHUB_SECRETS_CHANGED=""
create_github_secrets() {
  local pair name pat
  for pair in "$GITHUB_SECRET_WRITER:$WRITER_PAT" "$GITHUB_SECRET_REVIEWER:$REVIEWER_PAT"; do
    name="${pair%%:*}"; pat="${pair#*:}"
    if [ -z "$pat" ]; then ok "secret $name: unchanged (kept the existing token)"; continue; fi
    if [ "$(secret_token "$name")" = "$pat" ]; then ok "secret $name: already up to date"; continue; fi
    kubectl -n "$AGW_NS" create secret generic "$name" \
      --from-file=Authorization=<(printf 'Bearer %s' "$pat") --dry-run=client -o yaml \
      | kubectl apply -f - >/dev/null
    GITHUB_SECRETS_CHANGED=1
    ok "secret $name: written"
  done
}

install_gateway_config() {
  info "7/9 applying egress config (shared identity stamp + GitHub MCP + Bedrock LLM)"
  local m
  for m in "${SHARED_MANIFESTS[@]}"; do
    apply_manifest "$m"
    ok "applied $m"
  done
  create_github_secrets
  for m in "${GITHUB_MCP_MANIFESTS[@]}"; do
    apply_manifest "$m"
    ok "applied $m"
  done
  if [ "$BEDROCK_ENABLED" = "true" ]; then
    for m in "${BEDROCK_MANIFESTS[@]}"; do
      apply_manifest "$m"; ok "applied $m"
    done
    bedrock_health_gate
  else
    warn "skipped ${#BEDROCK_MANIFESTS[@]} Bedrock manifest(s) — they name IAM roles that stage 5 did not create"
  fi
  # A rotated token on a RE-run: restart the proxy so no connection keeps using the old one. (On a
  # first install the Secrets exist before any backend references them, so nothing to restart.)
  if [ -n "$GITHUB_SECRETS_CHANGED" ] && [ -n "$PROXY_EXISTED" ]; then
    kubectl -n "$AGW_NS" rollout restart deploy/"$GATEWAY_NAME" >/dev/null
    kubectl -n "$AGW_NS" rollout status deploy/"$GATEWAY_NAME" --timeout=180s >/dev/null
    ok "restarted deploy/$GATEWAY_NAME to pick up the new GitHub token(s)"
  fi
}

# bedrock_health_gate — verify the proxy ACCEPTED the config we just pushed.
#
# Why this is worth a dedicated check: a backend the control plane cannot translate is not a
# Bedrock-only failure. The proxy can reject the whole xDS push, which leaves it with no working
# listeners, and then EVERY egress path times out — including GitHub MCP, which we did not touch.
# That symptom (ConnectTimeout everywhere) is nearly impossible to trace back to one backend field, so
# surface it here, immediately after the apply that could cause it.
bedrock_health_gate() {
  local bad
  bad="$(kubectl -n "$AGW_NS" get agentgatewaybackend -o json 2>/dev/null \
    | jq -r '.items[] | select(
        [.status.conditions[]? | select(.type=="Accepted" and .status!="True")] | length > 0
      ) | "  \(.metadata.name): \([.status.conditions[]? | select(.type=="Accepted")] | map("\(.status) \(.reason // "") \(.message // "")") | join("; "))"' 2>/dev/null || true)"
  if [ -n "$bad" ]; then
    err "one or more AgentgatewayBackends were NOT accepted:"
    printf '%s\n' "$bad" >&2
    die "fix the backend config before continuing — a rejected config can take the whole proxy's listeners down"
  fi
  ok "all AgentgatewayBackends report Accepted=True"

  # A config the API server accepted can still be NACKed by the data plane. Non-fatal (the metric may
  # be unavailable depending on build/version) but worth surfacing.
  local nack
  nack="$(kubectl -n "$AGW_NS" exec deploy/"$GATEWAY_NAME" -- \
    curl -s --max-time 5 localhost:15020/metrics 2>/dev/null | grep -iE '^agentgateway_xds.*nack.* [1-9]' || true)"
  if [ -n "$nack" ]; then
    warn "the proxy reports xDS config rejections (NACK) — listeners may be stale:"
    printf '  %s\n' "$nack"
    warn "  inspect with: kubectl -n $AGW_NS logs deploy/$GATEWAY_NAME | grep -i -E 'nack|reject'"
  fi
}

install_ratelimit() {
  info "8/9 applying rate limit infrastructure (Envoy rate limit service + Redis)"
  local m
  for m in "${RATELIMIT_MANIFESTS[@]}"; do
    apply_manifest "$m"
    ok "applied $m"
  done
  ok "rate limits wired: llm-tokens (per-identity token budget) on the LLM routes, agentgateway (60 req/min per identity) on the GitHub MCP route"
}

install_agents() {
  info "9/9 applying agent workloads"
  local m lockdown=1
  # The egress lockdown is an ApplicationNetworkPolicy, enforced by EKS Auto Mode / the VPC CNI
  # network policy controller. Without that CRD the object cannot even be created; say so loudly
  # rather than failing the install or pretending egress is locked down.
  if ! kubectl get crd applicationnetworkpolicies.networking.k8s.aws >/dev/null 2>&1; then
    lockdown=""
  fi
  for m in "${AGENT_MANIFESTS[@]}"; do
    if [ "$m" = agents/appnetworkpolicy.yaml ] && [ -z "$lockdown" ]; then
      warn "skipped $m — this cluster has no ApplicationNetworkPolicy CRD (needs EKS Auto Mode or the"
      warn "  VPC CNI network policy controller). Agent egress is NOT locked down to the gateway."
      continue
    fi
    apply_manifest "$m"
    ok "applied $m"
  done
  local d
  for d in "${AGENT_DEPLOYMENTS[@]}"; do
    kubectl -n "${d%%/*}" rollout status deploy/"${d##*/}" --timeout=300s >/dev/null \
      || die "deploy/${d##*/} in ${d%%/*} did not become ready. Check:
         kubectl -n ${d%%/*} describe pods -l app=${d##*/}"
    ok "deploy/${d##*/} ready"
  done
  [ -n "$lockdown" ] && ok "egress lockdown applied on $AGENT_NS_1 and $AGENT_NS_2 (all egress must traverse the gateway)"
  return 0
}

# smoke_test — prove the paths work, from INSIDE each agent pod, as each agent's identity:
#   cooperative pods:  GitHub MCP `initialize` + an OpenAI chat completion to the gateway
#   transparent pods:  GitHub MCP `initialize` + a Bedrock Converse call to the real Bedrock host
# Running in the agent pods means the requests carry the real SPIFFE identity, go through ztunnel
# and the egress lockdown, and resolve DNS through the rendered resolver rule. The pods hold no
# credential, so a 200 means the gateway injected the right one.
SMOKE_PY='
import json, os, sys, urllib.parse, urllib.request
def post(url, body, headers):
    req = urllib.request.Request(url, json.dumps(body).encode(), {"Content-Type": "application/json", **headers})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return r.status, r.read(200)
    except urllib.error.HTTPError as e:
        return e.code, e.read(200)
    except Exception as e:
        return 0, repr(e).encode()
failed = False
for check in sys.argv[1].split(","):
    if check == "github-mcp":
        status, body = post(os.environ["MCP_ENDPOINT"], {"jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": {"protocolVersion": "2025-06-18", "capabilities": {},
                       "clientInfo": {"name": "install-smoke-test", "version": "0"}}},
            {"Accept": "application/json, text/event-stream"})
    elif check == "llm-cooperative":
        status, body = post(os.environ["LLM_ENDPOINT"].rstrip("/") + "/chat/completions",
            {"model": os.environ.get("COOPERATIVE_MODEL", ""), "max_tokens": 5,
             "messages": [{"role": "user", "content": "Reply with ok"}]}, {})
    elif check == "llm-transparent":
        model = urllib.parse.quote(os.environ["BEDROCK_MODEL"], safe="")
        status, body = post(os.environ["BEDROCK_ENDPOINT"].rstrip("/") + "/model/" + model + "/converse",
            {"messages": [{"role": "user", "content": [{"text": "Reply with ok"}]}],
             "inferenceConfig": {"maxTokens": 5}}, {})
    print(f"{check} {status} {body[:160]!r}")
    failed |= status != 200
sys.exit(1 if failed else 0)
'
smoke_test() {
  if [ -n "$SKIP_SMOKE_TEST" ]; then
    warn "SKIP_SMOKE_TEST=1 — end-to-end checks skipped"; return 0
  fi
  info "smoke test: GitHub MCP + LLM calls through the gateway, as each agent identity"
  local d checks out line failed=0
  for d in "${AGENT_DEPLOYMENTS[@]}"; do
    checks="github-mcp"
    if [ "$BEDROCK_ENABLED" = "true" ]; then
      case "$d" in *-cooperative) checks="$checks,llm-cooperative" ;; *-transparent) checks="$checks,llm-transparent" ;; esac
    fi
    if out="$(kubectl -n "${d%%/*}" exec deploy/"${d##*/}" -- python -c "$SMOKE_PY" "$checks" 2>&1)"; then
      while read -r line; do ok "${d##*/}: ${line%% *} -> 200"; done <<<"$out"
    else
      failed=1
      while read -r line; do
        case "$line" in *" 200 "*) ok "${d##*/}: ${line%% *} -> 200" ;; *) err "${d##*/}: $line" ;; esac
      done <<<"$out"
    fi
  done
  if [ "$failed" -ne 0 ]; then
    die "smoke test FAILED — the stack is installed but at least one egress path does not work.
       401/403 on github-mcp     -> check WRITER_PAT / REVIEWER_PAT (scopes, expiry)
       502 'backend authentication failed' -> ./bedrock/setup-pod-identity.sh --diagnose
       403 AccessDeniedException -> model not enabled in Bedrock, or not in the IAM allow-list
       0 (connection error)      -> DNS / egress lockdown (CLUSTER_DNS_IP=$CLUSTER_DNS_IP) or ztunnel
       Gateway log: kubectl -n $AGW_NS logs deploy/$GATEWAY_NAME | grep -E 'error|status=[45]'"
  fi
  ok "smoke test passed: every agent identity reached GitHub MCP$([ "$BEDROCK_ENABLED" = true ] && echo ' and Bedrock') through the gateway"
}

verify() {
  info "verification — components should report Ready/Programmed"
  echo
  info "Istio ambient pods (istiod, istio-cni, ztunnel):"
  kubectl -n istio-system get pods 2>/dev/null || warn "istio-system not found"
  echo
  info "Agent Gateway control plane pods ($AGW_NS):"
  kubectl -n "$AGW_NS" get pods 2>/dev/null || warn "$AGW_NS not found"
  echo
  info "ambient-enrolled namespaces:"
  kubectl get ns "$AGENT_NS_1" "$AGENT_NS_2" \
    -L istio.io/dataplane-mode 2>/dev/null || warn "agent namespaces not found"
  echo
  info "Gateway listener status:"
  kubectl -n "$AGW_NS" get gateway "$GATEWAY_NAME" \
    -o jsonpath='{range .status.listeners[*]}{"  "}{.name}{": Programmed="}{.conditions[?(@.type=="Programmed")].status}{"\n"}{end}' 2>/dev/null \
    || warn "Gateway $GATEWAY_NAME not found (the controller may still be reconciling)"
  echo
  info "GitHub MCP egress config in $AGW_NS:"
  kubectl -n "$AGW_NS" get agentgatewaybackend,backendtlspolicy,httproute,agentgatewaypolicy,serviceentry 2>/dev/null \
    || warn "MCP egress resources not found (CRDs present?)"
  echo
  info "rate limit infrastructure (ratelimit + redis should be Running):"
  kubectl -n ratelimit get pods 2>/dev/null || warn "ratelimit namespace not found"
  echo
  info "agent workloads:"
  kubectl -n "$AGENT_NS_1" get deploy,pods 2>/dev/null || warn "no workloads in $AGENT_NS_1"
  kubectl -n "$AGENT_NS_2" get deploy,pods 2>/dev/null || warn "no workloads in $AGENT_NS_2"
  echo
  if [ "$BEDROCK_ENABLED" = "true" ]; then
    info "Bedrock credentials (Pod Identity — expect AWS_CONTAINER_CREDENTIALS_FULL_URI on the proxy):"
    proxy_aws_env | sed 's/^/  /' | grep . \
      || warn "no AWS_ env vars on the proxy — run ./bedrock/setup-pod-identity.sh --verify"
    echo
    info "full IAM/association check: ./bedrock/setup-pod-identity.sh --verify"
  else
    warn "Bedrock was NOT installed (no AWS context, or SKIP_POD_IDENTITY set)"
    warn "  the GitHub MCP egress path is complete and usable on its own"
  fi
  echo
  ok "install complete. Follow the agents with:
       kubectl -n $AGENT_NS_1 logs -f deploy/writer-agent-cooperative
       kubectl -n $AGENT_NS_2 logs -f deploy/reviewer-agent-cooperative"
}

uninstall() {
  warn "tearing down resources created by install.sh"
  local m
  # AGENT_MANIFESTS includes the egress lockdown, so this removes it too. That matters: leaving the
  # policy behind would silently block egress for any future install.
  for m in "${AGENT_MANIFESTS[@]}"; do delete_manifest "$m"; done
  # Rate limit infra, reverse order (service -> config -> redis -> namespace).
  for (( i=${#RATELIMIT_MANIFESTS[@]}-1; i>=0; i-- )); do delete_manifest "${RATELIMIT_MANIFESTS[$i]}"; done
  # Reverse dependency order for the egress config.
  for (( i=${#BEDROCK_MANIFESTS[@]}-1; i>=0; i-- )); do delete_manifest "${BEDROCK_MANIFESTS[$i]}"; done
  for (( i=${#GITHUB_MCP_MANIFESTS[@]}-1; i>=0; i-- )); do delete_manifest "${GITHUB_MCP_MANIFESTS[$i]}"; done
  for (( i=${#SHARED_MANIFESTS[@]}-1; i>=0; i-- )); do delete_manifest "${SHARED_MANIFESTS[$i]}"; done
  kubectl -n "$AGW_NS" delete gateway "$GATEWAY_NAME" --ignore-not-found >/dev/null 2>&1 || true
  kubectl -n "$AGW_NS" delete agentgatewayparameters egress --ignore-not-found >/dev/null 2>&1 || true
  kubectl delete ns "$AGENT_NS_1" "$AGENT_NS_2" --ignore-not-found >/dev/null 2>&1 || true
  kubectl -n "$AGW_NS" delete secret "$GITHUB_SECRET_WRITER" "$GITHUB_SECRET_REVIEWER" --ignore-not-found >/dev/null 2>&1 || true
  helm uninstall agentgateway --namespace "$AGW_NS" >/dev/null 2>&1 || true
  helm uninstall agentgateway-crds --namespace "$AGW_NS" >/dev/null 2>&1 || true

  # AWS-side teardown: the Pod Identity association and the three IAM roles, via the same script that
  # created them. Deliberately LAST so a failure here cannot block the Kubernetes teardown, and gated
  # on BEDROCK_ENABLED so a run without AWS context is a no-op rather than an error. The
  # eks-pod-identity-agent addon is left installed — it is cluster infrastructure, not ours.
  if [ "$BEDROCK_ENABLED" = "true" ]; then
    info "removing Bedrock IAM roles + Pod Identity association"
    AWS_ACCOUNT_ID="$AWS_ACCOUNT_ID" CLUSTER_NAME="$CLUSTER_NAME" \
    AWS_REGION="$AWS_REGION" BEDROCK_REGION="$BEDROCK_REGION" GATEWAY_SA="$GATEWAY_NAME" \
      "${SCRIPT_DIR}/${POD_IDENTITY_SCRIPT}" --teardown \
      || warn "AWS teardown reported errors — check manually"
  else
    warn "skipped AWS teardown (no AWS context). If roles exist from an earlier run, remove them with:"
    warn "  AWS_ACCOUNT_ID=<acct> CLUSTER_NAME=<cluster> ./bedrock/setup-pod-identity.sh --teardown"
  fi
  # Images are only deleted on request: they are cheap, and rebuilding costs a CodeBuild run.
  if [ -n "$PURGE_IMAGES" ]; then
    info "PURGE_IMAGES=1 — removing the agent image ECR repos + build resources"
    AWS_ACCOUNT_ID="$AWS_ACCOUNT_ID" IMAGE_REGION="${AWS_REGION:-us-east-1}" \
      "${SCRIPT_DIR}/agents/build-images.sh" --teardown || warn "image teardown reported errors — check manually"
  else
    warn "agent images + build resources kept (ECR, CodeBuild). Remove them with PURGE_IMAGES=1 ./install.sh --uninstall"
  fi
  # Istio and the Gateway API CRDs are left in place — remove them explicitly if desired:
  #   istioctl uninstall --purge -y && kubectl delete ns istio-system
  ok "teardown complete (Istio + Gateway API CRDs left intact)"
}

main() {
  case "${1:-install}" in
    install|"")
      use_kube_context
      preflight
      resolve_aws_context
      resolve_inputs
      validate_manifests
      ensure_istioctl
      build_images
      install_istio
      install_gateway_api
      install_agentgateway
      enroll_namespaces
      install_pod_identity
      install_gateway
      install_gateway_config
      install_ratelimit
      install_agents
      smoke_test
      verify
      ;;
    --uninstall|uninstall)
      use_kube_context
      preflight
      resolve_aws_context
      uninstall
      ;;
    --validate|validate)
      use_kube_context
      preflight
      resolve_aws_context
      validate_manifests
      ;;
    *)
      die "unknown argument '${1}'. Use: install | --validate | --uninstall"
      ;;
  esac
}

main "$@"
