#!/usr/bin/env bash
# Language runtimes, version managers, and JS-based terminal tools.
#
# Sourced by install.sh after install/debian.sh. Bun is installed first because
# the optional AI tools, tuiboard, and hunk all use it.

# Bun runtime
#
# Bun installs itself to ~/.bun/bin and adds itself to the shell rc files.
# `config/shell/envs` owns the persistent PATH entry.
install_bun() {
  export PATH="$HOME/.bun/bin:$PATH"
  if ! command -v bun &>/dev/null; then
    section "Installing Bun..."
    curl -fsSL https://bun.sh/install | bash
  fi
}

# mise (not in Ubuntu repos)
install_mise() {
  if ! command -v mise &>/dev/null; then
    section "Installing mise..."
    curl -fsSL https://mise.run | sh 2>/dev/null
    export PATH="$HOME/.local/bin:$PATH"
    echo "✓ mise installed"
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

# hunk is optional: it is a terminal diff viewer for reviewing changes.
#
# The npm package is `hunkdiff` (the plain `hunk` package is unrelated), and
# it exposes the `hunk` executable. `hunk --version` prints a bare version,
# so no parsing is needed.
install_optional_hunk() {
  section "Optional hunk..."

  if ! command -v bun &>/dev/null; then
    echo "Skipping hunk (bun not found)."
    return
  fi
  if ! command -v gum &>/dev/null; then
    echo "Skipping hunk (gum not found)."
    return
  fi

  local installed latest
  installed=""
  if command -v hunk &>/dev/null; then
    installed="$(hunk --version 2>/dev/null | head -n 1 || true)"
  fi

  latest=""
  if command -v curl &>/dev/null && command -v jq &>/dev/null; then
    latest="$(curl -fsSL --connect-timeout 10 --max-time 30 \
      https://registry.npmjs.org/hunkdiff/latest 2>/dev/null \
      | jq -r '.version // empty' 2>/dev/null || true)"
  fi

  if [ -n "$installed" ]; then
    if [ -n "$latest" ] && [ "$installed" = "$latest" ]; then
      echo "✓ hunk $installed already up to date"
      return
    fi
    if [ -z "$latest" ]; then
      echo "✓ hunk $installed already installed (could not check for updates)"
      return
    fi
    echo "Updating hunk $installed -> $latest..."
  elif ! gum confirm "Install hunk (terminal diff viewer)?" </dev/tty; then
    return
  fi

  # Pin to the version just looked up when there is one, so the install cannot
  # race a fresh publish. Otherwise let Bun resolve the latest tag itself.
  if bun install -g "hunkdiff@${latest:-latest}"; then
    if ! command -v hunk &>/dev/null || \
       ! installed="$(hunk --version 2>/dev/null | head -n 1)" || \
       [ -z "$installed" ]; then
      echo "Error: hunk was installed, but --version did not report one." >&2
      return
    fi
    echo "✓ hunk $installed"
  else
    echo "Error: failed to install hunk" >&2
  fi
}
