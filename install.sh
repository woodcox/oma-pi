#!/usr/bin/env bash
set -euo pipefail

# Common functions for Piterm installation
show_banner() {
  clear
  echo
  cat <<'EOF'
██████╗ ██╗████████╗███████╗██████╗ ███╗   ███╗
██╔══██╗██║╚══██╔══╝██╔════╝██╔══██╗████╗ ████║
██████╔╝██║   ██║   █████╗  ██████╔╝██╔████╔██║
██╔═══╝ ██║   ██║   ██╔══╝  ██╔══██╗██║╚██╔╝██║
██║     ██║   ██║   ███████╗██║  ██║██║ ╚═╝ ██║
╚═╝     ╚═╝   ╚═╝   ╚══════╝╚═╝  ╚═╝╚═╝     ╚═╝
EOF
}

section() {
  echo -e "\n==> $1"
}

install_omadots() {
  curl -fsSL https://raw.githubusercontent.com/omacom-io/omadots/refs/heads/master/install.sh | bash
}

install_helix_binary() {
  section "Installing Helix from GitHub releases..."

  local arch
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

  version="$(curl -fsSL https://api.github.com/repos/helix-editor/helix/releases/latest | grep -Po '"tag_name": *"\K[^"]+')"
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
  echo "✓ Helix config"
  echo "✓ Starship"

  if ! grep -q "if \[\[ -z \$TMUX \]\]" "$HOME/.bashrc" 2>/dev/null; then
    cat >>"$HOME/.bashrc" <<'BASHRC_TMUX'
if [[ -z $TMUX ]]; then
  t
fi
BASHRC_TMUX
    echo "✓ Tmux auto-start"
  fi

  if ! grep -q 'export PATH="$HOME/.deno/bin:$PATH"' "$HOME/.bashrc" 2>/dev/null; then
    echo 'export PATH="$HOME/.deno/bin:$PATH"' >>"$HOME/.bashrc"
    echo "✓ Deno PATH"
  fi

}

install_bins() {
  section "Installing bins..."
  mkdir -p "$HOME/.local/bin"
  cp -Rf "$INSTALLER_DIR/bin/"* "$HOME/.local/bin/"
  chmod +x "$HOME/.local/bin/"*
  echo "✓ piterm-ssh"
  echo "✓ piterm-theme"
  echo "✓ piterm-refresh"
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

  if gum confirm "Allow Docker without sudo by adding $USER to the docker group?" </dev/tty; then
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
  section "Finished!"
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

  # Optional tools
  install_optional_ai_tools

  # OS-specific service enabling
  enable_services

  # Optional Docker group access
  configure_docker_access

  # Interactive setup
  interactive_setup

  # Done!
  finish
}

# Getting started
show_banner
section "Installing Piterm..."

# Ensure correct git is installed
if ! command -v git &>/dev/null; then
  if [ -f /etc/debian_version ]; then
    sudo apt-get update && sudo apt-get install -y git
  fi
fi

# Ensure curl exists for remote installers
if ! command -v curl &>/dev/null; then
  if [ -f /etc/debian_version ]; then
    sudo apt-get update && sudo apt-get install -y curl
  fi
fi

REPO="https://github.com/omacom-io/piterm.git"
INSTALLER_DIR="$(mktemp -d)"
trap 'rm -rf "$INSTALLER_DIR"' EXIT

git clone --depth 1 "$REPO" "$INSTALLER_DIR"

# OS detection and dispatch
if [ -f /etc/debian_version ]; then
  source "$INSTALLER_DIR/install/debian.sh"
else
  echo "Error: Unsupported operating system"
  echo "Piterm supports Debian/Ubuntu"
  exit 1
fi

run_installation
