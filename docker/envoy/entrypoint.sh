#!/bin/bash

# Wait for the DB migration sentinel to be created
if [ -n "$MIGRATION_SENTINEL" ]; then
    MAX_MIGRATION_ATTEMPTS=1200
    MIGRATION_ATTEMPT=0
    while [ ! -f "$MIGRATION_SENTINEL" ]; do
        echo "Waiting for database migrations via $MIGRATION_SENTINEL"
        sleep 0.1
        MIGRATION_ATTEMPT=$((MIGRATION_ATTEMPT + 1))
        if [ $MIGRATION_ATTEMPT -ge $MAX_MIGRATION_ATTEMPTS ]; then
            echo "Timed out waiting for database migrations!" >&2
            exit 1
        fi
    done

    echo "$MIGRATION_SENTINEL exists - database should be migrated."
else
    echo "MIGRATION_SENTINEL has not been specified. Skipping wait on migration."
fi

if [ -n "${RABBIT_MQ_BROKER_URL}" ]; then
    echo "Notifications are enabled. RABBIT_MQ_BROKER_URL has been set."

    # Extract hostname/port from rabbit mq connection string
    REMOVED_CREDS="${RABBIT_MQ_BROKER_URL#*@}"
    HOST_WITH_PORT="${REMOVED_CREDS%%/*}"
    HOST_WITH_PORT="${HOST_WITH_PORT:=localhost}"

    if [[ "$HOST_WITH_PORT" == *:* ]]; then
      RABBIT_MQ_HOST="${HOST_WITH_PORT%%:*}"
      RABBIT_MQ_PORT="${HOST_WITH_PORT#*:}"
      RABBIT_MQ_PORT="${RABBIT_MQ_PORT:=5672}"
    else
      RABBIT_MQ_HOST="$HOST_WITH_PORT"
      RABBIT_MQ_PORT=5672
    fi

    # Wait for RabbitMQ to be ready
    until nc -z $RABBIT_MQ_HOST $RABBIT_MQ_PORT; do
      echo "Waiting for RabbitMQ @ '${RABBIT_MQ_HOST}:${RABBIT_MQ_PORT}' to become available..."
      sleep 2
    done
    echo "RabbitMQ @ '${RABBIT_MQ_HOST}:${RABBIT_MQ_PORT}' is available, starting envoy..."
else
    echo "RABBIT_MQ_BROKER_URL has not been specified. Skipping wait."
fi

exec uvicorn $APP_MODULE --workers $WORKERS --log-config $LOG_CONFIG --host $HOST --port $PORT
