#!/usr/bin/env bash
set -e

BASE_DIR="$HOME/docker"

APP_NAME="${1:-}"

# --- helpers ---
validate_name() {
  [[ "$1" =~ ^[a-zA-Z0-9_-]+$ ]]
}

# --- input ---
if [ -z "$APP_NAME" ]; then
  echo "Usage: restart.sh <app-name>"
  exit 1
fi

if ! validate_name "$APP_NAME"; then
  echo "❌ Invalid app name"
  exit 1
fi

APP_DIR="$BASE_DIR/$APP_NAME"

if [ ! -d "$APP_DIR" ]; then
  echo "❌ App '$APP_NAME' does not exist"
  exit 1
fi

echo "=== Restart App ==="
echo "App: $APP_NAME"
echo

cd "$APP_DIR"

echo "🔄 Restarting container..."

# graceful restart
docker compose restart

echo "✅ Restart complete"

echo
