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
    # atool backs the nnn nuke plugin, which lists most archives through it
    # and falls back to bsdtar only when atool is absent. Neither is a
    # dependency of anything else here, so without this a box would install
    # nuke and then be unable to list anything with it. 136K, and perl is
    # already required by build-essential below.
    atool
  )

  section "Updating system packages..."
  sudo apt update
  sudo apt upgrade -y

  section "Installing Debian packages..."
  sudo apt install -y "${core_pkgs[@]}"

  # nnn is the interactive file manager. Its -e opens text files with $VISUAL,
  # which config/shell/envs pins to $EDITOR.
  #
  # Not in core_pkgs: nnn ships in Debian's main but in Ubuntu's universe on
  # every series, and this installer runs on both. A stock Ubuntu server image
  # does not enable universe, so an unconditional `apt install nnn` there dies
  # with "Unable to locate package" and, under `set -e`, takes every remaining
  # install step down with it. Check it is actually a candidate first, and say
  # so plainly rather than failing the whole run over a file manager.
  if apt-cache show nnn >/dev/null 2>&1; then
    sudo apt install -y nnn
  else
    echo "Skipping nnn: not available in the enabled apt components."
    echo "  On Ubuntu, enable universe with: sudo add-apt-repository universe"
  fi

  # nnn plugins: nuke browses and extracts archives, the rest add key bindings.
  # config/shell/fns/nnn points NNN_OPENER at nuke, so a box that skips this
  # has an opener path that resolves to nothing and archives stop opening.
  #
  # Upstream ships plugins/getplugs, but it cannot run here: when a plugin
  # file already differs it opens nvim/vimdiff or blocks on `read`, and an
  # installer that prompts halfway through is worse than one that skips. Fetch
  # the release tarball for the installed nnn and copy the directory directly
  # instead, so a run stays deterministic and re-runnable.
  #
  # Keyed on nnn's version because the tarball is per-release and nnn only
  # loads plugins matching the running binary. A box upgraded to a new nnn
  # gets a marker mismatch and refetches. The marker sits beside plugins/
  # rather than inside it, so the plugin directory holds only plugins.
  if ! command -v nnn &>/dev/null; then
    echo "Skipping nnn plugins: nnn is not installed."
  else
    local NNN_VERSION NNN_DIR NNN_MARKER
    NNN_VERSION="$(nnn -V)"
    NNN_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/nnn"
    NNN_MARKER="$NNN_DIR/.plugins-version"

    if [ -f "$NNN_MARKER" ] && [ "$(cat "$NNN_MARKER")" = "$NNN_VERSION" ]; then
      echo "nnn plugins already at $NNN_VERSION, skipping"
    else
      section "Installing nnn plugins (v$NNN_VERSION)..."
      # The archive unpacks to nnn-$VERSION, without the v that the release
      # tag and the tarball filename both carry.
      local nnn_tmp
      nnn_tmp="$(mktemp -d)" || return 1
      if curl -fsSL --connect-timeout 10 --max-time 120 \
           "https://github.com/jarun/nnn/releases/download/v${NNN_VERSION}/nnn-v${NNN_VERSION}.tar.gz" \
           -o "$nnn_tmp/nnn.tar.gz" \
         && tar -xzf "$nnn_tmp/nnn.tar.gz" -C "$nnn_tmp" \
         && [ -d "$nnn_tmp/nnn-${NNN_VERSION}/plugins" ]; then
        # Back up whatever is there before overwriting. This path only runs
        # when the marker disagrees, which is either an nnn upgrade or a
        # hand-edited plugin, and `cp -Rf` would silently discard the second.
        # getplugs backs up for the same reason, but then prompts on the
        # differing files; a backup we cannot act on interactively is the most
        # a non-interactive installer can do.
        if [ -d "$NNN_DIR/plugins" ] && [ -n "$(ls -A "$NNN_DIR/plugins" 2>/dev/null)" ]; then
          local nnn_backup="$NNN_DIR/plugins-$(date '+%Y%m%d%H%M').tar.gz"
          if tar -czf "$nnn_backup" -C "$NNN_DIR" plugins 2>/dev/null; then
            echo "✓ Existing plugins backed up to ${nnn_backup##*/}"
          else
            echo "Warning: could not back up existing plugins; continuing" >&2
          fi
        fi
        mkdir -p "$NNN_DIR/plugins"
        cp -Rf "$nnn_tmp/nnn-${NNN_VERSION}/plugins/." "$NNN_DIR/plugins/"
        printf '%s\n' "$NNN_VERSION" > "$NNN_MARKER"
        echo "✓ nnn plugins installed"
      else
        # Deliberately not fatal. nnn itself, and everything else in this
        # function, still works; only NNN_OPENER is left dangling, which is
        # a worse outcome than saying so and carrying on.
        echo "Error: could not fetch nnn plugins for v$NNN_VERSION;" >&2
        echo "  nnn still works, but archives will not open. Re-run with:" >&2
        echo "  curl -fsSL https://raw.githubusercontent.com/jarun/nnn/master/plugins/getplugs | sh" >&2
      fi
      rm -rf "$nnn_tmp"
    fi
  fi

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

  echo "Docker installation complete ✅"
}

# Deno treats a deno.json in the working directory (or any parent) as the
# project config for the install, and writes deno.lock next to it. Running
# from wherever the user happened to invoke the installer therefore created
# ~/deno.json and ~/deno.lock in their home directory. Install from the
# throwaway clone instead, which has no deno.json above it.
deno_global_install() {
  local name="$1"
  local package="$2"

  # Not fatal: a failure here should not skip the remaining optional tools,
  # docker and the service setup that follow. Report it rather than letting
  # the `|| true` that used to be here hide it completely.
  if ! (cd "$INSTALLER_DIR" && deno install -g -A --name "$name" "$package"); then
    echo "Error: failed to install $name" >&2
  fi
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

  # A refresh should not re-ask about a tool this box already has, and none of
  # these are cheap to repeat: the two deno installs are npm trees under
  # ~/.deno, and the Hermes installer writes a set of shims into ~/.local/bin.
  # Report what is present and ask only about what is actually missing, so
  # every question that does get asked has a real decision behind it.
  #
  # claude-code is matched under both names on purpose. The deno install below
  # puts it on PATH as `claude-code`, but the published npm package and every
  # alias in config/shell/aliases call it `claude`, so a box provisioned either
  # way should count as already having it.
  if command -v opencode &>/dev/null; then
    echo "✓ opencode already installed ($(command -v opencode))"
  elif gum confirm "Install opencode?" </dev/tty; then
    deno_global_install opencode npm:opencode-ai
  fi

  if command -v claude-code &>/dev/null || command -v claude &>/dev/null; then
    echo "✓ claude-code already installed ($(command -v claude-code || command -v claude))"
  elif gum confirm "Install claude-code?" </dev/tty; then
    deno_global_install claude-code npm:@anthropic-ai/claude-code
  fi

  # The Hermes installer drops `hermes` plus `hermes-acp` and `hermes-agent`
  # shims, so `hermes` alone is enough to detect it, with the other as a
  # fallback in case a future release renames the entry point.
  if command -v hermes &>/dev/null || command -v hermes-agent &>/dev/null; then
    echo "✓ Hermes Agent already installed ($(command -v hermes || command -v hermes-agent))"
  elif gum confirm "Install Hermes Agent?" </dev/tty; then
    curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash
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
