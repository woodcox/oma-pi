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

# ---------------------------------------------------------------------------
# Skill collision handling
#
# The skills CLI writes every global skill into the shared canonical directory
# (~/.agents/skills) and, when passed -a <agent>, links or copies it into that
# agent's own directory. With -y it does not ask before deleting whatever is
# already at the destination; that is how a bundled Hermes category was
# destroyed once. So this installer lets the CLI write only the canonical copy
# and manages the per-agent entries itself, after checking who owns them.
#
# A skill that collides is resolved once:
#   rename     install it as <skill>-<github-user>-<git-repo>, keeping the old
#              entry in place
#   skip       do not touch the colliding entry
#   overwrite  back the old entry up, then install over it
# The choice is remembered per skill in ~/.agents/.oma-pi-skill-choices.
# ---------------------------------------------------------------------------

# The shared copy every universal agent (OpenCode included) reads.
canonical_skills_dir() {
  printf '%s/skills\n' "$HOME/.agents"
}

# The skills CLI writes its lock here, so it is also the record of which
# canonical copies came from which source.
skill_lock_file() {
  if [[ -n ${XDG_STATE_HOME:-} ]]; then
    printf '%s/skills/.skill-lock.json\n' "$XDG_STATE_HOME"
  else
    printf '%s/.skill-lock.json\n' "$HOME/.agents"
  fi
}

# The canonical ownership check reads the skills CLI lock file. Refuse to
# guess when that file is missing or unreadable: treating every canonical
# entry as unowned would make the default rename choice install duplicates
# beside skills the installer already owns. Marker copies carry their own
# ownership record, so a tree of only marker copies needs no lock.
skill_lock_preflight() {
  local lock canonical entry needs_lock=0

  lock="$(skill_lock_file)"
  canonical="$(canonical_skills_dir)"

  if [[ -d $canonical ]]; then
    while IFS= read -r -d '' entry; do
      [[ -f $entry/.oma-pi-skill-source ]] && continue
      needs_lock=1
      break
    done < <(find "$canonical/" -mindepth 1 -maxdepth 1 -print0 2>/dev/null)
  fi
  [[ $needs_lock -eq 0 ]] && return 0

  if [[ ! -f $lock ]]; then
    echo "Error: $lock is missing; cannot tell which canonical skills oma-pi installed. Restore it or remove the affected skill directories, then rerun." >&2
    return 1
  fi
  if ! command -v jq &>/dev/null; then
    echo "Error: jq is required to read $lock" >&2
    return 1
  fi
  if ! jq -e '.skills | type == "object"' "$lock" >/dev/null 2>&1; then
    echo "Error: could not parse $lock" >&2
    return 1
  fi
  return 0
}

# Choices are private to this installer but shared across the agents it
# manages, so they live beside the canonical skills tree.
skill_choices_file() {
  printf '%s/.oma-pi-skill-choices\n' "$HOME/.agents"
}

# Move the Hermes-only choice file written by the previous installer, so a
# refresh does not ask about collisions that were already answered.
migrate_hermes_skill_choices() {
  local shared legacy

  shared="$(skill_choices_file)"
  legacy="${HERMES_HOME:-$HOME/.hermes}/.oma-pi-skill-choices"
  [[ -f $shared || ! -f $legacy ]] && return 0
  mkdir -p "$(dirname "$shared")" || return 1
  if cp "$legacy" "$shared"; then
    echo "Migrated skill choices from $legacy" >&2
  else
    echo "Warning: could not migrate $legacy" >&2
  fi
  return 0
}

# True when a generated rename target is a plain skill directory name.
skill_target_is_safe() {
  [[ $1 =~ ^[A-Za-z0-9._-]+$ && $1 != "." && $1 != ".." ]]
}

# Print "<action>\t<target>" for a stored choice. Returns non-zero when the
# skill has no valid choice yet. A malformed line is ignored so it can never
# send a path outside the skills tree.
skill_choice_get() {
  local skill="$1" stored action target
  local file

  file="$(skill_choices_file)"
  [[ -f $file ]] || return 1
  while IFS=$'\t' read -r stored action target || [[ -n $stored ]]; do
    [[ $stored == "$skill" ]] || continue
    case "$action" in
      rename) skill_target_is_safe "$target" || return 1 ;;
      skip|overwrite) target="" ;;
      *) return 1 ;;
    esac
    printf '%s\t%s\n' "$action" "$target"
    return 0
  done <"$file"
  return 1
}

# Persist one choice, replacing any previous choice for the same skill.
skill_choice_set() {
  local skill="$1" action="$2" target="${3:-}" file tmp

  case "$action" in
    rename)
      if ! skill_target_is_safe "$target"; then
        echo "Error: refusing to save an unsafe rename target: $target" >&2
        return 1
      fi
      ;;
    skip|overwrite) target="" ;;
    *)
      echo "Error: refusing to save an unknown skill action: $action" >&2
      return 1
      ;;
  esac

  file="$(skill_choices_file)"
  mkdir -p "$(dirname "$file")" || return 1
  tmp="$(mktemp "${file}.XXXXXX")" || return 1
  if [[ -f $file ]]; then
    if ! awk -F '\t' -v skill="$skill" '$1 != skill' "$file" >"$tmp"; then
      rm -f "$tmp"
      return 1
    fi
  fi
  if ! printf '%s\t%s\t%s\n' "$skill" "$action" "$target" >>"$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  if ! mv "$tmp" "$file"; then
    rm -f "$tmp"
    return 1
  fi
}

# Keep a generated name to the characters a skill name can safely contain.
skill_name_slug() {
  printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '-'
}

# The rename format is <skill>-<github-user>-<git-repo>.
skill_rename_base() {
  local skill="$1" source="$2" owner repo

  owner="${source%%/*}"
  repo="${source#*/}"
  printf '%s-%s-%s\n' "$skill" "$(skill_name_slug "$owner")" "$(skill_name_slug "$repo")"
}

# Every agent scope this installer manages, in the order it should check them.
# Canonical comes first: whether it collides decides if a rename is global.
skill_scopes() {
  printf 'canonical\n'
  have_claude_code && printf 'claude-code\n'
  have_hermes && printf 'hermes-agent\n'
  return 0
}

skill_scope_dir() {
  case "$1" in
    canonical) canonical_skills_dir ;;
    claude-code) claude_skills_dir ;;
    hermes-agent) hermes_skills_dir ;;
    *) return 1 ;;
  esac
}

skill_scope_label() {
  case "$1" in
    canonical) printf 'OpenCode (shared skills)' ;;
    claude-code) printf 'Claude Code' ;;
    hermes-agent) printf 'Hermes Agent' ;;
    *) printf '%s' "$1" ;;
  esac
}

# Backups live outside every agent's skills tree so no agent indexes them.
skill_backup_root() {
  case "$1" in
    canonical) printf '%s/.oma-pi-backups\n' "$HOME/.agents" ;;
    claude-code) printf '%s/.oma-pi-backups\n' "$(dirname "$(claude_skills_dir)")" ;;
    hermes-agent) printf '%s/.oma-pi-backups\n' "${HERMES_HOME:-$HOME/.hermes}" ;;
    *) return 1 ;;
  esac
}

# True when a directory was copied here by this installer (rename/overwrite).
skill_entry_is_marker_copy() {
  local target="$1" skill="$2"

  [[ -f $target/.oma-pi-skill-source ]] &&
    [[ "$(cat "$target/.oma-pi-skill-source")" == "$skill" ]]
}

# True when the entry at <scope>/<skill> is one this installer may replace.
skill_entry_is_ours() {
  local scope="$1" skill="$2" source="$3" dir target canonical resolved canonical_dir lock recorded

  dir="$(skill_scope_dir "$scope")" || return 1
  target="$dir/$skill"
  [[ -e $target || -L $target ]] || return 1
  skill_entry_is_marker_copy "$target" "$skill" && return 0

  # Canonical copies are recorded in the skills CLI lock file.
  if [[ $scope == canonical ]]; then
    lock="$(skill_lock_file)"
    if [[ ! -f $lock ]]; then
      echo "Error: $lock is missing; cannot classify $target" >&2
      return 1
    fi
    if ! command -v jq &>/dev/null; then
      echo "Error: jq is required to read $lock" >&2
      return 1
    fi
    if ! recorded="$(jq -r --arg s "$skill" '.skills[$s].source // empty' "$lock" 2>/dev/null)"; then
      echo "Error: could not parse $lock" >&2
      return 1
    fi
    [[ $recorded == "$source" ]]
    return
  fi

  # Agent entries are ours when they link into our canonical skills tree.
  [[ -L $target ]] || return 1
  resolved="$(readlink -f "$target" 2>/dev/null)" || return 1
  canonical_dir="$(readlink -f "$(canonical_skills_dir)" 2>/dev/null)" || return 1
  [[ -n $resolved && -n $canonical_dir && $resolved == "$canonical_dir"/* ]] || return 1

  # A link to a renamed copy carries our marker. A link to the original copy
  # is ours only when the lock file says our source installed it.
  skill_entry_is_marker_copy "$resolved" "$skill" && return 0
  [[ "$(basename "$resolved")" == "$skill" ]] || return 1
  skill_entry_is_ours canonical "$skill" "$source"
}

# True when installing <skill> into <scope> would replace an entry this
# installer does not manage (a bundled agent skill, a hand-written copy, or a
# skill from another source).
skill_scope_conflict() {
  local scope="$1" skill="$2" source="$3" dir target

  dir="$(skill_scope_dir "$scope")" || return 1
  target="$dir/$skill"
  [[ -e $target || -L $target ]] || return 1
  ! skill_entry_is_ours "$scope" "$skill" "$source"
}

# Pick a rename target that is not already used by an entry we do not own.
# Existing marker copies are reusable, so a refresh keeps the same name.
skill_rename_target() {
  local skill="$1" source="$2" base candidate suffix=2 scope target free

  base="$(skill_rename_base "$skill" "$source")"
  candidate="$base"
  while :; do
    free=1
    for scope in $(skill_scopes); do
      target="$(skill_scope_dir "$scope")/$candidate"
      if [[ -e $target || -L $target ]] && ! skill_entry_is_marker_copy "$target" "$skill"; then
        free=0
        break
      fi
    done
    [[ $free -eq 1 ]] && {
      printf '%s\n' "$candidate"
      return 0
    }
    candidate="$base-$suffix"
    suffix=$((suffix + 1))
  done
}

# Move a colliding entry out of the way. Returns non-zero when it could not be
# backed up, so the caller can leave the entry untouched.
skill_backup_entry() {
  local scope="$1" target="$2" root backup

  root="$(skill_backup_root "$scope")" || return 1
  mkdir -p "$root" || return 1
  backup="$(mktemp -d "$root/$(basename "$target").XXXXXX")" || return 1
  if ! mv -- "$target" "$backup/entry"; then
    rmdir "$backup" 2>/dev/null || true
    return 1
  fi
  echo "Backed up $(skill_scope_label "$scope") entry $target to $backup" >&2
}

# Ask how to install a colliding skill. Rename is both the first entry and the
# fallback (including when gum is cancelled), because it is the only choice
# that leaves every existing entry in place.
prompt_skill_conflict() {
  local skill="$1" source="$2" scope renamed choice action target conflicts=()

  renamed="$(skill_rename_target "$skill" "$source")"
  for scope in $(skill_scopes); do
    skill_scope_conflict "$scope" "$skill" "$source" || continue
    conflicts+=("$(skill_scope_label "$scope"): $(skill_scope_dir "$scope")/$skill")
  done

  printf '\n' >&2
  printf 'These skill entries already exist and are not managed by oma-pi:\n' >&2
  printf '  %s\n' "${conflicts[@]}" >&2
  printf 'Installing %s would replace them.\n' "$skill" >&2

  choice="$(gum choose \
    --header "How should oma-pi install $skill?" \
    "Rename to $renamed (recommended)" \
    "Skip $skill where it collides" \
    "Overwrite the conflicting entries" </dev/tty)" || choice=""

  case "$choice" in
    "Rename to "*) action=rename ;;
    "Skip "*) action=skip ;;
    "Overwrite "*) action=overwrite ;;
    *) action=rename ;;
  esac

  target=""
  [[ $action == rename ]] && target="$renamed"
  if ! skill_choice_set "$skill" "$action" "$target"; then
    echo "Error: could not save the '$action' choice for $skill" >&2
    return 1
  fi
  printf '%s\n' "$action"
}

# Resolve the action for a skill. Prints "<action>\t<target>"; "install" means
# there is no collision, so the original name is safe. A stored choice is only
# applied while the collision it answered still exists.
skill_action() {
  local skill="$1" source="$2" stored action target="" scope conflicts=0

  for scope in $(skill_scopes); do
    skill_scope_conflict "$scope" "$skill" "$source" && conflicts=1
  done
  if [[ $conflicts -eq 0 ]]; then
    # Keep an overwrite choice even after it took effect, so a later repair
    # (a new agent, a missing link) does not silently turn the Hermes copy back
    # into a symlink. A rename choice is stale once the collision is gone.
    if stored="$(skill_choice_get "$skill")" && [[ ${stored%%$'\t'*} == overwrite ]]; then
      printf 'overwrite\t\n'
      return 0
    fi
    printf 'install\t\n'
    return 0
  fi

  if stored="$(skill_choice_get "$skill")"; then
    action="${stored%%$'\t'*}"
    case "$action" in
      rename)
        # Recompute: the format is meant to be predictable, and a previous
        # suffix may have become free.
        target="$(skill_rename_target "$skill" "$source")"
        ;;
      skip|overwrite) ;;
      *) action="" ;;
    esac
    if [[ -n $action ]]; then
      printf '%s\t%s\n' "$action" "$target"
      return 0
    fi
  fi

  action="$(prompt_skill_conflict "$skill" "$source")" || return 1
  target=""
  [[ $action == rename ]] && target="$(skill_rename_target "$skill" "$source")"
  printf '%s\t%s\n' "$action" "$target"
}
# True when this skill still needs work: a missing copy/link, or a collision
# with no stored answer yet.
skill_needs_work() {
  local skill="$1" source="$2" stored action="" target="" scope conflict
  local canonical_conflict=0 expected

  if stored="$(skill_choice_get "$skill")"; then
    action="${stored%%$'\t'*}"
    target=""
    [[ $stored == *$'\t'* ]] && target="${stored#*$'\t'}"
  fi

  for scope in $(skill_scopes); do
    conflict=0
    skill_scope_conflict "$scope" "$skill" "$source" && conflict=1
    [[ $scope == canonical && $conflict -eq 1 ]] && canonical_conflict=1

    if [[ $conflict -eq 1 ]]; then
      [[ -n $action ]] || return 0
      case "$action" in
        skip) continue ;;
        rename)
          expected="$(skill_rename_target "$skill" "$source")"
          [[ -f "$(skill_scope_dir "$scope")/$expected/SKILL.md" ]] || return 0
          ;;
        overwrite)
          skill_entry_is_ours "$scope" "$skill" "$source" || return 0
          ;;
        *) return 0 ;;
      esac
    else
      if [[ $action == rename && $canonical_conflict -eq 1 ]]; then
        expected="${target:-$(skill_rename_target "$skill" "$source")}"
        [[ -e "$(skill_scope_dir "$scope")/$expected" ]] || return 0
      else
        [[ -e "$(skill_scope_dir "$scope")/$skill" ]] || return 0
      fi
    fi
  done
  return 1
}

# Rewrite the frontmatter name: line in place. The copied skill keeps the same
# body; only the name the agent indexes changes.
rewrite_skill_name() {
  local file="$1" name="$2" tmp first

  [[ -f $file ]] || return 1
  first="$(head -n 1 "$file")"
  if [[ ${first%$'\r'} != "---" ]]; then
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

# Copy <src> into a staging directory beside <parent> and print its path.
# The caller replaces the live entry only after this succeeds, so a failed
# copy cannot delete a working skill or leave a half-written one.
stage_skill_copy() {
  local src="$1" parent="$2" target_name="$3" skill="$4" tmp

  mkdir -p "$parent" || return 1
  tmp="$(mktemp -d "$parent/.oma-pi-${target_name}.XXXXXX")" || return 1
  if ! cp -a "$src/." "$tmp/"; then
    echo "Error: could not copy $src to $tmp" >&2
    rm -rf -- "$tmp"
    return 1
  fi
  chmod --reference="$src" "$tmp" 2>/dev/null || true
  if ! printf '%s\n' "$skill" >"$tmp/.oma-pi-skill-source"; then
    echo "Error: could not write $tmp/.oma-pi-skill-source" >&2
    rm -rf -- "$tmp"
    return 1
  fi
  if ! rewrite_skill_name "$tmp/SKILL.md" "$target_name"; then
    rm -rf -- "$tmp"
    return 1
  fi
  printf '%s\n' "$tmp"
}

# Create (or refresh) a link from an agent directory to the canonical copy.
# Falls back to a copy when the filesystem refuses links.
link_agent_skill() {
  local scope="$1" target_name="$2" canonical_name="$3" skill="$4" source="$5"
  local dir target canonical rel

  dir="$(skill_scope_dir "$scope")" || return 1
  target="$dir/$target_name"
  canonical="$(canonical_skills_dir)/$canonical_name"
  if [[ ! -d $canonical ]]; then
    echo "Error: canonical copy $canonical is missing" >&2
    return 1
  fi
  mkdir -p "$dir" || return 1

  if [[ -e $target || -L $target ]]; then
    if ! skill_entry_is_marker_copy "$target" "$skill" &&
      ! skill_entry_is_ours "$scope" "$canonical_name" "$source"; then
      echo "Error: refusing to replace unowned $target" >&2
      return 1
    fi
    rm -rf -- "$target" || return 1
  fi

  rel="$(realpath --relative-to="$(dirname "$target")" "$canonical" 2>/dev/null)" || rel=""
  if [[ -n $rel ]] && ln -s "$rel" "$target" 2>/dev/null; then
    return 0
  fi
  install_agent_copy "$canonical" "$scope" "$skill" "$target_name" "$source"
}

# Copy a skill directory into an agent's tree and rewrite the frontmatter name.
# Used for renames (the CLI has no --name), for Hermes overwrites (so its
# bundled-skill sync cannot write back through a link), and for installing a
# canonical-skipped skill into an agent that did not collide.
install_agent_copy() {
  local src="$1" scope="$2" skill="$3" target_name="$4" source="$5"
  local dir target tmp

  dir="$(skill_scope_dir "$scope")" || return 1
  target="$dir/$target_name"
  if [[ ! -d $src ]]; then
    echo "Error: source $src is missing; cannot install $target_name for $(skill_scope_label "$scope")" >&2
    return 1
  fi
  if [[ -e $target || -L $target ]] &&
    ! skill_entry_is_marker_copy "$target" "$skill" &&
    ! skill_entry_is_ours "$scope" "$target_name" "$source"; then
    echo "Error: refusing to replace unowned $target" >&2
    return 1
  fi
  if ! tmp="$(stage_skill_copy "$src" "$dir" "$target_name" "$skill")"; then
    return 1
  fi

  if [[ -e $target || -L $target ]]; then
    if ! rm -rf -- "$target"; then
      echo "Error: could not replace $target" >&2
      rm -rf -- "$tmp"
      return 1
    fi
  fi

  if ! mv -- "$tmp" "$target"; then
    echo "Error: could not move $tmp to $target" >&2
    rm -rf -- "$tmp"
    return 1
  fi
}

# The skills CLI installs each global skill once into ~/.agents/skills and can
# link it into each agent named with -a. This installer passes only `-a
# opencode` (the universal target) and manages the other agents itself, so an
# agent's bundled or hand-written entry is never handed to the CLI to delete.
# Skills that share a source go to one call, because --skill accepts several
# names and cloning the repo once per skill is slow.
install_ai_skills() {
  local entry source skill info action target scope expected
  local stage tmp_home src dest conflict canonical_conflict tmp
  local failed=0
  local -a sources=() normal=() staged=() cmd=()
  local -A SKILL_ACTION=() SKILL_TARGET=() SKILL_SOURCE=()

  migrate_hermes_skill_choices || failed=1
  if ! skill_lock_preflight; then
    return 1
  fi

  stage="$HOME/.agents/.oma-pi-staging"
  rm -rf -- "$stage" 2>/dev/null || true
  mkdir -p "$stage" || {
    echo "Error: could not create $stage" >&2
    return 1
  }

  for entry in "${AI_SKILLS[@]}"; do
    source="${entry%%|*}"
    [[ " ${sources[*]} " == *" $source "* ]] || sources+=("$source")
  done

  for source in "${sources[@]}"; do
    normal=()
    staged=()

    for entry in "${AI_SKILLS[@]}"; do
      [[ ${entry%%|*} == "$source" ]] || continue
      skill="${entry#*|}"

      if ! skill_needs_work "$skill" "$source"; then
        echo "✓ $skill already installed"
        continue
      fi

      # A "*" entry cannot be checked for collisions on disk.
      if [[ $skill == "*" ]]; then
        normal+=("$skill")
        continue
      fi

      if ! info="$(skill_action "$skill" "$source")"; then
        echo "Error: could not resolve the conflict for $skill; leaving it alone" >&2
        failed=1
        continue
      fi
      action="${info%%$'\t'*}"
      target=""
      [[ $info == *$'\t'* ]] && target="${info#*$'\t'}"

      SKILL_ACTION["$skill"]="$action"
      SKILL_TARGET["$skill"]="$target"
      SKILL_SOURCE["$skill"]="$source"

      case "$action" in
        rename)
          if skill_scope_conflict canonical "$skill" "$source"; then
            # The shared copy belongs to something else. Download ours into an
            # isolated HOME and copy it in under the new name, so the existing
            # canonical skill is never touched. Once that copy exists it is the
            # source for the agent entries, so a repair does not download it
            # again.
            if [[ ! -f "$(canonical_skills_dir)/$target/SKILL.md" ]]; then
              staged+=("$skill")
            fi
          else
            normal+=("$skill")
          fi
          ;;
        skip)
          if skill_scope_conflict canonical "$skill" "$source"; then
            # Still needed for agent scopes that did not collide.
            staged+=("$skill")
          else
            normal+=("$skill")
          fi
          ;;
        overwrite)
          if skill_scope_conflict canonical "$skill" "$source"; then
            # Download into the isolated HOME below, then back the live copy
            # up only after the replacement is ready.
            staged+=("$skill")
          else
            normal+=("$skill")
          fi
          ;;
        install)
          normal+=("$skill")
          ;;
        *)
          echo "Warning: unknown action '$action' for $skill, skipping" >&2
          failed=1
          ;;
      esac
    done

    if [[ ${#normal[@]} -gt 0 ]]; then
      cmd=(bunx skills@latest add "$source" -g -y --skill "${normal[@]}" -a opencode)
      if ! "${cmd[@]}"; then
        echo "Error: failed to install skills from $source (${normal[*]})" >&2
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
      # skill tree, config and lock file isolated from the machine's own
      # agents. XDG_STATE_HOME in particular decides where the CLI writes its
      # lock; leaving it set would add the staged skills to the real lock and
      # make a later run treat an unowned canonical entry as ours.
      if env -u XDG_STATE_HOME -u XDG_CONFIG_HOME -u XDG_DATA_HOME \
        HOME="$tmp_home" BUN_INSTALL="${BUN_INSTALL:-$HOME/.bun}" \
        bunx skills@latest add "$source" -g -y --skill "${staged[@]}" -a opencode; then
        for skill in "${staged[@]}"; do
          src="$tmp_home/.agents/skills/$skill"
          if [[ ! -d $src ]]; then
            echo "Error: the skills CLI did not produce $src" >&2
            failed=1
            continue
          fi
          action="${SKILL_ACTION[$skill]}"
          case "$action" in
            rename|overwrite)
              if [[ $action == rename ]]; then
                target="${SKILL_TARGET[$skill]}"
              else
                target="$skill"
              fi
              dest="$(canonical_skills_dir)/$target"

              # Build the replacement first. Only touch the live entry after
              # the copy, marker and frontmatter rewrite all succeed.
              if ! tmp="$(stage_skill_copy "$src" "$(canonical_skills_dir)" "$target" "$skill")"; then
                failed=1
                continue
              fi

              if [[ -e $dest || -L $dest ]]; then
                if [[ $action == rename ]] && skill_entry_is_marker_copy "$dest" "$skill"; then
                  if ! rm -rf -- "$dest"; then
                    rm -rf -- "$tmp"
                    failed=1
                    continue
                  fi
                elif ! skill_backup_entry canonical "$dest"; then
                  echo "Error: could not back up $dest" >&2
                  rm -rf -- "$tmp"
                  failed=1
                  continue
                fi
              fi

              if ! mv -- "$tmp" "$dest"; then
                echo "Error: could not move $tmp to $dest" >&2
                rm -rf -- "$tmp"
                failed=1
                continue
              fi
              ;;
            skip)
              # Skipped canonical copy: keep the content for agent scopes that
              # did not collide, then throw the isolated tree away.
              if ! tmp="$(stage_skill_copy "$src" "$stage" "$skill" "$skill")"; then
                failed=1
                continue
              fi
              if [[ -e "$stage/$skill" || -L "$stage/$skill" ]]; then
                if ! rm -rf -- "$stage/$skill"; then
                  rm -rf -- "$tmp"
                  failed=1
                  continue
                fi
              fi
              if ! mv -- "$tmp" "$stage/$skill"; then
                echo "Error: could not stage $skill" >&2
                rm -rf -- "$tmp"
                failed=1
              fi
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

  # Manage Claude Code and Hermes entries ourselves. The CLI never saw their
  # directories, so nothing here is deleted unless we checked it first.
  for entry in "${AI_SKILLS[@]}"; do
    skill="${entry#*|}"
    [[ -n ${SKILL_ACTION[$skill]+x} ]] || continue
    source="${SKILL_SOURCE[$skill]}"
    action="${SKILL_ACTION[$skill]}"
    target="${SKILL_TARGET[$skill]}"

    canonical_conflict=0
    skill_scope_conflict canonical "$skill" "$source" && canonical_conflict=1

    # If a canonical rename/overwrite was needed but the staged download did
    # not produce it, do not touch agent entries: the replacement source is
    # missing, and backing them up would only lose the working copy.
    if [[ $canonical_conflict -eq 1 ]]; then
      case "$action" in
        rename)
          if ! skill_entry_is_marker_copy "$(canonical_skills_dir)/$target" "$skill"; then
            echo "Error: canonical rename for $skill did not complete; leaving agent entries alone" >&2
            failed=1
            continue
          fi
          ;;
        overwrite)
          if ! skill_entry_is_ours canonical "$skill" "$source"; then
            echo "Error: canonical overwrite for $skill did not complete; leaving agent entries alone" >&2
            failed=1
            continue
          fi
          ;;
      esac
    fi

    for scope in $(skill_scopes); do
      [[ $scope == canonical ]] && continue

      conflict=0
      skill_scope_conflict "$scope" "$skill" "$source" && conflict=1

      if [[ $conflict -eq 1 ]]; then
        case "$action" in
          skip) continue ;;
          overwrite)
            # Back up the agent entry only after the replacement source
            # exists. Otherwise a failed download would delete a working
            # bundled or hand-written skill for nothing.
            if [[ ! -f "$(canonical_skills_dir)/$skill/SKILL.md" ]]; then
              echo "Error: $(canonical_skills_dir)/$skill is missing; leaving $(skill_scope_dir "$scope")/$skill alone" >&2
              failed=1
              continue
            fi
            if ! skill_backup_entry "$scope" "$(skill_scope_dir "$scope")/$skill"; then
              echo "Error: could not back up $(skill_scope_dir "$scope")/$skill; leaving it alone" >&2
              failed=1
              continue
            fi
            ;;
        esac
      fi

      # A collision is renamed. A scope that did not collide keeps the
      # original name unless the canonical collision forced a global rename.
      expected="$skill"
      if [[ $action == rename && ( $conflict -eq 1 || $canonical_conflict -eq 1 ) ]]; then
        expected="$target"
      fi

      if [[ $action == rename && $conflict -eq 1 && $canonical_conflict -eq 0 ]]; then
        # Agent-only collision: keep the canonical name, install the renamed
        # copy from it.
        install_agent_copy "$(canonical_skills_dir)/$skill" "$scope" "$skill" "$expected" "$source" || failed=1
      elif [[ $action == skip && $canonical_conflict -eq 1 && $conflict -eq 0 ]]; then
        # Canonical was skipped, so there is no shared copy to link to.
        install_agent_copy "$stage/$skill" "$scope" "$skill" "$expected" "$source" || failed=1
      elif [[ $scope == hermes-agent && ( $action == overwrite || $action == rename ) ]]; then
        # Hermes syncs bundled skills through its skills directory; a copy
        # keeps that sync from writing back into the canonical tree.
        install_agent_copy "$(canonical_skills_dir)/$expected" "$scope" "$skill" "$expected" "$source" || failed=1
      else
        link_agent_skill "$scope" "$expected" "$expected" "$skill" "$source" || failed=1
      fi
    done
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
