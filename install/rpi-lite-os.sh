install_packages() {
  local core_pkgs=(
    build-essential openssh-server
    fzf eza zoxide tmux btop jq
    gpg docker.io kitty-terminfo
  )

  section "Updating system packages..."
  sudo apt update
  sudo apt upgrade -y

  section "Installing packages..."
  sudo apt remove -y containerd.io 2>/dev/null || true
  sudo apt install -y "${core_pkgs[@]}"

  # docker compose package name differs across RP-lite-OS/Ubuntu releases
  if apt-cache show docker-compose-plugin &>/dev/null; then
    sudo apt install -y docker-compose-plugin
  elif apt-cache show docker-compose &>/dev/null; then
    sudo apt install -y docker-compose
  fi

  # docker-buildx (skip if docker-buildx-plugin from Docker's repo is already installed)
  if ! dpkg -l docker-buildx-plugin &>/dev/null; then
    sudo apt install -y docker-buildx 2>/dev/null || true
  fi

  # tldr: RP-lite-OS Trixie+ replaced tldr with tealdeer
  if apt-cache show tealdeer &>/dev/null; then
    sudo apt install -y tealdeer
  else
    sudo apt install -y tldr
  fi

  # github-cli (not in RP-lite-OS/Ubuntu repos)
  if ! command -v gh &>/dev/null; then
    section "Installing GitHub CLI..."
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | sudo dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | sudo tee /etc/apt/sources.list.d/github-cli.list
    sudo apt update
    sudo apt install -y gh
  fi

  # tailscale (not in RP-lite-OS/Ubuntu repos)
  if ! command -v tailscale &>/dev/null; then
    section "Installing Tailscale..."
    curl -fsSL https://tailscale.com/install.sh | sh
  fi

  # starship (not in RP-lite-OS/Ubuntu repos)
  if ! command -v starship &>/dev/null; then
    section "Installing starship..."
    curl -sS https://starship.rs/install.sh | sh -s -- --yes
  fi

  # lazygit (not in Ubuntu repos)
  if ! command -v lazygit &>/dev/null; then
    section "Installing lazygit..."
    local LAZYGIT_VERSION
    local arch
    arch="$(dpkg --print-architecture)"
    case "$arch" in
      amd64) arch="x86_64" ;;
      arm64) arch="arm64" ;;
      armhf) arch="armv6" ;;
      *) arch="x86_64" ;;
    esac
    LAZYGIT_VERSION=$(curl -s "https://api.github.com/repos/jesseduffield/lazygit/releases/latest" | grep -Po '"tag_name": *"v\K[^"]*')
    curl -Lo /tmp/lazygit.tar.gz "https://github.com/jesseduffield/lazygit/releases/download/v${LAZYGIT_VERSION}/lazygit_${LAZYGIT_VERSION}_Linux_${arch}.tar.gz"
    tar xf /tmp/lazygit.tar.gz -C /tmp lazygit
    sudo install /tmp/lazygit /usr/local/bin/
    rm -f /tmp/lazygit.tar.gz /tmp/lazygit
  fi

  # lazydocker (not in Ubuntu repos)
  if ! command -v lazydocker &>/dev/null; then
    section "Installing lazydocker..."
    curl -fsSL https://raw.githubusercontent.com/jesseduffield/lazydocker/master/scripts/install_update_linux.sh | bash
  fi

  # gum (from Charm apt repo)
  if ! command -v gum &>/dev/null; then
    section "Installing gum..."
    sudo mkdir -p /etc/apt/keyrings
    curl -fsSL https://repo.charm.sh/apt/gpg.key | sudo gpg --dearmor -o /etc/apt/keyrings/charm.gpg
    echo "deb [signed-by=/etc/apt/keyrings/charm.gpg] https://repo.charm.sh/apt/ * *" | sudo tee /etc/apt/sources.list.d/charm.list
    sudo apt update
    sudo apt install -y gum
  fi

  # deno runtime
  if ! command -v deno &>/dev/null; then
    section "Installing deno..."
    curl -fsSL https://deno.land/install.sh | sh -s -- -y
    export PATH="$HOME/.deno/bin:$PATH"
  fi
}

install_optional_ai_tools() {
  section "Optional AI coding assistants..."

  if ! command -v deno &>/dev/null; then
    echo "Skipping AI assistants (deno not found)."
    return
  fi

  if gum confirm "Install opencode?" </dev/tty; then
    deno install -g -A --name opencode npm:opencode-ai || true
  fi

  if gum confirm "Install claude-code?" </dev/tty; then
    deno install -g -A --name claude-code npm:@anthropic-ai/claude-code || true
  fi
}

enable_services() {
  section "Enabling services..."

  sudo systemctl enable docker.service
  sudo systemctl start --no-block docker.service
  echo "✓ Docker"

  sudo systemctl enable --now ssh.service
  echo "✓ sshd"
}
