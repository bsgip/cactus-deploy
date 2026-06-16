#!/bin/bash

# Wait for DB and run migrations
echo "(1) cactus-envoy-db Setup"
if [ -z "$ENVOY_DATABASE_URL" ]; then
  echo "Error: ENVOY_DATABASE_URL environment variable not set."
  exit 1
fi

echo "Waiting for db to be ready..."
until psql ${ENVOY_DATABASE_URL} -c "SELECT 1;" >/dev/null 2>&1; do
  sleep 1
done

set -e

echo "Running migrations..."
psql ${ENVOY_DATABASE_URL} -f /migrate.sql

if [ -n "$MIGRATION_SENTINEL" ]; then
  echo "Recording completion at $MIGRATION_SENTINEL"
  mkdir -p "$(dirname "$MIGRATION_SENTINEL")" && touch "$MIGRATION_SENTINEL"
else
  echo "MIGRATION_SENTINEL is NOT set - not recording completion"
fi

echo "End of teststack-init"