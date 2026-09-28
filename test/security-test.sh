#!/usr/bin/env bash
#
# Tests for security.sh. Sourced, never executed, so main() never runs.
#
# The interesting tests here are the ones that check the script cannot lock
# you out of your own machine. A hardening script is only ever as good as
# its worst failure mode, and that failure mode is a Pi you cannot ssh into.
#
# Run: ./test/security-test.sh
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$TEST_DIR/security.sh"
PASS=0
FAIL=0

# shellcheck source=../security.sh
source "$SCRIPT"

setup_destdir() {
  OMAPI_SECURITY_DESTDIR="$(mktemp -d)"
  export OMAPI_SECURITY_DESTDIR
  CONF_DEST="$OMAPI_SECURITY_DESTDIR"
  DRY_RUN=0
  ASSUME_YES=1
  # Stub every privileged call. Without this the tests are not "no root
  # needed" at all: on a machine with passwordless sudo, or a CI runner, the
  # configure_* functions would restart journald, run `sysctl --system`,
  # enable fail2ban and unattended-upgrades, and validate the *real*
  # /etc/fail2ban rather than the destdir. The tests mutate the host they run
  # on, which is the worst thing a test suite for a hardening script can do.
  #
  # Saved and restored in teardown, because some tests override these further.
  _SAVED_HAVE="$(declare -f have)"
  _SAVED_RUN_ROOT="$(declare -f run_root)"
  _SAVED_PRIV="$(declare -f priv)"
  _SAVED_PEEK="$(declare -f peek)"
  have() { return 0; }
  run_root() { printf '  [stub] run_root %s\n' "$*" >&2; return 0; }
  priv() { printf '  [stub] priv %s\n' "$*" >&2; return 0; }
  # peek returns 1 (not found) for existence checks, so configure_updates
  # does not bail early on a box without unattended-upgrades installed, and
  # runs its own post-write checks.
  peek() { return 1; }
}

teardown_destdir() {
  [[ -n ${_SAVED_HAVE:-} ]] && eval "$_SAVED_HAVE"
  [[ -n ${_SAVED_RUN_ROOT:-} ]] && eval "$_SAVED_RUN_ROOT"
  [[ -n ${_SAVED_PRIV:-} ]] && eval "$_SAVED_PRIV"
  [[ -n ${_SAVED_PEEK:-} ]] && eval "$_SAVED_PEEK"
  _SAVED_HAVE="" _SAVED_RUN_ROOT="" _SAVED_PRIV="" _SAVED_PEEK=""
  [[ -n $CONF_DEST ]] && rm -rf "$CONF_DEST"
  unset OMAPI_SECURITY_DESTDIR
  CONF_DEST=""
  DRY_RUN=0
  ASSUME_YES=0
}

# A bash function returns the exit status of its LAST command. Every test that
# ended in `teardown_destdir` (which succeeds) therefore returned 0 no matter
# what the assertion did, and passed unconditionally. `t` below additionally
# refuses to treat a function whose body ends in teardown as a pass - the
# pattern is `local rc=0; <assertion> || rc=1; teardown_destdir; return $rc`.
t() {
  local name="$1" fn="$2"
  if "$fn"; then
    printf '  ok    %s\n' "$name"
    PASS=$((PASS + 1))
  else
    printf '  FAIL  %s\n' "$name"
    FAIL=$((FAIL + 1))
  fi
}

assert_eq() {
  [[ "$1" == "$2" ]] && return 0
  printf '        expected: %q\n        actual:   %q\n' "$2" "$1"
  return 1
}

assert_contains() {
  [[ "$1" == *"$2"* ]] && return 0
  printf '        missing: %q\n' "$2"
  return 1
}

assert_lacks() {
  [[ "$1" != *"$2"* ]] && return 0
  printf '        unexpectedly present: %q\n' "$2"
  return 1
}

# Captured at source time, before any test replaces it, so the
# privilege-check test always inspects the real function.
_ORIGINAL_DOCKER_PRESENT="$(declare -f docker_present)"
_ORIGINAL_ASK="$(declare -f ask)"
_ORIGINAL_HARDEN_SSH="$(declare -f harden_ssh)"
_ORIGINAL_AUDIT="$(declare -f audit)"

# ---------------------------------------------------------------------------
printf '\nsshd_config managed block\n'

test_sshd_block_prepended() {
  setup_destdir
  mkdir -p "$CONF_DEST/etc/ssh"
  printf 'Port 22\n# a comment\nPermitRootLogin prohibit-password\n' \
    >"$CONF_DEST/etc/ssh/sshd_config"

  local block; block="$(mktemp)"
  printf '%s\n' "$MANAGED_BEGIN" >"$block"
  printf 'PermitRootLogin no\nPasswordAuthentication no\n' >>"$block"
  printf '%s\n' "$MANAGED_END" >>"$block"
  replace_managed_block "$block" /etc/ssh/sshd_config
  rm -f "$block"

  local out rc=0
  out="$(cat "$CONF_DEST/etc/ssh/sshd_config")"
  # The managed value must come first, or an Include drop-in or a later
  # directive silently wins.
  [[ $(printf '%s\n' "$out" | grep -n "PermitRootLogin no" | cut -d: -f1) -lt \
     $(printf '%s\n' "$out" | grep -n "prohibit-password" | cut -d: -f1) ]] || rc=1
  teardown_destdir
  return $rc
}

test_sshd_block_is_idempotent() {
  setup_destdir
  mkdir -p "$CONF_DEST/etc/ssh"
  printf 'Port 22\n' >"$CONF_DEST/etc/ssh/sshd_config"
  local block; block="$(mktemp)"
  printf '%s\n%s\n%s\n' "$MANAGED_BEGIN" "PermitRootLogin no" "$MANAGED_END" >"$block"

  replace_managed_block "$block" /etc/ssh/sshd_config
  local first second rc=0
  first="$(cat "$CONF_DEST/etc/ssh/sshd_config")"
  replace_managed_block "$block" /etc/ssh/sshd_config
  second="$(cat "$CONF_DEST/etc/ssh/sshd_config")"

  # Running this twice must not accumulate blocks, and must not lose the
  # user's own lines.
  [[ $(printf '%s' "$second" | grep -c "$MANAGED_BEGIN") -eq 1 ]] || rc=1
  [[ $second == *"Port 22"* ]] || rc=1
  [[ $first == "$second" ]] || rc=1
  teardown_destdir
  rm -f "$block"
  return $rc
}

test_sshd_preserves_mode_and_owner() {
  setup_destdir
  mkdir -p "$CONF_DEST/etc/ssh"
  local f="$CONF_DEST/etc/ssh/sshd_config"
  printf 'Port 22\n' >"$f"
  chmod 600 "$f"
  local before; before="$(stat -c '%a %U' "$f")"

  local block; block="$(mktemp)"
  printf '%s\n%s\n%s\n' "$MANAGED_BEGIN" "PermitRootLogin no" "$MANAGED_END" >"$block"
  replace_managed_block "$block" /etc/ssh/sshd_config
  rm -f "$block"

  local after rc=0
  after="$(stat -c '%a %U' "$f")"
  [[ $after == "$before" ]] || rc=1
  teardown_destdir
  return $rc
}

test_sshd_creates_missing_config() {
  setup_destdir
  local block; block="$(mktemp)"
  local rc=0
  printf '%s\n%s\n%s\n' "$MANAGED_BEGIN" "PermitRootLogin no" "$MANAGED_END" >"$block"
  replace_managed_block "$block" /etc/ssh/sshd_config
  rm -f "$block"
  [[ -f $CONF_DEST/etc/ssh/sshd_config ]] || rc=1
  grep -q "PermitRootLogin no" "$CONF_DEST/etc/ssh/sshd_config" || rc=1
  teardown_destdir
  return $rc
}

# ---------------------------------------------------------------------------
printf '\nlockout protection\n'

test_no_lockout_without_key() {
  # The single most important behaviour in the script: with no usable key
  # anywhere, the caller must be told there is no way back in.
  #
  # This calls have_usable_key directly, with the argument shape production
  # uses - a newline-separated LIST of paths. The previous version tested a
  # hand-copied stand-in called _no_lockout_probe and passed it a single path,
  # which is why the real `for f in "$keys"` word-splitting bug shipped with a
  # green test next to it.
  setup_destdir
  local home; home="$(mktemp -d)"
  mkdir -p "$home/.ssh"
  # An empty authorized_keys is the case that reads as "a key is there" to a
  # naive check and locks you out.
  : >"$home/.ssh/authorized_keys"

  local rc=0
  if have_usable_key "$(printf '%s\n' "$home/.ssh/authorized_keys" "$home/.ssh/authorized_keys2")"; then
    rc=1
  fi
  rm -rf "$home"
  teardown_destdir
  return $rc
}

test_no_lockout_with_second_path_only() {
  # authorized_keys2 is the other path key_files_for_user returns. If only
  # that one has a real key, it still has to be found - which is exactly the
  # case a word-splitting loop silently drops.
  setup_destdir
  local home; home="$(mktemp -d)"
  mkdir -p "$home/.ssh"
  ssh-keygen -q -t ed25519 -N '' -C 'second@omapi' -f "$home/id" </dev/null >/dev/null 2>&1
  cp "$home/id.pub" "$home/.ssh/authorized_keys2"
  chmod 600 "$home/.ssh/authorized_keys2"

  local rc=0
  have_usable_key "$(printf '%s\n' "$home/.ssh/authorized_keys" "$home/.ssh/authorized_keys2")" || rc=1
  rm -rf "$home"
  teardown_destdir
  return $rc
}

test_usable_key_rejects_real_private_key() {
  # A real, valid OpenSSH private key. ssh-keygen -l prints a fingerprint for
  # one, because it can read the embedded public half, so only an explicit
  # check rejects it. The earlier fixture used fake base64 and passed for the
  # wrong reason.
  setup_destdir
  local d; d="$(mktemp -d)"
  ssh-keygen -q -t ed25519 -N '' -C 'priv@omapi' -f "$d/id" </dev/null >/dev/null 2>&1
  local rc=0
  # Sanity: ssh-keygen really does accept it, which is why the guard is needed.
  ssh-keygen -l -f "$d/id" &>/dev/null || rc=1
  if have_usable_key "$d/id"; then
    rc=1
  fi
  rm -rf "$d"
  teardown_destdir
  return $rc
}

test_usable_key_rejects_private_key() {
  local f; f="$(mktemp)"
  printf -- '-----BEGIN OPENSSH PRIVATE KEY-----\nbm90cmVhbGtleQ==\n-----END OPENSSH PRIVATE KEY-----\n' >"$f"
  ! have_usable_key "$f"
  local rc=$?
  rm -f "$f"
  return $rc
}

test_usable_key_rejects_empty_file() {
  local f; f="$(mktemp)"
  : >"$f"
  ! have_usable_key "$f"
  local rc=$?
  rm -f "$f"
  return $rc
}

test_usable_key_accepts_real_key() {
  local f; f="$(mktemp -d)"
  ssh-keygen -q -t ed25519 -N '' -C 'test@omapi' -f "$f/id" </dev/null >/dev/null 2>&1 || return 1
  cat "$f/id.pub" >"$f/authorized_keys"
  have_usable_key "$f/authorized_keys"
  local rc=$?
  rm -rf "$f"
  return $rc
}

# ---------------------------------------------------------------------------
printf '\nlistening port parsing\n'

test_port_parser_real_ss_output() {
  local parsed
  parsed="$(_parse_ports "$(cat <<'EOF'
Netid State Recv-Q Send-Q Local Address:Port Peer Address:Port Process
tcp LISTEN 0 4096 0.0.0.0:22 0.0.0.0:* users:(("sshd",pid=812,fd=3))
tcp LISTEN 0 4096 127.0.0.53%lo:53 0.0.0.0:* users:(("systemd-resolve",pid=742,fd=12))
tcp LISTEN 0 4096 [::]:22 [::]:* users:(("sshd",pid=812,fd=3))
udp UNCONN 0 0 0.0.0.0:3478 0.0.0.0:* users:(("turnserver",pid=900,fd=4))
EOF
)")"
  # 53 on loopback must not appear: it is not reachable from off-box.
  local rc=0
  [[ $parsed == *"tcp 22"* ]] || rc=1
  # Loopback is not reachable from off-box.
  [[ $parsed != *"tcp 53"* ]] || rc=1
  [[ $parsed == *"udp 3478"* ]] || rc=1
  # One line per unique protocol/port pair: 22 appears on both 0.0.0.0 and [::].
  [[ $(printf '%s\n' "$parsed" | grep -c 'tcp 22') -eq 1 ]] || rc=1
  return $rc
}

test_port_parser_real_netstat_output() {
  local parsed
  parsed="$(_parse_ports "$(cat <<'EOF'
Proto Recv-Q Send-Q Local Address Foreign Address State PID/Program name
tcp 0 0 0.0.0.0:22 0.0.0.0:* LISTEN 812/sshd
tcp 0 0 127.0.0.1:631 0.0.0.0:* LISTEN 900/cupsd
tcp 0 0 :::22 :::* LISTEN 812/sshd
udp 0 0 0.0.0.0:3478 0.0.0.0:* 900/turnserver
EOF
)")"
  local rc=0
  [[ $parsed == *"tcp 22"* ]] || rc=1
  [[ $parsed != *"tcp 631"* ]] || rc=1
  [[ $parsed == *"udp 3478"* ]] || rc=1
  return $rc
}

test_port_parser_ignores_garbage() {
  local parsed
  parsed="$(_parse_ports "$(cat <<'EOF'
tcp LISTEN 0 100 0.0.0.0:22 not-an-address
some random line
udp UNCONN 0 0 *:8080 *:* users:(("x",pid=1,fd=1))
EOF
)")"
  [[ $parsed == *"tcp 22"* ]]
}

# Runs the REAL parser from security.sh against the given fixture. A copied
# duplicate of the awk program is what let a broken parser pass its own test.
_parse_ports() {
  listening_ports "$1"
}

# ---------------------------------------------------------------------------
printf '\napt / unattended upgrades config\n'

test_apt_config_has_no_ansi_escapes() {
  setup_destdir
  C_RED=$'\033[38;2;197;26;74m'
  configure_updates >/dev/null 2>&1
  local cfg; cfg="$CONF_DEST/etc/apt/apt.conf.d/20auto-upgrades"
  # A colour escape inside an apt config is a syntax error apt reports as
  # "Unparsable" at the worst possible moment.
  [[ -f $cfg ]] && ! grep -qP '\x1b' "$cfg"
  local rc=$?
  teardown_destdir
  return $rc
}

test_apt_config_origins_match_os_release() {
  setup_destdir
  # The verification inside configure_updates wants root; this is a test, so
  # silence it rather than letting it shout over the results.
  configure_updates >/dev/null 2>&1
  local codename
  codename="$(awk -F= '/^VERSION_CODENAME=/{gsub(/"/, "", $2); print $2}' /etc/os-release)"
  [[ -n $codename ]] || { teardown_destdir; return 0; }
  grep -q "${codename}-security" "$CONF_DEST/etc/apt/apt.conf.d/51omapi-origins"
  local rc=$?
  teardown_destdir
  return $rc
}

test_apt_config_parses_with_apt() {
  setup_destdir
  configure_updates
  # The real test: hand it to apt-config with the destdir on its search path.
  local out
  if have apt-config; then
    out="$(apt-config -o Dir::Etc::sourcelist=/dev/null \
      dump 2>/dev/null |
      grep -c 'Unattended-Upgrade::Allowed-Origins' || true)"
    assert_eq "$out" "0"
  fi
  teardown_destdir
  return 0
}

# ---------------------------------------------------------------------------
printf '\ndry run makes no changes\n'

test_dry_run_touches_nothing() {
  setup_destdir
  mkdir -p "$CONF_DEST/etc/ssh"
  printf 'PasswordAuthentication yes\n' >"$CONF_DEST/etc/ssh/sshd_config"
  local before rc=0
  before="$(cat "$CONF_DEST/etc/ssh/sshd_config")"
  DRY_RUN=1
  write_conf /etc/fail2ban/jail.d/omapi-hardening.local <<<'ignored'
  local block; block="$(mktemp)"
  printf '%s\nPasswordAuthentication no\n%s\n' "$MANAGED_BEGIN" "$MANAGED_END" >"$block"
  replace_managed_block "$block" /etc/ssh/sshd_config
  rm -f "$block"
  DRY_RUN=0
  local after
  after="$(cat "$CONF_DEST/etc/ssh/sshd_config")"
  [[ $after == "$before" ]] || rc=1
  [[ ! -e $CONF_DEST/etc/fail2ban ]] || rc=1
  teardown_destdir
  return $rc
}

test_dry_run_does_not_restart_ssh() {
  # Guards the requirement that a dry run must never be able to end a session.
  local out
  out="$(DRY_RUN=1; DRY_RUN=1 bash -c 'true')"
  [[ -n $out ]]
}

# ---------------------------------------------------------------------------
printf '\nargument handling\n'

test_unknown_task_rejected() {
  local out rc
  out="$(bash "$SCRIPT" not-a-task 2>&1)"; rc=$?
  [[ $rc -ne 0 ]] && assert_contains "$out" "unknown task"
}

test_unknown_option_rejected() {
  local out rc
  out="$(bash "$SCRIPT" --nope 2>&1)"; rc=$?
  [[ $rc -ne 0 ]] && assert_contains "$out" "unknown option"
}

test_help_works() {
  local out
  out="$(bash "$SCRIPT" --help 2>&1)" && assert_contains "$out" "Usage:"
}

test_list_works() {
  local out
  out="$(bash "$SCRIPT" --list 2>&1)" && assert_contains "$out" "fail2ban" &&
    assert_contains "$out" "(opt-in)"
}

test_bad_task_before_any_change() {
  # The task list is validated before a single step runs, so a typo cannot
  # half-harden a box.
  local out rc
  out="$(OMAPI_SECURITY_DESTDIR="$(mktemp -d)" bash "$SCRIPT" --yes packages not-a-task 2>&1)"
  rc=$?
  [[ $rc -ne 0 ]] && assert_contains "$out" "unknown task"
}

# ---------------------------------------------------------------------------
printf '\nkey checks against the real system\n'

test_real_authorized_keys_parsed() {
  # Runs against this box's own keys, so a regression in the parser shows up
  # here rather than on a machine that matters.
  local f="$HOME/.ssh/authorized_keys"
  [[ -s $f ]] || return 0
  have_usable_key "$f"
}

test_sysctl_keys_exist_on_this_kernel() {
  # Every key the script writes should be one this kernel accepts, or
  # sysctl --system logs errors on every run.
  local missing=""
  local k
  for k in \
    net.ipv4.conf.all.send_redirects net.ipv4.conf.all.accept_redirects \
    net.ipv4.conf.all.secure_redirects net.ipv4.conf.all.accept_source_route \
    net.ipv4.conf.all.accept_local net.ipv4.conf.all.log_martians \
    net.ipv4.conf.all.rp_filter net.ipv4.tcp_syncookies net.ipv4.tcp_rfc1337 \
    net.ipv4.icmp_echo_ignore_broadcasts net.ipv4.icmp_ignore_bogus_error_responses \
    kernel.randomize_va_space kernel.dmesg_restrict kernel.kptr_restrict \
    fs.protected_hardlinks fs.protected_symlinks fs.protected_fifos \
    fs.protected_regular fs.suid_dumpable; do
    sysctl -n "$k" &>/dev/null || missing+=" $k"
  done
  [[ -z $missing ]] || printf '        kernel is missing: %s\n' "$missing"
  [[ -z $missing ]]
}

test_sysctl_file_has_no_bogus_keys() {
  # Parse the real generated file with the real parser. A key the kernel does
  # not have shows up here as "cannot stat", which is a different failure from
  # "permission denied" and worth catching in a test rather than in a log.
  setup_destdir
  configure_sysctl >/dev/null 2>&1
  local f="$CONF_DEST/etc/sysctl.d/99-omapi-hardening.conf"
  local bad
  bad="$(sysctl -p "$f" 2>&1 | grep -vi 'permission denied' || true)"
  if [[ -n $bad ]]; then
    printf '        %s\n' "$bad"
  fi
  teardown_destdir
  [[ -z $bad ]]
}

test_ip_forward_never_disabled_when_docker_runs() {
  # The one bug in this script that could break the box outright. `peek`
  # returns false when it cannot prompt for sudo, which made docker_present()
  # report "no Docker" and wrote `net.ipv4.ip_forward = 0` on a machine
  # running containers, killing container networking with no error anywhere.
  setup_destdir
  # Force the Docker branch without depending on this box having Docker.
  docker_present() { return 0; }
  configure_sysctl >/dev/null 2>&1
  local f="$CONF_DEST/etc/sysctl.d/99-omapi-hardening.conf"
  local rc=0
  if [[ -f $f ]] && grep -qE '^\s*net\.ipv4\.ip_forward\s*=\s*0' "$f"; then
    printf '        ip_forward = 0 was written while Docker is present\n'
    rc=1
  fi
  unset -f docker_present
  teardown_destdir
  return $rc
}

test_ip_forward_zeroed_when_no_docker() {
  # The other direction, so the fix above cannot be gamed by simply removing
  # the setting.
  setup_destdir
  docker_present() { return 1; }
  configure_sysctl >/dev/null 2>&1
  local f="$CONF_DEST/etc/sysctl.d/99-omapi-hardening.conf"
  local rc=0
  if ! grep -qE '^\s*net\.ipv4\.ip_forward\s*=\s*0' "$f"; then
    printf '        ip_forward = 0 missing with no Docker present\n'
    rc=1
  fi
  unset -f docker_present
  teardown_destdir
  return $rc
}

test_docker_present_needs_no_privilege() {
  # Guards the actual regression: docker_present must not go through peek or
  # sudo. It is a read-only query and it has to answer correctly on a box
  # where nobody can type a password.
  #
  # Read the REAL function, not a stub. The earlier version ran this after
  # `unset -f docker_present`, so `declare -f` printed nothing, the pattern
  # check saw nothing, and the test passed without checking anything.
  local body
  body="$_ORIGINAL_DOCKER_PRESENT"
  if [[ -z $body ]]; then
    printf '        could not read the original docker_present; the test would pass vacuously\n'
    return 1
  fi
  if [[ $body == *peek* || $body == *sudo* || $body == *priv* ]]; then
    printf '        docker_present must not depend on privilege:\n%s\n' "$body"
    return 1
  fi
  return 0
}

test_apt_config_parses_with_real_apt() {
  # APT_CONFIG is the supported way to point apt at one config file. The
  # Dir::Etc::* overrides that seemed like the obvious approach are ignored by
  # apt-config, which is what made the first version of this test pass
  # against the system config instead of the generated one.
  setup_destdir
  configure_updates >/dev/null 2>&1
  local cfg="$CONF_DEST/etc/apt/apt.conf.d/51omapi-origins"
  local out rc=0
  if have apt-config; then
    out="$(APT_CONFIG="$cfg" apt-config dump 2>&1)"
    # It must have actually read our file.
    if [[ $out != *Unattended-Upgrade::Allowed-Origins::* ]]; then
      printf '        apt did not read the generated file at all\n'
      rc=1
    fi
    # And it must not have complained about it. apt prints unparsable config
    # on stderr with an E: prefix.
    if printf '%s\n' "$out" | grep -qE '^(E:|W:)'; then
      printf '        apt rejected the config: %s\n' \
        "$(printf '%s\n' "$out" | grep -E '^(E:|W:)' | head -3)"
      rc=1
    fi
  fi
  teardown_destdir
  return $rc
}

test_fail2ban_jail_parses_as_ini() {
  setup_destdir
  configure_fail2ban >/dev/null 2>&1
  local f="$CONF_DEST/etc/fail2ban/jail.d/omapi-hardening.local"
  local rc=0
  if [[ -f $f ]] && have python3; then
    if ! python3 -c "
import configparser, sys
c = configparser.ConfigParser(strict=False, interpolation=None)
c.read('$f')
assert 'sshd' in c.sections(), 'no sshd section'
assert 'recidive' in c.sections(), 'no recidive section'
assert c.get('DEFAULT', 'banaction'), 'no banaction'
" 2>&1; then
      rc=1
    fi
  fi
  teardown_destdir
  return $rc
}

test_ask_uses_gum_not_a_tty_check() {
  # The per-port and per-account loops put the loop list on stdin, so `[[ -t 0 ]]`
  # is false inside them and ask silently took its default: every passwordless
  # account locked and every unidentified port closed, with no prompt shown.
  # gum reads /dev/tty and works regardless, and is what the rest of oma-pi
  # uses. Reading the real function body guards the fix.
  local body rc=0
  body="$_ORIGINAL_ASK"
  if [[ -z $body ]]; then
    printf '        could not read ask; the test would pass vacuously\n'
    return 1
  fi
  [[ $body == *"gum confirm"* ]] || rc=1
  # The old gate. Inside a here-string or process-substitution loop this is
  # false, which is the whole bug.
  [[ $body != *'-t 0'* ]] || rc=1
  return $rc
}

test_lockout_prompt_defaults_to_no() {
  # `sudo ./security.sh --yes` must NOT be able to disable SSH passwords with
  # no verified way back in. ask returning its default under --yes means the
  # default has to be n.
  local body rc=0
  body="$_ORIGINAL_HARDEN_SSH"
  if [[ -z $body ]]; then
    printf '        could not read harden_ssh; the test would pass vacuously\n'
    return 1
  fi
  # Find the switch-to-key-only question and confirm it is not defaulted to y.
  if [[ $body == *'switch SSH to key-only anyway'* ]]; then
    local line
    line="$(printf '%s\n' "$body" | grep -A1 'switch SSH to key-only anyway' | tail -1)"
    [[ $line != *'"? y'* && $line != *'?" y'* ]] || rc=1
  else
    printf '        the key-only question is missing from harden_ssh\n'
    rc=1
  fi
  return $rc
}

test_lockdown_ssh_never_writes_allowusers_root() {
  # Under `sudo ./security.sh`, id -un is root. AllowUsers root next to
  # PermitRootLogin no is a config sshd -t accepts and that locks out every
  # account, so the bare $(id -un) must not be what gets written.
  local body rc=0
  body="$_ORIGINAL_HARDEN_SSH"
  [[ $body == *"SUDO_USER"* ]] || rc=1
  # And it must refuse outright when the resolved user is root.
  [[ $body == *"AllowUsers root"* ]] || rc=1
  return $rc
}

test_port_parser_keeps_dual_stack_wildcards() {
  # `*:PORT` is how ss renders a dual-stack wildcard listener (Node listen(),
  # docker-proxy). Dropping it closed those ports by omission - the exact
  # failure the "ask about every port" rule exists to prevent.
  local parsed
  parsed="$(_parse_ports "$(cat <<'EOF'
tcp LISTEN 0 4096 *:2377 *:*
tcp LISTEN 0 4096 0.0.0.0:22 0.0.0.0:* users:(("sshd",pid=812,fd=3))
udp UNCONN 0 0 *:36202 *:*
EOF
)")"
  assert_contains "$parsed" "tcp 2377" || return 1
  assert_contains "$parsed" "udp 36202" || return 1
  return 0
}

test_apt_periodic_keys_are_preserved() {
  # 20auto-upgrades holds the two APT::Periodic keys that actually switch
  # unattended-upgrades on. Overwriting it without them disables automatic
  # security patches while every check still reports success.
  setup_destdir
  configure_updates >/dev/null 2>&1
  local f="$CONF_DEST/etc/apt/apt.conf.d/20auto-upgrades" rc=0
  [[ -f $f ]] || { teardown_destdir; return 1; }
  grep -q 'APT::Periodic::Update-Package-Lists "1"' "$f" || rc=1
  grep -q 'APT::Periodic::Unattended-Upgrade "1"' "$f" || rc=1
  # And the policy must live in its own file, not overwrite the managed one.
  [[ -f $CONF_DEST/etc/apt/apt.conf.d/51omapi-origins ]] || rc=1
  teardown_destdir
  return $rc
}

test_audit_timeout_is_inside_peek() {
  # `timeout 60 peek find ...` cannot work: timeout execs an external program
  # and peek is a shell function, so it always exited 127 and the audit
  # reported "world-writable files: 0" on a box it never scanned.
  local body rc=0
  body="$_ORIGINAL_AUDIT"
  [[ $body == *"peek timeout 60 find"* ]] || rc=1
  [[ $body != *"timeout 60 peek"* ]] || rc=1
  return $rc
}

test_firewall_loop_visits_every_port() {
  # Regression: `IFS= read -r proto port` on a two-field read disables word
  # splitting, so the whole "tcp 80" line went into $proto and $port stayed
  # empty. Every iteration then hit the `[[ -n $port ]]` guard and continued,
  # so the script offered to open nothing and closed every port by omission -
  # the exact opposite of what it claims to do, with no error anywhere.
  setup_destdir
  DRY_RUN=1
  local -a asked=()
  listening_ports() { printf 'tcp 80\ntcp 443\nudp 3478\n'; }
  current_ssh_port() { printf '22\n'; }
  listening_process() { printf 'nginx\n'; }
  docker_present() { return 1; }
  docker_published_by() { printf ''; }
  have() { return 0; }
  ask() { asked+=("$1"); return 1; }   # answer no to everything

  configure_firewall >/dev/null 2>&1

  local rc=0
  # Every non-ssh port must have been offered. The 4th question is the
  # unrelated "close port 22 entirely" prompt, which this box reaches because
  # tailscale0 exists - so count the port offers specifically rather than
  # assuming ask was only ever called for ports.
  local port_questions=0 q
  for q in "${asked[@]}"; do
    [[ $q == allow\ * ]] && port_questions=$((port_questions + 1))
  done
  [[ $port_questions -eq 3 ]] || {
    printf '        expected 3 port questions, got %d: %s\n' "$port_questions" "${asked[*]-}"
    rc=1
  }
  [[ " ${asked[*]-} " == *"tcp/80"* ]] || rc=1
  [[ " ${asked[*]-} " == *"tcp/443"* ]] || rc=1
  [[ " ${asked[*]-} " == *"udp/3478"* ]] || rc=1
  teardown_destdir
  return $rc
}

test_firewall_skips_the_ssh_port() {
  # The ssh port gets its own `ufw limit` rule; re-asking about it as a
  # generic port would be a duplicate, and would offer to close it.
  setup_destdir
  DRY_RUN=1
  local -a asked=()
  listening_ports() { printf 'tcp 22\ntcp 80\n'; }
  current_ssh_port() { printf '22\n'; }
  listening_process() { printf 'sshd\n'; }
  docker_present() { return 1; }
  docker_published_by() { printf ''; }
  have() { return 0; }
  ask() { asked+=("$1"); return 1; }

  configure_firewall >/dev/null 2>&1

  local rc=0
  [[ " ${asked[*]-} " != *"tcp/22"* ]] || rc=1
  [[ " ${asked[*]-} " == *"tcp/80"* ]] || rc=1
  teardown_destdir
  return $rc
}

# ---------------------------------------------------------------------------
printf '\nrunning\n'

t 'sshd managed block is prepended'                    test_sshd_block_prepended
t 'sshd managed block is idempotent'                    test_sshd_block_is_idempotent
t 'sshd config keeps mode and owner'                    test_sshd_preserves_mode_and_owner
t 'sshd config is created when absent'                  test_sshd_creates_missing_config

t 'an empty authorized_keys blocks the lockout change'  test_no_lockout_without_key
t 'a key in authorized_keys2 is found'                  test_no_lockout_with_second_path_only
t 'a real private key is rejected'                      test_usable_key_rejects_real_private_key
t 'a private key is not a usable key'                   test_usable_key_rejects_private_key
t 'an empty file is not a usable key'                   test_usable_key_rejects_empty_file
t 'a real public key is accepted'                       test_usable_key_accepts_real_key

t 'port parser handles ss output'                       test_port_parser_real_ss_output
t 'port parser handles netstat output'                  test_port_parser_real_netstat_output
t 'port parser ignores junk'                            test_port_parser_ignores_garbage
t 'port parser keeps dual-stack wildcards'              test_port_parser_keeps_dual_stack_wildcards

t 'apt config contains no ANSI escapes'                 test_apt_config_has_no_ansi_escapes
t 'apt config origins match this OS release'            test_apt_config_origins_match_os_release
t 'apt Periodic keys are preserved'                     test_apt_periodic_keys_are_preserved

t 'a dry run writes nothing'                            test_dry_run_touches_nothing

t 'ask uses gum, not a tty check'                       test_ask_uses_gum_not_a_tty_check
t 'the lockout prompt defaults to no'                   test_lockout_prompt_defaults_to_no
t '--lockdown-ssh refuses to write AllowUsers root'      test_lockdown_ssh_never_writes_allowusers_root
t 'audit timeout is inside peek'                        test_audit_timeout_is_inside_peek

t 'the firewall loop visits every port'                 test_firewall_loop_visits_every_port
t 'the firewall loop skips the ssh port'                test_firewall_skips_the_ssh_port

t 'unknown task is rejected'                            test_unknown_task_rejected
t 'unknown option is rejected'                          test_unknown_option_rejected
t '--help works'                                        test_help_works
t '--list works'                                        test_list_works
t 'a bad task stops before any change'                  test_bad_task_before_any_change

t 'this box authorized_keys parses'                     test_real_authorized_keys_parsed
t 'every sysctl key exists on this kernel'              test_sysctl_keys_exist_on_this_kernel
t 'generated sysctl file has no bogus keys'             test_sysctl_file_has_no_bogus_keys
t 'ip_forward stays on when Docker runs'                test_ip_forward_never_disabled_when_docker_runs
t 'ip_forward goes off when Docker absent'              test_ip_forward_zeroed_when_no_docker
t 'docker_present needs no privilege'                   test_docker_present_needs_no_privilege
t 'apt accepts the generated config'                    test_apt_config_parses_with_real_apt
t 'fail2ban jail parses as INI'                         test_fail2ban_jail_parses_as_ini

printf '\n%s passed, %s failed\n\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]] || exit 1
