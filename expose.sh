#!/usr/bin/env bash
set -e

BASE_DIR="$HOME/docker"
CADDY_DIR="$BASE_DIR/caddy"
SITES_DIR="$CADDY_DIR/sites"

APP_NAME="${1:-}"
DOMAIN_INPUT="${2:-}"

# --- helpers ---
prompt() {
  local message="$1"
  local default="$2"
  read -rp "$message [$default]: " input
  echo "${input:-$default}"
}

confirm() {
  read -rp "Overwrite existing exposure? (y/n): " yn
  [[ "$yn" =~ ^[Yy]$ ]]
}

validate_name() {
  [[ "$1" =~ ^[a-zA-Z0-9_-]+$ ]]
}

# --- input validation ---
if [ -z "$APP_NAME" ]; then
  echo "Usage: expose.sh <app-name> [domain]"
  exit 1
fi

if ! validate_name "$APP_NAME"; then
  echo "❌ Invalid app name"
  exit 1
fi

APP_DIR="$BASE_DIR/$APP_NAME"
SITE_FILE="$SITES_DIR/$APP_NAME.caddy"

if [ ! -d "$APP_DIR" ]; then
  echo "❌ App '$APP_NAME' does not exist"
  exit 1
fi

# --- domain setup ---
if [ -z "$DOMAIN_INPUT" ]; then
  DOMAIN_INPUT=$(prompt "Domain (e.g. app.local or app.example.com)" "$APP_NAME.local")
fi

DOMAIN="$DOMAIN_INPUT"

# --- detect internal port from compose ---
COMPOSE_FILE="$APP_DIR/docker-compose.yml"

if [ ! -f "$COMPOSE_FILE" ]; then
  echo "❌ docker-compose.yml not found"
  exit 1
fi

# extract container port (right side of ports mapping)
INTERNAL_PORT=$(grep -E 'ports:' -A2 "$COMPOSE_FILE" | grep -Eo ':[0-9]+' | tail -1 | tr -d ':')

if [ -z "$INTERNAL_PORT" ]; then
  echo "❌ Could not detect internal port"
  exit 1
fi

# --- create/update site ---
mkdir -p "$SITES_DIR"

if [ -f "$SITE_FILE" ]; then
  echo "⚠️ Exposure already exists for $APP_NAME"

  if ! confirm; then
    echo "Cancelled"
    exit 0
  fi
fi

echo "Creating/updating Caddy site: $SITE_FILE"

cat <<EOF > "$SITE_FILE"
$DOMAIN {
  reverse_proxy $APP_NAME:$INTERNAL_PORT
}
EOF

# --- reload caddy ---
if docker ps --format '{{.Names}}' | grep -q '^caddy$'; then
  docker exec caddy caddy reload --config /etc/caddy/Caddyfile >/dev/null 2>&1 || true
  echo "Caddy reloaded"
else
  echo "⚠️ Caddy not running, reload skipped"
fi

# --- output ---
echo
echo "🌐 App '$APP_NAME' exposed!"
echo
echo "URL:"
echo "  http://$DOMAIN"
echo
