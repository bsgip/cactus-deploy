#!/bin/sh

# Exports variables from environment config file, if exists, then runs envoy app.

if [ -z "$ENVOY_ENV_FILE" ]; then
  echo "Error: ENVOY_ENV_FILE environment variable not set."
  exit 1
fi

if test -f "$ENVOY_ENV_FILE"; then
  set -a
    . "$ENVOY_ENV_FILE"
  set +a
else
    echo "No envfile found at $ENVOY_ENV_FILE"
fi


uvicorn $APP_MODULE --workers $WORKERS --log-config $LOG_CONFIG --host $HOST --port $PORT