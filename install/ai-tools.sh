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

# True if the Hermes Agent CLI is on the box. The venv entry point is named
# hermes; some installs expose hermes-agent instead.
have_hermes() {
  command -v hermes &>/dev/null || command -v hermes-agent &>/dev/null
}

# ---------------------------------------------------------------------------
# Skill collision handling
#
# The skills CLI writes every global skill into the shared canonical directory
# (~/.agents/skills) and, with -y, deletes whatever is already at the
# destination. That is how a bundled Hermes category was destroyed once. So
# this installer lets the CLI write only the canonical copy and manages every
# per-agent entry itself.
#
# Ownership is one rule: an entry is ours when a marker file
# (.oma-pi-skill-source) names the source that installed it, or when it is a
# link resolving to a marked canonical copy. Anything else is foreign and is
# never deleted without being backed up first.
#
# When installing a skill would replace foreign entries, gum asks once per
# skill:
#   rename     install as <skill>-<github-user>-<repo>; foreign entries stay
#   skip       do not touch the colliding entries
#   overwrite  back the foreign entries up, then install over them
# The choice is remembered in ~/.agents/.oma-pi-skill-choices until that file
# is deleted.
# ---------------------------------------------------------------------------

# The scopes the installer manages, one line each: "<label>\t<skills-dir>".
# Canonical (the shared OpenCode copy) comes first; agents follow only when
# their CLI is on the box.
skill_scopes() {
  printf 'OpenCode (shared)\t%s\n' "$(canonical_skills_dir)"
  have_claude_code && printf 'Claude Code\t%s\n' "$(claude_skills_dir)"
  have_hermes && printf 'Hermes Agent\t%s\n' "$(hermes_skills_dir)"
  return 0
}

canonical_skills_dir() {
  printf '%s/skills\n' "$HOME/.agents"
}

claude_skills_dir() {
  printf '%s/skills\n' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
}

hermes_skills_dir() {
  printf '%s/skills\n' "${HERMES_HOME:-$HOME/.hermes}"
}

# Backups live beside each agent's config, outside its skills tree, so no
# agent indexes them.
skill_backup_root() {
  printf '%s/.oma-pi-backups\n' "$(dirname "$1")"
}

# The skills CLI writes a lock here recording which copy came from which
# source; it is used once, below, to claim copies the CLI installed before
# this installer started marking them.
skill_lock_file() {
  if [[ -n ${XDG_STATE_HOME:-} ]]; then
    printf '%s/skills/.skill-lock.json\n' "$XDG_STATE_HOME"
  else
    printf '%s/.skill-lock.json\n' "$HOME/.agents"
  fi
}

# True when the entry at $1 belongs to this installer: it carries a marker
# naming $3 as the installing source, or it is a link into the canonical tree
# whose target does.
skill_entry_is_ours() {
  local target="$1" source="$3" canonical resolved

  [[ -e $target || -L $target ]] || return 1
  if [[ -f $target/.oma-pi-skill-source ]] &&
    [[ "$(cat "$target/.oma-pi-skill-source")" == "$source" ]]; then
    return 0
  fi
  [[ -L $target ]] || return 1
  resolved="$(readlink -f "$target" 2>/dev/null)" || return 1
  canonical="$(readlink -f "$(canonical_skills_dir)" 2>/dev/null)" || return 1
  [[ -n $resolved && -n $canonical && $resolved == "$canonical"/* ]] || return 1
  [[ -f $resolved/.oma-pi-skill-source ]] &&
    [[ "$(cat "$resolved/.oma-pi-skill-source")" == "$source" ]]
}

# True when installing <skill> from <source> into the skills dir at $1 would
# replace a foreign entry.
skill_collides() {
  { [[ -e $1/$2 || -L $1/$2 ]]; } && ! skill_entry_is_ours "$1/$2" "$2" "$3"
}

# Claim canonical copies the CLI installed before the installer marked them.
# Once, best-effort: if the lock is missing or jq is unavailable the worst
# case is one collision prompt per affected skill, not a failed install.
backfill_skill_markers() {
  local entry skill source dir recorded
  local lock canonical

  lock="$(skill_lock_file)"
  canonical="$(canonical_skills_dir)"
  [[ -f $lock ]] || return 0
  if ! command -v jq &>/dev/null; then
    echo "Warning: jq not found; pre-existing skills cannot be claimed, so some may prompt as conflicts" >&2
    return 0
  fi

  for entry in "${AI_SKILLS[@]}"; do
    source="${entry%%|*}"
    skill="${entry#*|}"
    dir="$canonical/$skill"
    [[ -d $dir && ! -f $dir/.oma-pi-skill-source ]] || continue
    recorded="$(jq -r --arg s "$skill" '.skills[$s].source // empty' "$lock" 2>/dev/null)" || continue
    [[ $recorded == "$source" ]] || continue
    if printf '%s\n' "$source" >"$dir/.oma-pi-skill-source" 2>/dev/null; then
      echo "✓ claimed $skill (installed by a previous run)"
    fi
  done
}

# Choices are private to this installer but shared across the agents it
# manages, so they live beside the canonical skills tree. Each line is
# "<skill>\t<action>"; the rename target is regenerated, not stored, so a
# malformed line can never redirect a path.
skill_choices_file() {
  printf '%s/.oma-pi-skill-choices\n' "$HOME/.agents"
}

# Move the Hermes-only choice file written by the previous installer, so a
# refresh does not ask about collisions that were already answered. Moving
# (rather than copying) also means deleting the shared file really does make
# the installer ask again.
migrate_hermes_skill_choices() {
  local shared legacy

  shared="$(skill_choices_file)"
  legacy="${HERMES_HOME:-$HOME/.hermes}/.oma-pi-skill-choices"
  [[ -f $legacy && ! -f $shared ]] || return 0
  mkdir -p "$(dirname "$shared")" || return 1
  if mv "$legacy" "$shared"; then
    echo "Migrated skill choices from $legacy" >&2
  else
    echo "Warning: could not migrate $legacy" >&2
  fi
}

# Print the stored action for a skill, or fail when there is none.
skill_choice_get() {
  local skill="$1" line
  local file

  file="$(skill_choices_file)"
  [[ -f $file ]] || return 1
  while read -r line || [[ -n $line ]]; do
    case "$line" in
      "$skill"$'\t'rename | "$skill"$'\t'skip | "$skill"$'\t'overwrite)
        printf '%s\n' "${line#*$'\t'}"
        return 0
        ;;
    esac
  done <"$file"
  return 1
}

# Remember the action chosen for a skill, replacing any previous entry.
skill_choice_set() {
  local skill="$1" action="$2" file tmp

  case "$action" in
    rename | skip | overwrite) ;;
    *)
      echo "Error: refusing to save an unknown skill action: $action" >&2
      return 1
      ;;
  esac

  file="$(skill_choices_file)"
  mkdir -p "$(dirname "$file")" || return 1
  tmp="$(mktemp "${file}.XXXXXX")" || return 1
  {
    awk -F '\t' -v s="$skill" '$1 != s' "$file" 2>/dev/null
    printf '%s\t%s\n' "$skill" "$action"
  } >"$tmp" && mv "$tmp" "$file" || {
    rm -f "$tmp"
    return 1
  }
}

# Keep a generated name to the characters a skill name can safely contain.
skill_name_slug() {
  printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '-'
}

# The rename format is <skill>-<github-user>-<git-repo>. Regenerated on every
# use; an existing entry of ours with the same name is reusable, so a refresh
# keeps the same name.
skill_rename_target() {
  local skill="$1" source="$2" base candidate suffix=2 dir target free

  base="$(printf '%s-%s-%s\n' "$skill" "$(skill_name_slug "${source%%/*}")" "$(skill_name_slug "${source#*/}")")"
  candidate="$base"
  while :; do
    free=1
    while IFS=$'\t' read -r _ dir; do
      target="$dir/$candidate"
      if { [[ -e $target || -L $target ]]; } && ! skill_entry_is_ours "$target" "$skill" "$source"; then
        free=0
        break
      fi
    done < <(skill_scopes)
    if [[ $free -eq 1 ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
    candidate="$base-$((suffix++))"
  done
}

# Ask how to install a colliding skill. Rename is both the first entry and the
# fallback (including when gum is cancelled), because it is the only choice
# that leaves every foreign entry in place.
prompt_skill_conflict() {
  local skill="$1" source="$2" label dir target conflicts=() choice action

  target="$(skill_rename_target "$skill" "$source")"
  while IFS=$'\t' read -r label dir; do
    skill_collides "$dir" "$skill" "$source" &&
      conflicts+=("$label: $dir/$skill")
  done < <(skill_scopes)

  printf '\n' >&2
  printf 'These skill entries already exist and are not managed by oma-pi:\n' >&2
  printf '  %s\n' "${conflicts[@]}" >&2
  printf 'Installing %s would replace them.\n' "$skill" >&2

  choice="$(gum choose \
    --header "How should oma-pi install $skill?" \
    "Rename to $target (recommended)" \
    "Skip $skill where it collides" \
    "Overwrite the conflicting entries" </dev/tty)" || choice=""

  case "$choice" in
    "Rename "*) action=rename ;;
    "Skip "*) action=skip ;;
    "Overwrite "*) action=overwrite ;;
    *) action=rename ;;
  esac

  if ! skill_choice_set "$skill" "$action"; then
    echo "Error: could not save the '$action' choice for $skill" >&2
    return 1
  fi
  printf '%s\n' "$action"
}

# Resolve the action for a skill: a stored choice still applies while its
# collision exists; otherwise install is safe.
skill_action() {
  local skill="$1" source="$2" label dir stored action

  while IFS=$'\t' read -r label dir; do
    skill_collides "$dir" "$skill" "$source" || continue
    if stored="$(skill_choice_get "$skill")" && [[ -n $stored ]]; then
      printf '%s\n' "$stored"
      return 0
    fi
    action="$(prompt_skill_conflict "$skill" "$source")" || return 1
    printf '%s\n' "$action"
    return 0
  done < <(skill_scopes)
  printf 'install\n'
}

# Rewrite the frontmatter name: line in place. The copied skill keeps the same
# body; only the name the agent indexes changes.
rewrite_skill_name() {
  local file="$1" name="$2" tmp

  [[ -f $file ]] || return 1
  if [[ $(head -n 1 "$file") != "---" ]]; then
    echo "Error: $file has no YAML frontmatter to rename" >&2
    return 1
  fi

  tmp="$(mktemp)" || {
    echo "Error: could not create a temporary file to rewrite $file" >&2
    return 1
  }
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

# Move $1 out of the way under $2's backup root and print where it went.
# Returns non-zero when it could not be backed up, so the caller can leave the
# entry untouched.
skill_backup_entry() {
  local dest="$1" root backup
  local target="$2"

  root="$(skill_backup_root "$(dirname "$dest")")"
  mkdir -p "$root" || return 1
  backup="$(mktemp -d "$root/$(basename "$dest").XXXXXX")" || return 1
  if ! mv -- "$dest" "$backup/entry"; then
    echo "Error: could not back up $dest; leaving it alone" >&2
    rmdir "$backup" 2>/dev/null || true
    return 1
  fi
  echo "$backup"
}

# Copy $3's content into place as $1/$6, replacing whatever is there. A
# foreign entry is backed up first, so a skill from another source, a bundled
# agent skill or a hand-written copy is never lost. Everything lands through a
# staging directory, so a failed copy leaves the live entry untouched.
install_skill_entry() {
  local dir="$1" label="$2" src="$3" skill="$4" source="$5" target="$6"
  local dest="$dir/$target" tmp backup

  if [[ ! -d $src ]]; then
    echo "Error: source $src is missing; cannot install $target for $label" >&2
    return 1
  fi
  mkdir -p "$dir" || return 1

  if [[ -e $dest || -L $dest ]]; then
    if ! skill_entry_is_ours "$dest" "$skill" "$source"; then
      if ! backup="$(skill_backup_entry "$dest" "$label")"; then
        return 1
      fi
      echo "Backed up $label entry $dest to $backup" >&2
    else
      rm -rf -- "$dest" || return 1
    fi
  fi

  tmp="$(mktemp -d "$dir/.oma-pi-${target}.XXXXXX")" || return 1
  if ! cp -a "$src/." "$tmp/" ||
    ! printf '%s\n' "$source" >"$tmp/.oma-pi-skill-source" ||
    ! rewrite_skill_name "$tmp/SKILL.md" "$target"; then
    echo "Error: could not stage $target for $label" >&2
    rm -rf -- "$tmp"
    return 1
  fi
  chmod --reference="$src" "$tmp" 2>/dev/null || true

  if ! mv -- "$tmp" "$dest"; then
    echo "Error: could not move $tmp to $dest" >&2
    rm -rf -- "$tmp"
    return 1
  fi
}

# Point an agent's entry at a canonical copy with a relative symlink, falling
# back to a copy when linking is refused. A foreign entry is backed up first,
# exactly like in install_skill_entry.
link_agent_skill() {
  local dir="$1" src="$2" skill="$3" source="$4" target="$5"
  local dest="$dir/$target" rel backup

  if [[ -e $dest || -L $dest ]]; then
    if skill_entry_is_ours "$dest" "$skill" "$source"; then
      rm -rf -- "$dest" || return 1
    elif ! backup="$(skill_backup_entry "$dest" "agent")"; then
      return 1
    fi
  fi
  rel="$(realpath --relative-to="$dir" "$src" 2>/dev/null)" || rel=""
  if [[ -n $rel ]] && mkdir -p "$dir" && ln -s "$rel" "$dest" 2>/dev/null; then
    return 0
  fi
  install_skill_entry "$dir" "agent" "$src" "$skill" "$source" "$target"
}

# True when the skill needs its content fetched through the CLI into an
# isolated HOME (see install_ai_skills for why). $4 is 1 when a previous
# rename choice is already in place under the same generated name.
skill_needs_stage() {
  local skill="$1" source="$2" action="$3" dir label canonical cname

  canonical="$(canonical_skills_dir)"
  case "$action" in
    rename)
      skill_entry_is_ours "$canonical/$(skill_rename_target "$skill" "$source")" "$skill" "$source" && return 1
      return 0
      ;;
    skip)
      skill_entry_is_ours "$canonical/$skill" "$skill" "$source" && return 1
      if ! skill_collides "$canonical" "$skill" "$source"; then
        return 1   # no canonical copy yet: the normal CLI batch covers it
      fi
      # The canonical entry is foreign: only agent scopes without a collision
      # need the staged content.
      while IFS=$'\t' read -r label dir; do
        skill_collides "$dir" "$skill" "$source" && continue
        skill_entry_is_ours "$dir/$skill" "$skill" "$source" || return 0
      done < <(skill_scopes)
      return 1
      ;;
    overwrite)
      skill_entry_is_ours "$canonical/$skill" "$skill" "$source" && return 1
      ! skill_collides "$canonical" "$skill" "$source" && return 1
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

# True when the skill wants the plain CLI batch (canonical neither ours nor
# foreign). Only install, skip and overwrite can reach here.
skill_needs_batch() {
  local skill="$1" source="$2" action="$3" canonical

  case "$action" in
    rename | overwrite | skip | install) ;;
    *) return 1 ;;
  esac
  canonical="$(canonical_skills_dir)"
  [[ $action == rename ]] && return 1
  { skill_entry_is_ours "$canonical/$skill" "$skill" "$source" || skill_collides "$canonical" "$skill" "$source"; } && return 1
  return 0
}

# The skills CLI installs each global skill into ~/.agents/skills and can link
# it into each agent named with -a. This installer passes only `-a opencode`
# (the universal target) and manages the other agents itself, so an agent's
# bundled or hand-written entry is never handed to the CLI to delete.
#
# One pass resolves every action (prompting where a collision is unanswered),
# two CLI calls per source install the content (the plain batch for free
# ground, an isolated HOME for anything that would touch a foreign entry), and
# a final reconciliation pass creates the per-agent entries.
install_ai_skills() {
  local entry source skill action src cname dir label
  local stage tmp_home canonical failed=0
  local -a sources=() fresh=() staged=()
  local -A SKILL_ACTION=()

  migrate_hermes_skill_choices || failed=1
  backfill_skill_markers

  canonical="$(canonical_skills_dir)"
  stage="$HOME/.agents/.oma-pi-staging"
  rm -rf -- "$stage" 2>/dev/null || true
  mkdir -p "$stage" || {
    echo "Error: could not create $stage" >&2
    return 1
  }

  local -A SKILL_SOURCE=()
  for entry in "${AI_SKILLS[@]}"; do
    source="${entry%%|*}"
    skill="${entry#*|}"
    SKILL_SOURCE["$skill"]="$source"
    [[ " ${sources[*]} " == *" $source "* ]] || sources+=("$source")
  done

  # Pass 1: resolve every action up front, so the user is never asked mid-way
  # through installing.
  for entry in "${AI_SKILLS[@]}"; do
    source="${entry%%|*}"
    skill="${entry#*|}"
    [[ $skill == "*" ]] && continue
    if ! action="$(skill_action "$skill" "$source")"; then
      echo "Error: could not resolve the conflict for $skill; leaving it alone" >&2
      failed=1
      continue
    fi
    SKILL_ACTION["$skill"]="$action"
  done

  # Pass 2: install the shared canonical copies. One `skills add` per source
  # for skills with free ground, and one isolated HOME per source for skills
  # whose canonical entry would collide with a foreign one.
  for source in "${sources[@]}"; do
    fresh=()
    staged=()

    for entry in "${AI_SKILLS[@]}"; do
      [[ ${entry%%|*} == "$source" ]] || continue
      skill="${entry#*|}"
      action="${SKILL_ACTION[$skill]:-}"

      if [[ $skill == "*" ]]; then
        fresh+=("$skill")
        continue
      fi
      [[ -n $action ]] || continue

      if skill_needs_stage "$skill" "$source" "$action"; then
        staged+=("$skill")
      elif skill_needs_batch "$skill" "$source" "$action"; then
        fresh+=("$skill")
      else
        echo "✓ $skill already installed"
      fi
    done

    if [[ ${#fresh[@]} -gt 0 ]]; then
      if bunx skills@latest add "$source" -g -y --skill "${fresh[@]}" -a opencode; then
        for skill in "${fresh[@]}"; do
          dir="$canonical/$skill"
          if [[ -d $dir ]] && [[ ! -f $dir/.oma-pi-skill-source ]]; then
            printf '%s\n' "$source" >"$dir/.oma-pi-skill-source" 2>/dev/null ||
              echo "Warning: could not mark $dir as ours; it may prompt as a conflict later" >&2
          fi
        done
      else
        echo "Error: failed to install skills from $source (${fresh[*]})" >&2
        failed=1
      fi
    fi

    if [[ ${#staged[@]} -gt 0 ]]; then
      if ! tmp_home="$(mktemp -d)"; then
        echo "Error: could not create an isolated HOME for $source" >&2
        failed=1
        continue
      fi
      # Reuse the real bun cache so the extra download is cheap, but keep the
      # skill tree isolated from the machine's own agents. Unsetting
      # XDG_STATE_HOME keeps the staged skills out of the real CLI lock.
      if env -u XDG_STATE_HOME -u XDG_CONFIG_HOME -u XDG_DATA_HOME \
        HOME="$tmp_home" BUN_INSTALL="${BUN_INSTALL:-$HOME/.bun}" \
        bunx skills@latest add "$source" -g -y --skill "${staged[@]}" -a opencode; then
        for skill in "${staged[@]}"; do
          src="$tmp_home/.agents/skills/$skill"
          action="${SKILL_ACTION[$skill]}"
          source="${SKILL_SOURCE[$skill]}"
          case "$action" in
            rename)
              install_skill_entry "$canonical" "OpenCode (shared)" "$src" "$skill" "$source" \
                "$(skill_rename_target "$skill" "$source")" || failed=1
              ;;
            overwrite)
              install_skill_entry "$canonical" "OpenCode (shared)" "$src" "$skill" "$source" \
                "$skill" || failed=1
              ;;
            skip)
              # The foreign canonical entry stays; keep the content for agent
              # scopes that did not collide.
              install_skill_entry "$stage" "staging" "$src" "$skill" "$source" \
                "$skill" || failed=1
              ;;
            *)
              echo "Error: unexpected action '$action' for $skill in the isolated install" >&2
              failed=1
              ;;
          esac
        done
      else
        echo "Error: failed to install skills from $source (${staged[*]}) in an isolated HOME" >&2
        failed=1
      fi
      rm -rf -- "$tmp_home" 2>/dev/null || true
    fi
  done

  # Pass 3: create (or repair) every per-agent entry. The CLI only wrote the
  # canonical copy, so nothing here is deleted unless install_skill_entry
  # checked and backed it up first.
  for entry in "${AI_SKILLS[@]}"; do
    skill="${entry#*|}"
    action="${SKILL_ACTION[$skill]:-}"
    [[ -n $action && $skill != "*" ]] || continue
    source="${SKILL_SOURCE[$skill]}"
    cname="$skill"
    [[ $action == rename ]] && cname="$(skill_rename_target "$skill" "$source")"

    # Content for the agent entries: the canonical copy (under the final
    # name), a staged copy for a canonical skip, or the plain canonical copy
    # for a rename the shared tree never needed.
    src="$canonical/$cname"
    if ! skill_entry_is_ours "$src" "$skill" "$source"; then
      src="$canonical/$skill"
      if ! skill_entry_is_ours "$src" "$skill" "$source"; then
        src="$stage/$skill"
      fi
    fi
    if [[ ! -d $src ]] || ! skill_entry_is_ours "$src" "$skill" "$source"; then
      echo "Error: no usable copy of $skill; leaving agent entries alone" >&2
      failed=1
      continue
    fi

    while IFS=$'\t' read -r label dir; do
      [[ $dir != "$canonical" ]] || continue

      if skill_entry_is_ours "$dir/$cname" "$skill" "$source"; then
        continue   # already in place
      fi
      if [[ $action == skip ]] && skill_collides "$dir" "$skill" "$source"; then
        continue   # skip means leave the colliding entries alone
      fi

      if [[ $label == "Hermes Agent" ]]; then
        # Hermes syncs bundled skills through its skills directory; a copy
        # keeps that sync from writing back into the canonical tree.
        install_skill_entry "$dir" "$label" "$src" "$skill" "$source" "$cname" || failed=1
      else
        link_agent_skill "$dir" "$src" "$skill" "$source" "$cname" || failed=1
      fi
    done < <(skill_scopes)
  done

  rm -rf -- "$stage" 2>/dev/null || true
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
