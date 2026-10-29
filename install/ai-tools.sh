#!/usr/bin/env bash
# Optional AI coding assistants and their shared helpers.
#
# Sourced by install.sh after install/debian.sh, which provides section() and
# installs bun and gum (the dependencies these tools need).

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
