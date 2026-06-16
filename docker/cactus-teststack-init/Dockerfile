# UV Docker best practices: https://docs.astral.sh/uv/guides/integration/docker/
# (1) Make database migration stage
FROM python:3.13-slim-bookworm AS builder
COPY --from=ghcr.io/astral-sh/uv:0.11.16 /uv /bin/uv

ARG ENVOY_VERSION
ARG GITHUB_ORG=bsgip

# copy instead of hardlink (cache mount requirement); strip dev deps;
# use the image's Python rather than downloading a new one
# UV_COMPILE_BYTECODE intentionally omitted - venv is discarded after generating migrate.sql
ENV UV_LINK_MODE=copy \
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
    uv sync --locked --no-editable

ENV PATH="/app/.venv/bin:$PATH"

WORKDIR /app/src/envoy/server
ENV DATABASE_URL="postgresql://abc:abc@abc/abc"
RUN alembic upgrade head --sql > /app/migrate.sql

# (2) Final stage
FROM alpine:3.23

ENV MIGRATION_SENTINEL=""

RUN apk add --no-cache inotify-tools bash postgresql-client

# Envoy migrations sql, tail it for current alembic revision
COPY --from=builder /app/migrate.sql /migrate.sql

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
