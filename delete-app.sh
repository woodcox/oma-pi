#!/usr/bin/env bash

set -e

BASE_DIR="$HOME/docker"
CADDYFILE="$BASE_DIR/caddy/Caddyfile"

# --- helpers ---
confirm() {
  read -rp "$1 (y/n): " yn
  [[ "$yn" == "y" || "$yn" == "Y" ]]
}

# --- input ---
APP_NAME="$1"

echo "=== Delete Docker App ==="

# If no arg, list apps
if [ -z "$APP_NAME" ]; then
  echo "Available apps:"
  ls -1 "$BASE_DIR" | grep -v "^caddy$" || true
  echo
  read -rp "Enter app name to delete: " APP_NAME
fi

APP_DIR="$BASE_DIR/$APP_NAME"

if [ ! -d "$APP_DIR" ]; then
  echo "❌ App '$APP_NAME' does not exist"
  exit 1
fi

echo
echo "⚠️  This will:"
echo "  - Stop and remove container"
echo "  - Delete folder: $APP_DIR"
echo "  - Remove Caddy route (if exists)"
echo

if ! confirm "Are you sure you want to delete '$APP_NAME'?"; then
  echo "Cancelled"
  exit 0
fi

# --- stop container ---
echo "Stopping container..."
cd "$APP_DIR"

if [ -f docker-compose.yml ]; then
  docker compose down || true
else
  docker rm -f "$APP_NAME" >/dev/null 2>&1 || true
fi

# --- remove folder ---
echo "Removing folder..."
rm -rf "$APP_DIR"

# --- remove Caddy route ---
if [ -f "$CADDYFILE" ]; then
  echo "Cleaning Caddyfile..."

  # Remove block like:
  # app.local { ... }
  sed -i "/^$APP_NAME\.local {/,/^}/d" "$CADDYFILE"

  # Reload Caddy
  docker exec caddy caddy reload --config /etc/caddy/Caddyfile >/dev/null 2>&1 || true
fi

echo
echo "✅ App '$APP_NAME' deleted"