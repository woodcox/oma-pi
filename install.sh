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

# Guard against `>>` concatenating onto a last line that has no trailing newline
ensure_trailing_newline() {
  local file="$1"
  [[ -s $file ]] || return 0
  if [[ -n $(tail -c 1 "$file") ]]; then
    printf '\n' >>"$file"
  fi
}

install_omadots() {
  section "Installing Omadots configs..."

  section "Copying dots to ~/.config..."
  mkdir -p "$HOME/.config"
  cp -rf "$INSTALLER_DIR/config/." "$HOME/.config/"
  echo "✓ Configs"

  section "Configuring shell..."
  # Tracked so later steps (tmux auto-start) patch the rc file this shell
  # actually reads, rather than assuming bash.
  SHELL_RC="$HOME/.bashrc"

  case "$(basename "${SHELL:-bash}")" in
    zsh)
      SHELL_RC="$HOME/.zshrc"
      cat >"$HOME/.zshrc" <<'EOF_ZSH'
[[ $- != *i* ]] && return

source ~/.config/shell/all
EOF_ZSH
      echo '. ~/.zshrc' >"$HOME/.zprofile"
      echo "✓ Zsh"
      ;;

    bash)
      cat >"$HOME/.bashrc" <<'EOF_BASH'
[[ $- != *i* ]] && return

source ~/.config/shell/all
EOF_BASH
      echo '. ~/.bashrc' >"$HOME/.bash_profile"
      ln -snf "$HOME/.config/shell/inputrc" "$HOME/.inputrc"
      echo "✓ Bash"
      ;;
  esac
}

patch_shell_config() {
  section "Patching shell config for oma-pi..."

  local SHELL_ENVS="$HOME/.config/shell/envs"
  local SHELL_ALIASES="$HOME/.config/shell/aliases"

  if [ -f "$SHELL_ENVS" ]; then
    ensure_trailing_newline "$SHELL_ENVS"

    # Replace nvim with helix as default editor
    sed -i 's/^export EDITOR="nvim"$/export EDITOR="hx"/' "$SHELL_ENVS"

    # Add tool PATH entries if not already present
    grep -qF '.deno/bin'  "$SHELL_ENVS" || printf '%s\n' 'export PATH="$HOME/.deno/bin:$PATH"'  >>"$SHELL_ENVS"
    grep -qF '.local/bin' "$SHELL_ENVS" || printf '%s\n' 'export PATH="$HOME/.local/bin:$PATH"' >>"$SHELL_ENVS"
  fi

  if [ -f "$SHELL_ALIASES" ]; then
    # Remove nvim aliases
    sed -i '/nvim/d' "$SHELL_ALIASES"
  fi

  echo "✓ Shell config patched"
}

install_helix_binary() {
  section "Installing Helix from GitHub releases..."

  local arch
  local current_version
  local version
  local asset
  local tmpdir

  arch="$(uname -m)"
  case "$arch" in
    x86_64) arch="x86_64-linux" ;;
    aarch64|arm64) arch="aarch64-linux" ;;
    armv7l) arch="armv7-linux" ;;
    *)
      echo "Unsupported architecture for Helix prebuilt binary: $arch"
      return 1
      ;;
  esac

  version="$(github_latest_tag helix-editor/helix)" || {
    echo "Error: could not determine the latest Helix release (GitHub API unreachable or rate limited)" >&2
    return 1
  }

  # Check current version of helix
  if command -v hx &>/dev/null; then
    current_version="$(hx --version 2>/dev/null | awk 'NR==1{print $2}')"
    if [ "$current_version" = "$version" ]; then
      echo "✓ Helix ${version} already installed"
      return 0
    fi
  fi
  
  asset="helix-${version}-${arch}.tar.xz"
  tmpdir="$(mktemp -d)"

  curl -fL "https://github.com/helix-editor/helix/releases/download/${version}/${asset}" -o "$tmpdir/helix.tar.xz"
  tar -xJf "$tmpdir/helix.tar.xz" -C "$tmpdir"

  mkdir -p "$HOME/.local/bin" "$HOME/.config/helix"
  install -m 0755 "$tmpdir/helix-${version}-${arch}/hx" "$HOME/.local/bin/hx"
  rm -rf "$HOME/.config/helix/runtime"
  cp -R "$tmpdir/helix-${version}-${arch}/runtime" "$HOME/.config/helix/runtime"

  rm -rf "$tmpdir"
  echo "✓ Helix ${version}"
}

install_configs() {
  section "Installing configs..."
  mkdir -p "$HOME/.config"
  cp -Rf "$INSTALLER_DIR/config/"* "$HOME/.config/"
  echo "✓ Helix"
  echo "✓ Starship"

  if ! grep -q "if \[\[ -z \$TMUX \]\]" "$SHELL_RC" 2>/dev/null; then
    ensure_trailing_newline "$SHELL_RC"
    cat >>"$SHELL_RC" <<'BASHRC_TMUX'
if [[ -z $TMUX ]]; then
  t
else
  if [[ -z "$(tmux showenv FASTFETCH_SHOWN 2>/dev/null || true)" ]]; then
    tmux setenv FASTFETCH_SHOWN 1
    fastfetch
  fi
fi
BASHRC_TMUX
    echo "✓ Tmux auto-start"
    echo "✓ fastfetch on tmux attach"
  fi
}

install_bins() {
  section "Installing bins..."
  mkdir -p "$HOME/.local/bin"
  cp -Rf "$INSTALLER_DIR/bin/"* "$HOME/.local/bin/"
  chmod +x "$HOME/.local/bin/"*
  echo "✓ omapi-ssh"
  echo "✓ omapi-refresh"
  echo "✓ omapi-setup"
  echo "✓ omapi-theme"
  echo "✓ omapi-help"
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

configure_docker_access() {
  section "Docker user access..."

  if groups | grep -q docker; then
    echo "✓ $USER is already in docker group"
    return
  fi

  if gum confirm "Allow Docker without sudo by adding $USER to the docker group - this may impact the security in your system, see [Docker Daemon Attack Surface](https://docs.docker.com/engine/security/#docker-daemon-attack-surface)" </dev/tty; then
    if command -v usermod &>/dev/null; then
      sudo usermod -aG docker "$USER"
    else
      sudo adduser "$USER" docker
    fi
    echo "✓ Added $USER to docker group (log out/in to apply)"
  else
    echo "✓ Keeping Docker usage with sudo"
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

  # Omadots
  install_omadots

  # Helix binary + runtime
  install_helix_binary

  # Configs and bins
  install_configs
  install_bins

  # Patch last: every step above re-copies config/ over ~/.config, so running
  # this earlier would silently discard the EDITOR/alias edits.
  patch_shell_config

  # Optional tools
  install_optional_ai_tools

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

run_installation
