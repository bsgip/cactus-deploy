
ARG ENVOY_VERSION

# We need a DB migration file - easiest way to
FROM python:3.11-slim-bookworm as build

WORKDIR /app

# Deps
RUN apt update && apt install --no-install-recommends -y git
RUN git clone https://git@github.com/bsgip/envoy.git@${ENVOY_VERSION}
RUN pip install --no-cache-dir alembic

WORKDIR /app/envoy/src/envoy/server

ENV DATABASE_URL="postgresql://"
RUN alembic upgrade head --offline > /app/migrate.sql


FROM alpine:latest

RUN apk add --no-cache inotify-tools bash postgresql-client

# Envoy migrations sql, tail it for current alembic revision
COPY --from=build /app/migrate.sql /migrate.sql

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
