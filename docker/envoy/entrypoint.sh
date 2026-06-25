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

exec uvicorn $APP_MODULE --workers $WORKERS --log-config $LOG_CONFIG --host $HOST --port $PORT
