#!/usr/bin/env bash

set -e

BASE_DIR="$HOME/docker"

# --- colours via tput (respects terminal theme) ---
if [[ -t 1 ]]; then
  GREEN=$(tput setaf 2)
  RED=$(tput setaf 1)
  YELLOW=$(tput setaf 3)
  GREY=$(tput setaf 8 2>/dev/null || tput setaf 7)
  BOLD=$(tput bold)
  RESET=$(tput sgr0)
else
  GREEN=""
  RED=""
  YELLOW=""
  GREY=""
  BOLD=""
  RESET=""
fi

echo "${BOLD}=== Docker Apps ===${RESET}"
echo

# Header
printf "%-20s %-12s %-25s %-15s\n" "APP" "STATUS" "IMAGE" "PORTS"
printf "%-20s %-12s %-25s %-15s\n" "----" "------" "-----" "-----"

for dir in "$BASE_DIR"/*; do
  [ -d "$dir" ] || continue

  APP_NAME=$(basename "$dir")

  # Skip system folders
  if [[ "$APP_NAME" == "caddy" || "$APP_NAME" == "networks" ]]; then
    continue
  fi

  if docker ps -a --format '{{.Names}}' | grep -q "^${APP_NAME}$"; then
    RAW_STATUS=$(docker inspect -f '{{.State.Status}}' "$APP_NAME")
    IMAGE=$(docker inspect -f '{{.Config.Image}}' "$APP_NAME")

    PORTS=$(docker ps --filter "name=$APP_NAME" \
      --format '{{.Ports}}')
    PORTS=${PORTS:-"-"}

    case "$RAW_STATUS" in
      running)
        STATUS="${GREEN}● running${RESET}"
        ;;
      exited)
        STATUS="${RED}● exited${RESET}"
        ;;
      paused)
        STATUS="${YELLOW}● paused${RESET}"
        ;;
      *)
        STATUS="${GREY}○ $RAW_STATUS${RESET}"
        ;;
    esac

  else
    STATUS="${GREY}○ not created${RESET}"
    IMAGE="-"
    PORTS="-"
  fi

  printf "%-20s %-20b %-25s %-15s\n" \
    "$APP_NAME" "$STATUS" "$IMAGE" "$PORTS"

done

echo
