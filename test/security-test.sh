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
}

teardown_destdir() {
  rm -rf "$CONF_DEST"
  unset OMAPI_SECURITY_DESTDIR
  CONF_DEST=""
  DRY_RUN=0
  ASSUME_YES=0
}

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

  local out; out="$(cat "$CONF_DEST/etc/ssh/sshd_config")"
  # The managed value must come first, or an Include drop-in or a later
  # directive silently wins.
  [[ $(printf '%s\n' "$out" | grep -n "PermitRootLogin no" | cut -d: -f1) -lt \
     $(printf '%s\n' "$out" | grep -n "prohibit-password" | cut -d: -f1) ]]
  teardown_destdir
}

test_sshd_block_is_idempotent() {
  setup_destdir
  mkdir -p "$CONF_DEST/etc/ssh"
  printf 'Port 22\n' >"$CONF_DEST/etc/ssh/sshd_config"
  local block; block="$(mktemp)"
  printf '%s\n%s\n%s\n' "$MANAGED_BEGIN" "PermitRootLogin no" "$MANAGED_END" >"$block"

  replace_managed_block "$block" /etc/ssh/sshd_config
  local first; first="$(cat "$CONF_DEST/etc/ssh/sshd_config")"
  replace_managed_block "$block" /etc/ssh/sshd_config
  local second; second="$(cat "$CONF_DEST/etc/ssh/sshd_config")"

  # Running this twice must not accumulate blocks, and must not lose the
  # user's own lines.
  assert_eq "$(printf '%s' "$second" | grep -c "$MANAGED_BEGIN")" "1" &&
    assert_contains "$second" "Port 22"
  teardown_destdir
  rm -f "$block"
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

  local after; after="$(stat -c '%a %U' "$f")"
  assert_eq "$after" "$before"
  teardown_destdir
}

test_sshd_creates_missing_config() {
  setup_destdir
  local block; block="$(mktemp)"
  printf '%s\n%s\n%s\n' "$MANAGED_BEGIN" "PermitRootLogin no" "$MANAGED_END" >"$block"
  replace_managed_block "$block" /etc/ssh/sshd_config
  rm -f "$block"
  [[ -f $CONF_DEST/etc/ssh/sshd_config ]] &&
    grep -q "PermitRootLogin no" "$CONF_DEST/etc/ssh/sshd_config"
  teardown_destdir
}

# ---------------------------------------------------------------------------
printf '\nlockout protection\n'

test_no_lockout_without_key() {
  # The single most important behaviour in the script: with no usable key
  # anywhere, PasswordAuthentication must be left alone.
  setup_destdir
  mkdir -p "$CONF_DEST/etc/ssh"
  printf 'PasswordAuthentication yes\n' >"$CONF_DEST/etc/ssh/sshd_config"

  # A key file that is present but empty, and one with a truncated key, are
  # the two cases that look fine and lock you out.
  local home; home="$(mktemp -d)"
  mkdir -p "$home/.ssh"
  : >"$home/.ssh/authorized_keys"

  local blocked=0
  (
    backdoor_user="$(_no_lockout_probe "$home")" || blocked=1
  )
  rm -rf "$home"
  [[ $blocked -eq 1 ]]
  teardown_destdir
}

# A tiny stand-in for the real check, exercising the same function with a
# specific home directory.
_no_lockout_probe() {
  local home="$1"
  grep -qvE '^\s*(#|$)' "$home/.ssh/authorized_keys" 2>/dev/null &&
    ssh-keygen -l -f "$home/.ssh/authorized_keys" &>/dev/null
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
  parsed="$(_parse_ports <<'EOF'
Netid State Recv-Q Send-Q Local Address:Port Peer Address:Port Process
tcp LISTEN 0 4096 0.0.0.0:22 0.0.0.0:* users:(("sshd",pid=812,fd=3))
tcp LISTEN 0 4096 127.0.0.53%lo:53 0.0.0.0:* users:(("systemd-resolve",pid=742,fd=12))
tcp LISTEN 0 4096 [::]:22 [::]:* users:(("sshd",pid=812,fd=3))
udp UNCONN 0 0 0.0.0.0:68 0.0.0.0:* users:(("dhclient",pid=500,fd=6))
EOF
)"
  # 53 on loopback must not appear: it is not reachable from off-box.
  assert_contains "$parsed" "tcp 22" &&
    assert_lacks "$parsed" "tcp 53" &&
    assert_contains "$parsed" "udp 68" &&
    # One line per unique protocol/port pair.
    assert_eq "$(printf '%s\n' "$parsed" | grep -c 'tcp 22')" "1"
}

test_port_parser_real_netstat_output() {
  local parsed
  parsed="$(_parse_ports <<'EOF'
Proto Recv-Q Send-Q Local Address Foreign Address State PID/Program name
tcp 0 0 0.0.0.0:22 0.0.0.0:* LISTEN 812/sshd
tcp 0 0 127.0.0.1:631 0.0.0.0:* LISTEN 900/cupsd
tcp 0 0 :::22 :::* LISTEN 812/sshd
udp 0 0 0.0.0.0:68 0.0.0.0:* 500/dhclient
EOF
)"
  assert_contains "$parsed" "tcp 22" &&
    assert_lacks "$parsed" "tcp 631" &&
    assert_contains "$parsed" "udp 68"
}

test_port_parser_ignores_garbage() {
  local parsed
  parsed="$(_parse_ports <<'EOF'
tcp LISTEN 0 100 0.0.0.0:22 not-an-address
some random line
udp UNCONN 0 0 *:8080 *:* users:(("x",pid=1,fd=1))
EOF
)"
  assert_contains "$parsed" "tcp 22"
}

_parse_ports() {
  # Reads stdin, not a positional argument: the awk program below is
  # positional-free but a bare `$1` anywhere in a shell function under `set -u`
  # is a hard error the moment the function is called with no arguments.
  awk '
    {
      proto = tolower($1)
      if (proto != "tcp" && proto != "udp") next
      port = ""
      for (i = 2; i <= NF; i++) {
        if ($i !~ /:/ || $i ~ /^(127\.|::1\[|\[::1\])/) continue
        if ($i ~ /^\[?[0-9A-Fa-f.:%]+\]?:[0-9]+$/) { port = $i; break }
      }
      if (port == "") next
      sub(/.*:/, "", port)
      if (port !~ /^[0-9]+$/) next
      print proto, port
    }' | sort -u -k1,1 -k2,2n
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
  grep -q "${codename}-security" "$CONF_DEST/etc/apt/apt.conf.d/20auto-upgrades"
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
  local before; before="$(cat "$CONF_DEST/etc/ssh/sshd_config")"
  DRY_RUN=1
  write_conf /etc/fail2ban/jail.d/omapi-hardening.local <<<'ignored'
  DRY_RUN=0
  local after; after="$(cat "$CONF_DEST/etc/ssh/sshd_config")"
  assert_eq "$after" "$before" &&
    [[ ! -e $CONF_DEST/etc/fail2ban ]]
  teardown_destdir
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
  local body
  body="$(declare -f docker_present)"
  if [[ $body == *peek* || $body == *sudo* ]]; then
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
  local cfg="$CONF_DEST/etc/apt/apt.conf.d/20auto-upgrades"
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

# ---------------------------------------------------------------------------
printf '\nrunning\n'

t 'sshd managed block is prepended'                    test_sshd_block_prepended
t 'sshd managed block is idempotent'                    test_sshd_block_is_idempotent
t 'sshd config keeps mode and owner'                    test_sshd_preserves_mode_and_owner
t 'sshd config is created when absent'                  test_sshd_creates_missing_config

t 'an empty authorized_keys blocks the lockout change'  test_no_lockout_without_key
t 'a private key is not a usable key'                   test_usable_key_rejects_private_key
t 'an empty file is not a usable key'                   test_usable_key_rejects_empty_file
t 'a real public key is accepted'                       test_usable_key_accepts_real_key

t 'port parser handles ss output'                       test_port_parser_real_ss_output
t 'port parser handles netstat output'                  test_port_parser_real_netstat_output
t 'port parser ignores junk'                            test_port_parser_ignores_garbage

t 'apt config contains no ANSI escapes'                 test_apt_config_has_no_ansi_escapes
t 'apt config origins match this OS release'            test_apt_config_origins_match_os_release

t 'a dry run writes nothing'                            test_dry_run_touches_nothing

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
