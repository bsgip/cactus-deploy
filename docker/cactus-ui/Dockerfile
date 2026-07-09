# UV Docker best practices: https://docs.astral.sh/uv/guides/integration/docker/
# CLONE stage - shared checkout so we only pull the repo once
FROM python:3.12-slim-bookworm AS source

ARG CACTUS_UI_VERSION
ARG GITHUB_ORG=bsgip

RUN apt-get update && apt-get install --no-install-recommends -y git && rm -rf /var/lib/apt/lists/*

# Clone so uv can read pyproject.toml + uv.lock for a fully locked install.
# Previously pip install git+... was used but couldn't leverage the lock file.
WORKDIR /app
RUN git clone --depth 1 --branch ${CACTUS_UI_VERSION} \
    https://github.com/${GITHUB_ORG}/cactus-ui.git . || \
    (git clone https://github.com/${GITHUB_ORG}/cactus-ui.git . && \
     git checkout ${CACTUS_UI_VERSION})

# FRONTEND BUILD stage - React SPA, served by Flask from frontend/dist
FROM node:20-bookworm-slim AS frontend-builder

WORKDIR /app/frontend
COPY --from=source /app/frontend/ .
RUN npm ci && npm run build

# BUILD stage
FROM python:3.12-slim-bookworm AS builder
COPY --from=ghcr.io/astral-sh/uv:0.11.16 /uv /bin/uv

# pre-compile .pyc at build time for faster startup; copy instead of hardlink (cache mount
# requirement); strip dev deps; use the image's Python rather than downloading a new one
ENV UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy \
    UV_NO_DEV=1 \
    UV_PYTHON_DOWNLOADS=0

WORKDIR /app
COPY --from=source /app .

RUN --mount=type=cache,target=/root/.cache/uv \
    uv sync --locked --no-editable && \
    uv pip install "uvicorn==0.48.0"

# Copy static overrides into the installed package directory
COPY static /tmp/static
RUN cp -rn /tmp/static/* /app/.venv/lib/python3.12/site-packages/cactus_ui/static/

# RUN stage
FROM python:3.12-slim-bookworm

RUN useradd -ms /bin/bash appuser

COPY --from=builder --chown=appuser:appuser /app/.venv /app/.venv
COPY --from=frontend-builder --chown=appuser:appuser /app/frontend/dist /home/appuser/app/frontend/dist

USER appuser
WORKDIR /home/appuser/app/

# conf
ENV PATH="/app/.venv/bin:$PATH"
ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1
ENV CACTUS_UI_FRONTEND_DIST=/home/appuser/app/frontend/dist
COPY --chown=appuser:appuser ./logconf.json /home/appuser/app/logconf.json

# Entrypoint
CMD ["uvicorn", "--host", "0.0.0.0", "--port", "8080", "--workers", "1", "--interface", "wsgi", "cactus_ui.server:app"]
