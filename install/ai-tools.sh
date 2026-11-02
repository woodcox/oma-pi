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

# How a skill that collides with an entry in the Hermes skills directory is
# handled. The choices are private to this installer, so they live beside the
# Hermes profile rather than in the shared ~/.agents tree.
skill_choices_file() {
  printf '%s/.oma-pi-skill-choices\n' "${HERMES_HOME:-$HOME/.hermes}"
}

# Print "<action>\t<target>" for a stored choice. The target is only meaningful
# for a rename. Returns non-zero when the skill has no choice yet.
skill_choice_get() {
  local skill="$1" stored action target
  local file

  file="$(skill_choices_file)"
  [[ -f $file ]] || return 1
  while IFS=$'\t' read -r stored action target || [[ -n $stored ]]; do
    [[ $stored == "$skill" ]] || continue
    printf '%s\t%s\n' "$action" "$target"
    return 0
  done <"$file"
  return 1
}

# Persist one choice, replacing any previous choice for the same skill.
skill_choice_set() {
  local skill="$1" action="$2" target="${3:-}" file tmp

  file="$(skill_choices_file)"
  mkdir -p "$(dirname "$file")"
  tmp="$(mktemp "${file}.XXXXXX")"
  if [[ -f $file ]]; then
    awk -F '\t' -v skill="$skill" '$1 != skill' "$file" >"$tmp"
  fi
  printf '%s\t%s\t%s\n' "$skill" "$action" "$target" >>"$tmp"
  mv "$tmp" "$file"
}

# Keep a generated name to the characters a skill name can safely contain.
skill_name_slug() {
  printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '-'
}

# The rename format is <skill>-<github-user>-<git-repo>.
skill_rename_target() {
  local skill="$1" source="$2" owner repo

  owner="${source%%/*}"
  repo="${source#*/}"
  printf '%s-%s-%s\n' "$skill" "$(skill_name_slug "$owner")" "$(skill_name_slug "$repo")"
}

# True when the Hermes entry is the symlink the skills CLI creates for this
# skill. A copy is treated as foreign on purpose: it may be a bundled category
# or a user's own skill with the same name.
hermes_skill_is_ours() {
  local skill="$1" target canonical

  target="$(hermes_skills_dir)/$skill"
  [[ -L $target && -e $target ]] || return 1
  canonical="$(readlink -f "$HOME/.agents/skills/$skill" 2>/dev/null)" || return 1
  [[ -n $canonical && "$(readlink -f "$target" 2>/dev/null)" == "$canonical" ]]
}

# True when installing this skill for Hermes would replace something that is
# not ours (for example the bundled ~/.hermes/skills/research/ category).
hermes_skill_conflict() {
  local skill="$1" target

  target="$(hermes_skills_dir)/$skill"
  [[ -e $target || -L $target ]] || return 1
  hermes_skill_is_ours "$skill" && return 1
  return 0
}

# Ask how to install a colliding skill. Rename is both the first entry and the
# fallback, because it is the only choice that keeps the existing Hermes skill.
prompt_skill_conflict() {
  local skill="$1" source="$2" target renamed choice action

  target="$(hermes_skills_dir)/$skill"
  renamed="$(skill_rename_target "$skill" "$source")"

  printf '\n' >&2
  printf 'Hermes already has %s\n' "$target" >&2
  printf 'Installing %s would replace it.\n' "$skill" >&2

  choice="$(gum choose \
    --header "How should oma-pi install $skill for Hermes?" \
    "Rename to $renamed (recommended)" \
    "Skip $skill in Hermes" \
    "Overwrite $target" </dev/tty)" || choice=""

  case "$choice" in
    "Rename to "*) action=rename ;;
    "Skip "*) action=skip ;;
    "Overwrite "*) action=overwrite ;;
    *) action=rename ;;
  esac

  if [[ $action == rename ]]; then
    if ! skill_choice_set "$skill" rename "$renamed"; then
      echo "Error: could not save the rename choice for $skill" >&2
      return 1
    fi
  elif ! skill_choice_set "$skill" "$action" ""; then
    echo "Error: could not save the '$action' choice for $skill" >&2
    return 1
  fi
  printf '%s\n' "$action"
}

# Resolve the Hermes action for a skill, prompting only when a real collision
# has no stored answer. Prints "<action>\t<target>"; "install" means let the
# skills CLI link it as usual.
skill_hermes_action() {
  local skill="$1" source="$2" stored action target

  if stored="$(skill_choice_get "$skill")"; then
    action="${stored%%$'\t'*}"
    target=""
    [[ $stored == *$'\t'* ]] && target="${stored#*$'\t'}"
    printf '%s\t%s\n' "$action" "$target"
    return 0
  fi

  if ! hermes_skill_conflict "$skill"; then
    printf 'install\t\n'
    return 0
  fi

  action="$(prompt_skill_conflict "$skill" "$source")" || return 1
  if [[ $action == rename ]]; then
    target="$(skill_rename_target "$skill" "$source")"
  else
    target=""
  fi
  printf '%s\t%s\n' "$action" "$target"
}

# True only when every agent this installer targets already has the skill.
# Checking the canonical directory alone would skip the CLI call that links a
# skill into a newly installed agent.
skill_installed_for_agents() {
  local skill="$1" stored action target

  [[ -d $HOME/.agents/skills/$skill ]] || return 1
  if have_claude_code && [[ ! -d "$(claude_skills_dir)/$skill" ]]; then
    return 1
  fi
  if ! have_hermes; then
    return 0
  fi

  if stored="$(skill_choice_get "$skill")"; then
    action="${stored%%$'\t'*}"
    target=""
    [[ $stored == *$'\t'* ]] && target="${stored#*$'\t'}"
    case "$action" in
      skip) return 0 ;;
      rename) [[ -n $target && -f "$(hermes_skills_dir)/$target/SKILL.md" ]] ;;
      *) [[ -f "$(hermes_skills_dir)/$skill/SKILL.md" ]] ;;
    esac
    return
  fi

  # Hermes bundles categories (for example ~/.hermes/skills/research/) that can
  # share a name with a skill, so require the skill's own SKILL.md. -f follows
  # symlinks, so a dangling link still counts as missing.
  [[ -f "$(hermes_skills_dir)/$skill/SKILL.md" ]]
}

# Rewrite the frontmatter name: line in place. The copied skill keeps the same
# body; only the name Hermes indexes changes.
rewrite_skill_name() {
  local file="$1" name="$2" tmp first

  [[ -f $file ]] || return 1
  first="$(head -n 1 "$file")"
  if [[ ${first%$'\r'} != "---" ]]; then
    echo "Error: $file has no YAML frontmatter to rename" >&2
    return 1
  fi

  tmp="$(mktemp)"
  if ! awk -v name="$name" '
    NR == 1 { print; fm = 1; next }
    fm && $0 ~ /^---[[:space:]]*$/ {
      if (!done) { print "name: " name; done = 1 }
      fm = 0; print; next
    }
    fm && !done && $0 ~ /^name:[[:space:]]*/ { print "name: " name; done = 1; next }
    { print }
  ' "$file" >"$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  if ! cp "$tmp" "$file"; then
    rm -f "$tmp"
    return 1
  fi
  rm -f "$tmp"
}

# Install a canonical skill into Hermes under a different name. This is used
# for the rename and overwrite choices: a copy avoids a symlink at a path that
# Hermes' bundled-skill sync also writes through.
install_hermes_copy() {
  local skill="$1" target_name="$2" canonical target marker backup_root backup failed=0

  canonical="$HOME/.agents/skills/$skill"
  if [[ ! -d $canonical ]]; then
    echo "Warning: $canonical is missing; cannot install $target_name for Hermes" >&2
    return 1
  fi

  target="$(hermes_skills_dir)/$target_name"
  marker="$target/.oma-pi-skill-source"

  if [[ -e $target || -L $target ]]; then
    if [[ -f $marker && "$(cat "$marker")" == "$skill" ]]; then
      if ! rm -rf -- "$target"; then
        echo "Error: could not replace $target" >&2
        return 1
      fi
    else
      # Never destroy a bundled category or a user skill by accident. The
      # backup lives outside the skills tree so Hermes does not index it.
      backup_root="${HERMES_HOME:-$HOME/.hermes}/.oma-pi-backups"
      if ! mkdir -p "$backup_root"; then
        echo "Error: could not create $backup_root" >&2
        return 1
      fi
      if ! backup="$(mktemp -d "$backup_root/${target_name}.XXXXXX")"; then
        echo "Error: could not back up $target" >&2
        return 1
      fi
      if ! mv "$target" "$backup/entry"; then
        echo "Error: could not move $target to $backup" >&2
        return 1
      fi
      echo "Backed up existing Hermes entry to $backup" >&2
    fi
  fi

  if ! mkdir -p "$target"; then
    echo "Error: could not create $target" >&2
    return 1
  fi
  if ! cp -a "$canonical/." "$target/"; then
    echo "Error: could not copy $canonical to $target" >&2
    return 1
  fi
  if ! printf '%s\n' "$skill" >"$marker"; then
    echo "Error: could not write $marker" >&2
    return 1
  fi
  rewrite_skill_name "$target/SKILL.md" "$target_name" || failed=1
  return "$failed"
}

# Keep renamed/overwritten copies in step with the canonical ~/.agents copy.
# The skills CLI only manages symlinks, so these copies need refreshing here.
sync_hermes_skill_copies() {
  local skill action target file failed=0

  have_hermes || return 0
  file="$(skill_choices_file)"
  [[ -f $file ]] || return 0

  while IFS=$'\t' read -r skill action target || [[ -n $skill ]]; do
    [[ -n $skill ]] || continue
    case "$action" in
      rename)
        if [[ -z $target ]]; then
          echo "Error: rename choice for $skill has no target" >&2
          failed=1
        else
          install_hermes_copy "$skill" "$target" || failed=1
        fi
        ;;
      overwrite)
        install_hermes_copy "$skill" "$skill" || failed=1
        ;;
      skip)
        ;;
      *)
        echo "Warning: unknown choice '$action' for $skill, ignoring" >&2
        ;;
    esac
  done <"$file"

  return "$failed"
}

# The skills CLI installs each global skill once into ~/.agents/skills and
# links it into every agent named with -a (opencode, claude-code,
# hermes-agent). Skills that share a source go to one call, because --skill
# accepts several names and cloning the repo once per skill is slow.
#
# A skill that collides with a Hermes entry is installed separately without
# -a hermes-agent, then copied into Hermes by sync_hermes_skill_copies. Passing
# hermes-agent for it would replace the existing directory (the bug that
# destroyed ~/.hermes/skills/research/).
install_ai_skills() {
  local entry source skill failed=0 stored action
  local -a cmd agent_args=() non_hermes_args=() sources=() normal=() special=()

  # OpenCode is a universal target, so listing it makes the CLI write the
  # canonical ~/.agents/skills copy. Include it even when OpenCode is not
  # installed: with only Claude Code selected the CLI switches to copy mode and
  # writes solely to ~/.claude/skills, leaving the canonical directory (and
  # ai_skills_pending) unaware of the skill. Adding a universal target keeps
  # the canonical copy plus each agent's link.
  agent_args=(-a opencode)
  non_hermes_args=(-a opencode)
  have_claude_code && agent_args+=(-a claude-code)
  have_claude_code && non_hermes_args+=(-a claude-code)
  have_hermes && agent_args+=(-a hermes-agent)

  for entry in "${AI_SKILLS[@]}"; do
    source="${entry%%|*}"
    [[ " ${sources[*]} " == *" $source "* ]] || sources+=("$source")
  done

  for source in "${sources[@]}"; do
    normal=()
    special=()
    for entry in "${AI_SKILLS[@]}"; do
      [[ ${entry%%|*} == "$source" ]] || continue
      skill="${entry#*|}"

      if [[ $skill != "*" ]] && skill_installed_for_agents "$skill"; then
        echo "✓ $skill already installed"
        continue
      fi

      if ! have_hermes || [[ $skill == "*" ]]; then
        normal+=("$skill")
        continue
      fi

      if ! stored="$(skill_hermes_action "$skill" "$source")"; then
        echo "Error: could not resolve the Hermes conflict for $skill; installing it for the other agents only" >&2
        special+=("$skill")
        failed=1
        continue
      fi
      action="${stored%%$'\t'*}"

      case "$action" in
        skip)
          echo "Skipping $skill in Hermes"
          special+=("$skill")
          ;;
        rename|overwrite)
          special+=("$skill")
          ;;
        *)
          normal+=("$skill")
          ;;
      esac
    done

    if [[ ${#normal[@]} -gt 0 ]]; then
      cmd=(bunx skills@latest add "$source" -g -y --skill "${normal[@]}" "${agent_args[@]}")
      if ! "${cmd[@]}"; then
        echo "Error: failed to install skills from $source (${normal[*]})" >&2
        if have_hermes; then
          echo "  If Hermes did not get its links, check that the skills CLI still supports -a hermes-agent." >&2
        fi
        failed=1
      fi
    fi

    if [[ ${#special[@]} -gt 0 ]]; then
      cmd=(bunx skills@latest add "$source" -g -y --skill "${special[@]}" "${non_hermes_args[@]}")
      if ! "${cmd[@]}"; then
        echo "Error: failed to install skills from $source (${special[*]})" >&2
        failed=1
      fi
    fi
  done

  sync_hermes_skill_copies || failed=1

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
