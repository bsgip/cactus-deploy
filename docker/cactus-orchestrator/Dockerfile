# UV Docker best practices: https://docs.astral.sh/uv/guides/integration/docker/
# BUILD stage
FROM python:3.12-slim-bookworm AS builder
COPY --from=ghcr.io/astral-sh/uv:0.11.16 /uv /bin/uv

ARG CACTUS_ORCHESTRATOR_VERSION
ARG GITHUB_ORG=bsgip

# pre-compile .pyc at build time for faster startup; copy instead of hardlink (cache mount
# requirement); strip dev deps; use the image's Python rather than downloading a new one
ENV UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy \
    UV_NO_DEV=1 \
    UV_PYTHON_DOWNLOADS=0

RUN apt-get update && apt-get install --no-install-recommends -y git && rm -rf /var/lib/apt/lists/*

# Clone so uv can read pyproject.toml + uv.lock for a fully locked install.
# Previously pip install git+... was used but couldn't leverage the lock file.
WORKDIR /app
RUN git clone --depth 1 --branch ${CACTUS_ORCHESTRATOR_VERSION} \
    https://github.com/${GITHUB_ORG}/cactus-orchestrator.git . || \
    (git clone https://github.com/${GITHUB_ORG}/cactus-orchestrator.git . && \
     git checkout ${CACTUS_ORCHESTRATOR_VERSION})

RUN --mount=type=cache,target=/root/.cache/uv \
    uv sync --locked --no-editable && \
    uv pip install "uvicorn==0.48.0"

# Record the alembic head this image expects, so update.sh can refuse to deploy
# against a database that hasn't had this migration applied yet.
RUN uv run alembic heads | awk '{print $1}' > /app/ALEMBIC_HEAD && \
    test "$(wc -l < /app/ALEMBIC_HEAD)" -eq 1

# RUN stage
FROM python:3.12-slim-bookworm

RUN apt-get update && apt-get install --no-install-recommends -y postgresql && rm -rf /var/lib/apt/lists/*

# entrypoint
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

RUN useradd -ms /bin/bash appuser

COPY --from=builder --chown=appuser:appuser /app/.venv /app/.venv
COPY --from=builder --chown=appuser:appuser /app/ALEMBIC_HEAD /app/ALEMBIC_HEAD

USER appuser

# conf
ENV PATH="/app/.venv/bin:$PATH"
ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1

# configurables
ENV LOG_LEVEL=info
COPY ./logconf.json /logconf.json

ENTRYPOINT ["/entrypoint.sh"]
