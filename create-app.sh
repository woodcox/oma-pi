#!/usr/bin/env bash

set -e

BASE_DIR="$HOME/docker"
CADDYFILE="$BASE_DIR/caddy/Caddyfile"

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
  [[ "$yn" == "y" || "$yn" == "Y" ]]
}

# --- input ---
APP_NAME="${1:-}"
PORT="${2:-}"
IMAGE="${3:-}"

echo "=== Create Docker App ==="

if [ -z "$APP_NAME" ]; then
  APP_NAME=$(prompt "App name" "myapp")
fi

if [ -z "$PORT" ]; then
  PORT=$(prompt "External port" "8080")
fi

if [ -z "$IMAGE" ]; then
  echo "Choose an image:"
  echo "1) nginx (static site)"
  echo "2) node (custom app)"
  echo "3) custom"
  read -rp "Select option [1]: " choice
  choice=${choice:-1}

  case "$choice" in
    1) IMAGE="nginx:alpine" ;;
    2) IMAGE="node:20-alpine" ;;
    3) read -rp "Enter image: " IMAGE ;;
    *) IMAGE="nginx:alpine" ;;
  esac
fi

ADD_CADDY=false
if yes_no "Add Caddy route?"; then
  ADD_CADDY=true
fi

# --- setup ---
APP_DIR="$BASE_DIR/$APP_NAME"

echo "Creating app in $APP_DIR..."

mkdir -p "$APP_DIR/data"

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
      - "$PORT:$PORT"
    volumes:
      - ./data:/data
    networks:
      - caddy

networks:
  caddy:
    external: true
EOF

  echo "docker-compose.yml created"
else
  echo "docker-compose.yml already exists, skipping"
fi

# --- caddy integration ---
if $ADD_CADDY && [ -f "$CADDYFILE" ]; then
  if ! grep -q "$APP_NAME.local" "$CADDYFILE"; then
    echo "Adding Caddy route..."

    cat <<EOF >> "$CADDYFILE"

$APP_NAME.local {
  reverse_proxy $APP_NAME:$PORT
}
EOF

    # Reload Caddy (no restart needed)
    docker exec caddy caddy reload --config /etc/caddy/Caddyfile >/dev/null 2>&1 || true

    echo "Caddy route added"
  else
    echo "Caddy route already exists"
  fi
fi

# --- start app ---
cd "$APP_DIR"
docker compose up -d

# --- output ---
IP=$(hostname -I | awk '{print $1}')

echo
echo "✅ App '$APP_NAME' is running!"
echo
echo "Access options:"
echo "  http://$IP:$PORT"

if $ADD_CADDY; then
  echo "  http://$APP_NAME.local (if hosts file configured)"
fi

echo