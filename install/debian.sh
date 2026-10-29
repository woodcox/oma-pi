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
    fzf zoxide btop jq
    gpg kitty-terminfo
    unzip fontconfig
    # bat backs the `ff`/`sff` fuzzy finders, parted + exfatprogs back
    # `format-drive`. Debian installs the bat binary as `batcat`, which
    # config/shell/aliases resolves for.
    bat parted exfatprogs
    # Yazi needs file(1) to identify what it is previewing; without it the
    # file manager starts but previews nothing. 7zip gives it archive preview
    # and extraction, the job nnn's nuke plugin used to do.
    file 7zip
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
  if apt-cache show tealdeer >/dev/null 2>&1; then
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
    FF_VERSION="$(github_latest_tag fastfetch-cli/fastfetch)" || {
      echo "Error: could not determine the latest fastfetch release (GitHub API unreachable or rate limited)" >&2
      return 1
    }

    # fastfetch names its amd64 build after the Debian architecture, not the
    # kernel one, so detect_arch's x86_64 has to be translated. detect_arch
    # exits inside the command substitution for anything else, which leaves
    # the value empty rather than failing the case, so catch that here.
    local FF_ARCH
    case "$(detect_arch)" in
      aarch64) FF_ARCH="aarch64" ;;
      x86_64)  FF_ARCH="amd64"   ;;
      *)
        echo "Error: unsupported architecture for the fastfetch package" >&2
        return 1
        ;;
    esac

    curl -Lo /tmp/fastfetch.deb \
      "https://github.com/fastfetch-cli/fastfetch/releases/download/${FF_VERSION}/fastfetch-linux-${FF_ARCH}.deb"
    sudo dpkg -i /tmp/fastfetch.deb
    rm -f /tmp/fastfetch.deb

    echo "✓ fastfetch installed with neofetch preset"
  fi

}

enable_services() {
  section "Enabling services..."

  enable_docker_service

  sudo systemctl enable --now ssh.service
  echo "✓ sshd"
}
