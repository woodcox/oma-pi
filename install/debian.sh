# Detect CPU architecture once; used by tools that ship per-arch binaries.
detect_arch() {
  local arch
  arch="$(uname -m)"
  case "$arch" in
    aarch64) echo "aarch64" ;;
    x86_64)  echo "x86_64"  ;;
    *)
      echo "ERROR: Unsupported architecture: $arch" >&2
      exit 1
      ;;
  esac
}

install_packages() {
  local core_pkgs=(
    build-essential openssh-server
    fzf zoxide tmux btop jq
    gpg kitty-terminfo
    unzip fontconfig
  )

  section "Updating system packages..."
  sudo apt update
  sudo apt upgrade -y

  section "Installing Debian packages..."
  sudo apt install -y "${core_pkgs[@]}"

  # eza (from deb.gierens.de)
  if ! command -v eza &>/dev/null; then
    section "Installing eza..."
    sudo mkdir -p /etc/apt/keyrings
    curl -fsSL https://raw.githubusercontent.com/eza-community/eza/main/deb.asc \
      | sudo gpg --dearmor -o /etc/apt/keyrings/gierens.gpg
    echo "deb [signed-by=/etc/apt/keyrings/gierens.gpg] http://deb.gierens.de stable main" \
      | sudo tee /etc/apt/sources.list.d/gierens.list >/dev/null
    sudo chmod 644 /etc/apt/keyrings/gierens.gpg /etc/apt/sources.list.d/gierens.list
    sudo apt update
    sudo apt install -y eza
  fi

  # tldr: Debian Trixie+ ships tealdeer instead of tldr
  if apt-cache show tealdeer &>/dev/null; then
    sudo apt install -y tealdeer
  else
    sudo apt install -y tldr
  fi

  # github-cli (not in Debian/Ubuntu repos)
  if ! command -v gh &>/dev/null; then
    section "Installing GitHub CLI..."
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      | sudo dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      | sudo tee /etc/apt/sources.list.d/github-cli.list
    sudo apt update
    sudo apt install -y gh
  fi

  # tailscale (not in Debian/Ubuntu repos)
  if ! command -v tailscale &>/dev/null; then
    section "Installing Tailscale..."
    curl -fsSL https://tailscale.com/install.sh | sh
  fi

  # Hack Nerd Font (required by Starship prompt)
  # To update HACK_FONT_VERSION, bump the version number as Nerd Fonts major versions occasionally change glyph mappings.
  local HACK_FONT_VERSION="3.3.0"
  local FONT_DIR="$HOME/.local/share/fonts/Hack"
  local FONT_MARKER="$FONT_DIR/.version"

  if [ ! -f "$FONT_MARKER" ] || [ "$(cat "$FONT_MARKER")" != "$HACK_FONT_VERSION" ]; then
    section "Installing Hack Nerd Font v$HACK_FONT_VERSION..."
    mkdir -p "$FONT_DIR"
    local tmp_zip="/tmp/hack-nerd-font.zip"
    wget -qO "$tmp_zip" \
      "https://github.com/ryanoasis/nerd-fonts/releases/download/v${HACK_FONT_VERSION}/Hack.zip"
    unzip -q "$tmp_zip" -d "$FONT_DIR"
    rm -f "$tmp_zip"
    echo "$HACK_FONT_VERSION" > "$FONT_MARKER"
    fc-cache -fv >/dev/null
    echo "✓ Hack Nerd Font installed"
  else
    echo "Hack Nerd Font already up to date, skipping"
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
    LAZYGIT_VERSION="$(curl -s "https://api.github.com/repos/jesseduffield/lazygit/releases/latest" \
      | grep -Po '"tag_name": *"v\K[^"]*')"

    # lazygit uses "arm64" not "aarch64" in its release filenames
    local ARCH LG_ARCH
    ARCH="$(detect_arch)"
    case "$ARCH" in
      aarch64) LG_ARCH="arm64"  ;;
      x86_64)  LG_ARCH="x86_64" ;;
    esac

    curl -Lo /tmp/lazygit.tar.gz \
      "https://github.com/jesseduffield/lazygit/releases/download/v${LAZYGIT_VERSION}/lazygit_${LAZYGIT_VERSION}_Linux_${LG_ARCH}.tar.gz"
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
    curl -fsSL https://repo.charm.sh/apt/gpg.key \
      | sudo gpg --dearmor -o /etc/apt/keyrings/charm.gpg
    echo "deb [signed-by=/etc/apt/keyrings/charm.gpg] https://repo.charm.sh/apt/ * *" \
      | sudo tee /etc/apt/sources.list.d/charm.list
    sudo apt update
    sudo apt install -y gum
  fi

  # fastfetch (not in Debian Bookworm repos; fetch .deb directly for aarch64)
  if ! command -v fastfetch &>/dev/null; then
    section "Installing fastfetch..."
    local FF_VERSION
    FF_VERSION="$(curl -s "https://api.github.com/repos/fastfetch-cli/fastfetch/releases/latest" \
      | grep -Po '"tag_name": *"v\K[^"]*')"

    local FF_ARCH
    FF_ARCH="$(detect_arch)"  # aarch64 or x86_64

    curl -Lo /tmp/fastfetch.deb \
      "https://github.com/fastfetch-cli/fastfetch/releases/download/v${FF_VERSION}/fastfetch-linux-${FF_ARCH}.deb"
    sudo dpkg -i /tmp/fastfetch.deb
    rm -f /tmp/fastfetch.deb

    # Install neofetch.jsonc preset as the default config
    local FF_CONFIG_DIR="$HOME/.config/fastfetch"
    mkdir -p "$FF_CONFIG_DIR"
    cat > "$FF_CONFIG_DIR/config.jsonc" << 'EOF'
{
  "$schema": "https://github.com/fastfetch-cli/fastfetch/raw/dev/doc/json_schema.json",
  "display": {
    "size": {
      "maxPrefix": "MB",
      "ndigits": 0,
      "spaceBeforeUnit": "never"
    },
    "freq": {
      "ndigits": 3,
      "spaceBeforeUnit": "never"
    }
  },
  "modules": [
    "title",
    "separator",
    "os",
    "host",
    {
      "type": "kernel",
      "format": "{release}"
    },
    "uptime",
    {
      "type": "packages",
      "combined": true
    },
    "shell",
    {
      "type": "display",
      "compactType": "original",
      "key": "Resolution"
    },
    "de",
    "wm",
    "wmtheme",
    "theme",
    "icons",
    "terminal",
    {
      "type": "terminalfont",
      "format": "{/name}{-}{/}{name}{?size} {size}{?}"
    },
    "cpu",
    {
      "type": "gpu",
      "key": "GPU",
      "format": "{name}"
    },
    {
      "type": "memory",
      "format": "{used} / {total}"
    },
    "break",
    "colors"
  ]
}
EOF
    echo "✓ fastfetch installed with neofetch preset"
  fi

  # deno runtime
  # Note: the installer adds ~/.deno/bin to shell rc files automatically.
  # We also export it here so subsequent steps in this script can use deno.
  if ! command -v deno &>/dev/null; then
    section "Installing deno..."
    curl -fsSL https://deno.land/install.sh | sh -s -- -y
    export PATH="$HOME/.deno/bin:$PATH"
  fi
}

# See: https://docs.docker.com/engine/install/debian/ for docker install guidance
install_docker() {
  echo "Installing Docker..."

  set -e  # stop on error

  # Ensure required packages
  sudo apt update
  sudo apt install -y ca-certificates curl

  # Create keyrings dir if it doesn't exist
  sudo install -m 0755 -d /etc/apt/keyrings

  # Add Docker GPG key (only if missing)
  if [ ! -f /etc/apt/keyrings/docker.asc ]; then
    echo "Adding Docker GPG key..."
    sudo curl -fsSL https://download.docker.com/linux/debian/gpg \
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
  echo "Setting up Docker repository..."
  sudo tee /etc/apt/sources.list.d/docker.sources > /dev/null <<EOF
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: ${CODENAME}
Components: stable
Architectures: ${ARCH}
Signed-By: /etc/apt/keyrings/docker.asc
EOF

  # Install Docker
  sudo apt update
  sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  echo "Docker installation complete ✅"
}

install_optional_ai_tools() {
  section "Optional AI coding assistants..."

  if ! command -v deno &>/dev/null; then
    echo "Skipping AI assistants (deno not found)."
    return
  fi

  if ! command -v gum &>/dev/null; then
    echo "Skipping AI assistants (gum not found)."
    return
  fi

  if gum confirm "Install opencode?" </dev/tty; then
    deno install -g -A --name opencode npm:opencode-ai || true
  fi

  if gum confirm "Install claude-code?" </dev/tty; then
    deno install -g -A --name claude-code npm:@anthropic-ai/claude-code || true
  fi

  if gum confirm "Install Openai Codex?" </dev/tty; then
    deno install -g -A --name codex npm:@openai/codex || true
  fi
}

enable_services() {
  section "Enabling services..."

  sudo systemctl enable docker
  sudo systemctl start docker
  echo "✓ Docker"

  sudo systemctl enable --now ssh.service
  echo "✓ sshd"
}
