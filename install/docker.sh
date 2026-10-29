#!/usr/bin/env bash
# Docker installation and user setup.
#
# Sourced by install.sh. Debian-specific because the repository setup and the
# package names differ from other distributions.
#
# See: https://docs.docker.com/engine/install/debian/ for docker install guidance
install_docker() {
  echo "Installing Docker..."

  set -e  # stop on error

  # Ensure required packages
  sudo apt update
  sudo apt install -y ca-certificates curl

  # Create keyrings dir if it doesn't exist
  sudo install -m 0755 -d /etc/apt/keyrings

  # Docker publishes separately for Debian and Ubuntu, and each carries only
  # its own distribution's release names: Ubuntu's VERSION_CODENAME (jammy,
  # noble) has no match in the Debian repo, so pointing an Ubuntu box at
  # linux/debian left apt with an unknown suite and failed the install.
  # Ubuntu also has /etc/debian_version, so this is the one place the
  # Debian-only assumption does not hold.
  local DOCKER_DISTRO
  case "$(. /etc/os-release && echo "${ID:-debian}")" in
    ubuntu) DOCKER_DISTRO="ubuntu" ;;
    *)      DOCKER_DISTRO="debian" ;;
  esac

  # Add Docker GPG key (only if missing)
  if [ ! -f /etc/apt/keyrings/docker.asc ]; then
    echo "Adding Docker GPG key..."
    sudo curl -fsSL "https://download.docker.com/linux/${DOCKER_DISTRO}/gpg" \
      -o /etc/apt/keyrings/docker.asc
    sudo chmod a+r /etc/apt/keyrings/docker.asc
  else
    echo "Docker GPG key already exists, skipping"
  fi

  # Detect codename + arch once
  local CODENAME ARCH
  CODENAME="$(. /etc/os-release && echo "$VERSION_CODENAME")"
  ARCH="$(dpkg --print-architecture)"

  # Add repo (overwrite safely every time)
  echo "Setting up Docker repository (${DOCKER_DISTRO} ${CODENAME})..."
  sudo tee /etc/apt/sources.list.d/docker.sources > /dev/null <<EOF
Types: deb
URIs: https://download.docker.com/linux/${DOCKER_DISTRO}
Suites: ${CODENAME}
Components: stable
Architectures: ${ARCH}
Signed-By: /etc/apt/keyrings/docker.asc
EOF

  # Install Docker
  sudo apt update
  sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  echo "✓ Docker installation complete"
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

enable_docker_service() {
  sudo systemctl enable docker
  sudo systemctl start docker
  echo "✓ Docker"
}
