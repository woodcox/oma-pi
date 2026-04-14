#!/usr/bin/env bash
set -e

BASE_DIR="$HOME/docker"
CADDY_DIR="$BASE_DIR/caddy"
SITES_DIR="$CADDY_DIR/sites"

APP_NAME="${1:-}"
FORCE="${2:-}"

# --- helpers ---
confirm() {
  read -rp "Remove exposure for '$APP_NAME'? (y/n): " yn
  [[ "$yn" =~ ^[Yy]$ ]]
}

validate_name() {
  [[ "$1" =~ ^[a-zA-Z0-9_-]+$ ]]
}

# --- input ---
if [ -z "$APP_NAME" ]; then
  echo "Usage: unexpose.sh <app-name> [--force]"
  exit 1
fi

if ! validate_name "$APP_NAME"; then
  echo "❌ Invalid app name"
  exit 1
fi

SITE_FILE="$SITES_DIR/$APP_NAME.caddy"

echo "=== Unexpose App ==="
echo "App: $APP_NAME"

# --- check existence ---
if [ ! -f "$SITE_FILE" ]; then
  echo "ℹ️ No exposure found for '$APP_NAME'"
  exit 0
fi

# --- confirm ---
if [ "$FORCE" != "--force" ]; then
  if ! confirm; then
    echo "Cancelled"
    exit 0
  fi
fi

# --- remove site ---
echo "Removing Caddy site..."
rm "$SITE_FILE"
echo "Caddy site removed"

# --- reload caddy ---
if docker ps --format '{{.Names}}' | grep -q '^caddy$'; then
  docker exec caddy caddy reload --config /etc/caddy/Caddyfile >/dev/null 2>&1 || true
  echo "Caddy reloaded"
else
  echo "⚠️ Caddy not running, reload skipped"
fi

# --- output ---
echo
echo "🚫 App '$APP_NAME' is no longer exposed"
echo
