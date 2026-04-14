#!/usr/bin/env bash
set -e

BASE_DIR="$HOME/docker"
NETWORK="caddy"

CADDY_DIR="$BASE_DIR/caddy"
SITES_DIR="$CADDY_DIR/sites"

# --- helpers ---
prompt() {
  local message="$1"
  local default="$2"
  read -rp "$message [$default]: " input
  echo "${input:-$default}"
}

yes_no() {
  local message="$1"
  read -rp "$message (y/n): " yn
  [[ "$yn" =~ ^[Yy]$ ]]
}

validate_name() {
  [[ "$1" =~ ^[a-zA-Z0-9_-]+$ ]]
}

# --- input ---
APP_NAME="${1:-}"
PORT="${2:-}"
IMAGE="${3:-}"
INTERNAL_PORT=""

echo "=== Create Docker App ==="

if [ -z "$APP_NAME" ]; then
  APP_NAME=$(prompt "App name" "myapp")
fi

if ! validate_name "$APP_NAME"; then
  echo "❌ Invalid app name. Use letters, numbers, - or _"
  exit 1
fi

if [ -z "$PORT" ]; then
  PORT=$(prompt "External port" "8080")
fi

# --- image selection ---
if [ -z "$IMAGE" ]; then
  echo "Choose an image:"
  echo "1) nginx (static site)"
  echo "2) node (dev server)"
  echo "3) custom"
  read -rp "Select option [1]: " choice
  choice=${choice:-1}

  case "$choice" in
    1)
      IMAGE="nginx:alpine"
      INTERNAL_PORT=80
      ;;
    2)
      IMAGE="node:20-alpine"
      INTERNAL_PORT=3000
      ;;
    3)
      read -rp "Enter image: " IMAGE
      INTERNAL_PORT=$(prompt "Internal container port" "80")
      ;;
    *)
      IMAGE="nginx:alpine"
      INTERNAL_PORT=80
      ;;
  esac
fi

ADD_CADDY=false
if yes_no "Add Caddy route?"; then
  ADD_CADDY=true
fi

APP_DIR="$BASE_DIR/$APP_NAME"
SITE_FILE="$SITES_DIR/$APP_NAME.caddy"
DOMAIN="$APP_NAME.local"

echo "Creating app in $APP_DIR..."
mkdir -p "$APP_DIR/data"

# --- ensure docker network exists ---
if ! docker network inspect "$NETWORK" >/dev/null 2>&1; then
  echo "Creating docker network: $NETWORK"
  docker network create "$NETWORK"
fi

# --- generate compose ---
if [ ! -f "$APP_DIR/docker-compose.yml" ]; then
  cat <<EOF > "$APP_DIR/docker-compose.yml"
version: "3.8"

services:
  $APP_NAME:
    image: $IMAGE
    container_name: $APP_NAME
    restart: unless-stopped
    ports:
      - "$PORT:$INTERNAL_PORT"
    volumes:
      - ./data:/data
    networks:
      - $NETWORK

networks:
  $NETWORK:
    external: true
EOF

  echo "docker-compose.yml created"
else
  echo "docker-compose.yml already exists, skipping"
fi

# --- caddy snippet ---
if $ADD_CADDY; then
  mkdir -p "$SITES_DIR"

  if [ ! -f "$SITE_FILE" ]; then
    echo "Creating Caddy site: $SITE_FILE"

    cat <<EOF > "$SITE_FILE"
$DOMAIN {
  reverse_proxy $APP_NAME:$INTERNAL_PORT
}
EOF

    # reload caddy if running
    if docker ps --format '{{.Names}}' | grep -q '^caddy$'; then
      docker exec caddy caddy reload --config /etc/caddy/Caddyfile >/dev/null 2>&1 || true
      echo "Caddy reloaded"
    else
      echo "⚠️ Caddy container not running, reload skipped"
    fi
  else
    echo "Caddy site already exists, skipping"
  fi
fi

# --- start app ---
cd "$APP_DIR"
docker compose up -d

IP=$(hostname -I | awk '{print $1}')

echo
echo "✅ App '$APP_NAME' is running!"
echo
echo "Access:"
echo "  http://$IP:$PORT"

if $ADD_CADDY; then
  echo "  http://$DOMAIN (if hosts file configured)"
fi

echo
