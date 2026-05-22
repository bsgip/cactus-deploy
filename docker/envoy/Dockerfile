# UV Docker best practices: https://docs.astral.sh/uv/guides/integration/docker/
# BUILD stage
FROM python:3.12-slim-bookworm AS builder
COPY --from=ghcr.io/astral-sh/uv:0.11.16 /uv /bin/uv

ARG ENVOY_VERSION
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
RUN git clone --depth 1 --branch ${ENVOY_VERSION} \
    https://github.com/${GITHUB_ORG}/envoy.git . || \
    (git clone https://github.com/${GITHUB_ORG}/envoy.git . && \
     git checkout ${ENVOY_VERSION})

RUN --mount=type=cache,target=/root/.cache/uv \
    uv sync --locked --no-editable && \
    uv pip install uvicorn python-json-logger

# RUN stage
FROM python:3.12-slim-bookworm

WORKDIR /app

RUN apt-get update && apt-get install --no-install-recommends -y netcat-traditional && rm -rf /var/lib/apt/lists/*

COPY --from=builder /app/.venv /app/.venv

# logging config
COPY logconf.admin.json ./logconf.admin.json
COPY logconf.notification.json ./logconf.notification.json
COPY logconf.server.json ./logconf.server.json
RUN mkdir /shared

# configurables
ENV PATH="/app/.venv/bin:$PATH"
ENV APP_MODULE="envoy.server.main:app"
ENV WORKERS=1
ENV LOG_CONFIG=logconf.server.json
ENV HOST=0.0.0.0
ENV PORT=8000

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
CMD ["/entrypoint.sh"]
