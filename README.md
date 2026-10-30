# Agentic mesh egress — example manifests

A two-agent "poem shop" running on **Istio ambient + Agent Gateway** on EKS, showing per-agent,
identity-based egress governance: agents carry **no credentials**, and the gateway vends each one a
different token keyed on its SPIFFE identity.

- **Writer** (`sa/writer-agent`) polls GitHub issues, self-assigns one, composes a poem, and opens a
  PR.
- **Reviewer** (`sa/reviewer-agent`) reviews open poem PRs against a quality bar and, on pass,
  merges — the reviewer-only action.

Both agents run on the [Strands Agents SDK](https://strandsagents.com/): the GitHub MCP tools are
loaded into a Strands `Agent` via `MCPClient` and the model chooses which to call, while the poll
loop and the writer/reviewer turn-taking protocol stay in plain Python. See
`agents/writer-agent/agent.py` for the reasoning behind that split.

Both reach GitHub (via an MCP server) and Bedrock (for the LLM) through the gateway. ztunnel
transparently wraps their egress in HBONE mTLS stamped with the workload's SPIFFE identity; the
gateway authorizes that identity, routes it to that agent's backend, and injects that agent's
credential.

## Layout

- `gateway/` — shared foundation: namespaces, `Gateway`/`AgentgatewayParameters`, the catch-all
  `ServiceEntry` that transparently captures all agent :80 egress to the gateway, the coarse
  frontend identity gate, and the PreRouting SPIFFE stamp (`x-agentgateway-spiffe`).
- `github/` — GitHub MCP egress: per-agent `Secret` + `AgentgatewayBackend` (+ TLS origination)
  and the identity-routed `HTTPRoute`.
- `bedrock/` — Bedrock LLM egress, in two models (per-agent credentials in both): `transparent` (agent
  speaks the real Bedrock API, gateway injects transparently) and `cooperative` (agent speaks OpenAI to
  the gateway, gateway steers the model). The cooperative backends use **priority-group model fallback**
  (primary Claude Sonnet → fallback Nova per agent); `bedrock-failover-policy.yaml` adds the health
  policy that evicts an unhealthy/throttled model and the retry policy that makes the failover
  transparent to the agent.
- `agents/` — the two workloads (each: `ServiceAccount` + `cooperative`/`transparent` Deployments), their image
  sources (`writer-agent/`, `reviewer-agent/`), and an `ApplicationNetworkPolicy` that default-denies
  agent egress except DNS + the HBONE hop to the gateway.
- `ratelimit/` — an external rate limit service (Envoy's reference implementation of the Rate Limit
  gRPC protocol) backed by Redis, its rules `ConfigMap`, and the `AgentgatewayPolicy` objects that
  consume them. The gateway calls this service at `ratelimit.ratelimit.svc:8081`. Two independent
  domains:
  - `agentgateway` — a request-count limit (60 requests/minute) per verified caller identity (the
    `x-agentgateway-spiffe` header stamped by `gateway/identity-header.yaml`), wired to the GitHub MCP
    route by `request-rate-limit.yaml`. Only that route: a route carries one global rate-limit
    domain, and the LLM routes use `llm-tokens`.
  - `llm-tokens` — a **distributed per-identity LLM token budget**, wired to both LLM routes
    (`bedrock-cooperative`, `bedrock-transparent`) by `llm-token-limit.yaml`. Cooperative path: 1M tokens/day
    (writer) and 500k tokens/day (reviewer). Transparent path, per model: Sonnet gets the same 1M/500k,
    and any other model 200k/day. Because
    that policy marks the descriptor `unit: Tokens`, Agent Gateway reports each request's total LLM
    token count as the cost — charged **after** the request completes — and Redis owns the shared
    counter, so all gateway replicas draw down one budget.

## Apply

Point a kube-context at an EKS cluster, have AWS credentials for its account, and run:

```bash
WRITER_PAT=ghp_... REVIEWER_PAT=ghp_... \
GITHUB_OWNER=my-user GITHUB_REPO=my-repo \
./install.sh
```

That is the whole install. In order, it:

0. **Builds and pushes the agent images** (`agents/build-images.sh`) to ECR in the cluster's
   account and region, tagged with a hash of `agents/{writer,reviewer}-agent/`. It uses local
   `docker buildx` if it works, else an AWS CodeBuild project (no local Docker needed). An unchanged
   source tree is never rebuilt. Bring your own images with `WRITER_IMAGE=… REVIEWER_IMAGE=…`.
1. **Installs Istio ambient at a pinned version** (`ISTIO_VERSION`, default `1.32.0-rc.0`),
   downloading and checksum-verifying `istioctl` if the one on `PATH` is a different version. It
   refuses versions with the ztunnel catch-all bug (see Known issue below) and will not change an
   existing Istio install without `ISTIO_UPGRADE=1`.
2. **Installs any missing Gateway API standard CRDs**, one by one. Existing (including EKS-managed)
   CRDs are left untouched.
3. Installs Agent Gateway and enrolls the agent namespaces in the mesh.
4. **Sets up Bedrock IAM + EKS Pod Identity** (`bedrock/setup-pod-identity.sh`). There is **no
   Bedrock Secret**: the gateway signs with SigV4 as a per-agent IAM role. Account, cluster, and
   region come from your kube-context and AWS credentials; override with `AWS_ACCOUNT_ID`,
   `CLUSTER_NAME`, `AWS_REGION`.
5. **Creates the GitHub credential Secrets** from `WRITER_PAT` / `REVIEWER_PAT` (passed to kubectl
   through a file descriptor, never written to disk), then applies the egress config, rate limits,
   agents, and the egress lockdown, with its DNS rule rendered for this cluster's resolver.
6. **Smoke-tests every path from inside each agent pod**: a GitHub MCP `initialize` and an LLM
   call (OpenAI-format on the cooperative pods, Bedrock Converse on the transparent ones), each of
   which must return 200 with the gateway injecting that agent's credential. The install fails, with
   per-status hints, if any one does not.

Re-running is safe and fast. If `WRITER_PAT`, `REVIEWER_PAT`, `GITHUB_OWNER`, or `GITHUB_REPO` are
omitted on a re-run, the values already in the cluster are kept — never replaced with placeholders.
To rotate a token, re-run with the new one; the script restarts the gateway proxy to pick it up.

Use two **different** tokens: per-agent credentials are the point of the demo. `GITHUB_PAT=…` sets
both at once, and the script warns that the agents are then indistinguishable to GitHub.

The gateway pod's ServiceAccount maps to `agentgateway-egress`, which holds **no** Bedrock
permissions — only `sts:AssumeRole` on `agentgateway-bedrock-{writer,reviewer}`. Each agent role
scopes `bedrock:InvokeModel` to its own model ARNs, so per-agent segregation is enforced by IAM
rather than by two bearer tokens. Check the Bedrock side any time with
`./bedrock/setup-pod-identity.sh --verify`.

One manual step remains: activate `agent` as a cost allocation tag in the Billing console for
per-agent spend to reach the Cost and Usage Report.

### Cluster requirements

- **EKS**, with AWS credentials allowed to create IAM roles, Pod Identity associations, and (for the
  image build) ECR repos, an S3 bucket, and a CodeBuild project.
- **The egress lockdown** (`agents/appnetworkpolicy.yaml`) is an `ApplicationNetworkPolicy`, which
  needs EKS Auto Mode or the VPC CNI network policy controller. Without that CRD the install
  continues but warns that agent egress is **not** locked down.
- The Sonnet and Nova models named in `bedrock/` must be enabled for your account in the Bedrock
  region (`us-east-1`); the smoke test catches it if they are not.
- **Non-standard EKS endpoints**: set `AWS_ENDPOINT_URL_EKS` if your cluster is not reachable
  through the default EKS API, and `POD_IDENTITY_EXTRA_PRINCIPALS` if its Pod Identity service
  assumes roles under a principal other than `pods.eks.amazonaws.com`.

### Options

```bash
KUBE_CONTEXT=<context> ./install.sh   # install into another context; your current one is not changed
./install.sh --validate               # dry-run every manifest, apply nothing
SKIP_POD_IDENTITY=1 ./install.sh      # GitHub MCP only, no Bedrock IAM
SKIP_SMOKE_TEST=1 ./install.sh        # skip the end-to-end checks
./install.sh --uninstall              # also removes the IAM roles and the association
PURGE_IMAGES=1 ./install.sh --uninstall   # ...and the ECR repos + CodeBuild resources
```

The header of `install.sh` lists every variable (`ISTIO_VERSION`, `IMAGE_PLATFORM`, `IMAGE_BUILDER`,
`CLUSTER_DNS_IP`, …).

> **Do not `kubectl apply` the manifests directly.** They carry placeholders (`<ACCOUNT_ID>`,
> `<WRITER_IMAGE>`, `<GITHUB_OWNER>`, `<CLUSTER_DNS_IP>`, …) that `install.sh` renders at apply
> time; it refuses to apply anything still containing one. The Bedrock backends' `roleArn` is
> validated by the CRD, so an unsubstituted placeholder is rejected by the API server outright.

## Notes on the Strands agent runtime

Three things follow from the agents driving their tools with an LLM rather than a hard-coded call
sequence, and all three are already reflected in the manifests:

- **Model choice is load-bearing.** The `transparent` Deployments name
  `global.anthropic.claude-sonnet-4-6` rather than a Nova Micro; a small model handles a one-shot
  "write me a poem" fine but is unreliable at multi-step tool calling. On the transparent path the
  per-agent IAM role's model allow-list is the only control on model choice, so any model you set in
  `BEDROCK_MODEL` must also be in `setup-pod-identity.sh` or Bedrock returns
  `AccessDeniedException`. The `cooperative` Deployments leave `COOPERATIVE_MODEL` empty so the gateway's
  backend (and its Sonnet → Nova priority-group failover) decides.
- **The pods need real memory.** `strands-agents` pulls in boto3, the OpenAI client, and the
  OpenTelemetry SDK, so the Deployments request 256Mi / limit 512Mi. A 128Mi limit OOMKills the
  container during import.
- **Cooperative mode streams.** Strands' `OpenAIModel` sends `stream: true` with
  `stream_options.include_usage: true`, so the gateway's OpenAI-compatible route sees an SSE response
  rather than a single JSON body. Usage is still reported, so the `llm-tokens` per-identity budget in
  `ratelimit/` keeps working.
- **Transparent mode's request path is percent-encoded.** boto3 escapes the model ID's colon, so the
  gateway sees `POST /model/amazon.nova-micro-v1%3A0/converse` rather than a literal `:`. This is what real Bedrock SDK traffic looks like, so the `Detect` route's model
  extraction should handle it. With the bare `key: model` default in `ratelimit/ratelimit-config.yaml`,
  an encoded model ID still lands in a budget; confirm the gateway resolves the model anyway before
  relying on per-model attribution.

Neither mode carries a credential. Transparent mode's `BedrockModel` is configured with botocore's
`signature_version=UNSIGNED`, so boto3 resolves no AWS credentials and signs nothing; cooperative mode
passes the OpenAI client a placeholder `api_key` (the SDK requires one) and strips the resulting
`Authorization` header in an httpx request hook. The MCP session is opened with no `headers` at all.
Verified locally against a fake endpoint: neither path emits an `Authorization` header.

## Status

Cluster-verified end to end on EKS Auto Mode (Kubernetes 1.36, Istio 1.32.0-rc.0, Agent Gateway
v1.7.0): the GitHub MCP egress path (transparent capture → HBONE → identity routing → credential
injection → TLS origination), both Bedrock paths (cooperative and transparent, per-agent IAM roles),
and the writer → reviewer flow (poem PR opened, reviewed, revised). Per-tool MCP governance is built
but not cluster-verified.

### Known issue: ztunnel catch-all `ServiceEntry` on Istio 1.30.4+

The `0.0.0.0/0` catch-all in `gateway/service-entry.yaml` can resolve to a stale, endpoint-less
service entry in ztunnel ("no healthy upstream") on Istio 1.30.4 and later, including 1.31.x. The
fix is [istio/ztunnel#2086](https://github.com/istio/ztunnel/pull/2086), which is not in any 1.30.x
or 1.31.x release. `install.sh` pins Istio to `1.32.0-rc.0`, which contains it, and refuses the affected versions
unless `ISTIO_ALLOW_ZTUNNEL_BUG=1`. Outside the script, either use a ztunnel build that contains it (e.g. 1.32.0-alpha),
pin ztunnel to 1.30.3 (and `kubectl -n istio-system rollout restart ds/ztunnel` after the gateway
pod restarts), or use per-host `ServiceEntry` objects instead of the catch-all.

## Next steps

- Add TLS MITM
- Add TLS pass through egress
