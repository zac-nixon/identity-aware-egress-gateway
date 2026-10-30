# Writer agent image: a small Strands Agents SDK agent.
#
# agent.py connects to a gateway-fronted MCP endpoint over streamable HTTP and loads the GitHub MCP
# tools into a Strands agent, which composes poems and opens pull requests for them. It does NOT run
# the GitHub MCP server itself and carries no GitHub credential — Agent Gateway fronts the MCP server
# and injects the credential — so nothing GitHub- or AWS-specific is bundled here.
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
