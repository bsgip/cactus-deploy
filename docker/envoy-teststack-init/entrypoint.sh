#!/bin/bash

# Watchdog - blocks until file is created

if [ -z "$WATCHED_FILE" ]; then
  echo "Error: WATCHED_FILE environment variable not set."
  exit 1
fi

WATCHED_DIR=$(dirname "$WATCHED_FILE")

# Ensure the directory exists
if [ ! -d "$WATCHED_DIR" ]; then
  echo "Error: Directory $WATCHED_DIR does not exist."
  exit 1
fi

echo "Blocking until $WATCHED_FILE is found..."

while true; do
  inotifywait -e create --include $(basename $WATCHED_FILE) "$WATCHED_DIR"

  echo "Detected $WATCHED_FILE at $(date)"
  break

done
