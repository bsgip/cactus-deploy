#!/bin/sh

# Exports variables from environment config file, if exists, then runs envoy app.

ENV_FILE="/shared/envoy.env"

if test -f "$ENV_FILE"; then
  set -a
    . "$ENV_FILE"
  set +a
else
    echo "No envfile found at $ENV_FILE"
fi


uvicorn $APP_MODULE --workers $WORKERS --log-config $LOG_CONFIG --host $HOST --port $PORT