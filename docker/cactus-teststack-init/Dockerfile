# (1) Make database migration stage
# We need a DB migration file - easiest way to
FROM python:3.11-slim-bookworm AS make-migration

ARG ENVOY_VERSION

WORKDIR /app

# Deps
RUN apt update && apt install --no-install-recommends -y git
RUN pip install --no-cache-dir -e git+https://git@github.com/bsgip/envoy.git@${ENVOY_VERSION}#egg=envoy
RUN pip install --no-cache-dir alembic

WORKDIR /app/src/envoy/src/envoy/server

ENV DATABASE_URL="postgresql://abc:abc@abc/abc"
RUN alembic upgrade head --sql > /app/migrate.sql

# (2) Final stage
FROM alpine:latest

RUN apk add --no-cache inotify-tools bash postgresql-client

# Envoy migrations sql, tail it for current alembic revision
COPY --from=make-migration /app/migrate.sql /migrate.sql

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
