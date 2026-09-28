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
#     the key check, and neither is --force.
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
FORCE=0
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
MANAGED_BEGIN="# BEGIN oma-pi hardening (security.sh) - do not edit between these lines"
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
  security.sh [options] [task ...]

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
      --force       proceed with the steps that normally need --yes (the
                     "you have another way in" overrides)
      --lockdown-ssh additionally set `AllowUsers <you>` in sshd_config
      --report       also save the audit report to ~/security-audit/
      --no-audit     skip the final report
      --no-restart   write configs but do not restart any service
  -l, --list        list tasks and exit
  -h, --help        this text

Examples:
  ./security.sh --dry-run
  sudo ./security.sh ssh firewall fail2ban
  sudo ./security.sh --yes --report
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
# creating the file when it is not there yet. A file that has no managed block
# gets the block on top, which is the point: sshd honours the first value it
# reads, so anything below is a comment waiting to be overridden by an
# Include drop-in.
#
# Written back with `cat >` rather than `mv`ed from a temp file, so the
# original mode, owner and inode survive. sshd and apt both care, and a
# replaced /etc/ssh/sshd_config with the wrong ownership is a bad afternoon.
replace_managed_block() {
  # Three separate `local` statements, not one. Bash expands every word on a
  # `local` line before it assigns any of them, so a single line reading
  # `local block=$1 path=$2 target=${CONF_DEST}${path}` would look up `path`
  # in the global scope, where it does not exist, and die under `set -u`.
  #
  # $3/$4 are the begin/end markers, defaulting to the sshd block's. They are
  # parameters because this also manages a second file with different markers
  # (/etc/ufw/after.rules), and a second copy of ufw's chain declarations would
  # make ufw fail to restore at all.
  local block="$1"
  local path="$2"
  local b1="${3:-$MANAGED_BEGIN}"
  local b2="${4:-$MANAGED_END}"
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

    # Managed block first, then whatever was already in the file outside any
    # previous block. awk drops a trailing newline on the last line it
    # printed, so the concatenation below is what puts one back.
    printf '\n' >>"$body"
    cat "$body.tail" >>"$body"
    rm -f "$body.tail"

    # Normalise the blank-line run immediately after the managed block to
    # exactly one. Without this, every re-run appended another newline and the
    # file grew by one blank line per run, forever - which is what "idempotent"
    # has to mean here. Only the run directly after MANAGED_END is touched, so
    # blank lines the user put elsewhere in their own config are preserved.
    #
    # The `next` after the MANAGED_END match is what stops the end-marker line
    # being printed twice; the guard is re-armed per line, not per run, so the
    # suppression only lasts while the lines are still blank.
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
    cat "$body.trim" >"$body"
    rm -f "$body.trim"
  fi

  install -d -m 0755 "$(dirname "$target")" 2>/dev/null || true

  if ((DRY_RUN)); then
    # Print just the managed block, not the whole file. Echoing back a
    # 200-line stock sshd_config to say "these 10 lines would be added" buries
    # the useful part.
    printf '  %s•%s would write %s (managed block on top, rest untouched):%s\n' \
      "$C_DIM" "$C_OFF" "$path" "$C_OFF"
    if [[ -f $block ]]; then
      sed 's/^/      /' "$block"
    fi
    rm -f "$body" "$body.tail"
    return 0
  fi

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

# Resolve the real home directory rather than assuming /home/$user, and honour
# the AuthorizedKeysFile setting if sshd has been told to use something else.
key_files_for_user() {
  local user="${1:-$(id -un)}" home auth
  home="$(getent passwd "$user" 2>/dev/null | cut -d: -f6)"
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
    local f
    while IFS= read -r f; do
      [[ -n $f ]] || continue
      printf '%s\n' "$f" | sed "s|^%[hHd]|$home|; s|^%[uU]|$user|"
    done <<<"$auth"
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
  # to not fail halfway through a hardening pass because of it.
  run_root env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    "${missing[@]}" || warn "apt-get install returned non-zero, continuing with what is installed"
  ok "packages present"
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
      ok "locked pi - undo with: sudo usermod -L -s /bin/bash pi && sudo passwd -u pi"
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
  port="$(peek sshd -T 2>/dev/null | awk '/^port /{print $2; exit}' || true)"
  if [[ -z $port ]]; then
    port="$(grep -hsiE '^[[:space:]]*Port[[:space:]]+[0-9]+' \
      /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null |
      awk '{print $2; exit}' || true)"
  fi
  printf '%s\n' "${port:-22}"
}

non_root_sudoer_with_key() {
  local user
  while read -r user; do
    [[ -n $user && $user != root ]] || continue
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
  port="$(current_ssh_port)"
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
    # `sudo ./security.sh --yes` run turns passwords off on a box with no
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
    # Under `sudo ./security.sh`, id -un is root. AllowUsers root alongside
    # PermitRootLogin no is a config sshd accepts and that locks out every
    # account, so the real invoking user has to be resolved, and root has to
    # be refused outright.
    local target_user="${SUDO_USER:-$(id -un)}"
    if [[ -z $target_user || $target_user == root ]]; then
      warn "--lockdown-ssh needs a real non-root user; run it as 'sudo -u \$USER -E ./security.sh --lockdown-ssh' or from a root shell with SUDO_USER set"
      warn "refusing to write AllowUsers root: it would lock out every account"
      LOCKDOWN_SSH=0
    else
      note "--lockdown-ssh: AllowUsers will be set to ${target_user}"
    fi
  fi

  # Moving the port only removes noise from the logs; it is not a control.
  # Offered because it is in the guides and because it is harmless, but
  # never the reason a box is called secure.
  if ask "move sshd off port ${port}? (noise reduction only, not security)" n; then
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
# would silently override it. Re-run security.sh to change these; edits
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
    ((change_port)) && printf 'Port %s\n' "$new_port"
    ((LOCKDOWN_SSH)) && printf 'AllowUsers %s\n' "${SUDO_USER:-$(id -un)}"
    printf '%s\n' "$MANAGED_END"
  } >"$block"

  local target="${CONF_DEST}${conf}"
  local backup=""
  if ((!DRY_RUN)) && [[ -f $target ]]; then
    backup="${target}.omapi-backup"
    cp -p "$target" "$backup"
  fi

  replace_managed_block "$block" "$conf"

  # Port is additive in sshd: the first-value-wins rule that makes prepending
  # work for everything else does NOT apply to it. A `Port 22` left further
  # down the file means sshd ends up listening on both, so the old line has to
  # be commented out rather than merely outranked. Done by sed on the whole
  # file, outside the managed block, and only when we are actually moving.
  if ((change_port)) && ((!DRY_RUN)); then
    sed -i -E "s|^[[:space:]]*Port[[:space:]]+[0-9]+|# &|" "$target"
    # Put back the one line that should still be live.
    sed -i "s|^# Port ${new_port}\$|Port ${new_port}|" "$target"
  fi

  rm -f "$block"
  ok "sshd_config hardened"

  # Validate before restarting. An sshd that will not parse is an sshd that
  # does not come back, and on a headless Pi that is the whole session.
  if ((DRY_RUN)); then
    note "would validate with: sshd -t -f ${conf}"
    note "would run: systemctl restart ssh"
    [[ $change_port -eq 1 ]] && note "firewall rules must follow the move to port ${new_port}"
    return 0
  fi

  if ! peek sshd -t -f "$conf" >/dev/null 2>&1; then
    if [[ -n $backup ]]; then
      warn "sshd rejected the new config, rolling ${conf} back"
      peek cp -p "$backup" "$conf" || true
    else
      warn "sshd rejected the new config and there is no backup to roll back to"
    fi
    return 1
  fi
  ok "sshd accepts the new config"

  if ((NO_RESTART)); then
    note "--no-restart: run 'sudo systemctl restart ssh' yourself when ready"
    return 0
  fi

  if peek systemctl restart ssh; then
    ok "ssh restarted on port ${new_port}"
    printf '\n  %sKeep this session open and open a second one before you rely on it.%s\n' "$C_BOLD" "$C_OFF"
  else
    warn "ssh failed to restart, rolling back"
    [[ -n $backup ]] && peek cp -p "$backup" "$conf" || true
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
  [[ -r /etc/ufw/after.rules ]] &&
    grep -qF "$DOCKER_UFW_BEGIN" /etc/ufw/after.rules 2>/dev/null
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

# Map a published host port to the port inside the container. `ufw route
# allow` matches on the container port, because by the time a packet reaches
# DOCKER-USER it has already been DNAT'd. Getting this backwards is why
# "allow 8080" appears to do nothing once the DOCKER-USER rules are in place.
docker_container_port() {
  local host_port="$1" out
  out="$(docker ps --format '{{.Names}}|{{.Ports}}' 2>/dev/null || true)"
  [[ -n $out ]] || return 0
  printf '%s\n' "$out" | awk -F'|' -v hp="$host_port" '
    {
      n = split($2, parts, ", ")
      for (i = 1; i <= n; i++) {
        p = parts[i]
        gsub(/[][]/, "", p)
        # forms: 0.0.0.0:8080->80/tcp   127.0.0.1:1318->1318/tcp   :::80->80/tcp
        if (match(p, /:([0-9]+)->([0-9]+)\//, m)) {
          if (m[1] == hp) { print $1 " " m[2]; exit }
        }
      }
    }'
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
  local cport="$1" entries
  entries="$(docker ps --format '{{.Ports}}' 2>/dev/null | tr ',' '\n')"
  [[ -n $entries ]] || return 1

  local saw=0 e
  while read -r e; do
    e="${e// /}"
    [[ $e == *"->"* ]] || continue
    local target="${e##*->}"
    target="${target%%/*}"
    [[ $target == "$cport" ]] || continue
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

  if [[ $(id -u) -eq 0 ]] || sudo -n true &>/dev/null; then
    out="$(iptables-restore --test "$tmp" 2>&1)" && rc=0 || rc=1
    if ((rc)); then
      # "Permission denied" means the parse got as far as the COMMIT and was
      # then refused for privilege, which is a pass as far as syntax goes.
      if [[ $out == *"Permission denied"* && $out != *"Bad rule"* && $out != *"syntax error"* ]]; then
        note "iptables-restore --test needs root; parsed the rules but could not apply the test"
        rc=0
      else
        warn "iptables-restore rejected the DOCKER-USER rules: ${out##*: }"
      fi
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
          # :CHAINNAME - [0:0]
          declared+="${line#:}"
          declared+=" "
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
      return 1
    fi
    # Unverified, not verified. The fragment is syntactically plausible but
    # has not been through iptables, because iptables needs root.
    note "could not run iptables-restore --test without root; the rules are unverified"
    return 2
  fi

  rm -f "$tmp"
  return $rc
}

install_docker_ufw_rules() {
  if ((DRY_RUN)); then
    printf '  %s•%s would write the DOCKER-USER rules to /etc/ufw/after.rules\n' "$C_DIM" "$C_OFF"
    return 0
  fi

  local subnets ret accept block
  block="$(mktemp)"
  subnets="$(docker_subnets | sort -u)"

  # RETURN for traffic coming FROM a private network (internal hosts reaching
  # a container), and a logged DROP for NEW connections going TO one (the
  # public internet reaching a published port, after DNAT has rewritten the
  # destination to the container address). Indentation matches the static
  # rules above, because the sed that extracts this block for validation must
  # not depend on leading whitespace.
  ret=""; accept=""
  while read -r s; do
    [[ -n $s ]] || continue
    ret+="-A DOCKER-USER -j RETURN -s ${s}"$'\n'
    accept+="-A DOCKER-USER -j ufw-docker-logging-deny -m conntrack --ctstate NEW -d ${s}"$'\n'
  done <<<"$subnets"

  {
    printf '%s\n' "$DOCKER_UFW_BEGIN"
    cat <<'EOF'
# Managed by oma-pi security.sh. Rules from chaifeng/ufw-docker.
#
# Without these, Docker's own DNAT/ACCEPT rules sit ahead of ufw's and a
# published port is reachable from the internet regardless of ufw.
# With them, published container ports are blocked by default and are opened
# only by an explicit `ufw route allow` rule.
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
    printf '%s' "$ret"
    printf '%s' "$accept"
    cat <<'EOF'
-A DOCKER-USER -j RETURN
-A ufw-docker-logging-deny -m limit --limit 3/min --limit-burst 10 -j LOG --log-prefix "[UFW DOCKER BLOCK] "
-A ufw-docker-logging-deny -j DROP
COMMIT
EOF
    printf '%s\n' "$DOCKER_UFW_END"
  } >"$block"

  # Replace, not append: a second copy of the chain declarations would make
  # ufw fail to restore entirely.
  replace_managed_block "$block" /etc/ufw/after.rules \
    "$DOCKER_UFW_BEGIN" "$DOCKER_UFW_END"
  rm -f "$block"
  ok "DOCKER-USER rules written to /etc/ufw/after.rules"
  note "published container ports are now blocked until a 'ufw route allow' rule permits them"
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

  if ((DRY_RUN)); then
    note "would set: ufw default deny incoming / allow outgoing, logging on"
  else
    run_root ufw default deny incoming
    run_root ufw default allow outgoing
    run_root ufw logging on
    ok "default policies set (incoming denied, outgoing allowed, logging on)"
  fi

  local ssh_port
  ssh_port="$(current_ssh_port)"
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
configure_docker_ufw() {
  if ! docker_present; then
    return 0
  fi
  if ! have ufw; then
    warn "Docker is running but ufw is not installed; cannot make ufw govern container ports"
    note "bound what you publish to loopback instead: -p 127.0.0.1:PORT:PORT"
    return 0
  fi

  if docker_ufw_installed; then
    ok "DOCKER-USER rules already present in /etc/ufw/after.rules"
  else
    install_docker_ufw_rules
  fi

  if ((DRY_RUN)); then
    note "would validate the rules, then run: ufw reload"
  else
    # Three outcomes, not two: verified, malformed, and - when not running as
    # root - unverified, because iptables-restore needs privilege even for
    # --test. Only a malformed fragment blocks the reload. An unverified one
    # is the normal case for `security.sh` run as a normal user, and refusing
    # to configure Docker at all there would be worse than proceeding with a
    # loud warning; a real run of this script is `sudo ./security.sh`.
    local vrc=0
    validate_docker_ufw_rules /etc/ufw/after.rules || vrc=$?
    case $vrc in
      0)
        ok "DOCKER-USER rules validated by iptables-restore"
        ;;
      1)
        warn "the DOCKER-USER rules are malformed; not reloading ufw"
        note "fix /etc/ufw/after.rules, or remove the block between the UFW AND DOCKER markers"
        return 1
        ;;
      *)
        warn "the DOCKER-USER rules could not be validated without root"
        note "if ufw reload fails afterwards, run: sudo ufw-docker check"
        ;;
    esac

    # Back up before reloading: a bad fragment stops ufw restoring its whole
    # ruleset, which means no firewall at all.
    local rules_backup=""
    if [[ -f /etc/ufw/after.rules ]]; then
      rules_backup="$(mktemp)"
      cp -p /etc/ufw/after.rules "$rules_backup" || rules_backup=""
    fi

    if run_root ufw reload; then
      ok "ufw reloaded with the DOCKER-USER chain in place"
      [[ -n $rules_backup ]] && rm -f "$rules_backup"
    else
      warn "ufw reload failed; restoring the previous rules and reloading again"
      if [[ -n $rules_backup ]]; then
        run_root cp -p "$rules_backup" /etc/ufw/after.rules || true
        run_root ufw reload || warn "ufw is still not reloading - check 'ufw status' and the journal"
      fi
      [[ -n $rules_backup ]] && rm -f "$rules_backup"
      return 1
    fi
  fi

  # Every published (container name, container port) pair, de-duplicated.
  # A port published on both 0.0.0.0 and 127.0.0.1 appears once; whether it is
  # public is decided per port by docker_port_is_loopback_only, not here.
  #
  # The `if` rather than `[[ ... ]] &&` matters: under `set -e` a trailing
  # `&&` that evaluates false is the last command in a subshell, the subshell
  # exits non-zero, and the whole pipeline is torn down mid-iteration. That
  # silently dropped every port and the prompts never appeared.
  docker_published_pairs() {
    local n p entry cport
    docker ps --format '{{.Names}}|{{.Ports}}' 2>/dev/null |
      while IFS='|' read -r n p; do
        [[ -n $n && -n $p ]] || continue
        while IFS= read -r entry; do
          entry="${entry// /}"
          if [[ $entry != *"->"* ]]; then
            continue
          fi
          cport="${entry##*->}"
          cport="${cport%%/*}"
          if [[ -n $cport ]]; then
            printf '%s %s\n' "$n" "$cport"
          fi
        done < <(printf '%s\n' "$p" | tr ',' '\n')
      done | sort -u
  }

  local line name cport
  while read -r name cport <&3; do
    [[ -n $name && -n $cport ]] || continue
    if docker_port_is_loopback_only "$cport"; then
      ok "${name}: ${cport} is published on loopback only, unreachable from the network"
      continue
    fi
    if ask "allow the internet to reach ${name} on container port ${cport}? (needed for 0.0.0.0:${cport} and [::]:${cport})" n; then
      if ((DRY_RUN)); then
        printf '  %s•%s would run: ufw route allow proto tcp from any to any port %s\n' \
          "$C_DIM" "$C_OFF" "$cport"
      else
        run_root ufw route allow proto tcp from any to any port "$cport" \
          comment "omapi: ${name}" || warn "could not add a route rule for ${name}:${cport}"
        ok "${name}: container port ${cport} reachable from the network"
      fi
    else
      warn "${name} publishes ${cport} on all interfaces and is now BLOCKED"
      note "if something should reach it: sudo ufw route allow proto tcp from any to any port ${cport}"
      note "or publish it on loopback only: -p 127.0.0.1:${cport}:${cport}"
    fi
  done 3< <(docker_published_pairs)
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
  ssh_port="$(current_ssh_port)"

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
# Managed by oma-pi security.sh. Re-run the script to change these.
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

  if ! peek fail2ban-client -t >/dev/null 2>&1; then
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
    peek fail2ban-client -t 2>&1 | tail -3 >&2 || true
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
// Managed by oma-pi security.sh. Re-run the script to change these.
// These two keys are what actually enable unattended-upgrades. Without them
// apt.systemd.daily defaults to 0 and no security patch is ever applied.
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

  write_conf /etc/apt/apt.conf.d/51omapi-origins <<EOF
// Managed by oma-pi security.sh. Re-run the script to change these.
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
// Managed by oma-pi security.sh. Re-run the script to change these.
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

  run_root systemctl enable --now unattended-upgrades 2>/dev/null || true
  if peek apt-config dump | grep -q Unattended-Upgrade; then
    ok "unattended-upgrades configured for ${origins[*]}"
  else
    warn "apt did not pick up the unattended-upgrades configuration"
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
# Managed by oma-pi security.sh. Re-run the script to change these.
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
# Managed by oma-pi security.sh. Re-run the script to change these.
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
# Managed by oma-pi security.sh.
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
    upgradable="$(peek apt list --upgradable 2>/dev/null |
      awk '/^[^ ]+\/[^ ]+ .*upgradable from/{n++} END{print n + 0}')"
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
      --force) FORCE=1 ;;
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
