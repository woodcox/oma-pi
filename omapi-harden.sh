#!/usr/bin/env bash
#
# oma-pi security hardening
#
# Sources, all three linked from the README "Requirements" section:
#   https://chrisapproved.com/blog/raspberry-pi-hardening.html
#   https://ohyaan.github.io/tips/raspberry_pi_security_hardening_complete_guide/
#   https://raspberrytips.com/security-tips-raspberry-pi/
#
# Every task here changes how the machine behaves, so the script is built to
# be survivable rather than thorough at any cost:
#
#   * A task that cannot prove it will not lock you out of this box is
#     skipped with a reason instead of guessing. Turning off SSH passwords
#     without a usable authorized_keys entry is the classic way to lose
#     remote access to a Pi you cannot walk over to.
#   * Every config write is validated before the service is restarted, and
#     the previous file is kept, so a rejected config is rolled back instead
#     of leaving you with no sshd.
#   * --dry-run prints the plan and runs only the read-only commands needed
#     to decide it. Read the plan before agreeing to it.
#   * --yes accepts the recommended defaults. It is not a licence to skip
#     the key check. There is deliberately no --force: the "you have
#     another way in" questions are the ones that stop a run from locking
#     you out, so no flag should be able to wave them through.
#
# Deliberate omissions, so they are not mistaken for oversights:
#   * AllowTcpForwarding is left alone - config/shell/fns/ssh-port-forwarding
#     depends on it.
#   * net.ipv4.ip_forward is not forced to 0 when Docker is installed; the
#     installer puts Docker on every box and its bridge needs forwarding.
#   * Wi-Fi and Bluetooth are not disabled. That needs a /boot/config.txt
#     dtoverlay and a reboot, and getting it wrong drops this box off the
#     network you are reading this over. The exact lines are printed at the
#     end of the run instead.
set -euo pipefail

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------
ASSUME_YES=0
DRY_RUN=0
LOCKDOWN_SSH=0
WANT_REPORT=0
RUN_AUDIT=1
NO_RESTART=0
# Test-only override so the config writers can be exercised against a
# throwaway tree instead of the live system. Unset in normal use.
CONF_DEST="${OMAPI_SECURITY_DESTDIR:-}"
SELECTED=()

# Prepended, not appended: sshd honours the FIRST value it reads, so a
# matching directive further down sshd_config - or in an Include drop-in
# above it - would silently win over one appended at the bottom.
# Deliberately does NOT name this file. An earlier version read
# "(security.sh)", and renaming the script would then have left an existing
# managed block in sshd_config unmatched: the new run writes a second block
# and never removes the first, leaving two conflicting copies of every
# directive in the file.
MANAGED_BEGIN="# BEGIN oma-pi hardening - do not edit between these lines"
MANAGED_END="# END oma-pi hardening"

# aideinit builds a file database over the whole filesystem. On an SD card
# that is minutes of 100% CPU, so it is opt-in rather than part of the
# default run.
TASKS=(packages users ssh firewall fail2ban updates apparmor sysctl aide audit)
DEFAULT_TASKS=(packages users ssh firewall fail2ban updates apparmor sysctl audit)

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
  C_RED=$'\033[38;2;197;26;74m'
  C_DIM=$'\033[2m'
  C_BOLD=$'\033[1m'
  C_OFF=$'\033[0m'
else
  C_RED="" C_DIM="" C_BOLD="" C_OFF=""
fi

section() { printf '\n%s==> %s%s\n' "$C_BOLD" "$1" "$C_OFF"; }
step() { printf '  %s\n' "$1"; }
ok() { printf '  %s✓%s %s\n' "$C_RED" "$C_OFF" "$1"; }
warn() { printf '  %s!%s %s\n' "$C_RED" "$C_OFF" "$1" >&2; }
note() { printf '  %s%s%s\n' "$C_DIM" "$1" "$C_OFF"; }
skip() { printf '  %s-%s %s\n' "$C_DIM" "$C_OFF" "$1"; }

usage() {
  cat <<'EOF'
oma-pi security hardening

Usage:
  omapi-harden.sh [options] [task ...]

Supported: Raspberry Pi OS Lite / Debian 12 (bookworm), or Ubuntu 24.04
(noble) and newer. Ubuntu 22.10-23.10 are not supported: sshd there is
socket-activated without a generator, so a `Port` change is ignored and
this script would report a move that never happened. See the README.

Tasks (default: all but aide):
  packages    install the hardening tooling (ufw, fail2ban, apparmor, ...)
  users       no empty passwords, lock the default `pi` account, audit UID 0
  ssh         sshd hardening: no root login, no passwords, key-only, limits
  firewall    ufw: deny incoming by default, allow only what is listening
  fail2ban    ban repeat SSH/auth failures, banaction matched to ufw
  updates     unattended-upgrades for security patches, no surprise reboots
  apparmor    enable AppArmor and report complain counts
  sysctl      network + kernel sysctls, journal size cap
  aide        opt-in file integrity monitoring (slow, first run is minutes)
  audit       report the resulting state, change nothing

Options:
  -y, --yes         accept recommended defaults, do not prompt
  -n, --dry-run     print the plan, run only read-only commands
      --lockdown-ssh additionally set `AllowUsers <you>` in sshd_config
      --report       also save the audit report to ~/security-audit/
      --no-audit     skip the final report
      --no-restart   write configs but do not restart any service
  -l, --list        list tasks and exit
  -h, --help        this text

Examples:
  ./omapi-harden.sh --dry-run
  sudo ./omapi-harden.sh ssh firewall fail2ban
  sudo ./omapi-harden.sh --yes --report
EOF
}

list_tasks() {
  printf 'tasks:\n'
  for t in "${TASKS[@]}"; do
    case " ${DEFAULT_TASKS[*]} " in
      *" $t "*) printf '  %s\n' "$t" ;;
      *) printf '  %s (opt-in)\n' "$t" ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# Primitives
# ---------------------------------------------------------------------------
have() { command -v "$1" &>/dev/null; }

# A privileged command that changes the system. Honours --dry-run by
# printing instead of running, which is also what keeps a dry run working
# on a box where the caller cannot sudo.
run_root() {
  if ((DRY_RUN)); then
    printf '  %s•%s would run: %s\n' "$C_DIM" "$C_OFF" "$*"
    return 0
  fi
  if [[ $(id -u) -eq 0 ]]; then
    "$@"
  else
    priv "$@"
  fi
}

# A read-only command. Runs for real even under --dry-run: it changes
# nothing, and the plan cannot be built without it.
peek() {
  if [[ $(id -u) -eq 0 ]]; then
    "$@"
  elif have sudo; then
    if sudo -n true &>/dev/null; then
      sudo -n "$@"
    elif [[ -t 0 ]]; then
      sudo "$@"
    else
      warn "needs root, skipping: $*"
      return 1
    fi
  else
    warn "needs root, skipping: $*"
    return 1
  fi
}

priv() {
  if sudo -n true &>/dev/null; then
    sudo -n "$@"
  elif [[ -t 0 ]]; then
    sudo "$@"
  else
    printf 'error: %s needs root, re-run with sudo\n' "$*" >&2
    return 1
  fi
}

# Yes/no with a recommended default. --yes takes the default, --dry-run takes
# it too (so a dry run shows the plan the real run would follow), and with
# neither and no tty we take the default and say so.
ask() {
  local question="$1" default="${2:-y}" answer
  if ((ASSUME_YES || DRY_RUN)); then
    # Say which way it actually went. "defaulting to yes" on a question whose
    # default is no turns a plan into a lie, and a plan is the entire point of
    # a dry run.
    if [[ $default == y ]]; then
      note "assuming yes: $question"
    else
      note "assuming no: $question"
    fi
    [[ $default == y ]]
    return
  fi

  # gum reads /dev/tty rather than stdin, so it still works when stdin is a
  # pipe - which is exactly the situation inside the per-port and per-account
  # loops, where the loop list occupies fd 0. Gating this on `[[ -t 0 ]]` was
  # wrong twice over: it skipped gum entirely inside those loops, and it also
  # reported "no tty" on a perfectly good terminal. </dev/tty is the same
  # pattern install.sh and bin/omapi-* already use.
  if have gum && [[ -e /dev/tty ]] && [[ -r /dev/tty ]]; then
    if [[ $default == y ]]; then
      gum confirm "$question" </dev/tty
    else
      gum confirm "$question" --default-no </dev/tty
    fi
    return
  fi

  # No gum. read from the tty explicitly for the same reason, falling back to
  # stdin only when there is genuinely no terminal to read from.
  if [[ -e /dev/tty && -r /dev/tty ]]; then
    if [[ $default == y ]]; then
      read -r -p "  $question [Y/n] " answer </dev/tty
      [[ -z $answer || $answer =~ ^[Yy] ]]
    else
      read -r -p "  $question [y/N] " answer </dev/tty
      [[ $answer =~ ^[Yy] ]]
    fi
    return
  fi

  # Genuinely headless: a pipe, cron, CI. Take the default and say so loudly,
  # because silently locking accounts or closing ports here is exactly the
  # failure mode this script is supposed to avoid.
  warn "no terminal to ask on, taking the default ($default) for: $question"
  [[ $default == y ]]
}

# Write a managed config file. `install -d` for the parent, plain truncate for
# the file itself so an existing file keeps its mode and owner.
write_conf() {
  local path="$1"
  local target="${CONF_DEST}${path}"
  if ((DRY_RUN)); then
    printf '  %s•%s would write %s\n' "$C_DIM" "$C_OFF" "$path"
    cat >/dev/null
    return 0
  fi
  install -d -m 0755 "$(dirname "$target")"
  cat >"$target"
  note "wrote $path"
}

# Replace the managed block in the file named by $2 with the contents of $1,
# or APPEND it when the file has no such block yet.
#
# Append, not prepend, and that distinction is load-bearing for
# /etc/ufw/after.rules: ufw feeds the whole file to iptables-restore as one
# ruleset, and a *filter table opened at the top and COMMITted in the middle
# would leave everything ufw itself appends after it outside any table -
# which stops ufw restoring its ruleset at all. This mirrors
# chaifeng/ufw-docker, which deletes the block and appends it back at the end.
# It is still prepended for /etc/ssh/sshd_config, where first-value-wins is
# what makes the managed settings authoritative; so placement is per file.
#
# $3/$4 are the begin/end markers, defaulting to the sshd block's.
#
# Written back with `cat >` rather than `mv`ed from a temp file, so the
# original mode, owner and inode survive. Both files care, and a replaced
# sshd_config or after.rules with the wrong ownership is a bad afternoon.
replace_managed_block() {
  # Three separate `local` statements, not one. Bash expands every word on a
  # `local` line before it assigns any of them, so a single line reading
  # `local block=$1 path=$2 target=${CONF_DEST}${path}` would look up `path`
  # in the global scope, where it does not exist, and die under `set -u`.
  local block="$1"
  local path="$2"
  local b1="${3:-$MANAGED_BEGIN}"
  local b2="${4:-$MANAGED_END}"
  local where="${5:-top}"
  local target="${CONF_DEST}${path}"
  local body
  body="$(mktemp)"

  if [[ -f $block ]]; then
    cat "$block" >"$body"
  fi

  if [[ -f $target ]]; then
    awk -v b1="$b1" -v b2="$b2" '
      $0 == b1 { inblock = 1; next }
      $0 == b2 { inblock = 0; next }
      inblock != 1 { print }
    ' "$target" >"$body.tail"

    if [[ $where == bottom ]]; then
      # Existing content first, then the block.
      cat "$body.tail" >"$body"
      printf '\n' >>"$body"
      if [[ -f $block ]]; then
        cat "$block" >>"$body"
      fi
    else
      # Managed block first, then whatever was already in the file outside
      # any previous block. awk drops a trailing newline on the last line it
      # printed, so the concatenation below is what puts one back.
      printf '\n' >>"$body"
      cat "$body.tail" >>"$body"
    fi
    rm -f "$body.tail"

    # Normalise blank lines at the join to exactly one. Without this, every
    # re-run appends another newline and the file grows by one blank line per
    # run, forever - which is what "idempotent" has to mean here. Only the run
    # adjacent to the managed block is touched, so blank lines the user put
    # elsewhere in their own config are preserved.
    if [[ $where == bottom ]]; then
      # Block is last: collapse ONLY the run of blank lines immediately before
      # the block - that run is the join this function created, and leaving it
      # to grow is what made the file gain a blank line per run.
      #
      # Every OTHER run of blanks belongs to the user's own after.rules and is
      # copied through untouched. An earlier version reset a `blank` flag on
      # each non-blank line, which stopped separate runs merging but still
      # collapsed every one of them to a single line: a file with three
      # deliberate blank lines between rules came back with one, in a
      # function whose entire job is to preserve the user's file.
      awk -v b1="$b1" '
        { lines[NR] = $0 }
        END {
          start = 0
          for (i = 1; i <= NR; i++) if (lines[i] == b1) { start = i; break }

          # First line of the trailing run of blanks directly before `start`.
          # Walk back from start-1 while the lines are blank.
          join = start
          if (join > 1) {
            k = join - 1
            while (k >= 1 && lines[k] == "") k--
            join = k + 1
          }

          for (i = 1; i <= NR; i++) {
            if (join > 1 && i >= join && i < start) {
              if (i == join) print ""   # one separator, then skip the rest
              continue
            }
            print lines[i]
          }
        }
      ' "$body" >"$body.trim"
    else
      awk -v b2="$b2" '
        {
          if (after == 1) {
            if ($0 == "") next      # swallow extra separators
            after = 0               # first real line: resume normal output
          }
          print
          if ($0 == b2) after = 1
        }
      ' "$body" >"$body.trim"
    fi
    cat "$body.trim" >"$body"
    rm -f "$body.trim"
  fi

  if ((DRY_RUN)); then
    # Print just the managed block, not the whole file. Echoing back a
    # 200-line stock sshd_config to say "these 10 lines would be added" buries
    # the useful part.
    #
    # Nothing between here and the return may touch a real path. `install -d`
    # used to run just above this check, so a dry run created /etc/ssh (and
    # /etc/ufw on a box that lacked it) - a real mutation, and the one
    # guarantee a dry run exists to provide. Scratch files in $TMPDIR from
    # `mktemp` are still made above and still cleaned up below; that is the
    # only filesystem effect a dry run has.
    printf '  %s•%s would write %s (managed block on top, rest untouched):%s\n' \
      "$C_DIM" "$C_OFF" "$path" "$C_OFF"
    if [[ -f $block ]]; then
      sed 's/^/      /' "$block"
    fi
    rm -f "$body" "$body.tail" "$body.trim"
    return 0
  fi

  # No `|| true`: the `cat > "$target"` below fails loudly if this did not
  # work, and swallowing it here only turned a clear error into a confusing
  # one three lines later.
  install -d -m 0755 "$(dirname "$target")"

  cat "$body" >"$target"
  rm -f "$body"
}

# At least one key sshd would actually accept. A truncated paste or a private
# key in authorized_keys is silently ignored by sshd, and that is exactly the
# case where turning off passwords strands you.
#
# $1 is a newline-separated list of paths, so it has to be read line by line.
# `for f in "$keys"` word-splits on nothing and the loop body runs once with
# both paths glued into a single non-existent filename, which made this report
# "no usable key" on a box that had a perfectly good authorized_keys.
have_usable_key() {
  local found=1 f
  while IFS= read -r f; do
    [[ -n $f && -s $f ]] || continue
    # sshd's StrictModes (on by default) silently IGNORES an authorized_keys
    # whose own mode, or whose .ssh or home directory, is group- or
    # world-writable. `ssh-keygen -l` does not care about any of that, so a
    # key sshd would refuse is indistinguishable here from one it would
    # accept - and the difference is the difference between "you can still get
    # in" and "you cannot". Check the same way sshd does, so this cannot report
    # a key is usable when it is not.
    key_strict_modes_ok "$f" || continue
    # A private key is not a usable authorized_keys entry. ssh-keygen -l will
    # happily print a fingerprint for one, because it can read the public half
    # embedded in it, so it has to be rejected explicitly.
    if grep -q -- 'PRIVATE KEY-----' "$f" 2>/dev/null; then
      continue
    fi
    if grep -qvE '^\s*(#|$)' "$f" 2>/dev/null &&
      ssh-keygen -l -f "$f" &>/dev/null; then
      found=0
      break
    fi
  done <<<"$1"
  return $found
}

# True when sshd would not reject this path over file permissions.
# Mirrors sshd's StrictModes check: the file, its .ssh directory and the
# user's home directory must not be group- or world-writable. Read-only, and
# every path involved is owned by the user being checked, so no privilege is
# needed.
key_strict_modes_ok() {
  local f="$1" d
  # The uid the key must be owned by: the owner of the .ssh directory it lives
  # in, which is the account sshd would be checking. Derived here rather than
  # passed, because this is also called from tests that build their own tree.
  local target_uid
  target_uid="$(stat -Lc '%u' "$(dirname "$f")" 2>/dev/null || echo '')"
  # Ownership, checked on the key file itself. sshd's StrictModes rejects an
  # authorized_keys owned by neither the user nor root even at 0600 - the file
  # is then writable by whoever owns it. `find -perm` cannot see that, so a
  # third party's key looked "usable" here, PasswordAuthentication was written
  # on the strength of it, and sshd ignored the key. Wrong direction: this
  # function's false positives become lockouts.
  local owner
  owner="$(stat -Lc '%u' "$f" 2>/dev/null || echo '')"
  if [[ -n $owner && $owner != 0 && -n $target_uid && $owner != "$target_uid" ]]; then
    return 1
  fi

  # Every directory from the file up to /, not just three levels. sshd walks
  # the whole canonical parent path, so a writable /home or /home/shared
  # above a correctly-permissioned .ssh still gets the key refused - and
  # that is the case a fixed three-level check cannot see.
  #
  # `pwd -P`, not `pwd`: a symlinked $HOME (/home -> /data/home is common) kept
  # the symlink in the logical path, and `find` does not follow a symlink in
  # its starting path, so it stat'ed the link itself - mode 777, always
  # group/world-writable - and rejected a key sshd would have accepted. That
  # blocks --lockdown-ssh on an entirely legitimate setup. The kernel's view
  # is what sshd uses, so ask for that. -L does the same for the walk.
  local d dircount=0
  # Resolve the FILE itself, not just its parent. `pwd -P` canonicalises the
  # directory, so a symlinked authorized_keys kept a clean link-path while
  # `find -L "$f"` only checked the target file's own mode - the target's
  # parents were never walked. sshd realpath()s the file and walks the
  # resolved chain, so a key under a group-writable directory was ACCEPTED
  # here and REFUSED by sshd. False "usable" is the lockout direction.
  f="$(readlink -f "$f" 2>/dev/null || echo '')"
  [[ -n $f && -e $f ]] || return 1
  d="$(cd "$(dirname "$f")" 2>/dev/null && pwd -P)" || return 1
  # No iteration cap: dirname converges to / on its own, so a cap bounds
  # nothing except the number of components actually checked. One version had
  # `&& ((dircount < 64))`, which on a path deeper than 64 SILENTLY SKIPPED the
  # remaining checks - so a group-writable ancestor 70 levels up was accepted
  # while the same tree two levels deep was rejected. That is the lockout
  # direction, and it was a "safety" cap that reduced safety. If the path is
  # pathological, fail rather than check part of it.
  while [[ -n $d && $d != "/" ]]; do
    dircount=$((dircount + 1))
    if ((dircount > 64)); then
      return 1
    fi
    # The 022 part: group or other has any write bit.
    [[ -n $(find -L "$d" -maxdepth 0 -perm /022 2>/dev/null) ]] && return 1
    # Ownership of EVERY component, not just the file: sshd's secure_filename
    # requires each path component to be owned by the user or root. Checking
    # only the key file and its .ssh missed an intermediate directory owned by
    # a third party at 0755 - accepted here, refused by sshd, which is the
    # direction that ends in a lockout.
    local downer
    downer="$(stat -Lc '%u' "$d" 2>/dev/null || echo '')"
    # Every component must be the user's or root's. When the uid could not be
    # determined at all, treat it as a failure rather than skipping the check:
    # an unverified permission is exactly the case that turns into a lockout,
    # and the caller can still fall back to PasswordAuthentication being left
    # alone. Skipping silently would report "usable" for a key sshd may ignore.
    if [[ -z $target_uid ]]; then
      return 1
    fi
    if [[ -n $downer && $downer != 0 && $downer != "$target_uid" ]]; then
      return 1
    fi
    [[ $d == "/" ]] && break
    d="$(dirname "$d")"
  done
  # The file itself, which is not a directory on the walk above.
  [[ -n $(find -L "$f" -maxdepth 0 -perm /022 2>/dev/null) ]] && return 1
  return 0
}

# Resolve the real home directory rather than assuming /home/$user, and honour
# the AuthorizedKeysFile setting if sshd has been told to use something else.
key_files_for_user() {
  local user="${1:-$(id -un)}" home auth target_uid
  home="$(getent passwd "$user" 2>/dev/null | cut -d: -f6)"
  # %U is the numeric UID. Resolved here rather than substituted with the
  # username, which is what a previous version did and which checked
  # authorized_keys_<username> instead of the authorized_keys_<uid> sshd
  # actually reads.
  target_uid="$(getent passwd "$user" 2>/dev/null | cut -d: -f3)"
  if [[ -z $home ]]; then
    # No passwd entry, or no getent. Fall back to the convention rather than
    # silently checking nothing.
    home="/home/$user"
  fi
  # Read the effective setting from sshd itself where possible; a drop-in can
  # have moved it away from the default.
  auth="$(peek sshd -T -C "user=$user,host=localhost,addr=127.0.0.1" 2>/dev/null |
    awk '/^authorizedkeysfile /{ $1=""; sub(/^ +/, ""); print; exit }' || true)"
  if [[ -n $auth ]]; then
    # `sshd -T` prints every AuthorizedKeysFile path space-separated on ONE
    # line, so a `while read` over it yields a single value containing all of
    # them glued together: "/home/u/.ssh/authorized_keys .ssh/authorized_keys2".
    # have_usable_key then tests that as one non-existent filename, so on a box
    # with two default paths NEITHER is ever checked - and the lockout check
    # reports "no usable key" while a perfectly good key sits in the first
    # file. Split on whitespace into separate entries, then expand each.
    local -a auth_paths=()
    local f
    read -r -a auth_paths <<<"$auth"
    for f in "${auth_paths[@]}"; do
      [[ -n $f ]] || continue
      f="${f//\%h/$home}"
      f="${f//\%H/$home}"
      f="${f//\%d/$home}"
      f="${f//\%u/$user}"
      # %U is the numeric UID, not the username. Expanding it to $user checked
      # a username-suffixed file instead of the UID-suffixed one sshd actually
      # reads, so a key in the real file was never found.
      f="${f//\%U/$target_uid}"
      # `sshd -T` prints the *effective* setting, and sshd's own default is
      # the relative `.ssh/authorized_keys` - it does not expand it to an
      # absolute path. The sed above only fired when the token literally
      # started with %h, so the default came back as a bare relative path and
      # `have_usable_key` tested it against the current working directory.
      # Every box therefore reported "no usable key" even with a perfectly
      # good authorized_keys: a false negative that makes the lockout check
      # meaningless and refuses --lockdown-ssh every time.
      [[ $f == /* ]] || f="$home/$f"
      printf '%s\n' "$f"
    done
  else
    printf '%s\n' "$home/.ssh/authorized_keys" "$home/.ssh/authorized_keys2"
  fi
}

# ---------------------------------------------------------------------------
# packages
# ---------------------------------------------------------------------------
install_hardening_packages() {
  section "Packages"

  local -a packages=(
    ufw
    fail2ban
    apparmor
    apparmor-utils
    unattended-upgrades
    ca-certificates
  )

  if ((DRY_RUN)); then
    printf '  %s•%s would install: %s\n' "$C_DIM" "$C_OFF" "${packages[*]}"
    return 0
  fi

  local missing=() p
  for p in "${packages[@]}"; do
    dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q "ok installed" || missing+=("$p")
  done

  if ((${#missing[@]} == 0)); then
    ok "hardening packages already installed"
    return 0
  fi

  step "installing: ${missing[*]}"
  run_root apt-get update -qq
  # apt pulling new things in mid-run is normal; the point of this script is
  # to not fail halfway through a hardening pass because of it. But the
  # success line used to be unconditional, so a failed install still printed
  # "packages present" with a check mark - for packages that are not present.
  # Later tasks re-guard on `have`, so continuing is right; claiming success
  # is not.
  local install_ok=1
  run_root env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    "${missing[@]}" || { warn "apt-get install returned non-zero, continuing with what is installed"; install_ok=0; }
  if ((install_ok)); then
    ok "packages present"
  else
    warn "some packages are still missing; later tasks will skip anything that needs them"
  fi
}

# ---------------------------------------------------------------------------
# users
# ---------------------------------------------------------------------------
check_users() {
  section "Users and accounts"

  # No empty passwords. A blank shadow field is an account anyone can log
  # into with no secret at all, and on a device that is scanned within
  # minutes of being online it will be tried first.
  local empty
  empty="$(peek awk -F: '($2 == "") { print $1 }' /etc/shadow 2>/dev/null || true)"
  # The loop reads from fd 3, not stdin, so that `ask` inside it can still see
  # a tty on stdin and prompt. With the list on stdin, `[[ -t 0 ]]` was false
  # inside ask and every question silently took its default: every
  # passwordless account got locked and every unidentified port got closed
  # without the user ever being asked.
  if [[ -z $empty ]]; then
    ok "no passwordless accounts"
  else
    while IFS= read -r account <&3; do
      [[ -n $account ]] || continue
      if ask "lock the passwordless account '$account'?"; then
        run_root passwd -l "$account"
        run_root usermod -s /usr/sbin/nologin "$account"
        ok "locked $account"
      else
        skip "left $account alone"
      fi
    done 3<<<"$empty"
  fi

  # The factory `pi` account is the single most scanned username on the
  # internet. Current Raspberry Pi OS images no longer ship it, but an older
  # or hand-built image still can.
  if id pi &>/dev/null; then
    warn "the default 'pi' account still exists"
    if ask "lock the 'pi' account (reversible, /home/pi is left untouched)?"; then
      run_root usermod -L -s /usr/sbin/nologin pi
      # -U, not -L. The undo message used to repeat the lock flag, so running
      # it as printed left the password locked and only restored the shell -
      # the opposite of undoing. It has to be the exact inverse of the line
      # above: unlock the password AND put a real shell back.
      ok "locked pi - undo with: sudo usermod -U -s /bin/bash pi"
    else
      skip "left the pi account alone"
    fi
  else
    ok "no default 'pi' account"
  fi

  # Anything else with UID 0 is root by another name.
  local uid0
  uid0="$(peek awk -F: '($3 == 0) { print $1 }' /etc/passwd 2>/dev/null || true)"
  if [[ -n $uid0 ]]; then
    local extra
    extra="$(printf '%s\n' "$uid0" | grep -vx 'root' || true)"
    if [[ -n $extra ]]; then
      warn "accounts with UID 0 besides root: $(printf '%s' "$extra" | tr '\n' ' ')"
    else
      ok "root is the only UID 0 account"
    fi
  fi

  # Report, do not touch: accounts that have never logged in are the ones
  # most likely to still carry a default or reused password.
  local never
  never="$(peek lastlog 2>/dev/null | awk '/\*\*\*/ {print $1}' | tr '\n' ' ' || true)"
  if [[ -n $never ]]; then
    note "never logged in: $never"
  fi
}

# ---------------------------------------------------------------------------
# ssh
# ---------------------------------------------------------------------------
# Effective SSH port, preferring what sshd itself reports, because a
# drop-in in /etc/ssh/sshd_config.d can move it and the file would not say so.
current_ssh_port() {
  local port=""
  # What the RUNNING daemon is listening on, not what the config file says.
  # `sshd -T` parses the config, so under --no-restart - where the new port
  # has been written but sshd has not been restarted - it happily reports the
  # new port while the daemon is still on the old one. The firewall then opens
  # the port nobody is listening on and offers to close the one that is in
  # use, which with default-deny enabled is how you lock yourself out of a
  # box you are still connected to.
  #
  # Sources are tried in order of trustworthiness, and NO source is allowed to
  # guess. A wrong guess here decides which port the firewall protects, so an
  # earlier version's "any listening port in 20-30 must be sshd" heuristic was
  # removed: on this box it matched Postfix on 25 before it ever reached
  # sshd on 1199, which would have had the firewall protecting the mail server.
  # Being wrong in the direction of 22 is not safer - the script would open
  # 22 and offer to close the port the user is actually on.
  #
  # `sshd -T` is the most authoritative answer but needs root to read the host
  # keys, and peek cannot elevate in a non-interactive dry run - so it comes
  # last, not first. Reading the config file is unprivileged and reflects the
  # first Port directive, which is what sshd will honour.
  #
  # 1. A socket that sshd itself is holding, when the process list is readable.
  #    Matched on the process name, never on a port range.
  port="$(peek ss -Hltnp 2>/dev/null |
    awk '/sshd/ && $4 ~ /:([0-9]+)$/ { n = $4; sub(/^.*:/, "", n); print n; exit }' || true)"
  if [[ -z $port ]]; then
    # 2. The first Port directive in the effective config. sshd takes the
    #    first value for Port, and the managed block is prepended, so this is
    #    the port a restart would use. Read through ${CONF_DEST} so a test can
    #    point this at an empty tree: it reads the real /etc otherwise, and a
    #    test that cannot silence this source tests the host, not the function.
    port="$(grep -hsiE '^[[:space:]]*Port[[:space:]]+[0-9]+' \
      "${CONF_DEST}"/etc/ssh/sshd_config "${CONF_DEST}"/etc/ssh/sshd_config.d/*.conf 2>/dev/null |
      awk '{print $2; exit}' || true)"
  fi
  if [[ -z $port ]]; then
    # 3. Needs root, so usually only reachable on a real run.
    port="$(peek sshd -T 2>/dev/null | awk '/^port /{print $2; exit}' || true)"
  fi
  if [[ -z $port ]]; then
    # Nothing authoritative. Do not invent a number: the caller decides what
    # to do about a port it cannot determine.
    printf '\n'
    return 1
  fi
  printf '%s\n' "$port"
}

non_root_sudoer_with_key() {
  local user groups
  # The "way back in" has to be an account that can actually repair whatever
  # this script changed. Being able to log in is not enough: without sudo you
  # cannot undo a bad sshd_config or reopen a closed firewall, so a key on a
  # non-admin account is not a way back in, it is a way to sit and watch.
  #
  # Membership of `docker` counts as well. The daemon socket is root
  # equivalent - a container can mount the host filesystem - so a user in it
  # can do everything sudo could, and this box puts the installing user in
  # docker. Counting only sudo would have rejected the sole real admin here.
  while read -r user; do
    [[ -n $user && $user != root ]] || continue
    groups="$(id -nG "$user" 2>/dev/null || true)"
    if [[ " $groups " != *" sudo "* && " $groups " != *" docker "* ]]; then
      continue
    fi
    if have_usable_key "$(key_files_for_user "$user")"; then
      printf '%s\n' "$user"
      return 0
    fi
  done < <(peek awk -F: '($3 >= 1000 && $3 < 65534) {print $1}' /etc/passwd 2>/dev/null || true)
  return 1
}

harden_ssh() {
  section "SSH"

  local conf="/etc/ssh/sshd_config"
  local port
  # `|| true` because current_ssh_port returns 1 when it cannot determine the
  # port, and under set -e that would abort the whole ssh task. Handled
  # explicitly below instead of being allowed to look like port 0.
  port="$(current_ssh_port || true)"
  if [[ -z $port ]]; then
    warn "cannot determine which port sshd is on; skipping SSH hardening"
    note "this is fail-safe: nothing is written, so the current config stays in force"
    note "run 'sudo sshd -T | grep ^port' to see the port, then re-run this task"
    return 1
  fi
  note "sshd is on port ${port}"

  if ! [[ -f $conf ]] && ! ((DRY_RUN)); then
    warn "no ${conf}, skipping SSH hardening"
    return 0
  fi

  # Lockout check, before anything is written. A key for a sudoer account is
  # the way back in once passwords are off.
  local backdoor_user=""
  if ! backdoor_user="$(non_root_sudoer_with_key)"; then
    if have tailscale && tailscale status &>/dev/null; then
      # Single quotes, not double: backticks inside a double-quoted string
      # are a command substitution, and this one really did try to run
      # `tailscale ssh` on the machine.
      note 'tailscale is up, so `tailscale ssh` is unaffected by sshd_config'
    fi
    warn "no non-root account with a usable authorized_keys entry was found"
    # Default no, and deliberately not overridable by --yes/--force. Those
    # flags take *defaults*, and defaulting this one to yes means every
    # `sudo ./omapi-harden.sh --yes` run turns passwords off on a box with no
    # verified way back in, which is the exact failure this whole check
    # exists to prevent. Continuing requires a deliberate interactive yes.
    if ! ask "switch SSH to key-only anyway (make sure you can reach this box another way)?" n; then
      skip "leaving PasswordAuthentication as it is"
      return 0
    fi
  else
    ok "key-based access confirmed for $backdoor_user"
  fi

  local new_port="$port" change_port=0
  if ((LOCKDOWN_SSH)); then
    # Under `sudo ./omapi-harden.sh`, id -un is root. AllowUsers root alongside
    # PermitRootLogin no is a config sshd accepts and that locks out every
    # account, so the real invoking user has to be resolved, and root has to
    # be refused outright.
    local target_user="${SUDO_USER:-$(id -un)}"
    if [[ -z $target_user || $target_user == root ]]; then
      warn "--lockdown-ssh needs a real non-root user; run it as 'sudo -u \$USER -E ./omapi-harden.sh --lockdown-ssh' or from a root shell with SUDO_USER set"
      warn "refusing to write AllowUsers root: it would lock out every account"
      LOCKDOWN_SSH=0
    elif ! have_usable_key "$(key_files_for_user "$target_user")"; then
      # The backdoor check above only proves that SOME non-root account has a
      # key. This flag names one specific account, and if that is not the one
      # with the key then AllowUsers <target_user> + PasswordAuthentication no
      # + PermitRootLogin no strands the box with no prompt at all. On the
      # --yes path there is no prompt to notice, because there is no prompt.
      warn "--lockdown-ssh would set AllowUsers ${target_user}, but that account has no usable authorized_keys"
      warn "the key check passed for a different account; refusing to lock down to a keyless user"
      note "put an authorized_keys file in ~${target_user} first, or drop --lockdown-ssh"
      LOCKDOWN_SSH=0
    else
      note "--lockdown-ssh: AllowUsers will be set to ${target_user}"
    fi
  fi

  # Moving the port only removes noise from the logs; it is not a control.
  # Offered because it is in the guides and because it is harmless, but
  # never the reason a box is called secure.
  #
  # Refused outright under --no-restart. That flag exists so a config change
  # can be staged and activated by hand, but the firewall stage runs in the
  # same pass and has to decide which port sshd is on. While sshd is still
  # running the old one, the two disagree: the config says the new port, the
  # daemon listens on the old. The firewall would then open a port nothing
  # listens on and offer to close the one in use - and with default-deny
  # enabled, accepting that is a lockout on a live port. A staged port change
  # and a firewall that is meant to follow it cannot coexist in one run.
  #
  # Asked once, and the answer is not re-offered on the other branch: an
  # earlier version used `if ((NO_RESTART)) && ask ...; then <refuse> elif ask
  # ...`, so answering "no" to the deferred question fell straight through to
  # the ordinary one, which had no --no-restart protection at all. That wrote
  # `Port 2222` while sshd stayed on 22, and the box locked out the moment
  # the user ran `systemctl restart ssh` by hand. Reproduced before fixing.
  if ((NO_RESTART)); then
    if ask "move sshd off port ${port}? (not possible: --no-restart is set)" n; then
      warn "not moving the port: --no-restart means sshd would keep listening on ${port}"
      note "the firewall stage protects the port sshd is really on, so a staged move would not be followed"
      note "move the port in a run WITHOUT --no-restart, or apply it by hand once"
    fi
  elif ask "move sshd off port ${port}? (noise reduction only, not security)" n; then
    local candidate=""
    # Read directly rather than through a process substitution: a `read` inside
    # `< <(...)` runs in a subshell, so the value it captured was discarded and
    # the port silently stayed where it was. gum's output is captured by
    # command substitution, which does survive, but the read fallback did not.
    if have gum && [[ -e /dev/tty && -r /dev/tty ]]; then
      candidate="$(gum input --placeholder "e.g. 2222" --prompt "New SSH port: " </dev/tty || true)"
    elif [[ -e /dev/tty && -r /dev/tty ]]; then
      read -r -p "  New SSH port [2222]: " candidate </dev/tty || true
    fi
    candidate="${candidate:-2222}"
    if [[ $candidate =~ ^[0-9]+$ ]] && ((candidate > 0 && candidate < 65535)) && ((candidate != port)); then
      new_port="$candidate"
      change_port=1
      note "sshd will move to port ${new_port}"
    else
      new_port="$port"
      note "keeping port ${port}"
    fi
  fi

  local block
  block="$(mktemp)"

  {
    printf '%s\n' "$MANAGED_BEGIN"
    cat <<EOF
# Prepended because sshd takes the first value it reads, so the same
# directive further down the file (or in an Include drop-in above this)
# would silently override it. Re-run omapi-harden.sh to change these; edits
# inside the block are lost on the next run.
PermitRootLogin no
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitEmptyPasswords no
X11Forwarding no
MaxAuthTries 3
# oma-pi runs tmux, a terminal multiplexer and tailscale sessions side by
# side, so 2 (the value in the guides) is too tight to be usable.
MaxSessions 5
LoginGraceTime 30
ClientAliveInterval 300
ClientAliveCountMax 2
# AllowTcpForwarding is intentionally untouched: config/shell/fns/ssh-port-forwarding
# relies on it.
EOF
    # Always written, not only when this run moved the port. sshd's `Port` is
    # additive and the first value wins, so the managed block is what makes the
    # choice stick. When `Port` was emitted only on a move, re-running after a
    # move and declining it rewrote the block with no Port line at all while
    # the old `Port 22` stayed commented out from the previous run - so sshd
    # silently reverted to 22 while the script went on protecting 2222, on a
    # path the block comment explicitly invites users to take.
    printf 'Port %s\n' "$new_port"
    ((LOCKDOWN_SSH)) && printf 'AllowUsers %s\n' "${SUDO_USER:-$(id -un)}"
    printf '%s\n' "$MANAGED_END"
  } >"$block"

  local target="${CONF_DEST}${conf}"
  local backup=""
  # Backups of the sshd_config.d drop-ins, populated when they are rewritten
  # and consumed by the rollback below. Declared here, not inside the rewrite
  # block, because the rollback is outside it and would otherwise see nothing.
  local dropin_backups=""
  if ((!DRY_RUN)) && [[ -f $target ]]; then
    backup="${target}.omapi-backup"
    cp -p "$target" "$backup"
  fi

  replace_managed_block "$block" "$conf"

  # Port is ADDITIVE in sshd: unlike every other directive here, first value
  # does not win, and two active `Port` lines for the same port make sshd die
  # with "Address already in use" at bind time. `sshd -t` does not bind, so
  # validation does not catch it.
  #
  # So every active `Port` line OUTSIDE the managed block is commented out on
  # every run, not only on a run that moves the port. Gating this on
  # change_port meant that on a box which had already moved ssh off 22 - the
  # exact box most likely to be run through a hardening script - a run that did
  # not move the port wrote `Port 2222` into the block and left the existing
  # `Port 2222` active, and the box came back unreachable after
  # `systemctl restart ssh`.
  #
  # awk rather than sed, so the managed block's own line is skipped by
  # position: a blanket regex cannot tell the block's `Port` from the
  # stock file's, and commenting out both would leave sshd with no port at all.
  if ((!DRY_RUN)); then
    if ! awk -v b1="$MANAGED_BEGIN" -v b2="$MANAGED_END" '
      $0 == b1 { inside = 1; print; next }
      $0 == b2 { inside = 0; print; next }
      inside != 1 && $0 ~ /^[[:space:]]*[#[:space:]]*Port[[:space:]]+[0-9]+/ {
        line = $0
        sub(/^[[:space:]]*/, "", line)
        if (line ~ /^#/) { print; next }          # already commented
        print "# " line                           # was active: disable it
        next
      }
      { print }
    ' "$target" >"$target.omapi-tmp"; then
      # A failure inside `awk && cat && rm` is exempt from set -e, so this
      # used to fail silently: harden_ssh returned 0, printed "sshd accepts
      # the new config", and left two active Port lines plus a stray temp file
      # with no warning anywhere. Verified with an injected failing awk. Treat
      # it as the config-write failure it is.
      warn "could not rewrite the Port lines in ${conf}"
      rm -f "$target.omapi-tmp"
      if [[ -n $backup && -f $backup ]]; then
        cp -p "$backup" "$target" || warn "could not restore ${conf} from the backup"
      fi
      return 1
    fi
    # cat into the original rather than mv, so mode, owner and inode survive.
    cat "$target.omapi-tmp" >"$target"
    rm -f "$target.omapi-tmp"

    # The same pass over /etc/ssh/sshd_config.d drop-ins. sshd reads those, and
    # current_ssh_port reads them, but the main-file pass cannot see them - so
    # a drop-in carrying an active `Port` was left untouched and sshd ended up
    # with the port twice. Reproduced end to end: drop-in `Port 2222` plus the
    # managed block's `Port 2222` gave `sshd -T` reporting the port twice.
    local dropin
    for dropin in "${CONF_DEST}"/etc/ssh/sshd_config.d/*.conf; do
      [[ -f $dropin ]] || continue
      # Back the drop-in up before rewriting it. `backup` covers only the main
      # file, so a failed `sshd -t` rolled the main config back and left the
      # drop-ins modified - a config inconsistency that would only bite on the
      # next sshd start, which is exactly the kind of thing that surfaces hours
      # later as "ssh won't come back".
      local dbak="${dropin}.omapi-backup"
      cp -p "$dropin" "$dbak" 2>/dev/null && dropin_backups+="$dbak"$'\n'
      if awk '
        $0 ~ /^[[:space:]]*Port[[:space:]]+[0-9]+/ {
          line = $0
          sub(/^[[:space:]]*/, "", line)
          if (line ~ /^#/) { print; next }
          print "# " line
          next
        }
        { print }
      ' "$dropin" >"$dropin.omapi-tmp"; then
        cat "$dropin.omapi-tmp" >"$dropin"
        rm -f "$dropin.omapi-tmp"
      else
        # Never rewrite a file we cannot read back correctly: a half-written
        # drop-in is a box that may not come back.
        warn "could not rewrite Port lines in ${dropin}; leaving it untouched"
        rm -f "$dropin.omapi-tmp"
      fi
    done
  fi

  rm -f "$block"
  ok "sshd_config hardened"

  # Validate before restarting. An sshd that will not parse is an sshd that
  # does not come back, and on a headless Pi that is the whole session.
  if ((DRY_RUN)); then
    note "would validate with: sshd -t -f ${conf}"
    # Report the right unit: on Ubuntu 22.10+ ssh.socket owns the port, and
    # telling the user to restart `ssh` when that is masked by the socket is
    # how a port change ends up silently not applied.
    if peek systemctl is-active --quiet ssh.socket; then
      note "would run: systemctl daemon-reload && systemctl restart ssh.socket (ssh.socket is active)"
    else
      note "would run: systemctl restart ssh"
    fi
    [[ $change_port -eq 1 ]] && note "firewall rules must follow the move to port ${new_port}"
    return 0
  fi

  if ! peek sshd -t -f "$conf" >/dev/null 2>&1; then
    # Drop-ins first: they were rewritten before this validation, and the
    # main file's rollback does not touch them.
    local dbak
    while read -r dbak; do
      [[ -n $dbak && -f $dbak ]] || continue
      cp -p "$dbak" "${dbak%.omapi-backup}" || warn "could not restore ${dbak%.omapi-backup}"
    done <<<"${dropin_backups:-}"
    if [[ -n $backup ]]; then
      warn "sshd rejected the new config, rolling ${conf} back"
      peek cp -p "$backup" "$conf" || warn "could not restore ${conf} from the backup - sshd_config is left in the rejected state"
    else
      warn "sshd rejected the new config and there is no backup to roll back to"
    fi
    return 1
  fi
  ok "sshd accepts the new config"

  # The config is good, so the drop-in backups have served their purpose.
  # Leaving them behind would accumulate one file per drop-in on every run.
  local dbak
  while read -r dbak; do
    [[ -n $dbak ]] && rm -f "$dbak"
  done <<<"${dropin_backups:-}"

  if ((NO_RESTART)); then
    note "--no-restart: run 'sudo systemctl restart ssh' yourself when ready"
    return 0
  fi

  # On Ubuntu 22.10 and later sshd is socket-activated: ssh.socket owns the
  # listening port and passes connections to sshd@.service per connection.
  # In that setup a `Port` change in sshd_config has no effect until the unit
  # definition is reloaded and the socket restarted - so the script would
  # report "ssh restarted on port N" while sshd was still listening on the old
  # one. Detect it rather than assuming either layout.
  local socket_activated=0
  if peek systemctl is-active --quiet ssh.socket; then
    socket_activated=1
    if ((change_port)); then
      note "ssh.socket is active: reloading the unit and restarting the socket"
      # daemon-reload picks up the port the socket template was generated
      # with; without it the socket keeps the old ListenStream=.
      peek systemctl daemon-reload || warn "systemctl daemon-reload failed"
    fi
  fi

  local restart_ok=1
  if ((socket_activated)); then
    if ! peek systemctl restart ssh.socket; then
      warn "ssh.socket failed to restart, rolling back"
      [[ -n $backup ]] && { peek cp -p "$backup" "$conf" || warn "could not restore ${conf} from the backup - sshd_config is left in the rejected state"; } || true
      peek systemctl daemon-reload || true
      peek systemctl restart ssh.socket || true
      return 1
    fi
    # The socket hands connections to sshd@.service, which reads sshd_config
    # per connection, so the service itself does not need restarting - but a
    # plain `systemctl restart ssh` would be masked by the socket anyway.
    ok "ssh.socket restarted; sshd picks up the config per connection"
  else
    if peek systemctl restart ssh; then
      ok "ssh restarted on port ${new_port}"
    else
      restart_ok=0
    fi
  fi

  if ((restart_ok)); then
    printf '\n  %sKeep this session open and open a second one before you rely on it.%s\n' "$C_BOLD" "$C_OFF"
  else
    warn "ssh failed to restart, rolling back"
    [[ -n $backup ]] && { peek cp -p "$backup" "$conf" || warn "could not restore ${conf} from the backup - sshd_config is left in the rejected state"; } || true
    peek systemctl restart ssh || true
    return 1
  fi
}

# ---------------------------------------------------------------------------
# firewall
# ---------------------------------------------------------------------------
# What is actually listening, and on what. The guides say "allow only what
# you need"; this is how the script finds out what that is.
# Parse `ss -H` and `netstat` output for the port on a routable address. The
# two formats disagree about which column the address is in, so match on the
# protocol token rather than a fixed index: with `ss` the token is $1, with
# `netstat` it is $1 as well but the address lands in $4 because of the
# extra Recv-Q/Send-Q columns. Finding the field that actually looks like
# host:port avoids the whole problem.
listening_ports() {
  local raw
  # ${1:-} lets a caller (the test suite) feed it captured `ss`/`netstat`
  # output. Testing a hand-copied duplicate of the awk program is how the
  # suite shipped a green test beside a parser that was dropping dual-stack
  # wildcards; the tests now run this exact code.
  if [[ -n ${1:-} ]]; then
    raw="$1"
  elif have ss; then
    raw="$(ss -H -tulnp 2>/dev/null || true)"
  elif have netstat; then
    raw="$(netstat -tulnp 2>/dev/null || true)"
  else
    warn "neither ss nor netstat, cannot enumerate listening ports"
    return 0
  fi
  printf '%s\n' "$raw" | awk '
    {
      proto = tolower($1)
      if (proto != "tcp" && proto != "udp") next
      addr = ""
      for (i = 2; i <= NF; i++) {
        # First address:port-shaped field is the local one, and it is the
        # only one on a listening socket (the peer is 0.0.0.0:* or :::*).
        #
        # `*:PORT` has to be matched explicitly. That is how ss renders a
        # dual-stack wildcard listener, which is what a Node listen(3000) or
        # docker-proxy produces, and the address regex below does not match
        # it - so those ports were being dropped and closed by omission.
        if ($i ~ /^\*:[0-9]+$/ ||
            ($i ~ /:/ && $i ~ /^\[?[0-9A-Fa-f.:%]+\]?:[0-9]+$/)) { addr = $i; break }
      }
      if (addr == "") next
      # Loopback-only. 127.x anywhere in the field, and either bracket form
      # of ::1, so [::1]:631 and ::1:631 both go.
      if (addr ~ /127\./ || addr ~ /::1\]?:/) next
      # Tailscale. The interface is usually 100.64.0.0/10, but a v6 tailnet
      # address is fd7a:115c:a1e0::/48, and filtering only the v4 range let
      # fd7a:115c:a1e0::...:35546 through as if it were public traffic.
      if (addr ~ /100\.[0-9]+\.[0-9]+\.[0-9]+:/ || addr ~ /\[?fd7a:115c:a1e0:/) next
      if (addr ~ /tailscale/) next
      # mDNS / LLMNR / SSDP name-service noise, not services you run.
      if (proto == "udp" && addr ~ /:(5353|5355|1900|123|1234)$/) next
      # DHCP client, which is an outbound thing and has no listener to open.
      if (addr ~ /:(68|546|547|67)$/) next
      port = addr
      sub(/.*:/, "", port)
      if (port !~ /^[0-9]+$/) next
      print proto, port
    }' | sort -u -k1,1 -k2,2n
}

docker_present() {
  # Deliberately not `peek`. `systemctl is-active` is a read-only query that
  # works unprivileged, and wrapping it in peek made this return false
  # whenever a sudo prompt was unavailable - which silently wrote
  # `net.ipv4.ip_forward = 0` on a machine running containers, breaking
  # Docker networking with no error anywhere. Getting this wrong breaks the
  # box, so it must never depend on privilege.
  have docker && systemctl is-active --quiet docker 2>/dev/null
}

# Docker inserts its DNAT and ACCEPT rules straight into iptables, ahead of
# everything ufw manages. A published port is therefore reachable from the
# internet no matter what ufw says - `ufw deny 8080` will not stop it. The
# fix is the DOCKER-USER chain, which Docker routes all forwarded container
# traffic through and which ufw does not otherwise touch.
#
# Rules are the ones published by chaifeng/ufw-docker (the de facto
# reference, 6.8k stars) and described in
# https://blog.jarrousse.org/2023/03/18/how-to-use-ufw-firewall-with-docker-containers/
#
# They are written inline rather than by curling ufw-docker into
# /usr/local/bin: the install step is a handful of static iptables lines, and
# fetching and executing a third-party script as root on every hardened box
# is a supply-chain risk this script has no business adding. The upstream
# markers are used verbatim so `ufw-docker check` and `ufw-docker uninstall`
# still recognise the block if you later install the real tool.
DOCKER_UFW_BEGIN="# BEGIN UFW AND DOCKER"
DOCKER_UFW_END="# END UFW AND DOCKER"

docker_ufw_installed() {
  # Through CONF_DEST, not a hardcoded /etc. configure_docker_uff says it
  # checks here so a test destdir cannot make the script read the real host
  # file; that was only true of the caller, not of this function.
  local f="${CONF_DEST}/etc/ufw/after.rules"
  [[ -r $f ]] && grep -qF "$DOCKER_UFW_BEGIN" "$f" 2>/dev/null
}

# Every subnet Docker currently has, so the rules cover custom networks and
# not just the default bridge. RFC1918 is always included.
docker_subnets() {
  printf '%s\n' "10.0.0.0/8" "172.16.0.0/12" "192.168.0.0/16"
  if have docker; then
    local n
    for n in $(docker network ls -q 2>/dev/null || true); do
      docker network inspect "$n" --format \
        '{{range .IPAM.Config}}{{.Subnet}} {{end}}' 2>/dev/null || true
    done | tr ' ' '\n' | grep -E '^[0-9a-fA-F:]+/[0-9]+$' || true
  fi
}

# True when every publication of this container port is bound to loopback
# only, i.e. it is not reachable from off-box at all and needs no rule.
#
# The question is per CONTAINER port, but the loopback binding is expressed in
# the HOST port (`-p 127.0.0.1:8080:80`), so a name that only appears on the
# host side would be missed. The check therefore has to consider every
# published binding that maps to this container port, and only report
# loopback if all of them are loopback: a port published on both
# 0.0.0.0 and 127.0.0.1 is publicly reachable via the first one.
docker_port_is_loopback_only() {
  local cport="$1" proto="${2:-tcp}" entries
  entries="$(docker ps --format '{{.Ports}}' 2>/dev/null | tr ',' '\n')"
  [[ -n $entries ]] || return 1

  local saw=0 e
  while read -r e; do
    e="${e// /}"
    [[ $e == *"->"* ]] || continue
    local rest="${e##*->}"
    local target="${rest%%/*}" eproto="${rest##*/}"
    # Test $rest, not $eproto: eproto is everything after the last "/", so it
    # can never itself contain one and the check never fired. docker omits the
    # protocol on some `docker ps` output, giving eproto="80" for "->80", which
    # then matched neither tcp nor udp - so a loopback-only port was reported
    # as publicly reachable and a pointless `ufw route allow` was demanded for
    # something nothing outside the box can reach.
    [[ $rest == */* ]] || eproto="tcp"
    # Per protocol: a port published on loopback for tcp and on 0.0.0.0 for
    # udp is publicly reachable over udp, and the tcp result must not mask it.
    [[ $target == "$cport" && $eproto == "$proto" ]] || continue
    saw=1
    # 0.0.0.0, [::], or an explicit private address: reachable off-box.
    if ! [[ $e =~ ^127\.0\.0\.1: ]]; then
      return 1
    fi
  done <<<"$entries"

  # No binding for this port at all: not loopback-only, just absent. Treated
  # as "not loopback" so the caller still offers it rather than assuming.
  [[ $saw -eq 1 ]]
}

# Syntax-check the fragment before it is allowed anywhere near the live
# firewall. Extracted from the file we just wrote and fed to
# iptables-restore --test as a complete ruleset.
#
# This has to distinguish "you are not root" from "this is malformed".
# iptables-restore --test needs root even though it changes nothing, so on an
# unprivileged run the honest answer is "could not check", not "looks fine" -
# and a function that returns 0 unconditionally gates nothing at all.
validate_docker_ufw_rules() {
  local path="$1" tmp out rc=0
  [[ -r $path ]] || return 1

  tmp="$(mktemp)"
  {
    printf '*filter\n'
    # awk rather than sed with the markers interpolated into a regex: the
    # markers contain `#`, which is only safe inside a bracket expression, and
    # building that expression by string surgery is how this quietly stopped
    # matching. awk takes them as plain strings.
    awk -v b1="$DOCKER_UFW_BEGIN" -v b2="$DOCKER_UFW_END" '
      $0 == b1 { inside = 1 }
      inside == 1 {
        line = $0
        sub(/^[[:space:]]+/, "", line)
        if (line == b2) { inside = 0; next }
        if (line ~ /^#/ || line == "*filter" || line == "COMMIT" || line == "") next
        print line
      }
    ' "$path"
    printf 'COMMIT\n'
  } >"$tmp"

  if ! have iptables-restore; then
    warn "iptables-restore is not installed; cannot validate the DOCKER-USER rules"
    rm -f "$tmp"
    return 1
  fi

  # Decide how to invoke the real parser. An array-length test cannot
  # distinguish "we are root, run it directly" from "we cannot run it at all",
  # and conflating them sends root down the unprivileged structural path.
  local use_restore=0
  local -a run_restore=()
  if [[ $(id -u) -eq 0 ]]; then
    use_restore=1
  elif sudo -n true &>/dev/null; then
    # Passwordless sudo is available, so actually USE it. Running
    # iptables-restore unprivileged and then interpreting its "Permission
    # denied" as a pass means a rule naming a chain that does not exist is
    # reported as verified, because iptables never got far enough to look.
    use_restore=1
    run_restore=(sudo -n)
  fi

  if ((use_restore)); then
    out="$("${run_restore[@]}" iptables-restore --test "$tmp" 2>&1)" && rc=0 || rc=1
    if ((rc)) && [[ $out == *"Permission denied"* ]]; then
      # sudo was available but still refused. Not a syntax problem, but also
      # not a verification - report it as unverified rather than as a pass.
      note "iptables-restore --test could not be applied: ${out##*: }"
      rc=2
    elif ((rc)); then
      warn "iptables-restore rejected the DOCKER-USER rules: ${out##*: }"
    fi
  else
    # No privilege, so the real parser is unavailable. Two checks are possible
    # without root, and they catch different things:
    #   - a line that is not a valid iptables-restore directive
    #   - a `-j TARGET` naming a chain this fragment never declares
    # Neither can catch every error - iptables-restore is the only real parser
    # - so an unverified result is reported as unverified, never as a pass.
    local bad="" declared declared_target
    # Chains this fragment declares, plus the ones ufw and Docker always
    # provide. iptables has a fixed set of BUILTIN targets that are not
    # chains and are not declared anywhere - LOG is the one this fragment
    # uses - so they have to be listed explicitly or every rule is reported
    # as jumping to a chain that does not exist.
    declared=" ufw-user-forward ufw-docker-logging-deny DOCKER-USER DOCKER DOCKER-CT nat PREROUTING POSTROUTING OUTPUT INPUT FORWARD "
    declared+=" ACCEPT DROP REJECT RETURN LOG QUEUE TRACE "
    declared+=" DNAT SNAT MASQUERADE REDIRECT MIRROR NOTRACK CT "
    while read -r line; do
      [[ -z $line ]] && continue
      case "$line" in
        '*filter' | 'COMMIT') continue ;;
        ':'*)
          # :CHAINNAME - [0:0] - take the NAME only. ${line#:} would give
          # "ufw-user-forward - [0:0]", which never matches the " ${chain} "
          # lookup and so silently defeats the undeclared-jump check the
          # moment a chain is not in the pre-listed set.
          local cname="${line#:}"
          declared+=" ${cname%% *} "
          continue
          ;;
        '-A'*)
          # Catch a jump to a chain that does not exist. A missing target is
          # the mistake most likely to be introduced by hand-editing, and
          # without this the fragment is accepted wholesale.
          declared_target=""
          read -r -a _words <<<"$line"
          local w prev=""
          for w in "${_words[@]}"; do
            if [[ $prev == "-j" ]]; then
              declared_target="$w"
              break
            fi
            prev="$w"
          done
          if [[ -n $declared_target && $declared_target != *!* &&
                $declared != *" ${declared_target} "* ]]; then
            bad+="jump to undeclared chain: ${declared_target}"$'\n'
          fi
          continue
          ;;
        *) bad+="$line"$'\n' ;;
      esac
    done <"$tmp"
    if [[ -n $bad ]]; then
      warn "the DOCKER-USER rules contain lines iptables would not accept:"
      while read -r l; do
        [[ -n $l ]] && warn "  ${l}"
      done <<<"$bad"
      rm -f "$tmp"
      return 1
    fi
    # Unverified, not verified. The fragment is syntactically plausible but
    # has not been through iptables, because iptables needs root.
    note "could not run iptables-restore --test without root; the rules are unverified"
    rm -f "$tmp"
    return 2
  fi

  rm -f "$tmp"
  return $rc
}

install_docker_ufw_rules() {
  if ((DRY_RUN)); then
    printf '  %s•%s would write the DOCKER-USER rules to /etc/ufw/after.rules (and after6.rules if IPv6 is enabled)\n' "$C_DIM" "$C_OFF"
    return 0
  fi

  local subnets block
  block="$(mktemp)"
  subnets="$(docker_subnets | sort -u)"

  {
    printf '%s\n' "$DOCKER_UFW_BEGIN"
    cat <<'EOF'
# Managed by oma-pi omapi-harden.sh. Rules from chaifeng/ufw-docker.
#
# Without these, Docker's own DNAT/ACCEPT rules sit ahead of ufw's and a
# published port is reachable from the internet regardless of ufw.
# With them, published container ports are blocked by default and are opened
# only by an explicit `ufw route allow` rule.
#
# This block must stay at the END of this file: ufw feeds the whole file to
# iptables-restore as a single ruleset, and a *filter table that COMMITs
# before ufw's own rules would leave those rules outside any table.
*filter
:ufw-user-forward - [0:0]
:ufw-docker-logging-deny - [0:0]
:DOCKER-USER - [0:0]
# Jump to ufw's own forward rules first: this is where `ufw route allow`
# lands, so an approved port is matched before anything below drops it.
-A DOCKER-USER -j ufw-user-forward
-A DOCKER-USER -m conntrack --ctstate RELATED,ESTABLISHED -j RETURN
-A DOCKER-USER -m conntrack --ctstate INVALID -j DROP
-A DOCKER-USER -i docker0 -o docker0 -j ACCEPT
EOF
    # RETURN for traffic coming FROM a private network (internal hosts reaching
    # a container), and a logged DROP for NEW connections going TO one (the
    # public internet reaching a published port, after DNAT has rewritten the
    # destination to the container address). No indentation, because the
    # extractor that validates this block must not depend on it.
    local s
    while read -r s; do
      [[ -n $s ]] || continue
      printf -- '-A DOCKER-USER -j RETURN -s %s\n' "$s"
    done <<<"$subnets"
    while read -r s; do
      [[ -n $s ]] || continue
      printf -- '-A DOCKER-USER -j ufw-docker-logging-deny -m conntrack --ctstate NEW -d %s\n' "$s"
    done <<<"$subnets"
    cat <<'EOF'

-A DOCKER-USER -j RETURN
-A ufw-docker-logging-deny -m limit --limit 3/min --limit-burst 10 -j LOG --log-prefix "[UFW DOCKER BLOCK] "
-A ufw-docker-logging-deny -j DROP

COMMIT
EOF
    printf '%s\n' "$DOCKER_UFW_END"
  } >"$block"

  # Replace, not append blindly: a second copy of the chain declarations would
  # make ufw fail to restore entirely. Placed at the bottom, matching upstream.
  replace_managed_block "$block" /etc/ufw/after.rules \
    "$DOCKER_UFW_BEGIN" "$DOCKER_UFW_END" bottom
  ok "DOCKER-USER rules written to /etc/ufw/after.rules"

  # ufw has two rule files: after.rules for IPv4 and after6.rules for IPv6.
  # Leaving after6.rules alone means an IPv6 client can reach a published port
  # that the IPv4 rules just closed - the same bypass, through the other door.
  install_docker_ufw6_rules "$subnets"

  rm -f "$block"
  note "published container ports are now blocked until a 'ufw route allow' rule permits them"
}

# The IPv6 twin. Only written when ufw actually has IPv6 enabled, because
# writing to after6.rules on a host with no IPv6 ruleset would make ufw fail
# to restore - with no firewall at all, which is the failure mode this whole
# block of code exists to avoid.
install_docker_ufw6_rules() {
  local subnets="$1"
  local ufw_default="${CONF_DEST}/etc/default/ufw"
  local after6="${CONF_DEST}/etc/ufw/after6.rules"

  # Read through CONF_DEST so this is testable against a temporary tree rather
  # than the live host's /etc.
  [[ -r $ufw_default ]] || return 0
  grep -qE '^IPV6=yes' "$ufw_default" 2>/dev/null || return 0
  [[ -f $after6 ]] || return 0
  have docker || return 0

  # Docker network subnets, IPv6 only. The v6 tailnet and ULA ranges are
  # included so a published port is not reachable from the local network either.
  local v6 subnets6="" s
  v6="$(docker network ls -q 2>/dev/null | while read -r n; do
    docker network inspect "$n" --format \
      '{{range .IPAM.Config}}{{.Subnet}} {{end}}' 2>/dev/null
  done | tr ' ' '\n' | grep -iE '^[0-9a-f]+:[0-9a-f:]+/[0-9]+$' || true)"
  subnets6="fd00::/8 fd7a:115c:a1e0::/48"
  subnets6+=" ${v6// /$' '}"

  local block; block="$(mktemp)"
  {
    printf '%s\n' "$DOCKER_UFW_BEGIN"
    cat <<'EOF'
# Managed by oma-pi omapi-harden.sh. IPv6 twin of the after.rules block.
*filter
:ufw6-user-forward - [0:0]
:ufw6-docker-logging-deny - [0:0]
:DOCKER-USER - [0:0]
-A DOCKER-USER -j ufw6-user-forward
-A DOCKER-USER -m conntrack --ctstate RELATED,ESTABLISHED -j RETURN
-A DOCKER-USER -m conntrack --ctstate INVALID -j DROP
-A DOCKER-USER -i docker0 -o docker0 -j ACCEPT
EOF
    while read -r s; do
      [[ -n $s ]] || continue
      printf -- '-A DOCKER-USER -j RETURN -s %s\n' "$s"
    done <<<"$(printf '%s\n' $subnets6 | sort -u)"
    while read -r s; do
      [[ -n $s ]] || continue
      printf -- '-A DOCKER-USER -j ufw6-docker-logging-deny -m conntrack --ctstate NEW -d %s\n' "$s"
    done <<<"$(printf '%s\n' $subnets6 | sort -u)"
    cat <<'EOF'

-A DOCKER-USER -j RETURN
-A ufw6-docker-logging-deny -m limit --limit 3/min --limit-burst 10 -j LOG --log-prefix "[UFW DOCKER BLOCK] "
-A ufw6-docker-logging-deny -j DROP

COMMIT
EOF
    printf '%s\n' "$DOCKER_UFW_END"
  } >"$block"

  replace_managed_block "$block" /etc/ufw/after6.rules \
    "$DOCKER_UFW_BEGIN" "$DOCKER_UFW_END" bottom
  rm -f "$block"
  ok "DOCKER-USER rules written to /etc/ufw/after6.rules (IPv6)"
}

# Docker's published ports are owned by docker-proxy, not by your container,
# and `ss -p` cannot attribute them to a name without a `docker ps` lookup.
# This box runs a proxy publishing 80/443, so the question "do you run a
# service here?" has to be answerable for them.
docker_published_by() {
  local port="$1" out
  have docker || return 0
  out="$(docker ps --format '{{.Names}}|{{.Ports}}' 2>/dev/null || true)"
  [[ -n $out ]] || return 0
  printf '%s\n' "$out" | awk -F'|' -v p=":$port" -v proto="$2" '
    $2 ~ p"(->|$)" || $2 ~ p"/" {
      name = $1
      # Confirm the protocol matches so a tcp/80 prompt is not answered for a
      # udp/80 socket.
      if (proto != "" && $2 !~ proto) next
      print "docker: " name
      exit
    }'
}

configure_firewall() {
  section "Firewall (ufw)"

  if ! have ufw && ((!DRY_RUN)); then
    warn "ufw is not installed, skipping (packages task installs it)"
    return 0
  fi

  # The SSH port is resolved BEFORE any policy change, and its failure guard
  # returns before the first `ufw` command runs. This guard used to sit after
  # `ufw default deny incoming`, so on a box where ufw was already active the
  # script flipped the incoming policy to deny and then bailed out - never
  # adding the `ufw limit` rule for the SSH port. If that box relied on the
  # broad allow policy, every new SSH connection was blocked while the script
  # reported "not touching the firewall".
  local ssh_port
  ssh_port="$(current_ssh_port || true)"
  # Stop rather than guess. A `ufw limit /tcp` with an empty port is silently
  # malformed, and carrying on to default-deny would close the port the user is
  # connected on. This is the one place in the script where not knowing the
  # answer must mean doing nothing.
  if [[ -z $ssh_port ]]; then
    warn "cannot determine which port sshd is on; not touching the firewall"
    note "sshd -T and ss both came back empty, so the port cannot be trusted"
    note "run 'sudo sshd -T | grep ^port' to see it, then re-run this task"
    return 1
  fi

  if ((DRY_RUN)); then
    note "would set: ufw default deny incoming / allow outgoing, logging on"
  else
    run_root ufw default deny incoming
    run_root ufw default allow outgoing
    run_root ufw logging on
    ok "default policies set (incoming denied, outgoing allowed, logging on)"
  fi

  if ((DRY_RUN)); then
    printf '  %s•%s would allow: ufw limit %s/tcp\n' "$C_DIM" "$C_OFF" "$ssh_port"
  else
    run_root ufw limit "$ssh_port/tcp"
    ok "ssh rate-limited on port ${ssh_port}"
  fi

  # Tailscale's interface is not a public interface, but ufw still counts
  # packets arriving on it, and losing the tailnet would lose the way back in.
  if [[ -d /sys/class/net/tailscale0 ]] || (peek tailscale status &>/dev/null); then
    if ((DRY_RUN)); then
      printf '  %s•%s would allow: ufw allow in on tailscale0\n' "$C_DIM" "$C_OFF"
    elif ask "allow traffic arriving on the tailscale0 interface?" y; then
      run_root ufw allow in on tailscale0 comment "omapi: tailscale"
      ok "tailscale0 allowed"
    else
      warn "tailnet traffic will be dropped by ufw"
    fi
  fi

  # Everything else that is listening on a routable address gets an explicit
  # decision, one port at a time, so nothing is opened by omission.
  #
  # Unidentified ports are still offered, and this is deliberate. Silently
  # skipping a port whose process you cannot see would deny it, and denying a
  # port someone is actually running is a broken service discovered later,
  # well after the hardening run that caused it. A prompt you can answer no
  # to costs one keystroke; a silently closed proxy costs an afternoon.
  local proto port owner
  # Default IFS, deliberately. `IFS= read -r proto port` looks tidier but it
  # disables word splitting entirely, so the whole "tcp 80" line lands in
  # $proto and $port stays empty - every iteration then failed the
  # `[[ -n $port ]]` guard and silently continued, so the script offered to
  # open no ports at all and closed them all by omission. Reading on fd 3 is
  # what matters here: it keeps stdin free for ask.
  while read -r proto port <&3; do
    [[ -n $proto && -n $port ]] || continue
    [[ $port == "$ssh_port" ]] && continue
    owner="$(listening_process "$proto" "$port")"
    if [[ $owner == unknown || $owner == "need root" ]]; then
      owner="$(docker_published_by "$port" "$proto" || true)"
      [[ -n $owner ]] || owner="unidentified (needs root to see the owner)"
    fi
    # A port a container is deliberately publishing defaults to yes. A
    # published port exists because something out there depends on it, and
    # defaulting to no here would break a working service the first time
    # someone runs a hardening script on a box they serve traffic from.
    # Anything we could not attribute still defaults to no.
    local default="n"
    [[ $owner == docker:* ]] && default="y"
    if ask "allow ${proto}/${port}?${owner:+  owner: ${owner}}" "$default"; then
      if ((DRY_RUN)); then
        printf '  %s•%s would allow: ufw allow %s/%s\n' "$C_DIM" "$C_OFF" "$port" "$proto"
      else
        run_root ufw allow "$port/$proto" comment "omapi: $(listening_process "$proto" "$port" || true)"
        ok "allowed ${proto}/${port}"
      fi
    else
      skip "left ${proto}/${port} closed"
    fi
  done 3< <(listening_ports)

  if docker_present; then
    warn "Docker's published ports bypass ufw: Docker writes its own DNAT and"
    note "ACCEPT rules ahead of ufw's, so 'ufw deny 8080' does not stop a"
    note "published port. Fixing that now with the DOCKER-USER chain."
  fi

  # If the tailnet is the only way in, port 22 can go away entirely. This is
  # the network-level half of the VPN advice in the guides, and it is the one
  # step that can end a session, so it is opt-in and loud.
  if [[ -d /sys/class/net/tailscale0 ]] && ask "close port ${ssh_port} completely (Tailscale SSH only)?" n; then
    if ((DRY_RUN)); then
      printf '  %s•%s would deny: ufw deny %s/tcp\n' "$C_DIM" "$C_OFF" "$ssh_port"
    else
      # `delete limit`, not `delete allow`: the rule added above is a
      # `ufw limit` one, so `delete allow` matches nothing and leaves it in
      # place. The `|| true` hid that, and a stale limit rule reappears the
      # moment the deny is ever removed. Delete both forms so a box that
      # predates this script is handled too.
      run_root ufw delete limit "$ssh_port/tcp" || true
      run_root ufw delete allow "$ssh_port/tcp" || true
      run_root ufw deny "$ssh_port/tcp" comment "omapi: ssh over tailscale only"
      warn "port ${ssh_port} is now denied - make sure a tailscale session works"
    fi
  fi

  configure_docker_ufw

  if ((DRY_RUN)); then
    note "would enable: ufw enable"
    return 0
  fi
  run_root ufw enable
  ok "ufw enabled"
  note "$(ufw status 2>/dev/null | head -1 || true)"
}

# Make ufw actually govern Docker's published ports.
#
# Order matters here. The DOCKER-USER rules are installed and ufw reloaded
# FIRST, which closes every published port by default. Only then is each
# published port offered to the user. Doing it the other way round would mean
# writing `ufw route allow` rules against a chain that is not installed yet,
# and the reload that activates them is what closes the ports.
#
# Top level rather than nested inside configure_docker_ufw so the test suite
# can reach these; a function defined inside another function is not callable
# from anywhere else.
#
# Two functions, and they have to stay two. docker_published_pairs only emits
# rows; docker_offer_published_ports only consumes them. Folding the loop back
# into the producer put `done 3< <(docker_published_pairs)` inside
# docker_published_pairs, so every call re-entered itself through a process
# substitution and forked until the machine ran out of process slots - the
# prompt loop was only ever reachable via that recursion, which also means
# configure_docker_ufw had no way left to call it.
#
# Every published (container name, container port, protocol) triple,
# de-duplicated.
#
# The protocol is carried because `sort -u` on (name, port) alone collapses a
# tcp and a udp publication of the same port into one entry, and the only rule
# ever emitted is `ufw route allow proto tcp`. A published UDP port - a DNS or
# WireGuard container - therefore could never be opened and stayed blocked
# with no way to reopen it from the prompt.
docker_published_pairs() {
  local n p entry cport proto
  docker ps --format '{{.Names}}|{{.Ports}}' 2>/dev/null |
    while IFS='|' read -r n p; do
      [[ -n $n && -n $p ]] || continue
      while IFS= read -r entry; do
        entry="${entry// /}"
        if [[ $entry != *"->"* ]]; then
          continue
        fi
        cport="${entry##*->}"
        # ...->80/tcp: split the protocol off, defaulting to tcp for the
        # forms docker omits it on.
        if [[ $cport == */* ]]; then
          proto="${cport#*/}"
          cport="${cport%%/*}"
        else
          proto="tcp"
        fi
        if [[ -n $cport ]]; then
          printf '%s %s %s\n' "$n" "$cport" "$proto"
        fi
      done < <(printf '%s\n' "$p" | tr ',' '\n')
    done | sort -u
}

# Offer each published port for opening, after the chain is in place.
#
# fd 3 rather than stdin, as in the original: `docker ps` and `ask` both read,
# and reading the pair list from stdin lets one of them swallow it, which
# silently drops every port and the prompts never appear.
docker_offer_published_ports() {
  local name cport proto
  while read -r name cport proto <&3; do
    [[ -n $name && -n $cport ]] || continue
    # A tcp and a udp publication of the same port are separate rules, and the
    # loopback test is per protocol: a container published on 127.0.0.1 for tcp
    # and 0.0.0.0 for udp is still publicly reachable over udp.
    if docker_port_is_loopback_only "$cport" "$proto"; then
      ok "${name}: ${cport}/${proto} is published on loopback only, unreachable from the network"
      continue
    fi
    if ask "allow the internet to reach ${name} on container port ${cport}/${proto}? (needed for 0.0.0.0:${cport} and [::]:${cport})" n; then
      if ((DRY_RUN)); then
        printf '  %s•%s would run: ufw route allow proto %s from any to any port %s\n' \
          "$C_DIM" "$C_OFF" "$proto" "$cport"
      else
        run_root ufw route allow proto "$proto" from any to any port "$cport" \
          comment "omapi: ${name}" || warn "could not add a route rule for ${name}:${cport}/${proto}"
        ok "${name}: container port ${cport}/${proto} reachable from the network"
      fi
    else
      warn "${name} publishes ${cport}/${proto} on all interfaces and is now BLOCKED"
      note "if something should reach it: sudo ufw route allow proto ${proto} from any to any port ${cport}"
      note "or publish it on loopback only: -p 127.0.0.1:${cport}:${cport}/${proto}"
    fi
  done 3< <(docker_published_pairs)
}

configure_docker_ufw() {
  if ! docker_present; then
    return 0
  fi
  if ! have ufw; then
    warn "Docker is running but ufw is not installed; cannot make ufw govern container ports"
    note "bound what you publish to loopback instead: -p 127.0.0.1:PORT:PORT"
    return 0
  fi

  # Snapshot BEFORE anything is written. Taking it after the install would
  # back up the file we are trying to protect against, so a failed reload
  # would "restore" the broken rules and leave ufw just as dead.
  local rules_backup=""
  if ((!DRY_RUN)) && [[ -f ${CONF_DEST}/etc/ufw/after.rules ]]; then
    rules_backup="$(mktemp)"
    cp -p "${CONF_DEST}/etc/ufw/after.rules" "$rules_backup" || rules_backup=""
  fi

  # Restoring puts the pre-change file back and reloads, so it is used both
  # when the fragment is malformed and when the reload itself fails.
  restore_rules() {
    if [[ -n $rules_backup ]]; then
      run_root cp -p "$rules_backup" "${CONF_DEST}/etc/ufw/after.rules" || warn "could not restore after.rules from the backup; ufw may fail to reload"
    fi
    rm -f "$rules_backup"
    rules_backup=""
  }

  # Checked through CONF_DEST so this works against a temporary tree, and so
  # OMAPI_SECURITY_DESTDIR cannot make the script inspect the real /etc.
  if docker_ufw_installed; then
    ok "DOCKER-USER rules already present in ${CONF_DEST}/etc/ufw/after.rules"
    # The v6 half is installed separately and independently. Skipping it just
    # because the v4 block is present means enabling IPV6=yes after a run
    # never gets an after6.rules block, and IPv6 clients reach published
    # ports through the gap. install_docker_ufw6_rules is idempotent and
    # checks its own preconditions.
    if ((!DRY_RUN)) && grep -qE '^IPV6=yes' "${CONF_DEST}/etc/default/ufw" 2>/dev/null; then
      install_docker_ufw6_rules "$(docker_subnets | sort -u)"
    fi
  else
    install_docker_ufw_rules
  fi

  if ((DRY_RUN)); then
    note "would validate the rules, then run: ufw reload"
  else
    # Three outcomes, not two: verified, malformed, and - when not running as
    # root - unverified, because iptables-restore needs privilege even for
    # --test. Only a malformed fragment blocks the reload. An unverified one
    # is the normal case for `omapi-harden.sh` run as a normal user, and refusing
    # to configure Docker at all there would be worse than proceeding with a
    # loud warning; a real run of this script is `sudo ./omapi-harden.sh`.
    local vrc=0
    validate_docker_ufw_rules "${CONF_DEST}/etc/ufw/after.rules" || vrc=$?
    case $vrc in
      0)
        ok "DOCKER-USER rules validated by iptables-restore"
        ;;
      1)
        # Restore here too. Leaving a fragment we have just called malformed on
        # disk means the next `ufw reload` by anything - including ufw's own
        # boot-time restore - trips over it, and the user gets no firewall.
        warn "the DOCKER-USER rules are malformed; not reloading ufw"
        restore_rules
        note "the previous /etc/ufw/after.rules has been restored"
        return 1
        ;;
      *)
        warn "the DOCKER-USER rules could not be validated without root"
        note "if ufw reload fails afterwards, run: sudo ufw-docker check"
        ;;
    esac

    if run_root ufw reload; then
      ok "ufw reloaded with the DOCKER-USER chain in place"
      rm -f "$rules_backup"
    else
      warn "ufw reload failed; restoring the previous rules and reloading again"
      restore_rules
      run_root ufw reload || warn "ufw is still not reloading - check 'ufw status' and the journal"
      return 1
    fi
  fi

  # Last, and only once the chain exists: every published port is closed by
  # the rules installed above, so this is what offers each one back. Skipping
  # it leaves a working container dark with no explanation anywhere.
  docker_offer_published_ports
}

listening_process() {
  local proto="$1" port="$2" pid name
  # `ss -p` only shows processes you are allowed to see, so on a system with
  # services owned by other users (docker, tailscaled, avahi) this comes back
  # empty for a socket that is genuinely listening. That is a different answer
  # from "no such service", and the firewall step needs to tell them apart.
  if have ss; then
    pid="$(ss -H -tulnp "sport = :${port}" 2>/dev/null |
      grep -oE 'pid=[0-9]+' | head -1 | cut -d= -f2 || true)"
    if [[ -z $pid ]] && [[ $(id -u) -ne 0 ]] && ! sudo -n true &>/dev/null; then
      printf 'need root'
      return 0
    fi
  fi
  if [[ -n $pid ]]; then
    name="$(peek ps -o comm= -p "$pid" 2>/dev/null | tr -d ' ' || true)"
    if [[ -n $name ]]; then
      printf '%s' "$name"
      return 0
    fi
  fi
  printf 'unknown'
}

# ---------------------------------------------------------------------------
# fail2ban
# ---------------------------------------------------------------------------
configure_fail2ban() {
  section "fail2ban"

  if ! have fail2ban-server && ((!DRY_RUN)); then
    warn "fail2ban is not installed, skipping (packages task installs it)"
    return 0
  fi

  local ssh_port
  ssh_port="$(current_ssh_port || true)"
  if [[ -z $ssh_port ]]; then
    warn "cannot determine which port sshd is on; skipping fail2ban setup"
    note "a jail with an empty port would ban nothing and look configured"
    return 1
  fi

  # ufw ships an action in fail2ban; without it a ban would be written to an
  # iptables chain ufw does not read, which looks configured and bans nothing.
  local banaction="iptables-multiport"
  if [[ -f /etc/fail2ban/action.d/ufw.conf ]] && ufw status 2>/dev/null | grep -q "Status: active"; then
    banaction="ufw"
  fi

  local jail="/etc/fail2ban/jail.d/omapi-hardening.local"
  # Snapshot the real file BEFORE write_conf truncates it, so a rejected jail
  # can be rolled back. Claiming "leaving the previous config in place" while
  # the overwrite has already happened is how a broken file ends up breaking
  # the next fail2ban start.
  local prev="" had_prev=0
  if ((!DRY_RUN)) && [[ -f $jail ]]; then
    prev="$(mktemp)"
    cp -p "$jail" "$prev" && had_prev=1
  fi

  write_conf "$jail" <<EOF
# Managed by oma-pi omapi-harden.sh. Re-run the script to change these.
[DEFAULT]
usedns = no
banaction = ${banaction}
bantime = 1h
findtime = 10m
maxretry = 5
# 100.64.0.0/10 is the tailnet range: a bug or a fat finger over Tailscale
# should not get your own devices banned.
ignoreip = 127.0.0.1/8 ::1 100.64.0.0/10

[sshd]
enabled = true
backend = systemd
port = ${ssh_port}
maxretry = 3
bantime = 12h

# Repeat offenders, across every jail, get a week.
[recidive]
enabled = true
port = all
findtime = 1d
bantime = 1w
EOF

  if ((DRY_RUN)); then
    note "would enable and start fail2ban, then run: fail2ban-client -t"
    [[ -n $prev ]] && rm -f "$prev"
    return 0
  fi

  # Capture the rejection output. It used to go to /dev/null, and the
  # "show the error" line below re-ran `fail2ban-client -t` AFTER the rollback -
  # so it validated the restored config, printed nothing, and the user never
  # saw the error explaining what was wrong with the jail they needed to fix.
  local f2b_err=""
  if ! f2b_err="$(peek fail2ban-client -t 2>&1)"; then
    warn "fail2ban rejected the jail file, rolling ${jail} back"
    if ((had_prev)); then
      peek cp -p "$prev" "$jail" || true
      ok "previous jail file restored"
    else
      # There was no previous file, so the correct rollback is to remove the
      # one we just wrote rather than leave fail2ban unable to start.
      rm -f "$jail"
      ok "no previous jail file existed, removed the rejected one"
    fi
    rm -f "$prev"
    # Show the error from the run that actually failed, not a fresh -t against
    # the restored config - which validates fine and tells the user nothing.
    if [[ -n ${f2b_err//[[:space:]]/} ]]; then
      note "fail2ban said:"
      printf '%s\n' "$f2b_err" | tail -5 | sed 's/^/  /'
    fi
    return 1
  fi
  [[ -n $prev ]] && rm -f "$prev"
  ok "fail2ban config accepted (banaction ${banaction})"

  run_root systemctl enable --now fail2ban
  ok "fail2ban running"
  note "$(peek fail2ban-client status sshd 2>/dev/null | grep -i "currently banned" || true)"
}

# ---------------------------------------------------------------------------
# updates
# ---------------------------------------------------------------------------

# `origin:suite` for the first `apt-cache policy` release line belonging to a
# repo whose Packages URLs contain $1, or nothing on stdout.
#
# Kept separate from configure_updates so the parsing can be tested against
# known-good input instead of only against whatever this host happens to have
# configured.
apt_release_line_for() {
  local needle="$1"
  peek apt-cache policy 2>/dev/null | awk -v needle="$needle" '
    index($0, needle) && $1 ~ /^(500|deb)$/ {w=1; next}
    w && /^[[:space:]]+release[[:space:]]/ {print; exit}'
}

# "origin:suite" from an `apt-cache policy` release line. Returns 1 if either
# half is missing rather than emitting a half-formed entry, because a partial
# value in Allowed-Origins matches nothing while looking entirely reasonable.
#
# The Origin is "Raspberry Pi Foundation" - it contains spaces, so the value
# runs to the next comma and cannot be recovered by splitting on whitespace,
# which is the version that silently yielded "Raspberry" and matched nothing.
apt_release_origin_combo() {
  local release="${1:-}" origin suite
  [[ -n $release ]] || return 1
  origin="$(sed -n 's/.*[, ]o=\([^,]*\).*/\1/p' <<<"$release")"
  suite="$(sed -n 's/.*[, ]n=\([^,]*\).*/\1/p' <<<"$release")"
  [[ -n $origin && -n $suite ]] || return 1
  printf '%s:%s\n' "$origin" "$suite"
}

# Kernel images in $1 (default /boot) that no package owns, space separated.
# Empty when every image is tracked, which is the normal case, or when there
# is no boot directory to look at.
#
# Scoped to kernel images on purpose. A Pi's /boot also holds cmdline.txt,
# config.txt, overlays and the initrd.img-*, and the Pi initramfs is generated
# on-device rather than shipped by any package, so every one of those is
# untracked by design. Checking the whole directory would report all of them
# on every single machine, and an audit that always has something to complain
# about is an audit nobody reads.
untracked_kernels() {
  # dpkg -S only reads the package database. Called without peek's sudo
  # fallback on purpose: an audit must never be able to stop on a password
  # prompt, and this needs no privilege anyway.
  have dpkg || return 0
  local dir="${1:-/boot}" f out=""
  [[ -d $dir ]] || return 0
  for f in "$dir"/vmlinuz-* "$dir"/Image-* "$dir"/zImage-* "$dir"/vmlinux-*; do
    [[ -f $f || -L $f ]] || continue
    dpkg -S "$f" >/dev/null 2>&1 || out+="${f##*/} "
  done
  printf '%s' "$out"
}

# Package owning the kernel image for a given uname -r, or nothing. A box
# that booted from somewhere other than the image named here - a netboot, an
# initramfs that moved the real root, a container - has no answer, and
# reporting "not tracked" for those would be a false alarm.
running_kernel_owner() {
  local rel="${1:-$(uname -r)}" img="/boot/vmlinuz-${1:-$(uname -r)}"
  [[ -f $img || -L $img ]] || return 1
  dpkg -S "$img" 2>/dev/null | cut -d: -f1
}

# Package names apt is holding back, one per line, or nothing on stdout.
#
# `apt upgrade` never installs a brand-new package, so an update that pulls in
# a dependency which is not installed yet is deferred to `apt full-upgrade` -
# and then never happens. Nothing errors, no timer notices, and the box reads
# as fully patched. rpi-eeprom 28.13 -> 28.31 wanted a Recommends that no
# configured repo carries and sat there indefinitely. A simulated upgrade is
# the only way to see this without changing anything, hence -s.
held_back_packages() {
  peek apt-get -s upgrade 2>/dev/null | awk '
    /^The following packages have been kept back:/ {f=1; next}
    f && /^[[:space:]]+[^[:space:]]/ {print $1}
    f && !/^[[:space:]]/ {exit}'
}

configure_updates() {
  section "Automatic security updates"

  if ! have unattended-upgrade && ((!DRY_RUN)); then
    warn "unattended-upgrades is not installed, skipping (packages task installs it)"
    return 0
  fi

  # The suite name is not guessable: it is whatever this image ships, and a
  # wrong Allowed-Origins entry means unattended-upgrades quietly matches
  # nothing and still reports success.
  local id="" codename="" field
  if [[ -r /etc/os-release ]]; then
    while IFS='=' read -r field value; do
      case "$field" in
        ID) id="${value%\"}"; id="${id#\"}" ;;
        VERSION_CODENAME) codename="${value%\"}"; codename="${codename#\"}" ;;
      esac
    done <"/etc/os-release"
  fi

  if [[ -z $codename ]]; then
    warn "could not read VERSION_CODENAME from /etc/os-release, skipping"
    return 0
  fi

  # Ubuntu publishes -updates as well as -security; Debian derivatives
  # generally only carry the security suite.
  local origins=(
    "\"${id}:${codename}-security\""
  )
  if [[ $id == ubuntu || $id == linuxmint || $id == pop ]]; then
    origins+=("\"${id}:${codename}-updates\"")
  fi

  # On a Pi the kernel, the bootloader and the EEPROM are not Debian packages.
  # They come from archive.raspberrypi.com, whose Origin is "Raspberry Pi
  # Foundation" and which publishes no -security suite at all - its dists/ are
  # bookworm, trixie, forky and the fixes go out on the main branch. So
  # `id:codename-security` above matches nothing for any RPi package and
  # unattended-upgrades leaves linux-image-*, rpi-eeprom and raspi-firmware on
  # whatever version they were installed at, indefinitely, with no warning.
  # That is the gap that leaves `apt list --upgradable` sitting on rpi-eeprom
  # forever while every check in this function reports success.
  #
  # Only the RPi archive is added. The docker, charm, tailscale, github-cli and
  # gierens repos in sources.list.d are deliberately left out: auto-upgrading
  # those unattended is how you take down a working stack at 3am, and they are
  # not where this box's kernel-level exposure lives.
  if grep -rqs 'archive\.raspberrypi\.com' \
    /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null; then
    local rpi_combo
    # `|| rpi_combo=""` matters: without root, and with stdin not a tty, peek
    # cannot run, the inner substitution returns non-zero, and under set -e
    # this line aborts the whole task. Reproduced as
    # `./omapi-harden.sh --dry-run updates` exiting 1 on the section header.
    rpi_combo="$(apt_release_origin_combo "$(apt_release_line_for archive.raspberrypi.com)" || true)" || rpi_combo=""
    if [[ -n $rpi_combo ]]; then
      origins+=("\"${rpi_combo}\"")
    else
      warn "Raspberry Pi archive is configured but its Origin/Suite could not be read;"
      warn "RPi kernel, bootloader and EEPROM will not be auto-updated"
    fi
  fi

  # Built with a plain newline rather than the heredoc below so no colour
  # escape can end up inside an apt config file. These strings go straight to
  # disk and are read by apt, not a terminal.
  local origin_block="" o
  for o in "${origins[@]}"; do
    origin_block+="        ${o};
"
  done

  # 20auto-upgrades is the file `dpkg-reconfigure unattended-upgrades`
  # manages, and on Debian it holds the two APT::Periodic keys that actually
  # switch unattended-upgrades on. Overwriting it with only an Allowed-Origins
  # block turned automatic security updates off while every check in this
  # function still reported success - the worst possible failure for a
  # hardening script, because it is silent. So: the Periodic keys go here, and
  # the policy goes in the script's own file.
  write_conf /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
// Managed by oma-pi omapi-harden.sh. Re-run the script to change these.
// These two keys are what actually enable unattended-upgrades. Without them
// apt.systemd.daily defaults to 0 and no security patch is ever applied.
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

  write_conf /etc/apt/apt.conf.d/51omapi-origins <<EOF
// Managed by oma-pi omapi-harden.sh. Re-run the script to change these.
Unattended-Upgrade::Allowed-Origins {
${origin_block}};

Unattended-Upgrade::Package-Blacklist {
        // Held back on purpose, do not remove without a reason.
};

Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Acquire::Retries "3";
EOF

  write_conf /etc/apt/apt.conf.d/52omapi-unattended-upgrades <<'EOF'
// Managed by oma-pi omapi-harden.sh. Re-run the script to change these.
// No Automatic-Reboot: this box runs containers and serves a tailnet, and an
// unattended reboot in the middle of a task is a worse outcome than a patch
// that waits for the next maintenance window. Set it to "true" here if the
// machine is disposable.
Unattended-Upgrade::Mail "root";
Unattended-Upgrade::MailOnlyOnError "true";
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Remove-New-Unused-Dependencies "true";
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::SyslogEnable "true";
Acquire::Retries "3";
EOF

  # Worth saying out loud: if the security suite is not in the sources, the
  # config above is correct and still installs nothing.
  if ! grep -rqE "${codename}-security" /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null; then
    warn "no ${codename}-security suite in the apt sources; updates will not match anything"
  fi

  if ((DRY_RUN)); then
    note "would verify with: apt-config dump | grep Unattended-Upgrade"
    return 0
  fi

  if ! run_root systemctl enable --now unattended-upgrades 2>/dev/null; then
    # Not swallowed: the check below reads apt-config and would otherwise
    # report "configured" while the service is disabled, which is precisely
    # the silent-failure class the rest of this script exists to prevent.
    warn "could not enable unattended-upgrades; automatic security updates are NOT active"
  fi
  if peek apt-config dump | grep -q Unattended-Upgrade; then
    ok "unattended-upgrades configured for ${origins[*]}"
  else
    warn "apt did not pick up the unattended-upgrades configuration"
  fi

  # Say it out loud when apt is holding something back. See
  # held_back_packages: this is a silent-failure class that nothing else in
  # this script would ever surface, and naming the packages is the whole fix
  # - it is a five second apt full-upgrade once somebody knows.
  local kept_back
  kept_back="$(held_back_packages)"
  if [[ -n $kept_back ]]; then
    warn "apt upgrade is holding back: ${kept_back//$'\n'/ }"
    note "these need a new dependency; unattended-upgrades will not install them:"
    note "  sudo apt full-upgrade"
  fi

  note "$(peek systemctl list-timers apt-daily.timer apt-daily-upgrade.timer --no-pager 2>/dev/null |
    head -3 | tail -2 | tr -s ' ' | cut -d' ' -f2-5 | tr '\n' '|' || true)"
}

# ---------------------------------------------------------------------------
# apparmor
# ---------------------------------------------------------------------------
configure_apparmor() {
  section "AppArmor"

  if ! have aa-status && ((!DRY_RUN)); then
    warn "apparmor-utils is not installed, skipping (packages task installs it)"
    return 0
  fi

  run_root systemctl enable apparmor
  run_root systemctl start apparmor

  if ((DRY_RUN)); then
    note "would report: aa-status --json summary"
    return 0
  fi

  local enforced complain
  enforced="$(peek aa-status 2>/dev/null | awk '/profiles are in enforce mode/{print $1}' || true)"
  complain="$(peek aa-status 2>/dev/null | awk '/profiles are in complain mode/{print $1}' || true)"
  ok "apparmor enabled (${enforced:-?} enforced, ${complain:-?} complaining)"
  if [[ ${complain:-0} != 0 && ${complain:-} != "0" ]]; then
    note "complaining profiles are noise in the logs until you decide they are fine:"
    note "  sudo aa-complain /etc/apparmor.d/<profile>   # or aa-enforce to lock it down"
  fi
}

# ---------------------------------------------------------------------------
# sysctl + journald
# ---------------------------------------------------------------------------
configure_sysctl() {
  section "Kernel and network sysctls"

  local docker_note=""
  if docker_present; then
    docker_note=$'\n# net.ipv4.ip_forward is left at the Docker default on purpose: the\n# installer puts Docker on this box and its bridge needs forwarding.\n# Forcing it to 0 breaks container networking silently.'
  else
    docker_note=$'\nnet.ipv4.ip_forward = 0'
  fi

  write_conf /etc/sysctl.d/99-omapi-hardening.conf <<EOF
# Managed by oma-pi omapi-harden.sh. Re-run the script to change these.
# Network redirects and source routes are off: a Pi is normally a plain
# endpoint on one LAN, and none of these have a use here.
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.conf.all.accept_local = 0
net.ipv4.conf.default.accept_local = 0
net.ipv4.conf.all.log_martians = 1
# Reverse path filtering. Tailscale sets its own interface to loose mode
# (2) and the kernel takes the max of this and the per-interface value, so
# the tailnet still works. If this box is multi-homed across subnets and
# traffic disappears after this runs, set the two rp_filter lines to 2.
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
# SYN cookies: no cost, and it is the difference between a queue staying up
# and not during a flood.
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_rfc1337 = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_source_route = 0${docker_note}
# Kernel and filesystem.
kernel.randomize_va_space = 2
kernel.dmesg_restrict = 1
kernel.kptr_restrict = 2
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
fs.protected_fifos = 2
fs.protected_regular = 1
fs.suid_dumpable = 0
EOF

  # An SD card fills up, and then the box stops logging, stops patching and
  # starts failing in ways that look like hardware faults.
  write_conf /etc/systemd/journald.conf.d/omapi-hardening.conf <<'EOF'
# Managed by oma-pi omapi-harden.sh. Re-run the script to change these.
[Journal]
SystemMaxUse=200M
RuntimeMaxUse=50M
ForwardToSyslog=no
EOF

  if ((DRY_RUN)); then
    note "would apply with: sysctl --system"
    note "would restart: systemd-journald"
    return 0
  fi

  # sysctl --system reports per-key, so a key this kernel does not have (older
  # Pi kernels lack some of these) must not abort the whole file.
  if peek sysctl --system >/dev/null 2>&1; then
    ok "sysctls applied"
  else
    warn "sysctl --system reported errors:"
    peek sysctl --system 2>&1 | grep -i error | head -5 >&2 || true
  fi
  run_root systemctl restart systemd-journald
  ok "journal capped at 200M"
}

# ---------------------------------------------------------------------------
# aide (opt-in)
# ---------------------------------------------------------------------------
configure_aide() {
  section "File integrity monitoring (aide)"

  if ! have aide && ((!DRY_RUN)); then
    warn "aide is not installed"
    if ! ask "install aide? (first run builds a database over the whole filesystem, several minutes of 100% CPU)" n; then
      skip "left file integrity monitoring off"
      return 0
    fi
    run_root env DEBIAN_FRONTEND=noninteractive apt-get install -y aide
  fi

  warn "aideinit reads every file on the system and will peg the CPU for a"
  warn "few minutes on an SD card. Run it when nothing else is happening."

  if ((DRY_RUN)); then
    note "would run: aideinit --yes --force, then daily report from /etc/cron.daily"
    return 0
  fi

  if [[ ! -f /var/lib/aide/aide.db ]]; then
    if ask "build the aide baseline now?" n; then
      run_root aideinit --yes --force
      ok "baseline built"
    else
      skip "no baseline yet, nothing to compare against"
    fi
  else
    ok "baseline already exists"
  fi

  if [[ ! -e /etc/cron.daily/aide-check ]]; then
    write_conf /etc/cron.daily/aide-check <<'EOF'
#!/bin/sh
# Managed by oma-pi omapi-harden.sh.
# A non-zero exit is expected on any change, so cron mails the diff.
exec /usr/bin/aide.wrapper --stdout
EOF
    run_root chmod 0755 /etc/cron.daily/aide-check
    ok "daily report installed"
  fi
  note "review changes with: sudo aide --check; accept them with: sudo aide --update"
}

# ---------------------------------------------------------------------------
# audit
# ---------------------------------------------------------------------------
audit() {
  section "Audit"

  local line pretty="unknown" upgradable="unknown"
  # Read /etc/os-release directly: it is world readable, and `peek . file`
  # is not a thing - sudo cannot source a file.
  if [[ -r /etc/os-release ]]; then
    pretty="$(awk -F= '/^PRETTY_NAME=/{gsub(/"/, "", $2); print $2}' /etc/os-release)"
    [[ -n $pretty ]] || pretty="unknown"
  fi
  # `grep -c` prints a 0 and still exits 1 when nothing matches, so the
  # `|| echo` used to fire as well and emit a stray '?' under the count.
  if [[ -r /var/lib/dpkg/status ]]; then
    # The `|| true` added when this aborting under set -e also let awk's
    # `END{print n+0}` print 0 when the lookup failed, so a peek that could
    # not run reported "pending updates: 0" - indistinguishable from a fully
    # patched box, and the more dangerous direction. Check the lookup's status
    # first and only accept its count when it actually succeeded.
    local apt_out=""
    if apt_out="$(peek apt list --upgradable 2>/dev/null)"; then
      upgradable="$(printf '%s' "$apt_out" |
        awk '/^[^ ]+\/[^ ]+ .*upgradable from/{n++} END{print n + 0}')"
    else
      upgradable="unknown (needs root)"
    fi
    [[ -n $upgradable ]] || upgradable="unknown (needs root)"
  fi

  {
    printf 'oma-pi security audit - %s\n' "$(date -u '+%Y-%m-%d %H:%M UTC')"
    printf 'host: %s   os: %s\n' "$(hostname)" "$pretty"

    printf '\n-- listening ports --\n'
    # Compared against the unique list, not the raw per-line output: a port
    # that shows up twice would print twice and read like two open ports.
    local ports
    ports="$(listening_ports)"
    if [[ -n $ports ]]; then
      while read -r proto port; do
        [[ -n $proto && -n $port ]] || continue
        printf '  %s/%s  %s\n' "$proto" "$port" "$(listening_process "$proto" "$port" || true)"
      done <<<"$ports"
    else
      printf '  (none, or not enough privilege to enumerate them)\n'
    fi

    printf '\n-- ufw --\n'
    if have ufw; then
      peek ufw status verbose 2>/dev/null | sed 's/^/  /' || printf '  unavailable\n'
    else
      printf '  not installed\n'
    fi

    printf '\n-- sshd (effective) --\n'
    if line="$(peek sshd -T 2>/dev/null | grep -iE '^(port|permitrootlogin|pubkeyauthentication|passwordauthentication|kbdinteractiveauthentication|permitemptypasswords|maxauthtries|maxsessions|logingracetime|x11forwarding|allowusers|allowtcpforwarding) ' )"; then
      printf '%s\n' "$line" | sed 's/^/  /'
    else
      printf '  unavailable (needs root)\n'
    fi

    printf '\n-- fail2ban --\n'
    if have fail2ban-client && peek fail2ban-client status &>/dev/null; then
      peek fail2ban-client status 2>/dev/null | sed 's/^/  /'
    else
      printf '  not running\n'
    fi

    printf '\n-- unattended upgrades --\n'
    peek apt-config dump 2>/dev/null |
      grep -E 'Unattended-Upgrade::(Allowed-Origins|Automatic-Reboot|Package-Blacklist)' |
      sed 's/^/  /' || printf '  not configured\n'
    printf '  pending updates: %s\n' "$upgradable"
    # Counted separately from the line above: these are the ones that will
    # never be applied by unattended-upgrades and never raise an error, so
    # "pending updates: 1" next to a silent 1 is the most misleading pair of
    # numbers this report can print.
    printf '  held back by apt upgrade: %s\n' \
      "$(held_back_packages | tr '\n' ' ' | sed 's/[[:space:]]*$//' || true)"

    printf '\n-- kernel patching --\n'
    # A kernel image no package owns can never be upgraded, so it stops
    # receiving security patches with nothing anywhere complaining: apt has no
    # newer one to pull, so no timer fires and no report mentions it. The
    # usual way in is rpi-update, which installs a kernel deliberately outside
    # apt's package management - and that also drops the running kernel out of
    # the RPi origin allowed above, so the origin fix stops covering it too.
    # Read-only by design. The remedy is a reinstall from apt, which is a
    # decision for a human with physical access, not something an audit
    # should do behind their back on a headless box.
    local kowner krel kbad
    krel="$(uname -r 2>/dev/null || echo '?')"
    if kowner="$(running_kernel_owner "$krel")" && [[ -n $kowner ]]; then
      printf '  running kernel: %s (owned by %s)\n' "$krel" "$kowner"
    else
      printf '  running kernel: %s (no /boot image owned by a package)\n' "$krel"
    fi
    kbad="$(untracked_kernels)"
    if [[ -n $kbad ]]; then
      printf '  UNTRACKED kernel images: %s\n' "$kbad"
      printf '  owned by no package, so apt can never upgrade them and they stop\n'
      printf '  receiving security patches silently. Reinstall from apt to fix.\n'
    else
      printf '  every kernel image in /boot is owned by a package\n'
    fi
    printf '\n-- apparmor --\n'
    peek aa-status 2>/dev/null | head -6 | sed 's/^/  /' || printf '  not installed\n'

    printf '\n-- sysctl --\n'
    printf '  file: %s\n' "$([[ -f ${CONF_DEST}/etc/sysctl.d/99-omapi-hardening.conf ]] &&
      echo present || echo absent)"
    peek sysctl net.ipv4.conf.all.rp_filter net.ipv4.tcp_syncookies 2>/dev/null |
      sed 's/^/  /' || true

    printf '\n-- accounts --\n'
    printf '  passwordless: %s\n' \
      "$(peek awk -F: '($2 == "") {print $1}' /etc/shadow 2>/dev/null | tr '\n' ' ' || true)"
    printf '  uid 0: %s\n' \
      "$(peek awk -F: '($3 == 0) {print $1}' /etc/passwd 2>/dev/null | tr '\n' ' ' || true)"
    printf '  default pi account: %s\n' "$(id pi &>/dev/null && echo PRESENT || echo absent)"
    printf '  sudoers: %s\n' \
      "$(peek getent group sudo 2>/dev/null | cut -d: -f4 || echo '?')"

    printf '\n-- recent auth failures --\n'
    peek journalctl -u ssh --since '-24 hours' --no-pager 2>/dev/null |
      grep -ciE 'failed|invalid|refused' |
      awk '{print "  ssh failures in 24h: " $1}' || true

    printf '\n-- filesystem --\n'
    printf '  %s\n' "$(peek df -h / 2>/dev/null | tail -1 || true)"
    # timeout must go inside peek, not around it: timeout execs an external
    # program and cannot run a shell function, so `timeout 60 peek find ...`
    # always failed with exit 127 and the audit reported "world-writable
    # files: 0" on a box it never actually scanned.
    printf '  world-writable files: %s\n' \
      "$(peek timeout 60 find / -xdev -type f -perm -002 2>/dev/null | wc -l || echo 'not scanned')"

    printf '\n-- disk space on the boot filesystem matters more than any of the above --\n'
  } 2>&1 | tee "$AUDIT_TMP"

  if ((WANT_REPORT)); then
    local dir="$HOME/security-audit"
    local out="$dir/security-$(date -u +%Y%m%d-%H%M).txt"
    if ((DRY_RUN)); then
      note "would save the report to ${out}"
    else
      install -d -m 0700 "$dir" 2>/dev/null || install -d -m 0755 "$dir"
      cp "$AUDIT_TMP" "$out" 2>/dev/null && ok "report saved to ${out}"
    fi
  fi
}

manual_followups() {
  section "Still on you"

  cat <<'EOF'
  These need a physical keyboard, a reboot or a decision this script should
  not make for you.

  1. Boot config, /boot/config.txt, then reboot:
         dtoverlay=disable-wifi
         dtoverlay=disable-bt
     Only worth it if the box is wired. A Pi cut off from the network you
     are managing it over is a Pi you cannot manage.

  2. Firmware: sudo raspi-config   ->  Advanced Options  ->  Update bootloader
     Bootloader bugs are how the good boot/config.txt hardening gets undone
     by an unattended update.

  3. Change the password for your own sudoer account, and make sure it is not
     the same one you use everywhere else.

  4. Backups. Hardening is not a backup. If the card dies tomorrow, none of
     the above matters.

  5. From another machine, confirm what the internet can actually see:
         nmap -sS -O -A <pi-ip>
     If you have not opened anything, this should be boring.

  6. VLAN-isolate this box if the network has more than a handful of devices.
     Network segmentation beats every setting in this script.
EOF
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
want_task() {
  local t="$1"
  if ((${#SELECTED[@]} == 0)); then
    case " ${DEFAULT_TASKS[*]} " in *" $t "*) return 0 ;; *) return 1 ;; esac
  fi
  local s
  for s in "${SELECTED[@]}"; do
    [[ $s == "$t" ]] && return 0
  done
  return 1
}

known_task() {
  local t="$1" k
  for k in "${TASKS[@]}"; do
    [[ $k == "$t" ]] && return 0
  done
  return 1
}

main() {
  while (($# > 0)); do
    case "$1" in
      -y | --yes) ASSUME_YES=1 ;;
      -n | --dry-run) DRY_RUN=1 ;;
      --lockdown-ssh) LOCKDOWN_SSH=1 ;;
      --report) WANT_REPORT=1 ;;
      --no-audit) RUN_AUDIT=0 ;;
      --no-restart) NO_RESTART=1 ;;
      -l | --list) list_tasks; return 0 ;;
      -h | --help) usage; return 0 ;;
      --)
        shift
        SELECTED+=("$@")
        break
        ;;
      -*) printf 'unknown option: %s\n\n' "$1" >&2; usage >&2; return 2 ;;
      *) SELECTED+=("$1") ;;
    esac
    shift
  done

  local t
  for t in "${SELECTED[@]+"${SELECTED[@]}"}"; do
    if ! known_task "$t"; then
      printf 'unknown task: %s\n\n' "$t" >&2
      usage >&2
      return 2
    fi
  done

  printf '%s   oma-pi  security hardening%s\n' "$C_RED" "$C_OFF"
  if ((DRY_RUN)); then
    printf '%s   dry run: nothing is changed, no service is restarted%s\n' "$C_DIM" "$C_OFF"
  fi

  # Warnings and the first sudo prompt are the same thing here, so warm the
  # credential cache once instead of prompting inside every step.
  if ! ((DRY_RUN)) && [[ $(id -u) -ne 0 ]] && have sudo; then
    if ! sudo -n true &>/dev/null; then
      if [[ -t 0 ]]; then
        step "asking for sudo once, everything after this is cached"
        sudo -v || {
          printf 'error: sudo is required for the privileged steps\n' >&2
          return 1
        }
      else
        printf 'error: needs a tty or an existing sudo timestamp, or run with sudo\n' >&2
        return 1
      fi
    fi
  fi

  want_task packages && install_hardening_packages
  want_task users && check_users
  want_task ssh && harden_ssh
  want_task firewall && configure_firewall
  want_task fail2ban && configure_fail2ban
  want_task updates && configure_updates
  want_task apparmor && configure_apparmor
  want_task sysctl && configure_sysctl
  want_task aide && configure_aide

  want_task audit && ((RUN_AUDIT)) && audit
  manual_followups

  if ((DRY_RUN)); then
    printf '\n%s   dry run. Re-run without --dry-run when this looks right.%s\n' "$C_DIM" "$C_OFF"
  fi
}

AUDIT_TMP=""
if [[ -z $AUDIT_TMP ]]; then
  AUDIT_TMP="$(mktemp)"
  trap 'rm -f "$AUDIT_TMP"' EXIT
fi

# Sourcing this file gives you the functions and runs nothing, which is what
# the tests in the repo do.
if [[ ${BASH_SOURCE[0]} == "${0}" ]]; then
  main "$@"
fi
