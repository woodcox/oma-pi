#!/usr/bin/env bash
set -euo pipefail

# Common functions for Omaterm installation
show_banner() {
  clear
  echo

  RED="\e[38;2;197;26;74m"
  RESET="\e[0m"

  echo -e "${RED}   
 ▄██████▄    ▄▄▄▄███▄▄▄▄      ▄████████    ▄████████ ▄██
███    ███ ▄██▀▀▀███▀▀▀██▄   ███    ███   ███    ███ █▀
███    ███ ███   ███   ███   ███    ███   ███    ███   ▄
███    ███ ███   ███   ███   ███    ███   ███    ███ ▄██
███    ███ ███   ███   ███ ▀███████████ ▀█████████▀  ███
███    ███ ███   ███   ███   ███    ███   ███        ███
███    ███ ███   ███   ███   ███    ███   ███        ███
 ▀██████▀   ▀█   ███   █▀    ███    █▀    ███        ███
                                          █▀         █▀
  ${RESET}"
}

section() {
  echo -e "\n==> $1"
}

# Fetch the latest release tag from the GitHub API.
# Prefers the authenticated gh CLI so we don't burn the 60/hr anonymous rate
# limit. Returns non-zero for every failure mode, because callers turn the
# result straight into a download URL: a rate limit, an offline host or a
# repo without releases would otherwise install a tarball named after the
# error response.
github_latest_tag() {
  local repo="$1"
  local url tag

  url="https://api.github.com/repos/${repo}/releases/latest"

  if command -v gh &>/dev/null && gh auth status &>/dev/null; then
    tag="$(gh api -q '.tag_name' "$url" 2>/dev/null)" || return 1
  else
    tag="$(curl -fsSL -H 'Accept: application/vnd.github+json' "$url" 2>/dev/null \
      | grep -Po '"tag_name": *"\K[^"]+' || true)"
  fi

  # gh echoes the raw response body on an HTTP error, so a plausible-looking
  # but non-scalar result still has to be rejected.
  [[ -n $tag && $tag != '{'* && $tag != '['* ]] || return 1

  printf '%s\n' "$tag"
}

# Keep the git identity out of the file this installer owns.
# When ~/.gitconfig does not exist, `git config --global` (which git-id runs)
# writes into ~/.config/git/config instead, and the config copies below
# overwrite that file, so a refresh silently discarded the identity. Seed
# ~/.gitconfig so it has a home the installer never touches, and rescue a
# [user] block an earlier install left behind. Runs before the copies.
ensure_git_config() {
  section "Protecting git identity..."

  local managed="$HOME/.config/git/config"
  local user_config="$HOME/.gitconfig"
  local key value

  touch "$user_config"

  for key in user.name user.email; do
    # Never clobber a value that is already set where git prefers it.
    if git config --file "$user_config" --get "$key" >/dev/null 2>&1; then
      continue
    fi
    value="$(git config --file "$managed" --get "$key" 2>/dev/null || true)"
    if [[ -n $value ]]; then
      git config --file "$user_config" "$key" "$value"
      echo "✓ Recovered $key from the managed config"
    fi
  done

  echo "✓ Git identity lives in ~/.gitconfig, which reinstalls do not overwrite"
}

interactive_setup() {
  section "Interactive setup..."

  if ! gh auth status &>/dev/null; then
    echo
    if gum confirm "Authenticate with GitHub?" </dev/tty; then
      gh auth login
    fi
  fi

  if ! tailscale status &>/dev/null; then
    echo
    if gum confirm "Connect to Tailscale network?" </dev/tty; then
      echo "This might take a minute..."
      sudo systemctl enable --now tailscaled.service
      sudo tailscale up --ssh --accept-routes
    fi
  fi

  if grep -qi proxmox /sys/class/dmi/id/product_name 2>/dev/null && [ -e /dev/ttyS0 ]; then
    if ! systemctl is-enabled serial-getty@ttyS0.service &>/dev/null; then
      echo
      if gum confirm "Proxmox VM detected with serial port. Enable serial console?" </dev/tty; then
        sudo systemctl enable serial-getty@ttyS0.service
        sudo systemctl start serial-getty@ttyS0.service
        echo "✓ Serial console enabled on ttyS0"
      fi
    fi
  fi
}

finish() {
  section "Almost Finished!"

  echo "Cleaning up unused packages..."
  sudo apt autoremove --purge -y

  echo "Now logout and back in for everything to take effect"
}

configure_parallel_builds() {
  section "Configuring parallel compilation..."
  export MAKEFLAGS="-j$(nproc)"

  if [ -f /etc/makepkg.conf ]; then
    sudo sed -i "s/^#\?MAKEFLAGS=.*/MAKEFLAGS=\"-j$(nproc)\"/" /etc/makepkg.conf
  fi

  echo "✓ Using $(nproc) cores for compilation"
}

run_installation() {
  # Use all cores for compilation
  configure_parallel_builds

  # OS-specific package installation
  install_packages

  # Bun runtime, needed by the AI tools and tuiboard
  install_bun

  # Before any config copy, so a previous identity can be recovered from the
  # managed file and future ones have somewhere durable to live.
  ensure_git_config

  # Omadots
  install_dots

  # MS Edit binary: the default $EDITOR
  install_msedit_binary

  # Yazi binary: the interactive file manager, plus its ya CLI
  install_yazi_binary

  # Herdr: the terminal workspace manager that replaces tmux
  install_herdr_binary

  # Configs and bins
  install_configs
  install_bins

  # Optional extras. Before patch_shell_config, which is the last step to
  # touch ~/.config.
  install_optional_editors

  # Optional tools
  install_optional_ai_tools
  install_optional_tuiboard

  # Setup Docker group with optional root level access
  install_docker
  configure_docker_access

  # OS-specific service enabling
  enable_services

  # Interactive setup
  interactive_setup

  # Done!
  finish
}

# Getting started
show_banner
section "Installing Oma-Pi..."

# Ensure git is installed
if ! command -v git &>/dev/null; then
  if [ -f /etc/debian_version ]; then
    sudo apt update && sudo apt install -y git
  fi
fi

REPO="https://github.com/woodcox/oma-pi.git"
INSTALLER_DIR="$(mktemp -d)"
trap 'rm -rf "$INSTALLER_DIR"' EXIT

git clone --depth 1 "$REPO" "$INSTALLER_DIR"

# OS detection and dispatch
if [ -f /etc/debian_version ]; then
  source "$INSTALLER_DIR/install/debian.sh"
else
  echo "Error: Unsupported operating system"
  echo "Oma-Pi only supports Debian based OS such as Raspberry Pi OS, Debian and Ubuntu"
  exit 1
fi

source "$INSTALLER_DIR/install/docker.sh"
source "$INSTALLER_DIR/install/js-tools.sh"
source "$INSTALLER_DIR/install/config.sh"
source "$INSTALLER_DIR/install/binary.sh"
source "$INSTALLER_DIR/install/ai-tools.sh"

run_installation
