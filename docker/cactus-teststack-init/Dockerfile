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

RUN apt-get update && apt-get install --no-install-recommends -y \
        git postgresql postgresql-client \
    && rm -rf /var/lib/apt/lists/*

# Clone so uv can read pyproject.toml + uv.lock for a fully locked install.
WORKDIR /app
RUN git clone --depth 1 --branch ${ENVOY_VERSION} \
    https://github.com/${GITHUB_ORG}/envoy.git . || \
    (git clone https://github.com/${GITHUB_ORG}/envoy.git . && \
     git checkout ${ENVOY_VERSION})

RUN --mount=type=cache,target=/root/.cache/uv \
    uv sync --locked --no-editable

ENV PATH="/app/.venv/bin:$PATH"

# Apply every migration to a throwaway local Postgres, then snapshot the
# resulting schema with pg_dump. This collapses the (now lengthy) migration
# chain into a single schema script, so deployments apply one CREATE-everything
# file instead of replaying the full migration history from empty.
WORKDIR /app/src/envoy/server
RUN <<'EOF'
#!/usr/bin/env bash
set -euxo pipefail

# Real binaries (avoid Debian's pg_wrapper); version-agnostic.
PG_BIN="$(ls -d /usr/lib/postgresql/*/bin | head -n1)"
export PATH="$PG_BIN:$PATH"
PGDATA=/tmp/pgdata

# Postgres won't run as root, so the server is driven as the 'postgres' system
# user. Trust auth keeps this ephemeral, build-only DB password-free.
install -d -o postgres -g postgres "$PGDATA" /var/run/postgresql
su postgres -c "initdb -D '$PGDATA' -U postgres --auth=trust --encoding=UTF8 >/dev/null"
su postgres -c "pg_ctl -D '$PGDATA' -o '-c listen_addresses=127.0.0.1 -p 5432' -w start"

# Fresh, empty target database, then run the migrations for real. The
# postgresql+asyncpg driver matches envoy's online env.py; under trust auth the
# postgres superuser needs no password.
psql -h 127.0.0.1 -U postgres -v ON_ERROR_STOP=1 -c "CREATE DATABASE envoy;"
DATABASE_URL="postgresql+asyncpg://postgres@127.0.0.1:5432/envoy" \
    alembic upgrade head

# Snapshot the schema -> migrate.sql. --no-owner/--no-privileges keeps it
# portable to whatever role the deployment's DB uses.
pg_dump -h 127.0.0.1 -U postgres --schema-only --no-owner --no-privileges envoy \
    > /app/migrate.sql

# --schema-only omits table data, but the single alembic_version row records the
# head revision and must be preserved (the final stage tails migrate.sql for it).
# Appended last so it remains the final statement in the file.
pg_dump -h 127.0.0.1 -U postgres --data-only --no-owner --no-privileges \
    --table=alembic_version envoy >> /app/migrate.sql

su postgres -c "pg_ctl -D '$PGDATA' -w stop"
EOF

# (2) Final stage
FROM alpine:3.23

ENV MIGRATION_SENTINEL=""

RUN apk add --no-cache inotify-tools bash postgresql-client

# Envoy migrations sql, tail it for current alembic revision
COPY --from=builder /app/migrate.sql /migrate.sql

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]