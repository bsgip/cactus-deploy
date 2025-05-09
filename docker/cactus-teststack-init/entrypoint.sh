#!/bin/bash

# Watchdog - blocks until file is created

if [ -z "$KICKOFF_FILE" ]; then
  echo "Error: KICKOFF_FILE environment variable not set."
  exit 1
fi

WATCHED_DIR=$(dirname "$KICKOFF_FILE")

# Ensure the directory exists
if [ ! -d "$WATCHED_DIR" ]; then
  echo "Error: Directory $WATCHED_DIR does not exist."
  exit 1
fi

echo "Blocking until $KICKOFF_FILE is found..."

while true; do
  inotifywait -e create --include $(basename $KICKOFF_FILE) "$WATCHED_DIR"

  echo "Detected $KICKOFF_FILE at $(date)"
  break

done
