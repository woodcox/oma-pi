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

  # lazygit (not in Ubuntu repos)
  if ! command -v lazygit &>/dev/null; then
    section "Installing lazygit..."
    local LAZYGIT_VERSION
    LAZYGIT_VERSION="$(github_latest_tag jesseduffield/lazygit)" || {
      echo "Error: could not determine the latest lazygit release (GitHub API unreachable or rate limited)" >&2
      return 1
    }
    LAZYGIT_VERSION="${LAZYGIT_VERSION#v}"   # release tag is v0.x.y, filenames are not

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

  # mise (not in Ubuntu repos)
  if ! command -v mise &>/dev/null; then
    section "Installing mise..."
    curl -fsSL https://mise.run | sh 2>/dev/null
    export PATH="$HOME/.local/bin:$PATH"
    echo "✓ mise installed"
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

  # Bun runtime
  #
  # Bun installs itself to ~/.bun/bin and adds to the shell rc files to allow optional_ai_apps to install. `config/shell/envs` owns the persistent entry.
  export PATH="$HOME/.bun/bin:$PATH"
  if ! command -v bun &>/dev/null; then
    section "Installing Bun..."
    curl -fsSL https://bun.sh/install | bash
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

# Bun installs global CLIs using the bin name each package declares.
# Returns non-zero on failure so a caller that depends on the result (the
# opencode-quota plugin entry) can check it. Failures stay non-fatal: callers
# that do not care append `|| true`, so the remaining optional tools, docker
# and the service setup still run.
bun_global_install() {
  local name="$1"
  local package="$2"

  if ! bun install -g --trust "$package"; then
    echo "Error: failed to install $name" >&2
    return 1
  fi
}

# opencode treats every package declared in `plugins` as installed: it resolves
# and caches it at startup, whether or not the CLI was ever installed. So the
# config entry is the opt-in, not a side effect of copying the config. 
set_opencode_quota_plugin() {
  local action="$1"
  local config="$HOME/.config/opencode/opencode.json"
  local pkg="@slkiser/opencode-quota"
  local filter tmp

  [[ -f $config ]] || return 0
  if ! command -v jq &>/dev/null; then
    echo "Warning: jq not found, cannot update $config" >&2
    return 0
  fi

  case "$action" in
    enable)
      filter='.plugins = ((.plugins // []) | if index($pkg) then . else . + [$pkg] end)'
      ;;
    disable)
      # Drop the key entirely once the list is empty, so the file goes back to
      # the shape the installer ships.
      filter='.plugins = ((.plugins // []) - [$pkg])
              | if (.plugins | length) == 0 then del(.plugins) else . end'
      ;;
    *)
      echo "Error: unknown action for $config: $action" >&2
      return 0
      ;;
  esac

  tmp="$(mktemp "${config}.XXXXXX")"
  # mktemp creates 0600; keep the mode the copied config had so opencode (or a
  # human) can still read it.
  chmod --reference="$config" "$tmp" 2>/dev/null || chmod 0644 "$tmp"

  # jq leaves nothing behind on a parse error, so only move the staged file
  # over the live config when jq actually produced output.
  if jq --arg pkg "$pkg" "$filter" "$config" >"$tmp"; then
    mv "$tmp" "$config" || {
      rm -f "$tmp"
      echo "Error: could not replace $config" >&2
    }
  else
    rm -f "$tmp"
    echo "Error: $config is not valid JSON, leaving it unchanged" >&2
  fi
}

install_optional_ai_tools() {
  section "Optional AI coding assistants..."

  if ! command -v bun &>/dev/null; then
    echo "Skipping AI assistants (bun not found)."
    return
  fi

  if ! command -v gum &>/dev/null; then
    echo "Skipping AI assistants (gum not found)."
    return
  fi

  # A refresh should not re-ask about a tool this box already has.
  # Report what is present and ask only about what is actually
  # missing, so every question is a real decision.
  #
  # Opencode
  if command -v opencode &>/dev/null; then
    echo "✓ opencode already installed ($(command -v opencode))"
  elif gum confirm "Install opencode?" </dev/tty; then
    bun_global_install opencode opencode-ai || true
  fi

  # opencode-quota turns the Go plan's rolling, weekly and monthly windows into
  # something the terminal (or an agent) can read.
  if command -v opencode &>/dev/null; then
    if command -v opencode-quota &>/dev/null; then
      echo "✓ opencode-quota already installed ($(command -v opencode-quota))"
      set_opencode_quota_plugin enable
    elif gum confirm "Install opencode-quota (OpenCode Go usage limits)?" </dev/tty; then
      # Only declare the plugin once the CLI is actually on the box. A failed
      # install must leave opencode.json alone: the entry is itself an install,
      # so writing it would have opencode fetch the package at startup anyway.
      if bun_global_install opencode-quota @slkiser/opencode-quota; then
        set_opencode_quota_plugin enable
      else
        echo "Skipping opencode-quota plugin config (install failed)." >&2
      fi
    else
      # Declining has to remove the entry too: opencode would otherwise fetch
      # and load the declared package itself at startup.
      set_opencode_quota_plugin disable
    fi
  fi

  # claude-code is matched under both names on purpose. The package is named
  # claude-code, but its bin is `claude`.
  if command -v claude-code &>/dev/null || command -v claude &>/dev/null; then
    echo "✓ claude-code already installed ($(command -v claude-code || command -v claude))"
  elif gum confirm "Install claude-code?" </dev/tty; then
    bun_global_install claude-code @anthropic-ai/claude-code || true
  fi

  # Hermes-agent installer 
  if command -v hermes &>/dev/null || command -v hermes-agent &>/dev/null; then
    echo "✓ Hermes Agent already installed ($(command -v hermes || command -v hermes-agent))"
  elif gum confirm "Install Hermes Agent?" </dev/tty; then
    curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash
  fi
}

# tuiboard is optional: it is a terminal kanban and planner for people and agents
#
# The installed version comes from the tool itself via `tuiboard doctor --json`. There
# is no package.json fallback: if doctor cannot report a version, the install
# is treated as absent. This is dependant on jq.
install_optional_tuiboard() {
  section "Optional tuiboard..."

  if ! command -v bun &>/dev/null; then
    echo "Skipping tuiboard (bun not found)."
    return
  fi
  if ! command -v gum &>/dev/null; then
    echo "Skipping tuiboard (gum not found)."
    return
  fi

  local installed latest
  installed=""
  if command -v tuiboard &>/dev/null; then
    installed="$(tuiboard doctor --json 2>/dev/null \
      | jq -r '.version // empty' 2>/dev/null || true)"
  fi

  latest=""
  if command -v curl &>/dev/null && command -v jq &>/dev/null; then
    latest="$(curl -fsSL --connect-timeout 10 --max-time 30 \
      https://registry.npmjs.org/tuiboard/latest 2>/dev/null \
      | jq -r '.version // empty' 2>/dev/null || true)"
  fi

  if [ -n "$installed" ]; then
    if [ -n "$latest" ] && [ "$installed" = "$latest" ]; then
      echo "✓ tuiboard $installed already up to date"
      return
    fi
    if [ -z "$latest" ]; then
      echo "✓ tuiboard $installed already installed (could not check for updates)"
      return
    fi
    echo "Updating tuiboard $installed -> $latest..."
  elif ! gum confirm "Install tuiboard (terminal kanban)?" </dev/tty; then
    return
  fi

  # Pin to the version just looked up when there is one, so the install cannot
  # race a fresh publish. Otherwise let Bun resolve the latest tag itself.
  if bun install -g "tuiboard@${latest:-latest}"; then
    if ! command -v tuiboard &>/dev/null || \
       ! installed="$(tuiboard doctor --json 2>/dev/null \
         | jq -r '.version // empty' 2>/dev/null)" || \
       [ -z "$installed" ]; then
      echo "Error: tuiboard was installed, but doctor did not report a version." >&2
      return
    fi
    echo "✓ tuiboard $installed"
  else
    echo "Error: failed to install tuiboard" >&2
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
