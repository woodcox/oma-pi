#!/usr/bin/env bash

APP_NAME="$1"

if [ -z "$APP_NAME" ]; then
  echo "Usage: app_restart <app-name>"
  exit 1
fi

echo "Restarting $APP_NAME..."

docker restart "$APP_NAME"

echo "Done ✅"
