#!/usr/bin/env bash
# Dotfiles, configs, and helper bins.
#
# Sourced by install.sh. install_dots runs before install_configs because it
# records the shell rc file that install_configs then patches.

# Guard against `>>` concatenating onto a last line that has no trailing newline
ensure_trailing_newline() {
  local file="$1"
  [[ -s $file ]] || return 0
  if [[ -n $(tail -c 1 "$file") ]]; then
    printf '\n' >>"$file"
  fi
}

install_dots() {
  section "Installing dots configs..."

  section "Copying dots to ~/.config..."
  mkdir -p "$HOME/.config"
  cp -rf "$INSTALLER_DIR/config/." "$HOME/.config/"
  echo "✓ Configs"

  section "Configuring shell..."
  # Tracked so later steps (Herdr auto-start) patch the rc file this shell
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

install_configs() {
  section "Installing configs..."
  mkdir -p "$HOME/.config"
  cp -Rf "$INSTALLER_DIR/config/"* "$HOME/.config/"
  echo "✓ Btop config"
  echo "✓ Git config"
  echo "✓ Lazygit config"
  echo "✓ Mise config"
  echo "✓ Opencode config"
  echo "✓ Starship config"

  if ! grep -qF 'if [[ -z ${HERDR_ENV:-} ]]; then' "$SHELL_RC" 2>/dev/null; then
    ensure_trailing_newline "$SHELL_RC"
    cat >>"$SHELL_RC" <<'BASHRC_HERDR'
if [[ -z ${HERDR_ENV:-} ]]; then
  h
else
  # Herdr has no server-wide environment like `tmux setenv`, so a marker keyed
  # on the session socket stands in for FASTFETCH_SHOWN. Named sessions get
  # their own socket, and therefore their own first-pane banner.
  _oma_fastfetch_marker="${XDG_RUNTIME_DIR:-/tmp}/oma-pi-fastfetch-$(printf '%s' "${HERDR_SOCKET_PATH:-default}" | md5sum | cut -d' ' -f1)"
  if [[ ! -e $_oma_fastfetch_marker ]]; then
    mkdir -p "$(dirname "$_oma_fastfetch_marker")"
    : >"$_oma_fastfetch_marker"
    fastfetch
  fi
  unset _oma_fastfetch_marker
fi
BASHRC_HERDR
    echo "✓ Herdr auto-start"
    echo "✓ fastfetch on first Herdr pane"
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
  echo "✓ omapi-harden"
}
