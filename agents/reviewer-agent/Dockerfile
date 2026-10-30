# Reviewer agent image: a small Strands Agents SDK agent.
#
# agent.py connects to a gateway-fronted MCP endpoint over streamable HTTP, loads the GitHub MCP
# tools into a Strands agent, reads the writer's poem PRs, judges each with the LLM, then comments
# and (on approval) merges. It does NOT run the GitHub MCP server itself and carries no GitHub
# credential — Agent Gateway fronts the MCP server and injects the reviewer's credential keyed on
# this workload's SPIFFE identity. Nothing GitHub- or AWS-specific is baked in.
# ECR Public mirror of the Docker Official Image: same image, no Docker Hub pull rate limits in CI.
FROM public.ecr.aws/docker/library/python:3.12-slim
WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY agent.py .

# Run as a non-root user (matches the Deployment's runAsNonRoot securityContext).
RUN useradd --uid 10001 --create-home agent
USER 10001

ENTRYPOINT ["python", "-u", "agent.py"]
