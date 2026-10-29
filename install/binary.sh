#!/usr/bin/env bash
# Install/update helpers for the binaries managed by the Oma-Pi installer.
#
# Managed binaries fall into two groups:
#
#   Mandatory (MS Edit, Yazi, Herdr, lazygit):
#     1. If already installed, fetch the latest release and compare versions.
#        When they match, skip the install.
#     2. If installed but outdated, install the newer release.
#     3. If not installed, install it without asking.
#
#   Optional (Fresh):
#     Same as above, except that when it is not installed it asks with gum
#     whether to install it, and only proceeds when confirmed (or skips when
#     gum is unavailable).
#
# Sourced by install.sh; relies on section, detect_arch and github_latest_tag
# from the installer.

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
    echo "MS Edit ${current_version:-unknown} installed; ${version} available - updating..."
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

install_yazi_binary() {
  section "Installing Yazi from GitHub releases..."

  local arch
  local current_version
  local version
  local dir
  local tmpdir
  local yazi_bin

  arch="$(detect_arch)"
  case "$arch" in
    aarch64|x86_64) ;;
    *)
      echo "Error: unsupported architecture for the Yazi package" >&2
      return 1
      ;;
  esac

  version="$(github_latest_tag sxyazi/yazi)" || {
    echo "Error: could not determine the latest Yazi release (GitHub API unreachable or rate limited)" >&2
    return 1
  }
  version="${version#v}"

  if command -v yazi &>/dev/null; then
    yazi_bin="$(command -v yazi)"
  else
    yazi_bin="$HOME/.local/bin/yazi"
  fi
  if [ -x "$yazi_bin" ]; then
    current_version="$("$yazi_bin" --version 2>/dev/null | awk '/Version:/{print $2; exit}')"
    if [ "$current_version" = "$version" ]; then
      echo "✓ Yazi ${version} already installed"
      return 0
    fi
    echo "Yazi ${current_version:-unknown} installed; ${version} available - updating..."
  fi

  # The GNU build requires glibc 2.39; Raspberry Pi OS bookworm still ships
  # 2.36, so that asset cannot even start there. The musl build is statically
  # linked and runs on every release this installer supports.
  dir="yazi-${arch}-unknown-linux-musl"
  tmpdir="$(mktemp -d)"

  if ! curl -fL "https://github.com/sxyazi/yazi/releases/download/v${version}/${dir}.zip" \
       -o "$tmpdir/yazi.zip"; then
    echo "Error: could not download Yazi ${version}" >&2
    rm -rf "$tmpdir"
    return 1
  fi
  if ! unzip -q "$tmpdir/yazi.zip" -d "$tmpdir"; then
    echo "Error: could not extract Yazi ${version}" >&2
    rm -rf "$tmpdir"
    return 1
  fi

  # Both binaries are installed: yazi is the TUI and ya is its CLI companion,
  # which the release ships and the shell completions expect.
  mkdir -p "$HOME/.local/bin"
  if ! install -m 0755 "$tmpdir/$dir/yazi" "$tmpdir/$dir/ya" "$HOME/.local/bin/"; then
    echo "Error: could not install Yazi to $HOME/.local/bin" >&2
    rm -rf "$tmpdir"
    return 1
  fi

  rm -rf "$tmpdir"
  echo "✓ Yazi ${version}"
}

install_herdr_binary() {
  section "Installing Herdr..."

  local herdr_bin
  local current_version
  local latest_version

  herdr_bin="$(command -v herdr 2>/dev/null || true)"
  [[ -n $herdr_bin ]] || herdr_bin="$HOME/.local/bin/herdr"

  latest_version="$(curl -fsSL https://herdr.dev/latest.json 2>/dev/null \
    | sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' | head -n1 || true)"

  if [[ -x $herdr_bin ]]; then
    current_version="$("$herdr_bin" --version 2>/dev/null | awk '{print $2}')"
    if [[ -z $latest_version || $current_version = "$latest_version" ]]; then
      echo "✓ Herdr ${current_version} already installed"
      return 0
    fi
    echo "Herdr ${current_version:-unknown} installed; ${latest_version} available - updating..."
  fi

  # Herdr publishes per-architecture Linux binaries and its installer verifies
  # the SHA-256 from https://herdr.dev/latest.json before installing. It is not
  # in the Debian repositories, so there is no apt package to prefer.
  if ! curl -fsSL https://herdr.dev/install.sh \
    | PATH="$HOME/.local/bin:$PATH" HERDR_INSTALL_DIR="$HOME/.local/bin" sh; then
    echo "Error: could not install Herdr" >&2
    return 1
  fi

  echo "✓ Herdr"
}

install_fresh_binary() {
  section "Installing Fresh from GitHub releases..."

  local arch
  local current_version
  local version
  local asset
  local tmpdir
  local subdir
  local ext

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
    echo "Fresh ${current_version:-unknown} installed; ${version} available - updating..."
  else
    if ! command -v gum &>/dev/null; then
      echo "Skipping Fresh (gum not found)."
      return 0
    fi
    if ! gum confirm "Install Fresh (terminal IDE)?" </dev/tty; then
      echo "Skipping Fresh."
      return 0
    fi
  fi

  # The musl build is statically linked, so it carries no glibc floor. The gnu
  # build is about the same size but needs glibc 2.30+, which is a floor this
  # repo should not be quietly assuming given it supports bookworm and Ubuntu.
  # Unlike the .deb assets, the tarballs carry no version in the filename, so
  # the name is fixed apart from the architecture.
  subdir="fresh-editor-${arch}-unknown-linux-musl"

  # Fresh publishes the same target triple as both .tar.xz and .tar.gz. tar -xJf
  # shells out to xz, so on a box that never installed xz-utils the extraction
  # died after the download had already succeeded, and nothing in core_pkgs
  # requires xz. Pick the gzip asset when xz is missing; the payload is the
  # same static binary either way.
  if command -v xz &>/dev/null; then
    ext="tar.xz"
  else
    ext="tar.gz"
  fi
  asset="${subdir}.${ext}"
  tmpdir="$(mktemp -d)"

  curl -fL "https://github.com/sinelaw/fresh/releases/download/v${version}/${asset}" -o "$tmpdir/fresh.${ext}" || {
    echo "Error: could not download Fresh ${version} from ${asset}" >&2
    rm -rf "$tmpdir"
    return 1
  }
  # The binary sits one level down inside a directory named after the target
  # triple, so pull just it rather than unpacking ~40MB of icons next to it.
  tar -xf "$tmpdir/fresh.${ext}" -C "$tmpdir" --strip-components=1 "${subdir}/fresh" || {
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

install_lazygit_binary() {
  section "Installing lazygit from GitHub releases..."

  local arch
  local current_version
  local version
  local asset
  local tmpdir

  arch="$(detect_arch)"
  case "$arch" in
    aarch64) arch="arm64"  ;;
    x86_64)  arch="x86_64" ;;
    *)
      echo "Error: unsupported architecture for the lazygit package" >&2
      return 1
      ;;
  esac

  version="$(github_latest_tag jesseduffield/lazygit)" || {
    echo "Error: could not determine the latest lazygit release (GitHub API unreachable or rate limited)" >&2
    return 1
  }
  version="${version#v}"   # release tag is v0.x.y, filenames are not

  if command -v lazygit &>/dev/null; then
    current_version="$(lazygit --version 2>/dev/null | sed -n 's/.*version=\([^, ]*\).*/\1/p')"
    if [ "$current_version" = "$version" ]; then
      echo "✓ lazygit ${version} already installed"
      return 0
    fi
    echo "lazygit ${current_version:-unknown} installed; ${version} available - updating..."
  fi

  asset="lazygit_${version}_Linux_${arch}.tar.gz"
  tmpdir="$(mktemp -d)"

  curl -fL "https://github.com/jesseduffield/lazygit/releases/download/v${version}/${asset}" -o "$tmpdir/lazygit.tar.gz" || {
    echo "Error: could not download lazygit ${version}" >&2
    rm -rf "$tmpdir"
    return 1
  }
  tar -xzf "$tmpdir/lazygit.tar.gz" -C "$tmpdir" lazygit || {
    echo "Error: could not extract lazygit ${version}" >&2
    rm -rf "$tmpdir"
    return 1
  }

  # Keep lazygit system-wide, where earlier installs put it. Installing to
  # ~/.local/bin while an older /usr/local/bin/lazygit exists would leave the
  # old copy first on PATH and the update would appear not to take effect.
  sudo install -m 0755 "$tmpdir/lazygit" /usr/local/bin/lazygit || {
    echo "Error: could not install lazygit to /usr/local/bin" >&2
    rm -rf "$tmpdir"
    return 1
  }

  rm -rf "$tmpdir"
  echo "✓ lazygit ${version}"
}

# Fresh is offered rather than installed outright. It is young (Dec 2024) and
# has no test coverage here, so a bad release taking the whole install run down
# with it is a worse trade than asking. MS Edit does not get this treatment: it
# is the default $EDITOR, and config/shell/aliases and the hds Herdr layout
# both invoke it by name, so a box that declined would have $EDITOR pointing at
# nothing.
install_optional_editors() {
  install_fresh_binary || echo "Error: Fresh install failed, continuing" >&2
}
