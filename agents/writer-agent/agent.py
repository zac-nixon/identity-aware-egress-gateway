#!/usr/bin/env python3
"""Writer agent: turn GitHub issues into poems, and revise them until the reviewer is satisfied.

Runtime: the **Strands Agents SDK**. The GitHub MCP server's tools are loaded into a Strands
`Agent` via `MCPClient`, and the model decides which of them to call. Strands also owns the model
call, through the provider that matches this pod's egress mode (see LLM_MODE below).

The writer polls a repo's open issues (via the GitHub MCP server). For each poem request that has
no open PR yet it:

  1. assigns the issue to itself (claiming the work), then
  2. cuts a pull request containing the requested poem (a new branch + a poem file + a PR that
     closes the issue).

For each poem request that ALREADY has an open PR, the writer instead reads the PR's comment thread
for reviewer feedback it has not yet addressed; if the reviewer requested changes, it rewrites the
poem to resolve them, pushes the revision onto the same branch, and leaves a comment handing the PR
back for another review. This closes the loop with the reviewer: request-changes -> revise ->
re-review, repeating until the reviewer merges (which closes the issue and ends the loop).

─────────────────────────────────────────────────────────────────────────────────────────────────
WHAT STRANDS OWNS AND WHAT THIS FILE STILL OWNS — the split is deliberate.

Strands owns the *agentic* part: composing the poem and then publishing it by calling GitHub MCP
tools (`create_branch`, `push_files`, `create_pull_request`, `add_issue_comment`, ...). The model
picks the tools and their arguments; this file does not hand-code that sequence.

This file keeps owning the *deterministic* part — the poller and the turn-taking protocol:

  * which issues are candidates, and whether an issue already has an open PR (revise vs. first
    draft). Read directly with `MCPClient.call_tool_async`, not through the model, so restart-safe
    idempotency does not depend on a prompt.
  * whose turn it is on a PR, decided by scanning the comment thread for the two markers below.
  * a fallback marker comment if the model finishes its work without posting one, so a missed
    marker can never wedge the writer/reviewer handoff.

That is the same division of labor the platform side of this example argues for: give the model
authority over the task, keep the invariants in code.

─────────────────────────────────────────────────────────────────────────────────────────────────
CREDENTIALS: there are none in this pod, and switching to Strands does not change that.

Every egress call is credential-free from the agent's side — Agent Gateway vends the credential.
ztunnel wraps each call in HBONE mTLS stamped with this workload's SPIFFE identity; the gateway
authorizes that identity and attaches the right credential. This is the whole point of the teaching
example: the Writer's identity (`sa/writer-agent`) is what earns it the create-PR + comment
authority; it never holds a GitHub token.

Two details keep that true through the SDK layer, and both are worth knowing:

  * MCP: `streamablehttp_client` is constructed with no `headers`, so the MCP session carries no
    Authorization header. The gateway injects the writer's GitHub token.
  * Bedrock (transparent mode): `BedrockModel` gets a botocore config with `signature_version=UNSIGNED`,
    so boto3 neither resolves AWS credentials nor signs the request — it emits a bare Converse call
    with no Authorization header. The gateway
    assumes this agent's IAM role and SigV4-signs on the way out.
  * Bedrock (cooperative mode): the OpenAI SDK insists on *some* api_key, so we pass a placeholder and
    then strip the `Authorization` header in an httpx request hook. Nothing resembling a credential
    leaves the pod, and the gateway's injected header has nothing to collide with.

─────────────────────────────────────────────────────────────────────────────────────────────────
The GitHub MCP calls are always the same. The LLM call has two modes (LLM_MODE), contrasting two
egress models:

  LLM_MODE=transparent  — Strands `BedrockModel` pointed at the REAL Bedrock runtime host
                     (endpoint_url=BEDROCK_ENDPOINT), unsigned. ztunnel transparently captures it
                     and the gateway injects the credential + originates TLS. The AGENT picks the
                     model (it is in the Bedrock URL); the gateway only vends the credential.

  LLM_MODE=cooperative  — Strands `OpenAIModel` pointed at the GATEWAY as an OpenAI-compatible endpoint
                     (base_url=LLM_ENDPOINT), no credential. The gateway steers the model/provider
                     and injects the token. The GATEWAY picks the model; the agent is
                     provider-agnostic.

  LLM_MODE=off (or unset) — skip the LLM step. The writer still polls and logs the poem requests it
                     would work on, but writes no poem and cuts no PR (a harmless dry run).

MODEL CHOICE MATTERS. A Strands agent drives the tools itself, so it needs solid tool-calling: prefer Claude Sonnet (cooperative mode's primary priority group) or Nova Pro over
Nova Micro. BEDROCK_MODEL still defaults to a small model for cheap smoke tests — raise it before
judging the loop's quality.

Notes on the GitHub MCP `list_issues` tool (verified against github/github-mcp-server):
  - It is GraphQL-backed and returns a JSON object: {"issues": [...], "totalCount": N,
    "pageInfo": {...}} — NOT a bare array and NOT an "items" wrapper.
  - Each issue carries number/title/body/state/user/labels/... but NOT `assignees`, and the
    connection returns issues only (never pull requests). Idempotency therefore can't lean on
    assignees; instead we skip any issue that already has an open PR on its poem branch.
"""

import asyncio
import json
import os
import re
import sys
import uuid

import httpx
from botocore import UNSIGNED
from botocore.config import Config as BotocoreConfig
from mcp.client.streamable_http import streamablehttp_client
from strands import Agent
from strands.tools.mcp import MCPClient

# Per-invocation budget caps landed after 1.0; tolerate an SDK that predates them rather than
# failing to start.
try:  # pragma: no cover - version shim
    from strands.types.agent import Limits
except ImportError:  # pragma: no cover - version shim
    Limits = None


def env(name: str, default: str = "", required: bool = False) -> str:
    val = os.environ.get(name, default)
    if required and not val:
        print(f"[writer-agent] FATAL: {name} is required", file=sys.stderr, flush=True)
        sys.exit(1)
    return val


OWNER = env("GITHUB_OWNER", required=True)
REPO = env("GITHUB_REPO", required=True)
STATE = env("GITHUB_ISSUE_STATE", "open")
INTERVAL = int(env("LIST_INTERVAL_SECONDS", "60"))
MCP_ENDPOINT = env("MCP_ENDPOINT", required=True)

# Only pick up issues carrying this label (empty => every open issue is a poem request).
POEM_LABEL = env("POEM_LABEL", "")
# The branch new poems are cut from and merged back into.
BASE_BRANCH = env("BASE_BRANCH", "main")

LLM_MODE = env("LLM_MODE", "off").lower()   # transparent | cooperative | off
# cooperative mode: OpenAI-compatible base URL on the gateway (gateway steers the model).
LLM_ENDPOINT = env("LLM_ENDPOINT")
# cooperative mode: usually empty, so the gateway's backend decides. Set it only to ask the gateway for a
# specific model.
COOPERATIVE_MODEL = env("COOPERATIVE_MODEL", "")
# transparent mode: the real Bedrock runtime base URL (the agent picks the model).
BEDROCK_ENDPOINT = env("BEDROCK_ENDPOINT")
BEDROCK_MODEL = env("BEDROCK_MODEL", "amazon.nova-micro-v1:0")
# Signing region for the unsigned client's endpoint resolution; the gateway re-signs anyway.
AWS_REGION = env("AWS_REGION", "us-east-1")
# Cap the agent loop so a confused model cannot spin on tools forever.
MAX_TURNS = int(env("MAX_AGENT_TURNS", "12"))

# The GitHub MCP tools the writer's model is allowed to see. Two reasons to allowlist rather than
# hand it everything the server exposes:
#   1. the GitHub MCP server publishes dozens of tools, and every unused tool spec is context the
#      model pays for on every turn;
#   2. it makes the writer/reviewer authority split legible in the code — `merge_pull_request` is
#      absent here, just as it is absent from the credential the gateway vends this identity. The
#      gateway is still the thing that ENFORCES that; this list only makes the intent obvious.
# Both the granular (`update_issue`) and consolidated (`issue_write`) tool names are listed, since
# which one a given github-mcp-server build exposes depends on its enabled toolsets.
WRITER_TOOLS = {
    "create_branch",
    "push_files",
    "create_or_update_file",
    "create_pull_request",
    "add_issue_comment",
    "update_issue",
    "issue_write",
}

# The writer and reviewer hand a poem PR back and forth through its comment thread — the loop's
# durable, restart-safe state. The reviewer tags each change request with REVIEWER_CHANGES_MARKER;
# the writer tags each revision with WRITER_REVISION_MARKER. Whichever marker is newest tells each
# agent whose turn it is, so the writer needs no in-memory bookkeeping to know what to revise.
REVIEWER_CHANGES_MARKER = "<!-- reviewer-agent:request-changes -->"
WRITER_REVISION_MARKER = "<!-- writer-agent:revised -->"

WRITER_SYSTEM_PROMPT = (
    "You are a poet who publishes through GitHub. You write original poems on request and ship them "
    "as pull requests using the GitHub tools available to you.\n"
    "\n"
    "Poem rules: honor any form, subject, tone, or length the request asks for. The poem text is "
    "verse only — no title line, no preamble, no commentary, and no Markdown code fences.\n"
    "\n"
    "Publishing rules:\n"
    "- Use EXACTLY the branch name, file path, and commit message given to you. Never invent your "
    "own; they are how the rest of the system finds your work.\n"
    "- Write the poem file with `push_files` (it creates the file on a new branch and updates it in "
    "place on later revisions).\n"
    "- A tool error saying a branch or pull request already exists is expected on a retry. Treat it "
    "as success and carry on.\n"
    "- When you have finished the GitHub work, reply with ONLY the final poem text. Do not "
    "summarize what you did.\n"
    "\n"
    "You hold no GitHub credential. The egress gateway attaches one based on this workload's "
    "identity, which is why some actions succeed for you and others do not exist for you at all."
)


# ─────────────────────────────────────────────────────────────────────────────────────────────────
# MCP plumbing: the deterministic reads go through call_tool_async on the SAME MCPClient session the
# agent's tools come from, so the poller and the model share one gateway connection (one HBONE hop,
# one credential injection) rather than opening a second.
# ─────────────────────────────────────────────────────────────────────────────────────────────────


def result_text(result) -> str:
    """Join the text content blocks of an MCP tool result into a printable string.

    Strands returns a ToolResult-shaped mapping ({"content": [{"text": ...}], "status": ...}); older
    shapes expose the same fields as attributes. Read both defensively."""
    content = result.get("content") if isinstance(result, dict) else getattr(result, "content", None)
    parts = []
    for block in content or []:
        text = block.get("text") if isinstance(block, dict) else getattr(block, "text", None)
        if text:
            parts.append(text)
    return "\n".join(parts)


def result_is_error(result) -> bool:
    """True when the tool reported failure. Strands surfaces it as status == "error"; tolerate the
    raw MCP `isError` flag too."""
    if isinstance(result, dict):
        if result.get("status") == "error":
            return True
        return bool(result.get("isError", result.get("is_error", False)))
    if getattr(result, "status", None) == "error":
        return True
    return bool(getattr(result, "isError", getattr(result, "is_error", False)))


async def call_tool(client: MCPClient, name: str, args: dict):
    """Call an MCP tool directly (bypassing the model); return (text, is_error). Never raises for a
    tool-level error."""
    try:
        result = await client.call_tool_async(tool_use_id=f"{name}-{uuid.uuid4().hex[:8]}", name=name, arguments=args)
    except Exception as exc:  # noqa: BLE001 - unknown tool / transport error surfaces as a soft error
        return f"{exc!r}", True
    return result_text(result), result_is_error(result)


def parse_json(text: str):
    """Parse a tool's textual result as JSON, tolerating leading/trailing prose."""
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        match = re.search(r"(\[.*\]|\{.*\})", text, re.DOTALL)
        if match:
            return json.loads(match.group(1))
        raise


def as_list(parsed, *keys) -> list:
    """Coerce a parsed tool result into a list of records. `list_issues`/`list_pull_requests`
    wrap their arrays under a key (e.g. "issues"); older/other tools return a bare array."""
    if isinstance(parsed, list):
        return parsed
    if isinstance(parsed, dict):
        for key in keys:
            if isinstance(parsed.get(key), list):
                return parsed[key]
        # last resort: the first list-valued field
        for value in parsed.values():
            if isinstance(value, list):
                return value
    return []


def slugify(text: str, limit: int = 40) -> str:
    slug = re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")
    return slug[:limit].strip("-") or "poem"


def branch_for(issue: dict) -> str:
    """Deterministic per-issue branch name — also our durable idempotency key."""
    return f"poem/issue-{issue['number']}-{slugify(issue.get('title') or '')}"


async def whoami(client: MCPClient) -> str | None:
    """Resolve the authenticated login (the credential Agent Gateway injects) so the agent can
    assign issues to itself."""
    text, is_error = await call_tool(client, "get_me", {"reason": "self-assign poem issues"})
    if is_error:
        print(f"[writer-agent] get_me error: {text}", flush=True)
        return None
    try:
        login = parse_json(text).get("login")
    except (json.JSONDecodeError, AttributeError):
        print(f"[writer-agent] could not parse get_me result: {text[:200]}", flush=True)
        return None
    print(f"[writer-agent] authenticated as {login!r}", flush=True)
    return login


async def fetch_issues(client: MCPClient) -> list | None:
    """List repo issues via the GitHub MCP server; return the parsed list, or None on error.
    The tool wraps the array under the "issues" key."""
    args = {"owner": OWNER, "repo": REPO, "state": STATE}
    if POEM_LABEL:
        args["labels"] = [POEM_LABEL]
    text, is_error = await call_tool(client, "list_issues", args)
    if is_error:
        print(f"[writer-agent] list_issues error: {text}", flush=True)
        return None
    try:
        return as_list(parse_json(text), "issues", "items")
    except json.JSONDecodeError:
        print(f"[writer-agent] could not parse list_issues result: {text[:200]}", flush=True)
        return None


def head_ref(pr: dict) -> str:
    """A PR's head branch name, across the shapes the MCP server may emit. Poem branch names are
    unique per issue, so a PR's head ref is the durable link back to the issue it came from."""
    head = pr.get("head")
    if isinstance(head, dict):
        return head.get("ref") or head.get("label") or ""
    if isinstance(head, str):
        return head
    return pr.get("headRefName") or ""


async def fetch_open_prs(client: MCPClient) -> list:
    """Parsed list of the repo's open PRs. A matching head ref tells us an issue already has a PR
    (revise vs. create fresh); the PR number lets us read its review thread. (list_issues does not
    return assignees, so we can't lean on our own assignment showing up — the PR is the signal.)"""
    text, is_error = await call_tool(client, "list_pull_requests", {"owner": OWNER, "repo": REPO, "state": "open"})
    if is_error:
        print(f"[writer-agent] list_pull_requests error (skipping this tick): {text}", flush=True)
        return []
    try:
        return as_list(parse_json(text), "pull_requests", "pullRequests", "items")
    except json.JSONDecodeError:
        print(f"[writer-agent] could not parse list_pull_requests result: {text[:200]}", flush=True)
        return []


async def read_pr(client: MCPClient, pr_number: int, method: str, legacy: str) -> tuple[str, bool]:
    """Read PR data via the consolidated `pull_request_read` tool (method=get_comments/get_diff),
    falling back to the legacy single-purpose tool if this server still exposes it."""
    text, is_error = await call_tool(
        client, "pull_request_read", {"method": method, "owner": OWNER, "repo": REPO, "pullNumber": pr_number}
    )
    if is_error:
        text2, is_error2 = await call_tool(client, legacy, {"owner": OWNER, "repo": REPO, "pullNumber": pr_number})
        if not is_error2:
            return text2, False
        return "", True
    return text, False


async def pr_comments(client: MCPClient, pr_number: int) -> list | None:
    """The PR's comment bodies, or None if they could not be read."""
    text, is_error = await read_pr(client, pr_number, "get_comments", "get_issue_comments")
    if is_error:
        return None
    try:
        return as_list(parse_json(text), "comments", "items")
    except json.JSONDecodeError:
        return None


def comment_body(comment) -> str:
    if isinstance(comment, dict):
        return comment.get("body") or ""
    return comment if isinstance(comment, str) else ""


def pending_feedback(comments: list) -> str | None:
    """The reviewer's latest change request that the writer has NOT yet answered, or None.

    Walk the PR comment thread in order: a reviewer change-request marker means "your turn, writer";
    a writer revision marker means the writer already answered the request before it. Whichever
    marker appears last decides — so feedback is returned only when there is an unaddressed round,
    which makes revising naturally idempotent (once we comment back, the writer is no longer 'up')."""
    pending = None
    for comment in comments:
        body = comment_body(comment)
        if REVIEWER_CHANGES_MARKER in body:
            pending = body
        elif WRITER_REVISION_MARKER in body:
            pending = None
    return pending


async def outstanding_feedback(client: MCPClient, pr_number: int) -> str | None:
    comments = await pr_comments(client, pr_number)
    return None if comments is None else pending_feedback(comments)


def poem_from_diff(diff: str) -> str:
    """Recover the current poem text from a PR's unified diff. The poem file is added whole against
    the base branch, so the added ('+') lines are the file; strip the title header and the
    '_Requested in #N._' footer the writer wraps around the verse to leave just the poem."""
    body_lines = []
    for line in diff.splitlines():
        if line.startswith(("+++", "---", "@@", "diff ", "index ")):
            continue
        if line.startswith("+"):
            body_lines.append(line[1:])
    poem_lines = []
    for line in body_lines:
        stripped = line.strip()
        if stripped.startswith("# "):
            continue
        if stripped.startswith("_Requested in #") and stripped.endswith("._"):
            continue
        poem_lines.append(line)
    return "\n".join(poem_lines).strip()


async def fetch_current_poem(client: MCPClient, pr_number: int) -> str:
    """The poem currently on the PR, so a revision can build on it rather than start from scratch."""
    text, is_error = await read_pr(client, pr_number, "get_diff", "get_pull_request_diff")
    return "" if is_error else poem_from_diff(text)


def is_poem_request(issue: dict) -> bool:
    """Pick issues this agent should turn into a poem: (if a POEM_LABEL filter is set) carrying that
    label. The GraphQL issues connection returns issues only, so there are no PRs to filter out."""
    number = issue.get("number")
    if number is None:
        return False
    if POEM_LABEL:
        labels = {lbl if isinstance(lbl, str) else lbl.get("name") for lbl in issue.get("labels", []) or []}
        if POEM_LABEL not in labels:
            return False
    return True


def poem_file(issue: dict) -> tuple[str, str]:
    """Return (branch, path) for an issue's poem — shared by the create and revise prompts so both
    always write the same file on the same branch (a revision overwrites the first draft)."""
    number = issue["number"]
    title = issue.get("title") or f"issue-{number}"
    return branch_for(issue), f"poems/issue-{number}-{slugify(title)}.md"


# ─────────────────────────────────────────────────────────────────────────────────────────────────
# Strands model providers — one per egress mode, both credential-free.
# ─────────────────────────────────────────────────────────────────────────────────────────────────


async def strip_authorization(request: httpx.Request) -> None:
    """Drop any Authorization header the OpenAI SDK added.

    The SDK refuses to build a client without an api_key, so we give it a placeholder and remove the
    header it derives from it. That keeps cooperative mode credential-free on the wire, and leaves nothing for the gateway's injected credential
    to collide with."""
    request.headers.pop("authorization", None)


def build_model():
    """The Strands model provider for this pod's egress mode. Neither path holds a credential."""
    if LLM_MODE == "transparent":
        from strands.models import BedrockModel

        # endpoint_url points at the REAL Bedrock host over plain http:// so the gateway can see and
        # inject; signature_version=UNSIGNED means botocore resolves no credentials and signs
        # nothing, so the request leaves this pod bare. streaming=False keeps it on the plain
        # /converse path the `Detect` route already covers, which is also where the gateway reads
        # token usage for the per-identity LLM budget.
        return BedrockModel(
            model_id=BEDROCK_MODEL,
            endpoint_url=BEDROCK_ENDPOINT,
            region_name=AWS_REGION,
            streaming=False,
            boto_client_config=BotocoreConfig(
                signature_version=UNSIGNED,
                retries={"max_attempts": 2, "mode": "standard"},
                read_timeout=60,
            ),
        )
    if LLM_MODE == "cooperative":
        import openai
        from strands.models.openai import OpenAIModel

        # The gateway is the OpenAI-compatible endpoint. An empty model_id lets the gateway's backend
        # choose (including its priority-group failover); set COOPERATIVE_MODEL only to request one.
        #
        # Pass a prebuilt `client`, NOT `client_args` with an http_client: with client_args, Strands
        # builds an AsyncOpenAI per request inside `async with`, and closing it closes the shared
        # httpx client too — the first LLM call succeeds and every later one is APIConnectionError.
        # An injected client is caller-managed and never closed; all calls run on main()'s loop.
        return OpenAIModel(
            model_id=COOPERATIVE_MODEL,
            client=openai.AsyncOpenAI(
                api_key="unused-agent-gateway-injects-the-credential",
                base_url=LLM_ENDPOINT,
                http_client=httpx.AsyncClient(timeout=120, event_hooks={"request": [strip_authorization]}),
            ),
        )
    raise ValueError(f"unknown LLM_MODE={LLM_MODE!r}")


def build_agent(model, tools) -> Agent:
    """A fresh Strands agent for one unit of work.

    Fresh per issue on purpose: each poem is an independent task, so a clean conversation keeps
    context (and cost) bounded and stops one issue's history from steering the next."""
    return Agent(model=model, tools=tools, system_prompt=WRITER_SYSTEM_PROMPT, callback_handler=None)


def select_tools(all_tools: list) -> list:
    """Narrow the MCP server's tools to the writer's allowlist."""
    tools = [tool for tool in all_tools if getattr(tool, "tool_name", None) in WRITER_TOOLS]
    if not tools:
        names = sorted(getattr(tool, "tool_name", "?") for tool in all_tools)
        print(
            "[writer-agent] WARNING: no tool matched WRITER_TOOLS; the model will have nothing to "
            f"call. Server exposes: {names}",
            file=sys.stderr,
            flush=True,
        )
    return tools


async def run_agent(agent: Agent, prompt: str) -> str:
    """Run one Strands agent invocation and return its final text."""
    kwargs = {}
    if Limits is not None:
        kwargs["limits"] = Limits(turns=MAX_TURNS)
    result = await agent.invoke_async(prompt, **kwargs)
    return str(result).strip()


def request_text(issue: dict) -> str:
    return f"Title: {issue.get('title', '')}\n\nRequest:\n{issue.get('body') or '(no description)'}"


# ─────────────────────────────────────────────────────────────────────────────────────────────────
# The two units of work.
# ─────────────────────────────────────────────────────────────────────────────────────────────────


async def handle_issue(client: MCPClient, model, tools, issue: dict, me: str | None) -> None:
    """First draft: hand the issue to the agent and let it claim, compose, and open the PR."""
    number = issue["number"]
    title = issue.get("title") or f"issue-{number}"
    branch, path = poem_file(issue)
    print(f"[writer-agent] handling poem request #{number}: {title!r}", flush=True)

    claim = (
        f"First, claim this issue by assigning it to {me!r} (use `update_issue`, or `issue_write` "
        "with method=update if that is what this server exposes). If the assignment fails, log "
        "nothing and continue — it is not required.\n\n"
        if me
        else ""
    )
    prompt = (
        f"A new poem has been requested in {OWNER}/{REPO} issue #{number}.\n\n"
        f"{request_text(issue)}\n\n"
        f"{claim}"
        "Then write the poem and open a pull request for it, in this order:\n"
        f"1. `create_branch` — branch {branch!r} from {BASE_BRANCH!r}.\n"
        f"2. `push_files` — on branch {branch!r}, write the single file {path!r} with commit message "
        f"'Add poem for issue #{number}'. The file content must be exactly:\n"
        f"   # {title}\n"
        "   <blank line>\n"
        "   <the poem>\n"
        "   <blank line>\n"
        f"   _Requested in #{number}._\n"
        f"3. `create_pull_request` — head {branch!r}, base {BASE_BRANCH!r}, title "
        f"'Add poem for issue #{number}: {title}' (truncate to 120 characters), and a body whose "
        f"first line is 'Closes #{number}'.\n\n"
        "Then reply with ONLY the poem text."
    )

    try:
        poem = await run_agent(build_agent(model, tools), prompt)
    except Exception as exc:  # noqa: BLE001 - keep the loop alive; retry next tick
        print(f"[writer-agent] agent error for issue #{number} ({LLM_MODE}): {exc!r}", file=sys.stderr, flush=True)
        return
    print(f"[writer-agent] poem for #{number}:\n{poem}", flush=True)


async def handle_revision(client: MCPClient, model, tools, issue: dict, pr: dict) -> None:
    """The PR already exists, so this issue is in the review loop. If the reviewer left change
    requests the writer has not answered yet, hand them to the agent to resolve, then make sure the
    PR goes back to the reviewer tagged with the revision marker."""
    number = issue["number"]
    pr_number = pr["number"]

    feedback = await outstanding_feedback(client, pr_number)
    if not feedback:
        print(f"[writer-agent] issue #{number}: PR #{pr_number} open, awaiting review; nothing to revise", flush=True)
        return

    print(f"[writer-agent] issue #{number}: addressing reviewer feedback on PR #{pr_number}", flush=True)
    previous = await fetch_current_poem(client, pr_number)
    branch, path = poem_file(issue)
    title = issue.get("title") or f"issue-{number}"

    prompt = (
        f"Your poem for {OWNER}/{REPO} issue #{number} is open as pull request #{pr_number}, and the "
        "reviewer has asked for changes.\n\n"
        f"THE ORIGINAL REQUEST\n{request_text(issue)}\n\n"
        f"YOUR PREVIOUS POEM\n{previous or '(unavailable)'}\n\n"
        f"REVIEWER FEEDBACK — address every point\n{feedback}\n\n"
        "Rewrite the poem so it still fulfills the request and resolves all of the feedback, then:\n"
        f"1. `push_files` — on the EXISTING branch {branch!r}, overwrite {path!r} with commit message "
        f"'Revise poem for issue #{number} per reviewer feedback'. Same file shape as before: the "
        f"'# {title}' heading, a blank line, the revised poem, a blank line, then "
        f"'_Requested in #{number}._'.\n"
        f"2. `add_issue_comment` — comment on issue_number {pr_number} to hand the PR back for "
        f"review. The comment body must BEGIN with this exact line:\n"
        f"   {WRITER_REVISION_MARKER}\n"
        "   followed by a short note on what you changed.\n\n"
        "Then reply with ONLY the revised poem text."
    )

    try:
        poem = await run_agent(build_agent(model, tools), prompt)
    except Exception as exc:  # noqa: BLE001 - keep the loop alive; retry next tick
        print(f"[writer-agent] agent error revising issue #{number} ({LLM_MODE}): {exc!r}", file=sys.stderr, flush=True)
        return
    print(f"[writer-agent] revised poem for #{number}:\n{poem}", flush=True)

    await ensure_handback(client, pr_number)


async def ensure_handback(client: MCPClient, pr_number: int) -> None:
    """Backstop the turn-taking protocol.

    The agent is told to post the revision marker itself, but the handoff is an invariant, not a
    suggestion: without a marker comment the reviewer never learns a fresh revision landed and the
    loop wedges. So re-read the thread and post the marker ourselves if the model did not."""
    comments = await pr_comments(client, pr_number)
    if comments is None:
        print(f"[writer-agent] could not verify handback comment on PR #{pr_number}", flush=True)
        return
    if pending_feedback(comments) is None:
        return  # the agent's own marker comment closed the round

    body = (
        f"{WRITER_REVISION_MARKER}\n**Writer agent: revised the poem to address the review.**\n\n"
        "Rewrote the poem to address the reviewer's points; ready for another look."
    )
    _, is_error = await call_tool(
        client, "add_issue_comment", {"owner": OWNER, "repo": REPO, "issue_number": pr_number, "body": body}
    )
    if is_error:
        print(f"[writer-agent] warning: could not comment on PR #{pr_number} after revising", flush=True)
    else:
        print(f"[writer-agent] posted the handback comment on PR #{pr_number} on the agent's behalf", flush=True)


async def run_once(client: MCPClient, model, tools, me: str | None) -> None:
    issues = await fetch_issues(client)
    if issues is None:
        return

    requests = [i for i in issues if is_poem_request(i)]
    print(
        f"[writer-agent] {OWNER}/{REPO}: {len(issues)} {STATE} issue(s), "
        f"{len(requests)} candidate poem request(s)",
        flush=True,
    )
    if not requests:
        return

    # With no LLM configured, this is a dry run: report the work, but don't claim, write, or revise.
    if model is None:
        for issue in requests:
            print(f"[writer-agent] (dry run) would handle poem request #{issue['number']}: {issue.get('title')!r}", flush=True)
        return

    # An issue with an open poem PR is already in the review loop (revise on feedback); one without
    # needs a first draft. The PR's head ref is the durable link back to its issue.
    branch_to_pr = {head_ref(pr): pr for pr in await fetch_open_prs(client)}
    for issue in requests:
        pr = branch_to_pr.get(branch_for(issue))
        if pr:
            await handle_revision(client, model, tools, issue, pr)
        else:
            await handle_issue(client, model, tools, issue, me)


async def main() -> None:
    target = LLM_ENDPOINT if LLM_MODE == "cooperative" else BEDROCK_ENDPOINT if LLM_MODE == "transparent" else "(disabled)"
    print(
        f"[writer-agent] starting; runtime=strands; mcp={MCP_ENDPOINT}; llm_mode={LLM_MODE}; "
        f"llm_target={target}; repo={OWNER}/{REPO}; label={POEM_LABEL or '(any)'}; base={BASE_BRANCH}; "
        f"interval={INTERVAL}s; no credentials carried by this pod",
        flush=True,
    )

    # Built once and reused: the provider is stateless, and in cooperative mode it owns an httpx client
    # whose connection pool should outlive a single tick.
    model = build_model() if LLM_MODE in ("cooperative", "transparent") else None

    while True:
        try:
            # No headers => no credential on the MCP session. The gateway injects this identity's
            # GitHub token.
            mcp_client = MCPClient(lambda: streamablehttp_client(MCP_ENDPOINT))
            with mcp_client:
                tools = select_tools(mcp_client.list_tools_sync())
                me = await whoami(mcp_client)
                await run_once(mcp_client, model, tools, me)
        except Exception as exc:  # noqa: BLE001 - keep the workload running; log and retry next tick
            print(f"[writer-agent] error: {exc!r}", file=sys.stderr, flush=True)
        await asyncio.sleep(INTERVAL)


if __name__ == "__main__":
    asyncio.run(main())
