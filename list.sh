#!/usr/bin/env bash
set -e

BASE_DIR="$HOME/docker"
CADDY_DIR="$BASE_DIR/caddy"
SITES_DIR="$CADDY_DIR/sites"

# --- preload docker data ---
DOCKER_PS=$(docker ps --format '{{.Names}}|{{.Image}}|{{.Status}}')
DOCKER_PS_ALL=$(docker ps -a --format '{{.Names}}|{{.Image}}|{{.Status}}')

declare -A IMAGE_MAP
declare -A STATUS_MAP
declare -A UPTIME_MAP

# --- build maps (running first) ---
while IFS='|' read -r NAME IMAGE STATUS; do
  [ -z "$NAME" ] && continue

  IMAGE_MAP["$NAME"]="$IMAGE"

  if [[ "$STATUS" == Up* ]]; then
    STATUS_MAP["$NAME"]="🟢 running"
    UPTIME_MAP["$NAME"]="${STATUS#Up }"
  else
    STATUS_MAP["$NAME"]="⚪ unknown"
    UPTIME_MAP["$NAME"]="-"
  fi
done <<< "$DOCKER_PS"

# --- fill in stopped containers (only if not already set) ---
while IFS='|' read -r NAME IMAGE STATUS; do
  [ -z "$NAME" ] && continue

  if [ -z "${STATUS_MAP[$NAME]}" ]; then
    IMAGE_MAP["$NAME"]="$IMAGE"

    if [[ "$STATUS" == Exited* ]]; then
      STATUS_MAP["$NAME"]="🔴 stopped"
    else
      STATUS_MAP["$NAME"]="⚪ none"
    fi

    UPTIME_MAP["$NAME"]="-"
  fi
done <<< "$DOCKER_PS_ALL"

# --- helpers ---
get_port() {
  local compose_file="$1"

  if [ -f "$compose_file" ]; then
    grep -E 'ports:' -A2 "$compose_file" \
      | grep -Eo '[0-9]+:[0-9]+' \
      | head -1 \
      | cut -d: -f1
  fi
}

get_domain() {
  local site_file="$1"

  if [ -f "$site_file" ]; then
    head -n1 "$site_file" | awk '{print $1}'
  else
    echo "-"
  fi
}

# --- header ---
printf "\n%-15s %-12s %-18s %-10s %-12s %-30s\n" \
  "APP" "STATUS" "IMAGE" "PORT" "UPTIME" "DOMAIN"

printf "%-15s %-12s %-18s %-10s %-12s %-30s\n" \
  "---------------" "------------" "------------------" "--------" "------------" "------------------------------"

# --- loop apps ---
for dir in "$BASE_DIR"/*; do
  [ -d "$dir" ] || continue

  APP_NAME=$(basename "$dir")

  # skip internal dirs
  if [[ "$APP_NAME" == "caddy" || "$APP_NAME" == "networks" ]]; then
    continue
  fi

  COMPOSE_FILE="$dir/docker-compose.yml"
  SITE_FILE="$SITES_DIR/$APP_NAME.caddy"

  IMAGE="${IMAGE_MAP[$APP_NAME]:--}"
  STATUS="${STATUS_MAP[$APP_NAME]:-⚪ none}"
  UPTIME="${UPTIME_MAP[$APP_NAME]:--}"

  PORT=$(get_port "$COMPOSE_FILE")
  DOMAIN=$(get_domain "$SITE_FILE")

  PORT=${PORT:-"-"}

  printf "%-15s %-12s %-18s %-10s %-12s %-30s\n" \
    "$APP_NAME" "$STATUS" "$IMAGE" "$PORT" "$UPTIME" "$DOMAIN"

done

echo
