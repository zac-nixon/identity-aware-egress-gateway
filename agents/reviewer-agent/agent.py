#!/usr/bin/env python3
"""Reviewer agent: critique the writer's poem PRs and merge the good ones.

Runtime: the **Strands Agents SDK**. The GitHub MCP server's tools are loaded into a Strands `Agent`
via `MCPClient`, and the model decides which of them to call — including the merge. Strands also owns
the model call, through the provider that matches this pod's egress mode (see LLM_MODE below).

The reviewer is the second half of the two-agent teaching example. It polls the repo's open pull
requests (via the GitHub MCP server), and for each poem PR the writer opened it:

  1. reads the original request (the issue the PR closes) and the poem (the PR diff),
  2. judges the poem against an explicit quality bar (below) using an LLM, then
  3. either MERGES the PR (quality bar met) or posts review comments returning it to the writer
     (quality bar not met). When the writer pushes a revision, the reviewer re-reviews it on the
     next poll, repeating until the poem clears the bar and is merged.

Merging is the reviewer-only authority — the whole point of the example, and it reads more directly
now: `merge_pull_request` is one of the tools this agent's model can call, and it is absent from the
writer's. The gateway is still what ENFORCES the split (it vends each identity a different GitHub
credential); the tool lists just make the intent legible.

Both agents are credential-free: Agent Gateway injects each one's GitHub token keyed on its SPIFFE
identity. The reviewer runs as `sa/reviewer-agent`, whose identity the gateway authorizes for the
merge-PR path; the writer's identity is not. No token ever lives in this pod. Switching to Strands
does not change that — see the writer agent's header for the three places that stay credential-free
through the SDK layer (unheadered MCP session, unsigned Bedrock client, stripped OpenAI auth header).

WHAT STRANDS OWNS AND WHAT THIS FILE STILL OWNS: Strands owns the judgment and the resulting GitHub
actions (comment, merge). This file keeps the poller and the turn-taking protocol — which PRs are
candidates, whether a PR is awaiting the writer or has a fresh revision to re-review, and a fallback
change-request comment if the model returns a REQUEST_CHANGES verdict without posting one. A missed
marker would strand the PR, so that invariant stays in code rather than in a prompt.

The LLM call has the same two egress models as the writer (LLM_MODE=transparent|cooperative); see the writer
agent for the contrast. LLM_MODE=off makes this a dry run (report, but don't comment or merge).

MODEL CHOICE MATTERS: the model drives tools itself, so prefer Claude Sonnet or Nova Pro
over Nova Micro. BEDROCK_MODEL still defaults small for cheap smoke tests.

Quality bar (explicit + observable):
  1. The poem is non-empty and is actual verse (multiple lines).
  2. It is on-topic — it responds to the subject the request asked for.
  3. If the request named a form (haiku, sonnet, limerick, couplet, a line/stanza count, etc.), the
     poem follows it.
  4. It is clean output — no preamble, no leftover instructions, no Markdown code fences.
A poem meeting all four is merged; otherwise the reviewer returns it with comments.

Notes on the GitHub MCP tools (verified against github/github-mcp-server):
  - PR tools take `pullNumber` (camelCase); issue tools take `issue_number` (snake_case).
  - The read tools are CONSOLIDATED: there is no `get_pull_request_diff` / `get_issue` /
    `get_issue_comments` anymore. Use `pull_request_read` with `method` (get_diff, get_comments, ...)
    and `issue_read` with `method` (get, get_comments, ...). We fall back to the legacy names in case
    a server still exposes them. `get_diff` returns the raw unified diff as text (the poem lines).
  - `list_pull_requests` returns a bare array (or a wrapper); `as_list` tolerates both.
  - `merge_pull_request` and `add_issue_comment` are still single-purpose tools.
  - We post feedback with `add_issue_comment` (a PR is an issue for comments) rather than a formal
    APPROVE/REQUEST_CHANGES review: GitHub rejects self-authored reviews, and in this demo the
    writer and reviewer may share one placeholder token. With DISTINCT writer/reviewer tokens you
    could instead give the agent `pull_request_review_write` (method=create,
    event=APPROVE/REQUEST_CHANGES).
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

# Per-invocation budget caps landed after 1.0; tolerate an SDK that predates them.
try:  # pragma: no cover - version shim
    from strands.types.agent import Limits
except ImportError:  # pragma: no cover - version shim
    Limits = None


def env(name: str, default: str = "", required: bool = False) -> str:
    val = os.environ.get(name, default)
    if required and not val:
        print(f"[reviewer-agent] FATAL: {name} is required", file=sys.stderr, flush=True)
        sys.exit(1)
    return val


OWNER = env("GITHUB_OWNER", required=True)
REPO = env("GITHUB_REPO", required=True)
INTERVAL = int(env("LIST_INTERVAL_SECONDS", "60"))
MCP_ENDPOINT = env("MCP_ENDPOINT", required=True)

# Only review PRs whose head branch starts with this prefix (the writer's poem branches).
POEM_BRANCH_PREFIX = env("POEM_BRANCH_PREFIX", "poem/")
# How to merge an approved poem PR.
MERGE_METHOD = env("MERGE_METHOD", "squash")

LLM_MODE = env("LLM_MODE", "off").lower()   # transparent | cooperative | off
LLM_ENDPOINT = env("LLM_ENDPOINT")
COOPERATIVE_MODEL = env("COOPERATIVE_MODEL", "")
BEDROCK_ENDPOINT = env("BEDROCK_ENDPOINT")
BEDROCK_MODEL = env("BEDROCK_MODEL", "amazon.nova-micro-v1:0")
AWS_REGION = env("AWS_REGION", "us-east-1")
MAX_TURNS = int(env("MAX_AGENT_TURNS", "8"))

# The GitHub MCP tools the reviewer's model is allowed to see — deliberately just two. `merge_pull_request`
# is the reviewer-only authority; the writer's allowlist does not contain it, and neither does the
# credential the gateway vends the writer's identity.
REVIEWER_TOOLS = {
    "add_issue_comment",
    "merge_pull_request",
}

# The reviewer and writer hand a poem PR back and forth through its comment thread — the loop's
# durable, restart-safe state. Every reviewer comment carries REVIEW_MARKER; a change request also
# carries REVIEWER_CHANGES_MARKER, and the writer tags each revision with WRITER_REVISION_MARKER.
# Whichever of those two markers is newest tells the reviewer whether a PR is awaiting the writer
# (skip) or has a fresh revision to re-review. An approved PR is merged and leaves the open list.
REVIEW_MARKER = "<!-- reviewer-agent -->"
REVIEWER_CHANGES_MARKER = "<!-- reviewer-agent:request-changes -->"
WRITER_REVISION_MARKER = "<!-- writer-agent:revised -->"

REVIEWER_SYSTEM_PROMPT = (
    "You are a poetry editor reviewing submitted poems on GitHub pull requests, and you have the "
    "authority to merge the ones that pass.\n"
    "\n"
    "Apply this quality bar: (1) the poem is non-empty and is actual verse with multiple lines; "
    "(2) it is on-topic for the request's subject; (3) if the request named a form (haiku, sonnet, "
    "limerick, couplet, a line or stanza count, a rhyme scheme), the poem follows it; (4) it is "
    "clean text with no preamble, no leftover instructions, and no Markdown code fences.\n"
    "\n"
    "Never merge on an unclear judgment — if you are unsure, request changes.\n"
    "\n"
    "Always finish by replying with your verdict as text: a first line of exactly "
    "'VERDICT: APPROVE' or 'VERDICT: REQUEST_CHANGES', then a blank line, then 2-4 short bullet "
    "points. If you approve, the bullets say what works; if you request changes, each bullet is a "
    "specific, actionable fix.\n"
    "\n"
    "You hold no GitHub credential. The egress gateway attaches one based on this workload's "
    "identity, which is why merging is available to you at all."
)


# ─────────────────────────────────────────────────────────────────────────────────────────────────
# MCP plumbing: the deterministic reads go through call_tool_async on the SAME MCPClient session the
# agent's tools come from, so the poller and the model share one gateway connection.
# ─────────────────────────────────────────────────────────────────────────────────────────────────


def result_text(result) -> str:
    """Join the text content blocks of an MCP tool result, across the shapes Strands may return."""
    content = result.get("content") if isinstance(result, dict) else getattr(result, "content", None)
    parts = []
    for block in content or []:
        text = block.get("text") if isinstance(block, dict) else getattr(block, "text", None)
        if text:
            parts.append(text)
    return "\n".join(parts)


def result_is_error(result) -> bool:
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
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        match = re.search(r"(\[.*\]|\{.*\})", text, re.DOTALL)
        if match:
            return json.loads(match.group(1))
        raise


def as_list(parsed, *keys) -> list:
    """Coerce a parsed tool result into a list of records, tolerating a wrapper key or a bare array."""
    if isinstance(parsed, list):
        return parsed
    if isinstance(parsed, dict):
        for key in keys:
            if isinstance(parsed.get(key), list):
                return parsed[key]
        for value in parsed.values():
            if isinstance(value, list):
                return value
    return []


def head_ref(pr: dict) -> str:
    """Extract a PR's head branch name across the shapes the MCP server may emit."""
    head = pr.get("head")
    if isinstance(head, dict):
        return head.get("ref") or head.get("label") or ""
    if isinstance(head, str):
        return head
    return pr.get("headRefName") or ""


def issue_number_from_ref(ref: str) -> int | None:
    """The writer names poem branches poem/issue-<N>-<slug>; recover the source issue number."""
    match = re.search(r"issue-(\d+)", ref)
    return int(match.group(1)) if match else None


async def whoami(client: MCPClient) -> str | None:
    text, is_error = await call_tool(client, "get_me", {"reason": "review and merge poem PRs"})
    if is_error:
        print(f"[reviewer-agent] get_me error: {text}", flush=True)
        return None
    try:
        login = parse_json(text).get("login")
    except (json.JSONDecodeError, AttributeError):
        return None
    print(f"[reviewer-agent] authenticated as {login!r}", flush=True)
    return login


async def fetch_open_prs(client: MCPClient) -> list | None:
    text, is_error = await call_tool(client, "list_pull_requests", {"owner": OWNER, "repo": REPO, "state": "open"})
    if is_error:
        print(f"[reviewer-agent] list_pull_requests error: {text}", flush=True)
        return None
    try:
        return as_list(parse_json(text), "pull_requests", "pullRequests", "items")
    except json.JSONDecodeError:
        print(f"[reviewer-agent] could not parse list_pull_requests result: {text[:200]}", flush=True)
        return None


async def read_pr(client: MCPClient, pr_number: int, method: str, legacy: str) -> tuple[str, bool]:
    """Read PR data via the consolidated `pull_request_read` tool (method=get_diff/get_comments/...),
    falling back to the legacy single-purpose tool name if this server still exposes it."""
    text, is_error = await call_tool(
        client, "pull_request_read", {"method": method, "owner": OWNER, "repo": REPO, "pullNumber": pr_number}
    )
    if is_error:
        text2, is_error2 = await call_tool(client, legacy, {"owner": OWNER, "repo": REPO, "pullNumber": pr_number})
        if not is_error2:
            return text2, False
        print(
            f"[reviewer-agent] read {method} for PR #{pr_number} failed; "
            f"pull_request_read -> {text!r}; {legacy} -> {text2!r}",
            flush=True,
        )
        return "", True
    return text, False


def comment_body(comment) -> str:
    if isinstance(comment, dict):
        return comment.get("body") or ""
    return comment if isinstance(comment, str) else ""


async def pr_comments(client: MCPClient, pr_number: int) -> list | None:
    text, is_error = await read_pr(client, pr_number, "get_comments", "get_issue_comments")
    if is_error:
        return None
    try:
        return as_list(parse_json(text), "comments", "items")
    except json.JSONDecodeError:
        return None


def review_pending(comments: list) -> bool:
    """Is it the reviewer's turn, given a PR's comment thread?

    Walk it in order: a change-request marker means the reviewer has judged the current revision (now
    wait for the writer); a writer-revision marker means a fresh revision landed (review it). A PR
    with neither has never been reviewed. Whichever marker is newest wins, so this is True exactly
    when an un-reviewed revision is waiting — which closes the loop with no in-memory bookkeeping."""
    pending = True
    for comment in comments:
        body = comment_body(comment)
        if REVIEWER_CHANGES_MARKER in body:
            pending = False
        elif WRITER_REVISION_MARKER in body:
            pending = True
    return pending


async def needs_review(client: MCPClient, pr_number: int) -> bool:
    comments = await pr_comments(client, pr_number)
    if comments is None:
        return True  # can't tell -> review; posting a comment and merging are safe to retry
    return review_pending(comments)


async def fetch_request(client: MCPClient, issue_number: int) -> str:
    """The original poem request — the issue the PR closes. Uses the consolidated `issue_read`
    (method=get), falling back to the legacy `get_issue`."""
    text, is_error = await call_tool(
        client, "issue_read", {"method": "get", "owner": OWNER, "repo": REPO, "issue_number": issue_number}
    )
    if is_error:
        text, is_error = await call_tool(
            client, "get_issue", {"owner": OWNER, "repo": REPO, "issue_number": issue_number}
        )
    if is_error:
        return ""
    try:
        issue = parse_json(text)
        return f"Title: {issue.get('title', '')}\n\nRequest:\n{issue.get('body') or '(no description)'}"
    except json.JSONDecodeError:
        return text


async def fetch_poem_diff(client: MCPClient, pr_number: int) -> str:
    """The submitted poem, as the PR's unified diff (added lines are the poem)."""
    text, is_error = await read_pr(client, pr_number, "get_diff", "get_pull_request_diff")
    return "" if is_error else text


def parse_verdict(review: str) -> tuple[bool, str]:
    """Return (approved, comments) from the agent's final text. Default to NOT approved if the
    verdict line is unclear — never treat an ambiguous review as an approval."""
    first, _, rest = review.partition("\n")
    approved = "APPROVE" in first.upper() and "REQUEST" not in first.upper()
    comments = rest.strip() or review.strip()
    return approved, comments


# ─────────────────────────────────────────────────────────────────────────────────────────────────
# Strands model providers — one per egress mode, both credential-free. Identical to the writer's.
# ─────────────────────────────────────────────────────────────────────────────────────────────────


async def strip_authorization(request: httpx.Request) -> None:
    """Drop the Authorization header the OpenAI SDK derives from its (placeholder) api_key, so cooperative
    mode stays credential-free on the wire."""
    request.headers.pop("authorization", None)


def build_model():
    """The Strands model provider for this pod's egress mode. Neither path holds a credential."""
    if LLM_MODE == "transparent":
        from strands.models import BedrockModel

        # endpoint_url is the REAL Bedrock host over plain http:// so the gateway can see and inject;
        # signature_version=UNSIGNED means botocore resolves no credentials and signs nothing.
        # streaming=False keeps it on the plain /converse path the `Detect` route covers.
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

        # An empty model_id lets the gateway's backend choose (including priority-group failover).
        # A prebuilt `client` rather than `client_args`: Strands closes per-request clients built from
        # client_args, which also closes a shared http_client (see writer-agent/agent.py).
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
    """A fresh Strands agent per PR: each review is an independent task, so a clean conversation keeps
    context bounded and stops one PR's history from steering the next."""
    return Agent(model=model, tools=tools, system_prompt=REVIEWER_SYSTEM_PROMPT, callback_handler=None)


def select_tools(all_tools: list) -> list:
    """Narrow the MCP server's tools to the reviewer's allowlist."""
    tools = [tool for tool in all_tools if getattr(tool, "tool_name", None) in REVIEWER_TOOLS]
    if not tools:
        names = sorted(getattr(tool, "tool_name", "?") for tool in all_tools)
        print(
            "[reviewer-agent] WARNING: no tool matched REVIEWER_TOOLS; the model will have nothing "
            f"to call. Server exposes: {names}",
            file=sys.stderr,
            flush=True,
        )
    return tools


async def run_agent(agent: Agent, prompt: str) -> str:
    kwargs = {}
    if Limits is not None:
        kwargs["limits"] = Limits(turns=MAX_TURNS)
    result = await agent.invoke_async(prompt, **kwargs)
    return str(result).strip()


# ─────────────────────────────────────────────────────────────────────────────────────────────────
# The unit of work.
# ─────────────────────────────────────────────────────────────────────────────────────────────────


async def handle_pr(client: MCPClient, model, tools, pr: dict) -> None:
    """Review one poem PR: read request + poem deterministically, then let the agent judge and act."""
    number = pr["number"]
    ref = head_ref(pr)
    print(f"[reviewer-agent] reviewing PR #{number} ({ref})", flush=True)

    issue_number = issue_number_from_ref(ref)
    request = await fetch_request(client, issue_number) if issue_number else "(request not found)"
    diff = await fetch_poem_diff(client, number)
    if not diff:
        print(f"[reviewer-agent] no diff for PR #{number}; skipping this tick", flush=True)
        return

    prompt = (
        f"Review pull request #{number} in {OWNER}/{REPO}.\n\n"
        f"THE REQUEST THAT ASKED FOR THIS POEM\n{request}\n\n"
        f"THE SUBMITTED POEM (the PR diff; added lines are the poem)\n{diff[:8000]}\n\n"
        "Judge it against the quality bar, then act:\n"
        "- If it MEETS the bar: `add_issue_comment` on issue_number "
        f"{number} with a body that BEGINS with this exact line:\n"
        f"    {REVIEW_MARKER}\n"
        "  followed by '**Reviewer agent: quality bar met, merging.**' and your bullets. Then "
        f"`merge_pull_request` with pullNumber {number} and merge_method '{MERGE_METHOD}'.\n"
        "- If it does NOT meet the bar: `add_issue_comment` on issue_number "
        f"{number} with a body that BEGINS with these two exact lines:\n"
        f"    {REVIEW_MARKER}\n"
        f"    {REVIEWER_CHANGES_MARKER}\n"
        "  followed by '**Reviewer agent: changes requested.**' and your bullets. Do NOT merge.\n"
        "  The second marker line is what tells the writer it is their turn — it must be present, "
        "verbatim, or the poem is never revised.\n\n"
        "Then reply with your verdict text as instructed."
    )

    try:
        review = await run_agent(build_agent(model, tools), prompt)
    except Exception as exc:  # noqa: BLE001 - keep the loop alive; retry next tick
        print(f"[reviewer-agent] agent error for PR #{number} ({LLM_MODE}): {exc!r}", file=sys.stderr, flush=True)
        return

    approved, comments = parse_verdict(review)
    print(f"[reviewer-agent] PR #{number} verdict: {'APPROVE' if approved else 'REQUEST_CHANGES'}", flush=True)

    if not approved:
        await ensure_change_request(client, number, comments)
    # An approval that the model failed to merge needs no repair: the PR simply stays open and is
    # re-reviewed on the next tick. Only the change-request handoff can wedge the loop, so only it is
    # backstopped — and merging stays the model's action, which is the point of the example.


async def ensure_change_request(client: MCPClient, pr_number: int, comments: str) -> None:
    """Backstop the turn-taking protocol.

    The agent is told to tag its change request with REVIEWER_CHANGES_MARKER, but the handoff is an
    invariant: without that marker the writer never learns it is their turn and the PR is stranded.
    So re-read the thread and post the tagged comment ourselves if the model's did not land."""
    thread = await pr_comments(client, pr_number)
    if thread is None:
        print(f"[reviewer-agent] could not verify the change-request comment on PR #{pr_number}", flush=True)
        return
    if not review_pending(thread):
        return  # the agent's own marker comment handed the PR back

    body = (
        f"{REVIEW_MARKER}\n{REVIEWER_CHANGES_MARKER}\n**Reviewer agent: changes requested.**\n\n"
        f"{comments}"
    )
    _, is_error = await call_tool(
        client, "add_issue_comment", {"owner": OWNER, "repo": REPO, "issue_number": pr_number, "body": body}
    )
    if is_error:
        print(f"[reviewer-agent] warning: could not comment on PR #{pr_number}", flush=True)
    else:
        print(f"[reviewer-agent] posted the change request on PR #{pr_number} on the agent's behalf", flush=True)


async def run_once(client: MCPClient, model, tools) -> None:
    prs = await fetch_open_prs(client)
    if prs is None:
        return

    poem_prs = [pr for pr in prs if head_ref(pr).startswith(POEM_BRANCH_PREFIX)]
    print(f"[reviewer-agent] {OWNER}/{REPO}: {len(prs)} open PR(s), {len(poem_prs)} poem PR(s)", flush=True)
    if not poem_prs:
        return

    if model is None:
        for pr in poem_prs:
            print(f"[reviewer-agent] (dry run) would review PR #{pr['number']} ({head_ref(pr)})", flush=True)
        return

    for pr in poem_prs:
        if not await needs_review(client, pr["number"]):
            print(f"[reviewer-agent] PR #{pr['number']} already reviewed; awaiting writer revision; skipping", flush=True)
            continue
        await handle_pr(client, model, tools, pr)


async def main() -> None:
    target = LLM_ENDPOINT if LLM_MODE == "cooperative" else BEDROCK_ENDPOINT if LLM_MODE == "transparent" else "(disabled)"
    print(
        f"[reviewer-agent] starting; runtime=strands; mcp={MCP_ENDPOINT}; llm_mode={LLM_MODE}; "
        f"llm_target={target}; repo={OWNER}/{REPO}; branch_prefix={POEM_BRANCH_PREFIX}; "
        f"merge_method={MERGE_METHOD}; interval={INTERVAL}s; no credentials carried by this pod",
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
                await whoami(mcp_client)
                await run_once(mcp_client, model, tools)
        except Exception as exc:  # noqa: BLE001 - keep the workload running; log and retry next tick
            print(f"[reviewer-agent] error: {exc!r}", file=sys.stderr, flush=True)
        await asyncio.sleep(INTERVAL)


if __name__ == "__main__":
    asyncio.run(main())
