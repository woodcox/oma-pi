#!/usr/bin/env bash
#
# Integration tests for install/ai-tools.sh skill collision handling.
#
# These run the installer's collision flow against fake bunx/gum/claude/hermes
# binaries and throwaway HOMEs. The interesting cases are the same ones a
# single bad run once cost a bundled Hermes skill category: a foreign skill
# entry must never be deleted or overwritten silently.
#
# Run: ./test/ai-tools-test.sh   (needs `script` to provide a pseudo-tty, so
# gum's `choose </dev/tty` redirection works inside the fake binaries)

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_FILE="$TEST_DIR/install/ai-tools.sh"
PASS=0
FAIL=0
SKIPPED=0

command -v script &>/dev/null || {
  echo "skip: needs \`script\` (bsdutils) to provide a pseudo-tty" >&2
  exit 77
}

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
BIN="$SANDBOX/bin"
LOGS="$SANDBOX/logs"
HOMES="$SANDBOX/homes"
mkdir -p "$BIN" "$LOGS" "$HOMES"
# Logged outside any fake HOME so the isolated-HOME run can append to it too.
FAKE_BUNX_LOG="$LOGS/bunx-args.log"
export FAKE_BUNX_LOG

# ---------------------------------------------------------------- fake agents

# Fake bunx: understands "skills@latest add <source> -g -y --skill <names...>
# -a <targets>", writes each skill into $HOME/.agents/skills and a matching
# lock file, like the real CLI.
cat >"$BIN/bunx" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${FAKE_BUNX_LOG:?}"
[[ ${1:-} == skills@latest ]] || { echo "fake-bunx: unexpected command: $*" >&2; exit 1; }
shift
[[ ${1:-} == add ]] || { echo "fake-bunx: expected add" >&2; exit 1; }
shift

source=""
mode=""
skills=()
for arg in "$@"; do
  case "$arg" in
    --skill) mode="skill"; continue ;;
    -a) mode="agent"; continue ;;
    -g | -y) continue ;;
  esac
  case "$mode" in
    skill) skills+=("$arg") ;;
    agent) mode="" ;;
    *) source="$arg" ;;
  esac
done
[[ ${#skills[@]} -gt 0 ]] || { echo "fake-bunx: no skills requested" >&2; exit 1; }

canonical="$HOME/.agents/skills"
mkdir -p "$canonical"
skills_json="{" first=1
for skill in "${skills[@]}"; do
  dest="$canonical/$skill"
  mkdir -p "$dest"
  printf '%s\n' --- "name: $skill" description: test --- body >"$dest/SKILL.md"
  [[ $first -eq 1 ]] || skills_json+=", "
  first=0
  skills_json+="\"$skill\": {\"source\": \"$source\"}"
done
printf '{"skills": %s}\n' "$skills_json}" >"$HOME/.agents/.skill-lock.json"
FAKE

# Fake gum: `choose` prints the configured answer (SHIPPI_TEST_CHOICE), `confirm`
# exits 0. Outside a collision run nothing ever calls it.
cat >"$BIN/gum" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  choose)
    case "${SHIPPI_TEST_CHOICE:-rename}" in
      rename) echo "Rename to whatever (recommended)" ;;
      skip) echo "Skip x where it collides" ;;
      overwrite) echo "Overwrite the conflicting entries" ;;
      none) exit 1 ;;
    esac
    ;;
  confirm) exit 0 ;;
  *) echo "fake-gum: unexpected command: $*" >&2; exit 1 ;;
esac
FAKE

# Existence is all `have_claude_code` and `have_hermes` need.
touch "$BIN/claude" "$BIN/hermes"
chmod +x "$BIN"/*

# ------------------------------------------------------------------ plumbing

# Run install_ai_skills in a named fake home, under a pseudo-tty so the fake
# gum can receive its </dev/tty stdin. The exit status is asserted too: the
# checks alone cannot notice an installer that failed halfway.
CASE_STATUS=0
run_case() {
  local home="$1" choice="${2:-}"
  CASE_STATUS=0
  SHIPPI_TEST_CHOICE="$choice" script -qec \
    "set -euo pipefail; export PATH='$BIN:$PATH' HOME='$home' SHIPPI_TEST_CHOICE='$choice';
     source '$SOURCE_FILE'; install_ai_skills" /dev/null || CASE_STATUS=$?
  check "installer exit status ($(basename "$home"))" '[[ $CASE_STATUS -eq 0 ]]'
}

check() {  # check <desc> <expr>   (expr is evaluated as a command)
  local desc="$1" expr="$2"
  if eval "$expr"; then
    PASS=$((PASS + 1))
    echo "PASS $desc"
  else
    FAIL=$((FAIL + 1))
    echo "FAIL $desc"
  fi
}

marker() { tail -n1 "$1/.shippi-skill-source" 2>/dev/null; }
linkname() { readlink "$1" 2>/dev/null; }

# ------------------------------------------------------------------- the tests

echo "=== T1: fresh install, no conflicts ==="
: >"$FAKE_BUNX_LOG"
run_case "$HOMES/t1" >/dev/null 2>&1
H="$HOMES/t1"
check "canonical marked"     '[[ $(marker "$H/.agents/skills/tdd") == "mattpocock/skills" ]]'
check "claude link created"  '[[ $(linkname "$H/.claude/skills/tdd") == *".agents/skills/tdd" ]]'
check "claude link works"    'grep -q "name: tdd" "$H/.claude/skills/tdd/SKILL.md"'
check "hermes copy created"  'grep -q "name: tdd" "$H/.hermes/skills/tdd/SKILL.md"'
check "CLI calls target opencode only" \
  '[[ -s "$FAKE_BUNX_LOG" && $(grep -vc -- "-a opencode$" "$FAKE_BUNX_LOG") -eq 0 ]]'

echo "=== T2: research collides everywhere; choice = rename ==="
H="$HOMES/t2"
mkdir -p "$H/.agents/skills/research" "$H/.claude/skills/research" "$H/.hermes/skills/research/arxiv"
echo "canonical foreign" >"$H/.agents/skills/research/SKILL.md"
echo "claude bundled"   >"$H/.claude/skills/research/notes.md"
echo "hermes bundled"   >"$H/.hermes/skills/research/arxiv/data"
run_case "$H" rename >"$LOGS/t2.out" 2>&1
check "foreign canonical intact"  'grep -q "canonical foreign" "$H/.agents/skills/research/SKILL.md"'
check "foreign claude intact"     'grep -q "claude bundled" "$H/.claude/skills/research/notes.md"'
check "foreign hermes intact"     'grep -q "hermes bundled" "$H/.hermes/skills/research/arxiv/data"'
check "renamed canonical exists"  'grep -q "name: research-mattpocock-skills" "$H/.agents/skills/research-mattpocock-skills/SKILL.md"'
check "renamed canonical marked"  '[[ $(marker "$H/.agents/skills/research-mattpocock-skills") == "mattpocock/skills" ]]'
check "claude renamed link"       '[[ $(linkname "$H/.claude/skills/research-mattpocock-skills") == *".agents/skills/research-mattpocock-skills" ]]'
check "hermes renamed copy"       'grep -q "name: research-mattpocock-skills" "$H/.hermes/skills/research-mattpocock-skills/SKILL.md"'
check "choice recorded"           'awk -F "\t" '\''$1=="research" && $2=="rename"'\'' "$H/.agents/.shippi-skill-choices" | grep -q .'
check "other skills installed"    'grep -q "name: tdd" "$H/.agents/skills/tdd/SKILL.md"'

echo "=== T3: rerun with gum failing → stored rename applies, no prompt ==="
rm -rf "$HOMES/t3"; cp -a "$H" "$HOMES/t3"
run_case "$HOMES/t3" none >"$LOGS/t3.out" 2>&1
check "no prompt on rerun"        '! grep -q "These skill entries already exist" "$LOGS/t3.out"'
check "foreign entries survived"  'grep -q "claude bundled" "$HOMES/t3/.claude/skills/research/notes.md"'
check "renamed copy intact"       'grep -q "name: research-mattpocock-skills" "$HOMES/t3/.agents/skills/research-mattpocock-skills/SKILL.md"'

echo "=== T4: choice = overwrite → backups, foreign replaced ==="
H="$HOMES/t4"
rm -rf "$H"; cp -a "$HOMES/t2" "$H"; rm -f "$H/.agents/.shippi-skill-choices"
run_case "$H" overwrite >"$LOGS/t4.out" 2>&1
check "canonical backed up"       'ls "$H/.agents/.shippi-backups/" | grep -q "^research\."'
check "claude backed up"          'ls "$H/.claude/.shippi-backups/" | grep -q "^research\."'
check "canon backup has content"  'grep -q "canonical foreign" "$H/.agents/.shippi-backups/"research.*/entry/SKILL.md'
check "claude backup has content" 'grep -q "claude bundled" "$H/.claude/.shippi-backups/"research.*/entry/notes.md'
check "canonical replaced marker" '[[ $(marker "$H/.agents/skills/research") == "mattpocock/skills" ]]'
check "claude research replaced"  'grep -q "name: research" "$H/.claude/skills/research/SKILL.md"'
check "hermes research replaced"  'grep -q "name: research" "$H/.hermes/skills/research/SKILL.md"'

echo "=== T5: managed canonical research + claude collision → global rename ==="
H="$HOMES/t5"
mkdir -p "$H/.agents/skills/research"
printf '%s\n' --- "name: research" description: seeded --- body >"$H/.agents/skills/research/SKILL.md"
printf '%s\n' 'mattpocock/skills' >"$H/.agents/skills/research/.shippi-skill-source"
run_case "$H" >/dev/null 2>&1          # no collision yet: links the seeded copy
rm -f "$H/.claude/skills/research"     # replace the link with a foreign entry
mkdir -p "$H/.claude/skills/research"
echo "claude bundled" >"$H/.claude/skills/research/notes.md"
rm -f "$H/.agents/.shippi-skill-choices"
run_case "$H" rename >"$LOGS/t5.out" 2>&1
check "managed canonical intact"  '[[ $(marker "$H/.agents/skills/research") == "mattpocock/skills" ]]'
check "renamed canonical copy"    'grep -q "name: research-mattpocock-skills" "$H/.agents/skills/research-mattpocock-skills/SKILL.md"'
check "claude foreign intact"     'grep -q "claude bundled" "$H/.claude/skills/research/notes.md"'
check "claude gets renamed link"  'grep -q "name: research-mattpocock-skills" "$H/.claude/skills/research-mattpocock-skills/SKILL.md"'
check "hermes gets renamed copy"  'grep -q "name: research-mattpocock-skills" "$H/.hermes/skills/research-mattpocock-skills/SKILL.md"'

echo "=== T6: claude link repair and stale Hermes copy refresh ==="
H="$HOMES/t6"
run_case "$H" >/dev/null 2>&1
rm -f "$H/.claude/skills/tdd"
run_case "$H" >"$LOGS/t6.out" 2>&1
check "link repaired"  '[[ $(linkname "$H/.claude/skills/tdd") == *".agents/skills/tdd" ]]'
echo "stale" >>"$H/.hermes/skills/tdd/SKILL.md"
run_case "$H" >"$LOGS/t6-refresh.out" 2>&1
check "hermes copy refreshed" '! grep -q stale "$H/.hermes/skills/tdd/SKILL.md"'

echo "=== T7: unmarked canonical copy prompts once; the choice sticks ==="
H="$HOMES/t7"
mkdir -p "$H/.agents/skills/research"
echo "canonical foreign" >"$H/.agents/skills/research/SKILL.md"
run_case "$H" skip >"$LOGS/t7.out" 2>&1
check "prompt shown"              'grep -q "These skill entries already exist" "$LOGS/t7.out"'
check "choice recorded"           'awk -F "\t" '\''$1=="research" && $2=="skip"'\'' "$H/.agents/.shippi-skill-choices" | grep -q .'
check "foreign canonical intact"  'grep -q "canonical foreign" "$H/.agents/skills/research/SKILL.md"'
check "claude got a real copy"    '[[ ! -L "$H/.claude/skills/research" && -d "$H/.claude/skills/research" ]]'
run_case "$H" none >"$LOGS/t7-rerun.out" 2>&1
check "no repeat prompt"          '! grep -q "These skill entries already exist" "$LOGS/t7-rerun.out"'

echo "=== T8: stored skip + foreign canonical + free hermes → hermes gets it ==="
H="$HOMES/t8"
mkdir -p "$H/.agents/skills/research" "$H/.hermes/skills"
echo "canonical foreign" >"$H/.agents/skills/research/SKILL.md"
printf '%s\n' 'research	skip' >"$H/.agents/.shippi-skill-choices"
run_case "$H" none >"$LOGS/t8.out" 2>&1
check "no prompt (stored skip)"   '! grep -q "not managed by shippi" "$LOGS/t8.out"'
check "foreign canonical intact"  'grep -q "canonical foreign" "$H/.agents/skills/research/SKILL.md"'
check "hermes gets research"      'grep -q "name: research" "$H/.hermes/skills/research/SKILL.md"'
check "hermes research marked"    '[[ $(marker "$H/.hermes/skills/research") == "mattpocock/skills" ]]'
check "claude gets real copy"     '[[ ! -L "$H/.claude/skills/research" && -d "$H/.claude/skills/research" ]]'
check "claude copy works"         'grep -q "name: research" "$H/.claude/skills/research/SKILL.md"'
check "other skills still fine"   'grep -q "name: tdd" "$H/.hermes/skills/tdd/SKILL.md"'
run_case "$H" none >"$LOGS/t8-rerun.out" 2>&1
check "skip rerun has no false error" '! grep -q "no usable copy" "$LOGS/t8-rerun.out"'

echo "=== T9: legacy three-field choice rows still apply ==="
H="$HOMES/t9"
mkdir -p "$H/.agents/skills/research" "$H/.claude/skills/research"
echo "canonical foreign" >"$H/.agents/skills/research/SKILL.md"
echo "claude bundled" >"$H/.claude/skills/research/notes.md"
printf '%s\t%s\t%s\n' 'research' 'rename' 'research-old-target' >"$H/.agents/.shippi-skill-choices"
run_case "$H" none >"$LOGS/t9.out" 2>&1
check "legacy row used, no prompt" '! grep -q "These skill entries already exist" "$LOGS/t9.out"'
check "rename applied"             'grep -q "name: research-mattpocock-skills" "$H/.agents/skills/research-mattpocock-skills/SKILL.md"'

echo
echo "passed: $PASS  failed: $FAIL"
[[ $FAIL -eq 0 ]]
