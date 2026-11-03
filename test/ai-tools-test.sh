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
command -v jq &>/dev/null || {
  echo "skip: needs jq for the lock-file claiming test" >&2
  exit 77
}

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
BIN="$SANDBOX/bin"
LOGS="$SANDBOX/logs"
HOMES="$SANDBOX/homes"
mkdir -p "$BIN" "$LOGS" "$HOMES"

# ---------------------------------------------------------------- fake agents

# Fake bunx: understands "skills@latest add <source> -g -y --skill <names...>
# -a <targets>", writes each skill into $HOME/.agents/skills and a matching
# lock file, like the real CLI.
cat >"$BIN/bunx" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
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

# Fake gum: `choose` prints the configured answer (OMA_TEST_CHOICE), `confirm`
# exits 0. Outside a collision run nothing ever calls it.
cat >"$BIN/gum" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  choose)
    case "${OMA_TEST_CHOICE:-rename}" in
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
# gum can receive its </dev/tty stdin.
run_case() {
  local home="$1" choice="${2:-}"
  OMA_TEST_CHOICE="$choice" script -qec \
    "set -euo pipefail; export PATH='$BIN:$PATH' HOME='$home' OMA_TEST_CHOICE='$choice';
     source '$SOURCE_FILE'; install_ai_skills" /dev/null
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

marker() { tail -n1 "$1/.oma-pi-skill-source" 2>/dev/null; }
linkname() { readlink "$1" 2>/dev/null; }

# ------------------------------------------------------------------- the tests

echo "=== T1: fresh install, no conflicts ==="
run_case "$HOMES/t1" >/dev/null 2>&1
H="$HOMES/t1"
check "canonical marked"     '[[ $(marker "$H/.agents/skills/tdd") == "mattpocock/skills" ]]'
check "claude link created"  '[[ $(linkname "$H/.claude/skills/tdd") == *".agents/skills/tdd" ]]'
check "claude link works"    'grep -q "name: tdd" "$H/.claude/skills/tdd/SKILL.md"'
check "hermes copy created"  'grep -q "name: tdd" "$H/.hermes/skills/tdd/SKILL.md"'

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
check "choice recorded"           'awk -F "\t" '\''$1=="research" && $2=="rename"'\'' "$H/.agents/.oma-pi-skill-choices" | grep -q .'
check "other skills installed"    'grep -q "name: tdd" "$H/.agents/skills/tdd/SKILL.md"'

echo "=== T3: rerun with gum failing → stored rename applies, no prompt ==="
rm -rf "$HOMES/t3"; cp -a "$H" "$HOMES/t3"
run_case "$HOMES/t3" none >"$LOGS/t3.out" 2>&1
check "no prompt on rerun"        '! grep -q "could not resolve the conflict" "$LOGS/t3.out"'
check "foreign entries survived"  'grep -q "claude bundled" "$HOMES/t3/.claude/skills/research/notes.md"'
check "renamed copy intact"       'grep -q "name: research-mattpocock-skills" "$HOMES/t3/.agents/skills/research-mattpocock-skills/SKILL.md"'

echo "=== T4: choice = overwrite → backups, foreign replaced ==="
H="$HOMES/t4"
rm -rf "$H"; cp -a "$HOMES/t2" "$H"; rm -f "$H/.agents/.oma-pi-skill-choices"
run_case "$H" overwrite >"$LOGS/t4.out" 2>&1
check "canonical backed up"       'ls "$H/.agents/.oma-pi-backups/" | grep -q "^research\."'
check "claude backed up"          'ls "$H/.claude/.oma-pi-backups/" | grep -q "^research\."'
check "canon backup has content"  'grep -q "canonical foreign" "$H/.agents/.oma-pi-backups/"research.*/entry/SKILL.md'
check "claude backup has content" 'grep -q "claude bundled" "$H/.claude/.oma-pi-backups/"research.*/entry/notes.md'
check "canonical replaced marker" '[[ $(marker "$H/.agents/skills/research") == "mattpocock/skills" ]]'
check "claude research replaced"  'grep -q "name: research" "$H/.claude/skills/research/SKILL.md"'
check "hermes research replaced"  'grep -q "name: research" "$H/.hermes/skills/research/SKILL.md"'

echo "=== T5: claude-only collision, canonical ours → rename; foreign survives ==="
H="$HOMES/t5"
mkdir -p "$H/.agents/skills" "$H/.claude/skills/research"
echo "claude bundled" >"$H/.claude/skills/research/notes.md"
run_case "$H" >/dev/null 2>&1
rm -f "$H/.agents/.oma-pi-skill-choices"
run_case "$H" rename >"$LOGS/t5.out" 2>&1
check "renamed canonical copy"    'grep -q "name: research-mattpocock-skills" "$H/.agents/skills/research-mattpocock-skills/SKILL.md"'
check "claude foreign intact"     'grep -q "claude bundled" "$H/.claude/skills/research/notes.md"'
check "claude gets renamed link"  'grep -q "name: research-mattpocock-skills" "$H/.claude/skills/research-mattpocock-skills/SKILL.md"'
check "hermes gets renamed copy"  'grep -q "name: research-mattpocock-skills" "$H/.hermes/skills/research-mattpocock-skills/SKILL.md"'

echo "=== T6: claude link repair on refresh ==="
H="$HOMES/t6"
run_case "$H" >/dev/null 2>&1
rm -f "$H/.claude/skills/tdd"
run_case "$H" >"$LOGS/t6.out" 2>&1
check "link repaired"  '[[ $(linkname "$H/.claude/skills/tdd") == *".agents/skills/tdd" ]]'

echo "=== T7: pre-marker CLI installs are claimed from the lock ==="
H="$HOMES/t7"
mkdir -p "$H/.agents/skills/tdd"
printf '%s\n' --- "name: tdd" description: x --- body >"$H/.agents/skills/tdd/SKILL.md"
printf '%s\n' '{"skills": {"tdd": {"source": "mattpocock/skills"}}}' >"$H/.agents/.skill-lock.json"
run_case "$H" >"$LOGS/t7.out" 2>&1
check "claimed from lock"      'grep -q "claimed tdd" "$LOGS/t7.out"'
check "claimed marker written" '[[ $(marker "$H/.agents/skills/tdd") == "mattpocock/skills" ]]'
check "no prompt for claimed"  '! grep -q "not managed by oma-pi" "$LOGS/t7.out"'
check "claude link created"    '[[ $(linkname "$H/.claude/skills/tdd") == *".agents/skills/tdd" ]]'

echo "=== T8: stored skip + foreign canonical + free hermes → hermes gets it ==="
H="$HOMES/t8"
mkdir -p "$H/.agents/skills/research" "$H/.hermes/skills"
echo "canonical foreign" >"$H/.agents/skills/research/SKILL.md"
printf '%s\n' 'research	skip' >"$H/.agents/.oma-pi-skill-choices"
run_case "$H" none >"$LOGS/t8.out" 2>&1
check "no prompt (stored skip)"   '! grep -q "not managed by oma-pi" "$LOGS/t8.out"'
check "foreign canonical intact"  'grep -q "canonical foreign" "$H/.agents/skills/research/SKILL.md"'
check "hermes gets research"      'grep -q "name: research" "$H/.hermes/skills/research/SKILL.md"'
check "hermes research marked"    '[[ $(marker "$H/.hermes/skills/research") == "mattpocock/skills" ]]'
check "other skills still fine"   'grep -q "name: tdd" "$H/.hermes/skills/tdd/SKILL.md"'

echo
echo "passed: $PASS  failed: $FAIL"
[[ $FAIL -eq 0 ]]
