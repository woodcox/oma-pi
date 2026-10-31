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

# One entry per install: "<github-owner/repo>|<skill-name>". Use "*" as the
# skill name to install every skill the repo ships.
# Add skills here:
# ===================================================
AI_SKILLS=(
  "modem-dev/hunk|hunk-review"
  "mattpocock/skills|*"
)
# ===================================================

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

# Hermes does not scan ~/.agents/skills on its own. Listing it under
# skills.external_dirs in config.yaml is what makes the skills CLI's global
# installs visible to it. Idempotent, and bails out (without touching the
# file) on YAML shapes it does not understand, such as inline `skills: {}`.
set_hermes_external_skills_dir() {
  local config="$HOME/.hermes/config.yaml"
  local entry="~/.agents/skills"
  local tmp

  if [[ ! -f $config ]]; then
    echo "Note: $config not found; run Hermes once, then re-run this installer to link skills." >&2
    return 0
  fi

  # Only accept a match under skills.external_dirs: the same path can appear
  # under another key (for example skills.trusted_project_dirs), which Hermes
  # does not use for external skills.
  if awk '
    function indent(line) {
      match(line, /^[[:space:]]*/)
      return RLENGTH
    }
    /^skills:[[:space:]]*(#.*)?$/ {
      in_skills = 1
      in_external = 0
      next
    }
    in_skills && /^[^[:space:]#]/ {
      in_skills = 0
      in_external = 0
    }
    in_skills && /^[[:space:]]+external_dirs:[[:space:]]*(#.*)?$/ {
      external_indent = indent($0)
      in_external = 1
      next
    }
    # A sibling key closes the list. A sequence item at the key indentation is
    # still part of it (YAML allows indentationless sequences).
    in_skills && in_external &&
      $0 !~ /^[[:space:]]*(#.*)?$/ &&
      $0 !~ /^[[:space:]]*-[[:space:]]/ &&
      indent($0) <= external_indent {
      in_external = 0
    }
    in_skills && in_external &&
      /^[[:space:]]+-[[:space:]]+["'\'']?(~|\$HOME|\/[^[:space:]]+)\/\.agents\/skills["'\'']?[[:space:]]*$/ {
      found = 1
    }
    END { exit !found }
  ' "$config"; then
    echo "✓ Hermes already reads ~/.agents/skills"
    return 0
  fi

  if grep -qE '^skills:' "$config" && ! grep -qE '^skills:[[:space:]]*(#.*)?$' "$config"; then
    echo "Warning: unsupported 'skills:' layout in $config; add '$entry' to skills.external_dirs by hand" >&2
    return 0
  fi
  if grep -qE '^[[:space:]]+external_dirs:[[:space:]]*[^[:space:]#]' "$config"; then
    echo "Warning: inline external_dirs in $config; add '$entry' by hand" >&2
    return 0
  fi

  tmp="$(mktemp "${config}.XXXXXX")"
  chmod --reference="$config" "$tmp" 2>/dev/null || chmod 0644 "$tmp"

  if awk -v entry="$entry" '
    BEGIN { ind = "  " }

    /^skills:[[:space:]]*(#.*)?$/ { print; in_skills = 1; seen = 1; next }

    # First indented line under skills: sets the block indentation.
    in_skills && !have_child && /^[[:space:]]+[^[:space:]#]/ {
      match($0, /^[[:space:]]+/); ind = substr($0, 1, RLENGTH); have_child = 1
    }

    # Between "external_dirs:" and its first item: pass blanks/comments through.
    pending && /^[[:space:]]*(#.*)?$/ { print; next }

    # First real line after "external_dirs:" decides the item indentation.
    pending {
      pending = 0
      if ($0 ~ /^[[:space:]]*-[[:space:]]/) {
        match($0, /^[[:space:]]*/); print substr($0, 1, RLENGTH) "- " entry
      } else {
        print ekey "  - " entry   # empty list: indent relative to the key
      }
      done = 1
      # fall through so this line is handled normally
    }

    in_skills && /^[^[:space:]#]/ {
      # Reached the next top-level key without finding external_dirs.
      if (!done) { print ind "external_dirs:"; print ind "  - " entry; done = 1 }
      in_skills = 0
    }

    in_skills && !done && /^[[:space:]]+external_dirs:[[:space:]]*(#.*)?$/ {
      match($0, /^[[:space:]]+/); ekey = substr($0, 1, RLENGTH)
      print; pending = 1; next
    }

    { print }

    END {
      if (!seen) {
        print "skills:"; print "  external_dirs:"; print "    - " entry
      } else if (pending) {
        print ekey "  - " entry          # file ended right after the key
      } else if (in_skills && !done) {
        print ind "external_dirs:"; print ind "  - " entry
      }
    }
  ' "$config" >"$tmp"; then
    mv "$tmp" "$config" || {
      rm -f "$tmp"
      echo "Error: could not replace $config" >&2
      return 1
    }
    echo "✓ added ~/.agents/skills to Hermes skills.external_dirs"
  else
    rm -f "$tmp"
    echo "Error: failed to update $config" >&2
    return 1
  fi
}


# True if at least one entry still needs installing. A "*" entry cannot be
# checked on disk, so it always counts as pending.
ai_skills_pending() {
  local entry skill
  for entry in "${AI_SKILLS[@]}"; do
    skill="${entry#*|}"
    [[ $skill == "*" || ! -d $HOME/.agents/skills/$skill ]] && return 0
  done
  return 1
}

# True if the Claude Code CLI is on the box. The package is claude-code, but
# its bin is `claude`, so check both names.
have_claude_code() {
  command -v claude &>/dev/null || command -v claude-code &>/dev/null
}

# Claude Code keeps its own copy (or link) of each skill; the CLI honours
# CLAUDE_CONFIG_DIR when it chooses that directory.
claude_skills_dir() {
  printf '%s/skills\n' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
}

# True only when every agent this installer targets already has the skill.
# Checking the canonical directory alone would skip the CLI call that links a
# skill into a newly installed agent.
skill_installed_for_agents() {
  local skill="$1"

  [[ -d $HOME/.agents/skills/$skill ]] || return 1
  if have_claude_code && [[ ! -d "$(claude_skills_dir)/$skill" ]]; then
    return 1
  fi
}

have_hermes() {
  command -v hermes &>/dev/null || command -v hermes-agent &>/dev/null
}

# The skills CLI installs each global skill once into ~/.agents/skills and
# links it into every agent named with -a (opencode, claude-code). Hermes has
# no CLI target, so it reads ~/.agents/skills via skills.external_dirs.
install_ai_skills() {
  local entry source skill failed=0
  local -a cmd agent_args=()

  # OpenCode is a universal target, so listing it makes the CLI write the
  # canonical ~/.agents/skills copy. Include it even when OpenCode is not
  # installed: with only Claude Code selected the CLI switches to copy mode and
  # writes solely to ~/.claude/skills, leaving Hermes (which reads the
  # canonical directory) and ai_skills_pending unaware of the skill. Adding a
  # universal target keeps the canonical copy plus Claude Code's link.
  agent_args=(-a opencode)
  have_claude_code && agent_args+=(-a claude-code)

  for entry in "${AI_SKILLS[@]}"; do
    source="${entry%%|*}"
    skill="${entry#*|}"

    if [[ $skill != "*" ]] && skill_installed_for_agents "$skill"; then
      echo "✓ $skill already installed"
      continue
    fi

    cmd=(bunx skills@latest add "$source" -g -y --skill "$skill" "${agent_args[@]}")
    if ! "${cmd[@]}"; then
      echo "Error: failed to install skills from $source ($skill)" >&2
      failed=1
    fi
  done

  if have_hermes; then
    set_hermes_external_skills_dir
  fi

  return "$failed"
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
  if have_claude_code; then
    echo "✓ claude-code already installed ($(command -v claude-code || command -v claude))"
  elif gum confirm "Install claude-code?" </dev/tty; then
    bun_global_install claude-code @anthropic-ai/claude-code || true
  fi

  # Hermes-agent installer
  if have_hermes; then
    echo "✓ Hermes Agent already installed ($(command -v hermes || command -v hermes-agent))"
  elif gum confirm "Install Hermes Agent?" </dev/tty; then
    curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash
  fi

  # Shared agent skills: only worth installing if an agent will use them.
  if command -v opencode &>/dev/null || have_claude_code || have_hermes; then
    if ! ai_skills_pending; then
      echo "✓ agent skills already installed"
      install_ai_skills || true   # still ensure the Hermes config entry exists
    elif gum confirm "Install agent skills (${#AI_SKILLS[@]} sources) for opencode / claude-code / Hermes?" </dev/tty; then
      install_ai_skills || true
    fi
  fi
}
