#!/usr/bin/env bash
#
# setup-pod-identity.sh — Bedrock credentials without a Secret: EKS Pod Identity plus per-agent IAM
# roles. Called automatically by install.sh (stage 5), and independently runnable.
#
# WHAT THIS BUILDS
#
#   EKS Pod Identity association
#     (cluster, agentgateway-system, <gateway SA>)  ->  role/agentgateway-egress
#
#   role/agentgateway-egress            the gateway proxy's own identity.
#                                       NO Bedrock permissions. Only sts:AssumeRole + sts:TagSession
#                                       on the two agent roles. This is the "source credential" for
#                                       every assumeRole the gateway performs.
#
#   role/agentgateway-bedrock-writer    bedrock:InvokeModel[WithResponseStream] on the writer's models
#   role/agentgateway-bedrock-reviewer  ...same, on the reviewer's models
#                                       Each trusts ONLY role/agentgateway-egress.
#
# The two agent roles are what the AgentgatewayBackends name in
# `policies.auth.aws.assumeRole.roleArn`. Segregation lives in these roles' IAM policies, not in the
# gateway's identity — the gateway is only the principal permitted to become either agent.
#
# WHY POD IDENTITY RATHER THAN IRSA
#   * No OIDC provider to create or maintain per cluster.
#   * The trust policy is a fixed `pods.eks.amazonaws.com` statement — it does not embed a
#     cluster-specific OIDC issuer URL, so the same role definition is portable across clusters.
#   * Associations are managed through the EKS API, so the mapping is visible in
#     `aws eks list-pod-identity-associations` rather than only a ServiceAccount annotation.
# Credentials reach the proxy via AWS_CONTAINER_CREDENTIALS_FULL_URI, which the AWS SDK credential
# chain resolves automatically. Agentgateway's `aws` backend auth with no `secretRef` uses that chain,
# so nothing in the manifests names a credential.
#
# USAGE
#   export AWS_ACCOUNT_ID=123456789012 CLUSTER_NAME=my-cluster AWS_REGION=us-east-1
#   ./setup-pod-identity.sh              # create roles + association
#   ./setup-pod-identity.sh --verify     # check the association and that assumeRole works
#   ./setup-pod-identity.sh --diagnose   # walk the AWS credential chain to find why creds fail to load
#   ./setup-pod-identity.sh --teardown   # remove the association and the three roles
#
# Idempotent: re-running updates the trust and inline policies rather than failing.
#
set -euo pipefail

AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID:-}"
CLUSTER_NAME="${CLUSTER_NAME:-}"
# TWO INDEPENDENT REGIONS. Conflating them is a real bug that produces a confusing AccessDenied:
#
#   AWS_REGION      the region the EKS CLUSTER lives in. Used for every `aws eks` call. If this is
#                   wrong you get "Credential should be scoped to a valid region" or
#                   "cluster not found" — nothing that mentions the region being wrong.
#   BEDROCK_REGION  the region the GATEWAY CALLS BEDROCK IN. Used only to build the inference-profile
#                   ARN in the IAM policy. It must match `region:` in bedrock-*-backend.yaml, which is
#                   us-east-1 — and there is no reason for that to equal the cluster's region.
#
# Getting BEDROCK_REGION wrong grants the agent roles a profile ARN in one region while the gateway
# invokes another, so the association works, credentials load, and then Bedrock returns AccessDenied.
AWS_REGION_SET="${AWS_REGION:-}"   # explicit region wins over the kube-context's (see preflight)
AWS_REGION="${AWS_REGION:-us-east-1}"
BEDROCK_REGION="${BEDROCK_REGION:-us-east-1}"
# Extra Pod Identity service principals for the egress role's trust policy — see egress_trust_policy().
POD_IDENTITY_EXTRA_PRINCIPALS="${POD_IDENTITY_EXTRA_PRINCIPALS:-}"

AGW_NS="agentgateway-system"
# The Agent Gateway controller derives the proxy Deployment (and its ServiceAccount) from the Gateway
# name, which is `egress` (see gateway/gateway.yaml for why it must not be "agentgateway").
# install.sh passes GATEWAY_SA explicitly and re-checks the real SA once the proxy is provisioned.
# Standalone, confirm with:
#   kubectl -n agentgateway-system get deploy egress -o jsonpath='{.spec.template.spec.serviceAccountName}'
GATEWAY_SA="${GATEWAY_SA:-egress}"

EGRESS_ROLE="agentgateway-egress"
WRITER_ROLE="agentgateway-bedrock-writer"
REVIEWER_ROLE="agentgateway-bedrock-reviewer"

# Models each agent may invoke. This list MUST cover every model the agents can actually request:
#   * bedrock-cooperative-backend.yaml priority groups (gateway-steered)  -> sonnet-4-6, nova-lite
#   * the transparent path, where the AGENT names the model in the URL    -> BEDROCK_MODEL in
#                                                                       agents/*-agent-transparent.yaml,
#                                                                       currently sonnet-4-6
# On the transparent path IAM is the ONLY control on model choice, so a model missing here fails at
# runtime with AccessDeniedException from Bedrock (not a credential error).
#
# Inference profiles need BOTH the profile ARN and the underlying foundation-model ARNs. A `global.`
# or `us.` profile routes across regions, so the foundation-model ARNs must cover every region it can
# land in; the wildcard region below is the pragmatic way to express that. Tighten it to an explicit
# region list if your security review requires it.
SONNET_PROFILE="global.anthropic.claude-sonnet-4-6"
# Foundation models addressed directly (no inference profile). Add to this list, not to the policy
# body, so the two agents stay in sync.
FOUNDATION_MODELS=(
  "amazon.nova-micro-v1:0"     # agent.py BEDROCK_MODEL fallback default — transparent path
  "amazon.nova-lite-v1:0"      # cooperative-path fallback tier
)

info() { printf '\033[1;34m----\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m OK \033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARN\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31mFAIL\033[0m %s\n' "$*" >&2; exit 1; }

require() { command -v "$1" >/dev/null 2>&1 || die "$1 not found on PATH"; }

preflight() {
  require aws
  require kubectl
  # Same derivation as install.sh, so `--verify` / `--diagnose` work standalone: an EKS kube-context
  # ARN (arn:aws:eks:<region>:<acct>:cluster/<name>) supplies whatever was not set explicitly.
  local ctx; ctx="$(kubectl config current-context 2>/dev/null || true)"
  if [[ "$ctx" =~ ^arn:aws[a-z-]*:eks:([a-z0-9-]+):([0-9]{12}):cluster/(.+)$ ]]; then
    [ -n "$AWS_REGION_SET" ] || AWS_REGION="${BASH_REMATCH[1]}"
    [ -n "$AWS_ACCOUNT_ID" ] || AWS_ACCOUNT_ID="${BASH_REMATCH[2]}"
    [ -n "$CLUSTER_NAME" ]   || CLUSTER_NAME="${BASH_REMATCH[3]}"
  fi
  [ -n "$AWS_ACCOUNT_ID" ] || AWS_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text 2>/dev/null || true)"
  [ -n "$AWS_ACCOUNT_ID" ] || die "set AWS_ACCOUNT_ID"
  [ -n "$CLUSTER_NAME" ]   || die "set CLUSTER_NAME"
  # The CRD validates roleArn against ^arn:aws[a-z-]*:iam::[0-9]{12}:role/.+$, so a malformed account
  # id here becomes a rejected manifest later. Fail now, with a clearer message.
  [[ "$AWS_ACCOUNT_ID" =~ ^[0-9]{12}$ ]] \
    || die "AWS_ACCOUNT_ID='$AWS_ACCOUNT_ID' must be exactly 12 digits"

  local caller
  caller="$(aws sts get-caller-identity --query Account --output text)"
  [ "$caller" = "$AWS_ACCOUNT_ID" ] \
    || die "AWS_ACCOUNT_ID=$AWS_ACCOUNT_ID but current credentials are for $caller"

  # Verify the cluster is actually reachable in AWS_REGION. Without this, a region mismatch surfaces
  # much later as "InvalidSignatureException: Credential should be scoped to a valid region" or
  # "cluster not found" — neither of which points at the region being wrong.
  if ! aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" \
        --query 'cluster.name' --output text >/dev/null 2>&1; then
    local found=""
    # Look for the cluster in the usual suspects so the error can name the right region.
    local r
    for r in us-east-1 us-west-2 us-east-2 us-west-1 eu-west-1 eu-central-1 ap-southeast-1; do
      [ "$r" = "$AWS_REGION" ] && continue
      if aws eks describe-cluster --name "$CLUSTER_NAME" --region "$r" \
           --query 'cluster.name' --output text >/dev/null 2>&1; then
        found="$r"; break
      fi
    done
    if [ -n "$found" ]; then
      die "cluster '$CLUSTER_NAME' does not exist in AWS_REGION=$AWS_REGION, but DOES exist in $found.
       Re-run with the cluster's region:
         AWS_REGION=$found CLUSTER_NAME=$CLUSTER_NAME $0 ${1:-setup}
       Note AWS_REGION is the CLUSTER's region. The Bedrock region is separate (BEDROCK_REGION,
       currently $BEDROCK_REGION) and must match 'region:' in bedrock-*-backend.yaml."
    fi
    die "cluster '$CLUSTER_NAME' not found in region $AWS_REGION (and not in the regions I probed).
       Check the name and region:  aws eks list-clusters --region <region>"
  fi
  ok "cluster '$CLUSTER_NAME' found in $AWS_REGION"

  # Surface the two-region split explicitly — it is legitimate, but silently wrong is expensive.
  if [ "$BEDROCK_REGION" != "$AWS_REGION" ]; then
    warn "cluster region ($AWS_REGION) differs from Bedrock region ($BEDROCK_REGION) — that is fine,"
    warn "  but BEDROCK_REGION must match 'region:' in bedrock-*-backend.yaml or the inference-profile"
    warn "  ARN in the IAM policy will point at the wrong region and Bedrock will return AccessDenied."
  fi

  ok "preflight passed (account $AWS_ACCOUNT_ID, cluster $CLUSTER_NAME, eks-region $AWS_REGION, bedrock-region $BEDROCK_REGION)"
}

# ---------------------------------------------------------------------------------------------
# Trust policies
# ---------------------------------------------------------------------------------------------

# The gateway role is assumed by the EKS Pod Identity service principal. sts:TagSession is required
# in ADDITION to sts:AssumeRole — Pod Identity always tags the session, and omitting TagSession is
# the single most common reason an association silently yields no credentials.
# This is byte-for-byte the policy AWS documents for Pod Identity, including the Sid. EKS validates
# the role's trust policy when you create an association and rejects anything else with:
#   InvalidParameterException: Trust policy of the role provided is invalid.
# Keep it identical to:
#   https://docs.aws.amazon.com/eks/latest/userguide/pod-id-association.html
#
# POD_IDENTITY_EXTRA_PRINCIPALS (space-separated) adds service principals alongside the documented
# one, for EKS environments whose Pod Identity service assumes roles under a different principal.
# The symptom of a missing one: the association exists and credentials are requested, but EKS Auth
# answers "EKS does not have permissions to assume the associated role".
egress_trust_policy() {
  local svc='"pods.eks.amazonaws.com"' p
  for p in $POD_IDENTITY_EXTRA_PRINCIPALS; do svc="${svc}, \"${p}\""; done
  cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowEksAuthToAssumeRoleForPodIdentity",
      "Effect": "Allow",
      "Principal": { "Service": [ ${svc} ] },
      "Action": [ "sts:AssumeRole", "sts:TagSession" ]
    }
  ]
}
EOF
}

# assert_egress_trust_policy — read the trust policy BACK from IAM and confirm it is what Pod Identity
# requires, before asking EKS to validate it.
#
# This distinguishes the two causes of "Trust policy of the role provided is invalid", which are
# otherwise indistinguishable from the error message:
#   * the policy really is wrong          -> we can say so precisely, and re-apply it
#   * the policy is right but EKS's view of IAM has not caught up (eventual consistency)
#                                        -> retrying is the only fix, so retry
# show_egress_trust_policy — print exactly what IAM holds, pretty-printed.
show_egress_trust_policy() {
  aws iam get-role --role-name "$EGRESS_ROLE" \
    --query 'Role.AssumeRolePolicyDocument' --output json 2>/dev/null \
    | python3 -m json.tool 2>/dev/null \
    || echo "  (could not read role/${EGRESS_ROLE} — does it exist?)"
}

# validate_trust_policy_doc — STRUCTURAL validation, reading the document on stdin.
#
# Deliberately not grep. A substring match on the JSON would pass even if Effect were "Deny", the
# Principal were the wrong shape, or a second statement contradicted the first — so it could never
# support a claim that the policy is or is not valid. This checks the actual requirements:
#   Version present, and SOME statement with
#     Effect  == "Allow"
#     Principal.Service includes "pods.eks.amazonaws.com"
#     Action  includes BOTH sts:AssumeRole and sts:TagSession
# Prints a per-field verdict and exits non-zero on failure.
validate_trust_policy_doc() {
  # Read the document from stdin into a variable and pass it to python as argv[1]. It CANNOT be piped
  # to `python3 - <<PY`, because there the heredoc is python's stdin and the document is lost.
  local doc; doc="$(cat)"
  python3 -c "$TRUST_POLICY_VALIDATOR" "$doc"
}

TRUST_POLICY_VALIDATOR=$(cat <<'PY'
import json, sys
try:
    doc = json.loads(sys.argv[1])
except Exception as e:
    print(f"    NOT VALID JSON: {e}"); sys.exit(1)
if not isinstance(doc, dict):
    print("    document is not a JSON object"); sys.exit(1)

print(f"    Version                  : {doc.get('Version', '<missing>')}")
stmts = doc.get("Statement")
if isinstance(stmts, dict): stmts = [stmts]
if not isinstance(stmts, list) or not stmts:
    print("    Statement                : <missing or empty>"); sys.exit(1)
print(f"    Statement count          : {len(stmts)}")

NEEDED = {"sts:AssumeRole", "sts:TagSession"}
good = False
for i, s in enumerate(stmts):
    eff = s.get("Effect")
    pr  = s.get("Principal") or {}
    svc = pr.get("Service") if isinstance(pr, dict) else None
    svcs = {svc} if isinstance(svc, str) else set(svc or [])
    act = s.get("Action")
    acts = {act} if isinstance(act, str) else set(act or [])
    print(f"    [{i}] Effect               : {eff}")
    print(f"    [{i}] Principal            : {pr}")
    print(f"    [{i}] Principal.Service    : {sorted(svcs) or '<none>'}")
    print(f"    [{i}] Action               : {sorted(acts) or '<none>'}")
    if s.get("Condition"):
        print(f"    [{i}] Condition            : {s['Condition']}   <-- EKS may not satisfy this")
    missing = NEEDED - acts
    if eff == "Allow" and "pods.eks.amazonaws.com" in svcs and not missing:
        good = True
        print(f"    [{i}] -> satisfies Pod Identity requirements")
    else:
        why = []
        if eff != "Allow": why.append(f"Effect is {eff!r}, need 'Allow'")
        if "pods.eks.amazonaws.com" not in svcs: why.append("Principal.Service lacks pods.eks.amazonaws.com")
        if missing: why.append("Action missing " + ", ".join(sorted(missing)))
        print(f"    [{i}] -> does NOT satisfy: {'; '.join(why)}")
sys.exit(0 if good else 1)
PY
)

# assert_egress_trust_policy — validate structurally, force-reapply once, validate again, and on
# failure print the live document so the cause is visible rather than inferred.
assert_egress_trust_policy() {
  local attempt
  for attempt in $(seq 1 3); do
    info "validating role/${EGRESS_ROLE} trust policy (attempt ${attempt}/3)"
    if show_egress_trust_policy | validate_trust_policy_doc; then
      ok "role/${EGRESS_ROLE} trust policy satisfies Pod Identity"
      return 0
    fi
    warn "trust policy does NOT satisfy Pod Identity — overwriting it with the documented form"
    if ! out="$(aws iam update-assume-role-policy --role-name "$EGRESS_ROLE" \
                  --policy-document "$(egress_trust_policy)" 2>&1)"; then
      die "could not update the trust policy on role/${EGRESS_ROLE}: $out
       If this is an AccessDenied, your credentials lack iam:UpdateAssumeRolePolicy."
    fi
    ok "trust policy overwritten"
    sleep "$IAM_RETRY_SLEEP"
  done

  err "role/${EGRESS_ROLE} trust policy is still invalid after being overwritten. Live document:"
  show_egress_trust_policy | sed 's/^/    /' >&2
  err "expected (per https://docs.aws.amazon.com/eks/latest/userguide/pod-id-association.html):"
  egress_trust_policy | sed 's/^/    /' >&2
  die "cannot create a Pod Identity association against this role."
}

# Each agent role trusts ONLY the gateway role. No OIDC and no external id needed, because the only
# principal that can reach STS with the gateway's credentials is the gateway pod itself.
agent_trust_policy() {
  cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "AWS": "arn:aws:iam::${AWS_ACCOUNT_ID}:role/${EGRESS_ROLE}" },
      "Action": [ "sts:AssumeRole", "sts:TagSession" ]
    }
  ]
}
EOF
}

# ---------------------------------------------------------------------------------------------
# Permission policies
# ---------------------------------------------------------------------------------------------

# The gateway role's ONLY permission is to become one of the two agent roles; it cannot call Bedrock.
# If the gateway is compromised it can still assume either agent role — the value is not preventing
# that, it is that neither role can invoke a model outside its own allow-list, and every call is
# attributed to a named role session.
egress_permissions_policy() {
  cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AssumeAgentRoles",
      "Effect": "Allow",
      "Action": [ "sts:AssumeRole", "sts:TagSession" ],
      "Resource": [
        "arn:aws:iam::${AWS_ACCOUNT_ID}:role/${WRITER_ROLE}",
        "arn:aws:iam::${AWS_ACCOUNT_ID}:role/${REVIEWER_ROLE}"
      ]
    }
  ]
}
EOF
}

# Per-agent model allow-list. Both agents get the same two models in this walkthrough; the point is
# that they are enforced SEPARATELY, so narrowing one agent later is a one-role change. To make the
# segregation visible in a demo, drop $NOVA_MODEL from the reviewer and watch failover return
# AccessDeniedException for that agent only.
agent_permissions_policy() {
  # Build the resource list: the Sonnet inference profile, its underlying foundation models (any
  # region, because a global profile routes across them), and each directly-addressed model.
  local resources=(
    "arn:aws:bedrock:${BEDROCK_REGION}:${AWS_ACCOUNT_ID}:inference-profile/${SONNET_PROFILE}"
    "arn:aws:bedrock:*::foundation-model/anthropic.claude-sonnet-4-6*"
  )
  local m
  for m in "${FOUNDATION_MODELS[@]}"; do
    resources+=( "arn:aws:bedrock:*::foundation-model/${m}" )
  done
  local json_resources
  json_resources="$(printf '        "%s",\n' "${resources[@]}" | sed '$ s/,$//')"

  cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "InvokeAllowedModels",
      "Effect": "Allow",
      "Action": [
        "bedrock:InvokeModel",
        "bedrock:InvokeModelWithResponseStream"
      ],
      "Resource": [
${json_resources}
      ]
    }
  ]
}
EOF
}

# ---------------------------------------------------------------------------------------------

# IAM is EVENTUALLY CONSISTENT for role principals.
#
# The two agent roles' trust policies name role/agentgateway-egress as an AWS principal. IAM refuses a
# trust policy whose principal it cannot yet resolve, so creating the egress role and immediately
# referencing it fails with:
#   MalformedPolicyDocument: Invalid principal in policy: "AWS":"arn:aws:iam::<acct>:role/agentgateway-egress"
# The role is fine — it just has not propagated. The only correct handling is to retry.
IAM_RETRIES="${IAM_RETRIES:-10}"
IAM_RETRY_SLEEP="${IAM_RETRY_SLEEP:-5}"

# iam_retry DESCRIPTION -- COMMAND...
# Retries only on the propagation error; any other failure is fatal immediately so real problems are
# not hidden behind a long retry loop.
iam_retry() {
  local desc="$1"; shift
  [ "$1" = "--" ] && shift
  local attempt out
  for attempt in $(seq 1 "$IAM_RETRIES"); do
    if out="$("$@" 2>&1)"; then
      return 0
    fi
    if grep -qE 'Invalid principal|NoSuchEntity' <<<"$out"; then
      warn "$desc: principal not yet resolvable (IAM propagation), retry ${attempt}/${IAM_RETRIES} in ${IAM_RETRY_SLEEP}s"
      sleep "$IAM_RETRY_SLEEP"
      continue
    fi
    if grep -q 'EntityAlreadyExists' <<<"$out"; then
      return 0   # created concurrently — fine
    fi
    die "$desc failed: $out"
  done
  die "$desc still failing after $IAM_RETRIES attempts (IAM propagation took too long).
       Re-running the script usually succeeds, since the prerequisite role now exists."
}

# upsert_role NAME TRUST_JSON
upsert_role() {
  local name="$1" trust="$2"
  if aws iam get-role --role-name "$name" >/dev/null 2>&1; then
    iam_retry "update trust policy for $name" -- \
      aws iam update-assume-role-policy --role-name "$name" --policy-document "$trust"
    ok "role $name exists — trust policy updated"
  else
    iam_retry "create role $name" -- \
      aws iam create-role --role-name "$name" \
        --assume-role-policy-document "$trust" \
        --description "agentgateway egress: $name"
    ok "role $name created"
  fi
}

# put_inline_policy ROLE POLICY_NAME POLICY_JSON
put_inline_policy() {
  aws iam put-role-policy --role-name "$1" --policy-name "$2" --policy-document "$3" >/dev/null
  ok "inline policy $2 applied to $1"
}

create_roles() {
  info "creating IAM roles"

  # ORDER MATTERS. The egress role must exist AND have propagated before the agent roles, whose trust
  # policies name it as a principal. `wait role-exists` covers creation; iam_retry inside upsert_role
  # covers the propagation window that `get-role` succeeding does not guarantee.
  upsert_role "$EGRESS_ROLE" "$(egress_trust_policy)"
  info "waiting for role/${EGRESS_ROLE} to become referenceable as a principal"
  aws iam wait role-exists --role-name "$EGRESS_ROLE" 2>/dev/null || true
  ok "role/${EGRESS_ROLE} exists"

  upsert_role "$WRITER_ROLE"   "$(agent_trust_policy)"
  upsert_role "$REVIEWER_ROLE" "$(agent_trust_policy)"

  put_inline_policy "$EGRESS_ROLE"   assume-agent-roles "$(egress_permissions_policy)"
  put_inline_policy "$WRITER_ROLE"   invoke-bedrock     "$(agent_permissions_policy)"
  put_inline_policy "$REVIEWER_ROLE" invoke-bedrock     "$(agent_permissions_policy)"
}

# is_auto_mode — EKS Auto Mode reports computeConfig.enabled=true. On Auto Mode the Pod Identity
# Agent is BUILT IN and managed by AWS, so the addon must not be installed:
#   "You do not need to install the EKS Pod Identity Agent on EKS Auto Mode Clusters. This capability
#    is built into EKS Auto Mode."
#   https://docs.aws.amazon.com/eks/latest/userguide/pod-id-agent-setup.html
is_auto_mode() {
  local enabled
  enabled="$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" \
    --query 'cluster.computeConfig.enabled' --output text 2>/dev/null || echo unknown)"
  [ "$enabled" = "True" ] || [ "$enabled" = "true" ]
}

# enable_pod_identity_addon — best effort, NEVER fatal.
#
# If this aborted the script on failure, then on EKS Auto Mode create_association would never run:
# the roles get created, no association exists, the proxy gets no
# AWS_CONTAINER_CREDENTIALS_FULL_URI, and the credential chain falls through to IMDS — which Auto Mode
# blocks (nodes launch with IMDS hop limit = 1). The visible result is:
#   error="backend authentication failed: an error occurred while loading credentials" duration=~1000ms
# The ~1s is the IMDS timeout. Hence: the association is what matters, and nothing here may block it.
enable_pod_identity_addon() {
  info "checking the EKS Pod Identity Agent"
  if is_auto_mode; then
    ok "EKS Auto Mode detected — Pod Identity Agent is built in, skipping addon install"
    return 0
  fi
  if aws eks describe-addon --cluster-name "$CLUSTER_NAME" \
       --addon-name eks-pod-identity-agent --region "$AWS_REGION" >/dev/null 2>&1; then
    ok "eks-pod-identity-agent already installed"
    return 0
  fi
  info "installing the eks-pod-identity-agent addon"
  if ! aws eks create-addon --cluster-name "$CLUSTER_NAME" \
         --addon-name eks-pod-identity-agent --region "$AWS_REGION" >/dev/null 2>&1; then
    warn "could not create the eks-pod-identity-agent addon — continuing anyway."
    warn "  If this cluster provides the agent some other way (Auto Mode, a self-managed DaemonSet,"
    warn "  or baked into the AMI) that is fine. If not, credentials will fail to load and"
    warn "  '$0 --diagnose' will tell you."
    return 0
  fi
  if ! aws eks wait addon-active --cluster-name "$CLUSTER_NAME" \
         --addon-name eks-pod-identity-agent --region "$AWS_REGION" 2>/dev/null; then
    warn "addon did not reach ACTIVE in time — continuing; re-check with '$0 --diagnose'"
    return 0
  fi
  ok "eks-pod-identity-agent installed"
}

create_association() {
  # Prove the trust policy is right before EKS judges it, so a genuine content error is reported as
  # such instead of hiding behind a retry loop.
  assert_egress_trust_policy

  info "associating ${AGW_NS}/${GATEWAY_SA} with role/${EGRESS_ROLE}"
  local existing
  existing="$(aws eks list-pod-identity-associations \
    --cluster-name "$CLUSTER_NAME" --namespace "$AGW_NS" \
    --service-account "$GATEWAY_SA" --region "$AWS_REGION" \
    --query 'associations[0].associationId' --output text 2>/dev/null || echo None)"

  if [ "$existing" != "None" ] && [ -n "$existing" ]; then
    ok "association already exists ($existing) — leaving in place"
  else
    # EKS validates the IAM trust policy server-side and its view of IAM lags. Retry only that
    # specific rejection; anything else is fatal immediately.
    local attempt out created=0
    for attempt in $(seq 1 "$IAM_RETRIES"); do
      if out="$(aws eks create-pod-identity-association \
                  --cluster-name "$CLUSTER_NAME" \
                  --namespace "$AGW_NS" \
                  --service-account "$GATEWAY_SA" \
                  --role-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:role/${EGRESS_ROLE}" \
                  --region "$AWS_REGION" 2>&1)"; then
        created=1; break
      fi
      if grep -qE 'Trust policy of the role provided is invalid|Role provided in the request does not exist' <<<"$out"; then
        warn "EKS has not yet seen the role/trust policy (IAM propagation), retry ${attempt}/${IAM_RETRIES} in ${IAM_RETRY_SLEEP}s"
        sleep "$IAM_RETRY_SLEEP"
        continue
      fi
      if grep -q 'ResourceInUseException' <<<"$out"; then
        created=1; break   # created concurrently
      fi
      die "failed to create the Pod Identity association: $out"
    done
    [ "$created" -eq 1 ] || die "could not create the Pod Identity association after $IAM_RETRIES attempts.
       The trust policy on role/${EGRESS_ROLE} verified correct locally, so this is EKS-side propagation.
       Wait a minute and re-run:  $0 setup"
    ok "association created"
  fi

  # install.sh runs this BEFORE the Gateway exists, so the proxy picks credentials up on first start.
  # Run standalone against an existing proxy and it needs a restart. (Under install.sh,
  # assert_proxy_credentials checks the proxy and restarts it only if needed, so stay quiet.)
  if [ -z "${AGW_INSTALL_SH:-}" ] && kubectl -n "$AGW_NS" get deploy egress >/dev/null 2>&1; then
    warn "deploy/egress already exists — restart it to pick up Pod Identity credentials:"
    echo "    kubectl -n ${AGW_NS} rollout restart deploy/egress"
  fi
}

post_setup_notes() {
  cat <<EOF

$(info "remaining manual step")

Activate 'agent' as a cost allocation tag so per-agent spend reaches the Cost and Usage Report:
  Billing console -> Cost allocation tags -> user-defined -> activate 'agent'
Until you do, the session tag is attached to each role session but appears in no report.

Verify everything:  ./bedrock/setup-pod-identity.sh --verify

EOF
}

verify() {
  info "Pod Identity association"
  aws eks list-pod-identity-associations \
    --cluster-name "$CLUSTER_NAME" --namespace "$AGW_NS" --region "$AWS_REGION" \
    --output table || warn "no associations found"

  info "gateway proxy ServiceAccount (must match GATEWAY_SA=${GATEWAY_SA})"
  kubectl -n "$AGW_NS" get deploy egress \
    -o jsonpath='{.spec.template.spec.serviceAccountName}{"\n"}' 2>/dev/null \
    || warn "deploy/egress not found — is the Gateway provisioned?"

  info "credential env vars on the proxy pod (expect AWS_CONTAINER_CREDENTIALS_FULL_URI)"
  kubectl -n "$AGW_NS" get pods -l app=agentgateway-egress \
    -o jsonpath='{.items[*].spec.containers[*].env[*].name}' 2>/dev/null | tr ' ' '\n' \
    | grep -E '^AWS_' | sort -u | sed 's/^/  /' \
    || warn "no AWS_ env vars — the pod may predate the association; restart it"

  info "can the gateway role assume the agent roles?"
  local r
  for r in "$WRITER_ROLE" "$REVIEWER_ROLE"; do
    if aws iam simulate-principal-policy \
        --policy-source-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:role/${EGRESS_ROLE}" \
        --action-names sts:AssumeRole \
        --resource-arns "arn:aws:iam::${AWS_ACCOUNT_ID}:role/${r}" \
        --query 'EvaluationResults[0].EvalDecision' --output text 2>/dev/null \
        | grep -q allowed; then
      ok "$EGRESS_ROLE may assume $r"
    else
      warn "$EGRESS_ROLE may NOT assume $r — check the inline policy"
    fi
  done

  info "gateway role must NOT be able to call Bedrock directly (expect implicitDeny)"
  aws iam simulate-principal-policy \
    --policy-source-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:role/${EGRESS_ROLE}" \
    --action-names bedrock:InvokeModel \
    --query 'EvaluationResults[0].EvalDecision' --output text 2>/dev/null \
    | sed 's/^/  /' || warn "simulation failed"

  info "backends should report Accepted=True (a rejected config can down the whole proxy)"
  kubectl -n "$AGW_NS" get agentgatewaybackend \
    -o custom-columns='NAME:.metadata.name,ACCEPTED:.status.conditions[?(@.type=="Accepted")].status' \
    2>/dev/null || warn "no AgentgatewayBackends found"

  echo
  info "end-to-end: after a request, the role session should appear in CloudTrail:"
  echo "    aws cloudtrail lookup-events --region ${AWS_REGION} \\"
  echo "      --lookup-attributes AttributeKey=EventName,AttributeValue=AssumeRole \\"
  echo "      --max-results 5 --query 'Events[].CloudTrailEvent' --output text \\"
  echo "      | jq -r '.requestParameters.roleSessionName'"
}

# diagnose — isolate WHY the gateway cannot load credentials.
#
# Symptom this exists for:
#   error="backend authentication failed: an error occurred while loading credentials"  duration=1001ms
#
# That message means the AWS credential chain produced nothing. `assumeRole` needs AMBIENT credentials
# as the source for its STS call, so if the chain is empty the STS call never happens. The ~1s duration
# is a timeout, which means something was dialled and did not answer.
#
# The chain the proxy walks, in order:
#   1. AWS_ACCESS_KEY_ID / SECRET / SESSION_TOKEN env vars
#   2. ~/.aws/config and ~/.aws/credentials
#   3. AWS_WEB_IDENTITY_TOKEN_FILE + AWS_ROLE_ARN        <- IRSA
#   4. AWS_CONTAINER_CREDENTIALS_FULL_URI + _TOKEN_FILE  <- EKS POD IDENTITY
#   5. IMDSv2 on the node
# Pod Identity is step 4. The checks below walk that in order and stop at the first broken link.
diagnose() {
  local fail=0

  # THE MOST COMMON FAILURE FIRST. Without an association nothing else matters: no env vars get
  # injected, the chain falls through to IMDS, and on Auto Mode IMDS is blocked (hop limit = 1), so
  # you get a ~1s timeout and "an error occurred while loading credentials".
  info "1. association for ${AGW_NS}/${GATEWAY_SA}  <-- check this first"
  # list- returns PodIdentityAssociationSummary, which has NO roleArn (AWS strips it from the
  # summary). Test existence with associationId, then describe- to get the role.
  local assoc_id assoc_role
  assoc_id="$(aws eks list-pod-identity-associations \
    --cluster-name "$CLUSTER_NAME" --namespace "$AGW_NS" --service-account "$GATEWAY_SA" \
    --region "$AWS_REGION" --query 'associations[0].associationId' --output text 2>/dev/null || echo None)"
  if [ "$assoc_id" != "None" ] && [ -n "$assoc_id" ]; then
    assoc_role="$(aws eks describe-pod-identity-association \
      --cluster-name "$CLUSTER_NAME" --association-id "$assoc_id" --region "$AWS_REGION" \
      --query 'association.roleArn' --output text 2>/dev/null || echo '<unknown>')"
  else
    assoc_role="None"
  fi
  if [ "$assoc_role" = "None" ] || [ -z "$assoc_role" ]; then
    warn "NO association for ${AGW_NS}/${GATEWAY_SA} — this is almost certainly your problem."
    warn "  Create it:  $0 setup"
    warn "  Then restart the proxy so the webhook injects the credential env vars:"
    echo "    kubectl -n $AGW_NS rollout restart deploy/egress"
    fail=1
  else
    ok "association -> $assoc_role  (${assoc_id})"
    if [ "$assoc_role" != "arn:aws:iam::${AWS_ACCOUNT_ID}:role/${EGRESS_ROLE}" ]; then
      warn "  but it points at a DIFFERENT role than expected:"
      warn "    expected arn:aws:iam::${AWS_ACCOUNT_ID}:role/${EGRESS_ROLE}"
      warn "  the proxy will get credentials for the wrong identity. Fix: $0 --teardown && $0 setup"
      fail=1
    fi
  fi
  info "   all associations on this cluster (for context):"
  aws eks list-pod-identity-associations --cluster-name "$CLUSTER_NAME" --region "$AWS_REGION" \
    --query 'associations[].[namespace,serviceAccount]' --output text 2>/dev/null | sed 's/^/     /' \
    || warn "     none"

  info "1b. role/${EGRESS_ROLE} trust policy (what EKS validates when creating the association)"
  if show_egress_trust_policy | validate_trust_policy_doc; then
    ok "trust policy satisfies Pod Identity"
  else
    warn "trust policy does NOT satisfy Pod Identity — this is why CreatePodIdentityAssociation fails with"
    warn "  'InvalidParameterException: Trust policy of the role provided is invalid.'"
    warn "  Fix by re-running setup (it overwrites the policy):  $0 setup"
    fail=1
  fi
  info "    live document:"
  show_egress_trust_policy | sed 's/^/      /'

  info "2. Pod Identity Agent availability"
  if is_auto_mode; then
    ok "EKS Auto Mode — the agent is built in and managed by AWS (no addon expected)"
    warn "  Auto Mode also blocks pod IMDS access (hop limit = 1), so there is NO fallback:"
    warn "  if the association is missing, credentials fail rather than silently using the node role."
  elif aws eks describe-addon --cluster-name "$CLUSTER_NAME" --addon-name eks-pod-identity-agent \
         --region "$AWS_REGION" --query 'addon.status' --output text 2>/dev/null | grep -q ACTIVE; then
    ok "eks-pod-identity-agent addon ACTIVE"
  else
    warn "no eks-pod-identity-agent addon and not Auto Mode — the agent may be missing entirely. Fix:"
    echo "    aws eks create-addon --cluster-name $CLUSTER_NAME --addon-name eks-pod-identity-agent --region $AWS_REGION"
    fail=1
  fi

  info "3. proxy ServiceAccount actually in use"
  local actual_sa
  actual_sa="$(kubectl -n "$AGW_NS" get deploy egress \
    -o jsonpath='{.spec.template.spec.serviceAccountName}' 2>/dev/null || true)"
  if [ -z "$actual_sa" ]; then
    warn "deploy/egress not found"
    fail=1
  elif [ "$actual_sa" != "$GATEWAY_SA" ]; then
    warn "proxy runs as '$actual_sa' but the association targets '$GATEWAY_SA' — MISMATCH. Fix:"
    echo "    GATEWAY_SA=$actual_sa $0 setup"
    fail=1
  else
    ok "proxy SA '$actual_sa' matches the association"
  fi

  info "4. credential env vars injected into the proxy pod"
  local envs
  envs="$(kubectl -n "$AGW_NS" get pods -l app=agentgateway-egress \
    -o jsonpath='{.items[*].spec.containers[*].env[*].name}' 2>/dev/null | tr ' ' '\n' \
    | grep -E '^AWS_' | sort -u || true)"
  if [ -z "$envs" ]; then
    warn "NO AWS_* env vars on the proxy — the webhook did not inject them."
    warn "  Almost always: the pod started BEFORE the association existed. Restart it:"
    echo "    kubectl -n $AGW_NS rollout restart deploy/egress"
    fail=1
  else
    printf '    %s\n' $envs
    if grep -q AWS_CONTAINER_CREDENTIALS_FULL_URI <<<"$envs"; then
      ok "Pod Identity variables present (chain step 4)"
    elif grep -q AWS_WEB_IDENTITY_TOKEN_FILE <<<"$envs"; then
      ok "IRSA variables present (chain step 3)"
    else
      warn "AWS_* vars present but neither Pod Identity nor IRSA — chain will fall through to IMDS"
      fail=1
    fi
  fi

  info "5. can the proxy actually REACH the credential endpoint?"
  # This is the decisive test. If the env vars are present but this times out, the problem is the
  # network path to 169.254.170.23 (the Pod Identity agent), not IAM.
  local pod
  pod="$(kubectl -n "$AGW_NS" get pods -l app=agentgateway-egress \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [ -z "$pod" ]; then
    warn "no proxy pod to exec into"
  else
    local probe
    probe="$(kubectl -n "$AGW_NS" exec "$pod" -- sh -c '
        [ -n "$AWS_CONTAINER_CREDENTIALS_FULL_URI" ] || { echo "NO_URI"; exit 0; }
        TOK=""
        [ -f "$AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE" ] && TOK=$(cat "$AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE")
        code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 3 \
          -H "Authorization: $TOK" "$AWS_CONTAINER_CREDENTIALS_FULL_URI" 2>/dev/null)
        echo "HTTP_$code"
      ' 2>/dev/null || echo EXEC_FAILED)"
    case "$probe" in
      HTTP_200)   ok "credential endpoint returned 200 — Pod Identity is delivering credentials" ;;
      HTTP_000|"") warn "credential endpoint TIMED OUT — this matches your 1001ms failure."
                   warn "  The Pod Identity agent is unreachable from the proxy pod. Check that the"
                   warn "  addon pods are Running on the SAME NODE as the proxy, and that nothing"
                   warn "  blocks egress to 169.254.170.23:80 from agentgateway-system."
                   fail=1 ;;
      NO_URI)     warn "AWS_CONTAINER_CREDENTIALS_FULL_URI is unset inside the pod — restart it" ; fail=1 ;;
      EXEC_FAILED) warn "could not exec into the proxy (no shell/curl in the image?) — skip this check" ;;
      *)          warn "credential endpoint returned $probe" ; fail=1 ;;
    esac
  fi

  info "6. model allow-list vs. what the agents request"
  warn "the transparent path lets the AGENT choose the model, and IAM is the only control."
  echo "    allowed: ${SONNET_PROFILE} ${FOUNDATION_MODELS[*]}"
  echo "    if a request 500s with AccessDeniedException, add the model to FOUNDATION_MODELS and re-run setup"

  echo
  if [ "$fail" -eq 0 ]; then
    ok "no credential-chain problems found — if requests still fail, capture the proxy log:"
    echo "    kubectl -n $AGW_NS logs deploy/egress | grep -iE 'credential|sts|assume|aws'"
  else
    warn "$fail problem(s) above. Fix them top-down; step 4 (restart) resolves most cases."
  fi
}

teardown() {
  warn "removing the Pod Identity association and the three IAM roles"
  local assoc
  assoc="$(aws eks list-pod-identity-associations \
    --cluster-name "$CLUSTER_NAME" --namespace "$AGW_NS" \
    --service-account "$GATEWAY_SA" --region "$AWS_REGION" \
    --query 'associations[0].associationId' --output text 2>/dev/null || echo None)"
  if [ "$assoc" != "None" ] && [ -n "$assoc" ]; then
    aws eks delete-pod-identity-association --cluster-name "$CLUSTER_NAME" \
      --association-id "$assoc" --region "$AWS_REGION" >/dev/null
    ok "association $assoc deleted"
  fi

  aws iam delete-role-policy --role-name "$EGRESS_ROLE"   --policy-name assume-agent-roles 2>/dev/null || true
  aws iam delete-role-policy --role-name "$WRITER_ROLE"   --policy-name invoke-bedrock     2>/dev/null || true
  aws iam delete-role-policy --role-name "$REVIEWER_ROLE" --policy-name invoke-bedrock     2>/dev/null || true
  local r
  for r in "$EGRESS_ROLE" "$WRITER_ROLE" "$REVIEWER_ROLE"; do
    if aws iam delete-role --role-name "$r" 2>/dev/null; then ok "role $r deleted"; fi
  done
  warn "the eks-pod-identity-agent addon was left installed — remove it explicitly if desired"
}

main() {
  case "${1:-setup}" in
    setup|"")
      preflight
      create_roles
      enable_pod_identity_addon
      create_association
      post_setup_notes
      ;;
    --verify|verify)     preflight; verify ;;
    --diagnose|diagnose) preflight; diagnose ;;
    --teardown|teardown) preflight; teardown ;;
    *) die "unknown argument '${1}'. Use: setup | --verify | --diagnose | --teardown" ;;
  esac
}

main "$@"
