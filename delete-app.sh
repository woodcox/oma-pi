#!/usr/bin/env bash
set -e

BASE_DIR="$HOME/docker"
CADDY_DIR="$BASE_DIR/caddy"
SITES_DIR="$CADDY_DIR/sites"

APP_NAME="${1:-}"

# --- helpers ---
confirm() {
  read -rp "⚠️  Delete '$APP_NAME'? This cannot be undone. (y/n): " yn
  [[ "$yn" =~ ^[Yy]$ ]]
}

validate_name() {
  [[ "$1" =~ ^[a-zA-Z0-9_-]+$ ]]
}

# --- input ---
if [ -z "$APP_NAME" ]; then
  echo "Usage: delete.sh <app-name>"
  exit 1
fi

if ! validate_name "$APP_NAME"; then
  echo "❌ Invalid app name"
  exit 1
fi

APP_DIR="$BASE_DIR/$APP_NAME"
SITE_FILE="$SITES_DIR/$APP_NAME.caddy"

echo "=== Delete Docker App ==="
echo "App: $APP_NAME"

if ! confirm; then
  echo "Cancelled"
  exit 0
fi

echo

# --- stop & remove container ---
if [ -d "$APP_DIR" ]; then
  echo "Stopping containers..."

  (
    cd "$APP_DIR"
    docker compose down >/dev/null 2>&1 || true
  )

  echo "Containers stopped"
else
  echo "App directory not found, skipping container stop"
fi

# --- remove app directory ---
if [ -d "$APP_DIR" ]; then
  echo "Removing app directory..."
  rm -rf "$APP_DIR"
  echo "Directory removed"
else
  echo "App directory already removed"
fi

# --- remove caddy site ---
if [ -f "$SITE_FILE" ]; then
  echo "Removing Caddy site..."
  rm "$SITE_FILE"
  echo "Caddy site removed"

  # reload caddy if running
  if docker ps --format '{{.Names}}' | grep -q '^caddy$'; then
    docker exec caddy caddy reload --config /etc/caddy/Caddyfile >/dev/null 2>&1 || true
    echo "Caddy reloaded"
  else
    echo "⚠️ Caddy not running, reload skipped"
  fi
else
  echo "No Caddy site found, skipping"
fi

echo
echo "🗑️ App '$APP_NAME' deleted successfully"
echo
