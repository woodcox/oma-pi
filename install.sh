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

    # Point EDITOR at MS Edit. Matches the nvim line it replaces, so a box
    # last set up with nvim picks this up on refresh.
    sed -i -e 's/^export EDITOR="nvim"$/export EDITOR="msedit"/' "$SHELL_ENVS"


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

install_msedit_binary() {
  section "Installing MS Edit from GitHub releases..."

  local arch
  local current_version
  local version
  local asset
  local tmpdir

  # detect_arch already returns the names these release assets use, so no
  # translation layer is needed here the way fastfetch and Helix needed one.
  # It exits inside the command substitution for an unsupported machine, which
  # leaves arch empty rather than failing, so reject that explicitly.
  arch="$(detect_arch)"
  case "$arch" in
    aarch64|x86_64) ;;
    *)
      echo "Error: unsupported architecture for the MS Edit package" >&2
      return 1
      ;;
  esac

  version="$(github_latest_tag microsoft/edit)" || {
    echo "Error: could not determine the latest MS Edit release (GitHub API unreachable or rate limited)" >&2
    return 1
  }
  version="${version#v}"   # release tag is v2.0.0, asset filenames are not

  if command -v msedit &>/dev/null; then
    current_version="$(msedit --version 2>/dev/null | awk 'NR==1{print $NF}')"
    if [ "$current_version" = "$version" ]; then
      echo "✓ MS Edit ${version} already installed"
      return 0
    fi
  fi

  asset="edit-${version}-${arch}-linux-gnu.tar.gz"
  tmpdir="$(mktemp -d)"

  curl -fL "https://github.com/microsoft/edit/releases/download/v${version}/${asset}" -o "$tmpdir/msedit.tar.gz"
  tar -xzf "$tmpdir/msedit.tar.gz" -C "$tmpdir"

  # The release ships a single bare binary named `edit`, which would shadow
  # the `edit(1)` line editor every Debian install already has. Install it
  # under the name the project uses for it, as its own README and Homebrew
  # formula do.
  mkdir -p "$HOME/.local/bin"
  install -m 0755 "$tmpdir/edit" "$HOME/.local/bin/msedit"

  rm -rf "$tmpdir"
  echo "✓ MS Edit ${version} (as 'msedit')"
}

install_fresh_binary() {
  section "Installing Fresh from GitHub releases..."

  local arch
  local current_version
  local version
  local asset
  local tmpdir
  local subdir

  # Same reason as MS Edit: catch detect_arch's in-subshell exit, which would
  # otherwise produce a download URL with an empty architecture in it.
  arch="$(detect_arch)"
  case "$arch" in
    aarch64|x86_64) ;;
    *)
      echo "Error: unsupported architecture for the Fresh package" >&2
      return 1
      ;;
  esac

  version="$(github_latest_tag sinelaw/fresh)" || {
    echo "Error: could not determine the latest Fresh release (GitHub API unreachable or rate limited)" >&2
    return 1
  }
  version="${version#v}"

  if command -v fresh &>/dev/null; then
    current_version="$(fresh --version 2>/dev/null | awk 'NR==1{print $NF}')"
    if [ "$current_version" = "$version" ]; then
      echo "✓ Fresh ${version} already installed"
      return 0
    fi
  fi

  # The musl build is statically linked, so it carries no glibc floor. The gnu
  # build is about the same size but needs glibc 2.30+, which is a floor this
  # repo should not be quietly assuming given it supports bookworm and Ubuntu.
  # Unlike the .deb assets, the tarballs carry no version in the filename, so
  # the name is fixed apart from the architecture.
  subdir="fresh-editor-${arch}-unknown-linux-musl"
  asset="${subdir}.tar.xz"
  tmpdir="$(mktemp -d)"

  curl -fL "https://github.com/sinelaw/fresh/releases/download/v${version}/${asset}" -o "$tmpdir/fresh.tar.xz" || {
    echo "Error: could not download Fresh ${version} from ${asset}" >&2
    rm -rf "$tmpdir"
    return 1
  }
  # The binary sits one level down inside a directory named after the target
  # triple, so pull just it rather than unpacking ~40MB of icons next to it.
  tar -xJf "$tmpdir/fresh.tar.xz" -C "$tmpdir" --strip-components=1 "${subdir}/fresh" || {
    echo "Error: could not extract ${asset}" >&2
    rm -rf "$tmpdir"
    return 1
  }

  mkdir -p "$HOME/.local/bin"
  install -m 0755 "$tmpdir/fresh" "$HOME/.local/bin/fresh" || {
    echo "Error: could not install fresh to $HOME/.local/bin" >&2
    rm -rf "$tmpdir"
    return 1
  }

  rm -rf "$tmpdir"
  echo "✓ Fresh ${version}"
}

# Only Fresh is offered rather than installed outright. It is young (Dec 2024)
# and has no test coverage here, so a bad release taking the whole install run
# down with it is a worse trade than asking. MS Edit does not get this
# treatment: it is the default $EDITOR, and config/shell/aliases and the tds
# tmux layout both invoke it by name, so a box that declined would have
# $EDITOR pointing at nothing.
install_optional_editors() {
  section "Optional editors..."

  if ! command -v gum &>/dev/null; then
    echo "Skipping Fresh (gum not found)."
    return
  fi

  if gum confirm "Install Fresh (terminal IDE)?" </dev/tty; then
    # Called on the left of `||` because the failure is meant to be survivable.
    # That also means `set -e` is disabled for the whole of install_fresh_binary,
    # so the checks inside it are explicit rather than left to errexit.
    install_fresh_binary || echo "Error: Fresh install failed, continuing" >&2
  fi
}

install_configs() {
  section "Installing configs..."
  mkdir -p "$HOME/.config"
  cp -Rf "$INSTALLER_DIR/config/"* "$HOME/.config/"
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

  # Before any config copy, so a previous identity can be recovered from the
  # managed file and future ones have somewhere durable to live.
  ensure_git_config

  # Omadots
  install_omadots

  # MS Edit binary: the default $EDITOR
  install_msedit_binary

  # Configs and bins
  install_configs
  install_bins

  # Optional extras. Before patch_shell_config, which is the last step to
  # touch ~/.config.
  install_optional_editors

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
