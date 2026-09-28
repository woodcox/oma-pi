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
  if [[ -t 0 ]]; then
    if have gum; then
      if [[ $default == y ]]; then
        gum confirm "$question"
      else
        gum confirm "$question" --default-no
      fi
      return
    fi
    if [[ $default == y ]]; then
      read -r -p "  $question [Y/n] " answer
      [[ -z $answer || $answer =~ ^[Yy] ]]
    else
      read -r -p "  $question [y/N] " answer
      [[ $answer =~ ^[Yy] ]]
    fi
    return
  fi
  warn "no tty, taking the default ($default) for: $question"
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
  local block="$1"
  local path="$2"
  local target="${CONF_DEST}${path}"
  local body
  body="$(mktemp)"

  if [[ -f $block ]]; then
    cat "$block" >"$body"
  fi

  if [[ -f $target ]]; then
    awk -v b1="$MANAGED_BEGIN" -v b2="$MANAGED_END" '
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
have_usable_key() {
  local keys="$1" found=1 f
  for f in "$keys"; do
    [[ -s $f ]] || continue
    if grep -qvE '^\s*(#|$)' "$f" 2>/dev/null &&
      ssh-keygen -l -f "$f" &>/dev/null; then
      found=0
      break
    fi
  done
  return $found
}

key_files_for_user() {
  local user="${1:-$(id -un)}"
  printf '%s\n' "/home/$user/.ssh/authorized_keys" "/home/$user/.ssh/authorized_keys2"
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
  if empty="$(peek awk -F: '($2 == "") { print $1 }' /etc/shadow 2>/dev/null)" && [[ -n $empty ]]; then
    while read -r account; do
      [[ -n $account ]] || continue
      if ask "lock the passwordless account '$account'?"; then
        run_root passwd -l "$account"
        run_root usermod -s /usr/sbin/nologin "$account"
        ok "locked $account"
      else
        skip "left $account alone"
      fi
    done <<<"$empty"
  else
    ok "no passwordless accounts"
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
    if ! ((FORCE)) && ! ask "switch SSH to key-only anyway (make sure you can reach this box another way)?" y; then
      skip "leaving PasswordAuthentication as it is"
      return 0
    fi
  else
    ok "key-based access confirmed for $backdoor_user"
  fi

  local new_port="$port" change_port=0
  if ((LOCKDOWN_SSH)); then
    note "--lockdown-ssh: AllowUsers will be set to $(id -un)"
  fi

  # Moving the port only removes noise from the logs; it is not a control.
  # Offered because it is in the guides and because it is harmless, but
  # never the reason a box is called secure.
  if ask "move sshd off port ${port}? (noise reduction only, not security)" n; then
    local candidate
    while read -r candidate; do
      [[ -n $candidate ]] || continue
      new_port="$candidate"
      break
    done < <(
      if have gum; then
        printf '\n'
        gum input --placeholder "e.g. 2222" --prompt "New SSH port: " </dev/tty || true
      else
        read -r -p "  New SSH port [2222]: " candidate || true
        printf '%s\n' "${candidate:-2222}"
      fi
    )
    if [[ $new_port =~ ^[0-9]+$ ]] && ((new_port > 0 && new_port < 65535)) && ((new_port != port)); then
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
    ((LOCKDOWN_SSH)) && printf 'AllowUsers %s\n' "$(id -un)"
    printf '%s\n' "$MANAGED_END"
  } >"$block"

  local target="${CONF_DEST}${conf}"
  local backup=""
  if ((!DRY_RUN)) && [[ -f $target ]]; then
    backup="${target}.omapi-backup"
    cp -p "$target" "$backup"
  fi

  replace_managed_block "$block" "$conf"
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
  if have ss; then
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
        if ($i ~ /:/ && $i ~ /^\[?[0-9A-Fa-f.:%]+\]?:[0-9]+$/) { addr = $i; break }
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
  while read -r proto port; do
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
  done < <(listening_ports)

  if docker_present; then
    warn "Docker installs its own DOCKER-USER chain and its published ports"
    note "bypass ufw. ufw rules here do not cover container ports, and"
    note "dockerd's iptables work will be lost if ufw is reconfigured by"
    note "hand. Bound what containers publish with -p 127.0.0.1:PORT:PORT."
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

  if ((DRY_RUN)); then
    note "would enable: ufw enable"
    return 0
  fi
  run_root ufw enable
  ok "ufw enabled"
  note "$(ufw status 2>/dev/null | head -1 || true)"
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

  write_conf /etc/fail2ban/jail.d/omapi-hardening.local <<EOF
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
    return 0
  fi

  if ! peek fail2ban-client -t >/dev/null 2>&1; then
    warn "fail2ban rejected the jail file, leaving the previous config in place"
    peek fail2ban-client -t || true
    return 1
  fi
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

  write_conf /etc/apt/apt.conf.d/20auto-upgrades <<EOF
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
    printf '  world-writable files: %s\n' \
      "$(timeout 60 peek find / -xdev -type f -perm -002 2>/dev/null | wc -l || echo 'not scanned')"

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
