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

# One entry per skill: "<github-owner/repo>|<skill-name>". Entries that share a
# repo are installed with one `skills add` call, so listing every skill does
# not clone the repo once per skill. Avoid "*": it cannot be checked on disk,
# so ai_skills_pending would ask to install it on every run.
# Add skills here:
# ===================================================
AI_SKILLS=(
  "modem-dev/hunk|hunk-review"
  "mattpocock/skills|ask-matt"
  "mattpocock/skills|chief-of-staff"
  "mattpocock/skills|claude-handoff"
  "mattpocock/skills|code-review"
  "mattpocock/skills|codebase-design"
  "mattpocock/skills|diagnosing-bugs"
  "mattpocock/skills|domain-modeling"
  "mattpocock/skills|git-guardrails-claude-code"
  "mattpocock/skills|grill-me"
  "mattpocock/skills|grill-with-docs"
  "mattpocock/skills|grilling"
  "mattpocock/skills|handoff"
  "mattpocock/skills|implement"
  "mattpocock/skills|implement-spec"
  "mattpocock/skills|improve-codebase-architecture"
  "mattpocock/skills|loop-me"
  "mattpocock/skills|migrate-to-shoehorn"
  "mattpocock/skills|pr"
  "mattpocock/skills|prototype"
  "mattpocock/skills|research"
  "mattpocock/skills|retro"
  "mattpocock/skills|scaffold-exercises"
  "mattpocock/skills|setup-matt-pocock-skills"
  "mattpocock/skills|setup-pre-commit"
  "mattpocock/skills|setup-ts-deep-modules"
  "mattpocock/skills|tdd"
  "mattpocock/skills|teach"
  "mattpocock/skills|to-questionnaire"
  "mattpocock/skills|to-spec"
  "mattpocock/skills|to-tickets"
  "mattpocock/skills|triage"
  "mattpocock/skills|wait-what"
  "mattpocock/skills|wayfinder"
  "mattpocock/skills|wizard"
  "mattpocock/skills|writing-beats"
  "mattpocock/skills|writing-for-agents"
  "mattpocock/skills|writing-fragments"
  "mattpocock/skills|writing-shape"
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

# True if the Hermes Agent CLI is on the box. The venv entry point is named
# hermes; some installs expose hermes-agent instead.
have_hermes() {
  command -v hermes &>/dev/null || command -v hermes-agent &>/dev/null
}

# Hermes keeps a link (or copy) of each skill in $HERMES_HOME/skills. The
# skills CLI resolves the same way: HERMES_HOME, then ~/.hermes.
hermes_skills_dir() {
  printf '%s/skills\n' "${HERMES_HOME:-$HOME/.hermes}"
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
  # Hermes bundles categories (for example ~/.hermes/skills/research/) that can
  # share a name with a skill, so require the skill's own SKILL.md. -f follows
  # symlinks, so a dangling link still counts as missing.
  if have_hermes && [[ ! -f "$(hermes_skills_dir)/$skill/SKILL.md" ]]; then
    return 1
  fi
}

# The skills CLI installs each global skill once into ~/.agents/skills and
# links it into every agent named with -a (opencode, claude-code,
# hermes-agent). Skills that share a source go to one call, because --skill
# accepts several names and cloning the repo once per skill is slow.
install_ai_skills() {
  local entry source skill failed=0
  local -a cmd agent_args=() sources=() pending=()

  # OpenCode is a universal target, so listing it makes the CLI write the
  # canonical ~/.agents/skills copy. Include it even when OpenCode is not
  # installed: with only Claude Code selected the CLI switches to copy mode and
  # writes solely to ~/.claude/skills, leaving the canonical directory (and
  # ai_skills_pending) unaware of the skill. Adding a universal target keeps
  # the canonical copy plus each agent's link.
  agent_args=(-a opencode)
  have_claude_code && agent_args+=(-a claude-code)
  have_hermes && agent_args+=(-a hermes-agent)

  for entry in "${AI_SKILLS[@]}"; do
    source="${entry%%|*}"
    [[ " ${sources[*]} " == *" $source "* ]] || sources+=("$source")
  done

  for source in "${sources[@]}"; do
    pending=()
    for entry in "${AI_SKILLS[@]}"; do
      [[ ${entry%%|*} == "$source" ]] || continue
      skill="${entry#*|}"
      if [[ $skill != "*" ]] && skill_installed_for_agents "$skill"; then
        echo "✓ $skill already installed"
      else
        pending+=("$skill")
      fi
    done
    [[ ${#pending[@]} -gt 0 ]] || continue

    cmd=(bunx skills@latest add "$source" -g -y --skill "${pending[@]}" "${agent_args[@]}")
    if ! "${cmd[@]}"; then
      echo "Error: failed to install skills from $source (${pending[*]})" >&2
      if have_hermes; then
        echo "  If Hermes did not get its links, check that the skills CLI still supports -a hermes-agent." >&2
      fi
      failed=1
    fi
  done

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
      install_ai_skills || true   # still repair missing agent links
    elif gum confirm "Install agent skills (${#AI_SKILLS[@]} skills) for opencode / claude-code / Hermes?" </dev/tty; then
      install_ai_skills || true
    fi
  fi
}
