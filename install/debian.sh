install_packages() {
  local DEB_ARCH BINARY_ARCH
  DEB_ARCH="$(dpkg --print-architecture)"
  case "$DEB_ARCH" in
    amd64) BINARY_ARCH="x86_64" ;;
    arm64) BINARY_ARCH="arm64" ;;
    *) echo "Unsupported architecture: $DEB_ARCH"; return 1 ;;
  esac

  section "Updating system packages..."
  sudo apt-get update
  sudo apt-get upgrade -y

  section "Installing Debian packages..."
  sudo apt-get remove -y containerd.io 2>/dev/null || true
  sudo apt-get install -y \
    build-essential git openssh-server libssl-dev sudo less net-tools whois \
    fzf eza zoxide tmux btop jq man-db \
    vim luarocks \
    clang llvm rustc libyaml-0-2 \
    curl wget gpg \
    docker.io docker-compose \
    kitty-terminfo

  # Neovim from Debian/Ubuntu repos is too old for LazyVim. Use the official stable build when needed.
  local NVIM_BIN
  if ! NVIM_BIN="$(type -P nvim)" || ! dpkg --compare-versions "$($NVIM_BIN --version | awk 'NR == 1 { sub(/^v/, "", $2); print $2 }')" ge "0.11.2"; then
    section "Installing Neovim..."
    sudo apt-get remove -y neovim neovim-runtime 2>/dev/null || true
    sudo rm -rf "/opt/nvim-linux-${BINARY_ARCH}"
    curl -fsSL "https://github.com/neovim/neovim/releases/download/stable/nvim-linux-${BINARY_ARCH}.tar.gz" | sudo tar -C /opt -xz
    sudo ln -sfn "/opt/nvim-linux-${BINARY_ARCH}/bin/nvim" /usr/local/bin/nvim
    hash -r
  fi

  # docker-buildx (skip if docker-buildx-plugin from Docker's repo is already installed)
  if ! dpkg -l docker-buildx-plugin &>/dev/null; then
    sudo apt-get install -y docker-buildx 2>/dev/null || true
  fi

  # tldr: Debian Trixie+ replaced tldr with tealdeer
  if apt-cache show tealdeer &>/dev/null; then
    sudo apt-get install -y tealdeer
  else
    sudo apt-get install -y tldr
  fi

  # github-cli (not in Debian/Ubuntu repos)
  if ! command -v gh &>/dev/null; then
    section "Installing GitHub CLI..."
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | sudo dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | sudo tee /etc/apt/sources.list.d/github-cli.list
    sudo apt-get update
    sudo apt-get install -y gh
  fi

  # tailscale (not in Debian/Ubuntu repos)
  if ! command -v tailscale &>/dev/null; then
    section "Installing Tailscale..."
    curl -fsSL https://tailscale.com/install.sh | sh
  fi

  # starship (not in Debian/Ubuntu repos)
  if ! command -v starship &>/dev/null; then
    section "Installing starship..."
    curl -sS https://starship.rs/install.sh | sh -s -- --yes
  fi

  # lazygit (not in Ubuntu repos)
  if ! command -v lazygit &>/dev/null; then
    section "Installing lazygit..."
    local LAZYGIT_VERSION
    LAZYGIT_VERSION=$(curl -s "https://api.github.com/repos/jesseduffield/lazygit/releases/latest" | grep -Po '"tag_name": *"v\K[^"]*')
    curl -fsSL "https://github.com/jesseduffield/lazygit/releases/download/v${LAZYGIT_VERSION}/lazygit_${LAZYGIT_VERSION}_linux_${BINARY_ARCH}.tar.gz" | tar xz -C /tmp lazygit
    sudo install /tmp/lazygit /usr/local/bin/
    rm -f /tmp/lazygit
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
    sudo apt-get update
    sudo apt-get install -y gum
  fi

  # mise (not in Ubuntu repos)
  if ! command -v mise &>/dev/null; then
    section "Installing mise..."
    curl -fsSL https://mise.run | sh 2>/dev/null
    export PATH="$HOME/.local/bin:$PATH"
  fi
}

install_npm_tools() {
  section "Installing AI coding assistants..."
  if ! command -v opencode &>/dev/null; then
    npm install -g opencode-ai
  fi
  if ! command -v claude-code &>/dev/null; then
    npm install -g @anthropic-ai/claude-code
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
