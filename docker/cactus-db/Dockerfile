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

install -d -o postgres -g postgres "$PGDATA" /var/run/postgresql
su postgres -c "initdb -D '$PGDATA' -U postgres --auth=trust --encoding=UTF8 >/dev/null"
su postgres -c "pg_ctl -D '$PGDATA' -o '-c listen_addresses=127.0.0.1 -p 5432' -w start"

# Fresh, empty target database, then run the migrations for real. The
# postgresql+asyncpg driver matches envoy's online env.py; under trust auth the
# postgres superuser needs no password.
psql -h 127.0.0.1 -U postgres -v ON_ERROR_STOP=1 -c "CREATE DATABASE envoy;"
DATABASE_URL="postgresql+asyncpg://postgres@127.0.0.1:5432/envoy" \
    alembic upgrade head

# Snapshot the migrated DB as a custom-format archive (-Fc). It's a *full* dump,
# but after a from-empty migration the only row anywhere is alembic_version's head
# revision, so the archive is effectively "schema + revision marker".
pg_dump -h 127.0.0.1 -U postgres -Fc --no-owner --no-privileges envoy \
    -f /app/migrate.dump

su postgres -c "pg_ctl -D '$PGDATA' -w stop"
EOF

# (2) Final stage
FROM postgres:18-alpine


ARG POSTGRES_USER=envoy
ARG POSTGRES_PASSWORD=envoy
ARG POSTGRES_DB=envoy

ENV PGDATA=/var/lib/postgresql/data \
    POSTGRES_USER=${POSTGRES_USER} \
    POSTGRES_DB=${POSTGRES_DB}

COPY --from=builder /app/migrate.dump /tmp/migrate.dump

RUN mkdir -p /var/run/postgresql "$PGDATA" && \
    chown -R postgres:postgres /var/run/postgresql "$PGDATA"

USER postgres

# Init a real cluster, start it on a local socket only (no TCP),
# create the db, restore the dump, then shut it down cleanly.
RUN echo "$POSTGRES_PASSWORD" > /tmp/pwfile && \
    initdb --username="$POSTGRES_USER" --pwfile=/tmp/pwfile --auth=scram-sha-256 -D "$PGDATA" --locale=C.UTF-8 && \
    rm -f /tmp/pwfile && \
    pg_ctl -D "$PGDATA" -o "-c listen_addresses='' -c unix_socket_directories=/var/run/postgresql" -w start && \
    PGPASSWORD="$POSTGRES_PASSWORD" psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" -h /var/run/postgresql -d postgres \
        -c "CREATE DATABASE \"$POSTGRES_DB\";" && \
    PGPASSWORD="$POSTGRES_PASSWORD" pg_restore --username "$POSTGRES_USER" --host /var/run/postgresql \
        --dbname "$POSTGRES_DB" --no-owner --exit-on-error /tmp/migrate.dump && \
    pg_ctl -D "$PGDATA" -m fast -w stop


USER root
RUN rm -f /tmp/migrate.dump

EXPOSE 5432