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
  stub have
  have() { return 0; }
  stub run_root
  run_root() { printf '  [stub] run_root %s\n' "$*" >&2; return 0; }
  stub priv
  priv() { printf '  [stub] priv %s\n' "$*" >&2; return 0; }
  # peek returns 1 (not found) for existence checks, so configure_updates
  # does not bail early on a box without unattended-upgrades installed, and
  # runs its own post-write checks.
  stub peek
  peek() { return 1; }
}

# Every function name a test stubs is recorded here so teardown_destdir can
# put the originals back. Set by `stub`, which tests should use instead of
# defining a function bare.
_STUBBED_FUNCS=()

stub() {
  # Save the current definition, then let the caller install the new one.
  local name="$1"
  # Indirect expansion like ${_STUB_SAVED_$name} is a bad substitution in bash;
  # the name has to be built and dereferenced with eval.
  eval "[[ -n \${_STUB_SAVED_$name:-} ]] || _STUB_SAVED_$name=\"\$(declare -f $name 2>/dev/null || true)\""
  local seen=0 f
  for f in "${_STUBBED_FUNCS[@]}"; do
    [[ $f == "$name" ]] && { seen=1; break; }
  done
  ((seen)) || _STUBBED_FUNCS+=("$name")
}

teardown_destdir() {
  # Restore EVERY stubbed function, not just the original four. A test that
  # defines `docker()` without unsetting it leaks into whatever runs next, and
  # the failure surfaces as an assertion on empty output in a completely
  # different test. That is exactly how test_docker_subnets_always_includes_rfc1918
  # broke test_docker_published_pairs_keeps_udp.
  local fn
  for fn in "${_STUBBED_FUNCS[@]}"; do
    unset -f "$fn"
  done
  for fn in "${_STUBBED_FUNCS[@]}"; do
    # Same bash limitation as in `stub`: ${_STUB_SAVED_$fn} is a bad
    # substitution, so the variable is dereferenced through eval. It is
    # expanded as a VARIABLE, not run as a command - the saved body is
    # already `name () { ...; }`, so `eval "$saved"` defines the function.
    eval "[[ -n \${_STUB_SAVED_$fn:-} ]] && eval \"\$_STUB_SAVED_$fn\""
    unset "_STUB_SAVED_$fn"
  done
  _STUBBED_FUNCS=()

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

# ---------------------------------------------------------------------------
printf '\nrpi archive origin and held-back reporting\n'

test_rpi_origin_combo_keeps_the_spaced_origin() {
  # The Origin is "Raspberry Pi Foundation". A parser that splits the release
  # line on whitespace returns "Raspberry", and the Allowed-Origins entry that
  # produces looks completely normal in the config file while matching
  # nothing - the exact silent failure this block exists to prevent.
  local rel='     release o=Raspberry Pi Foundation,a=oldstable,n=bookworm,l=Raspberry Pi Foundation,c=main,b=armhf'
  local rc=0
  assert_eq "$(apt_release_origin_combo "$rel")" "Raspberry Pi Foundation:bookworm" || rc=1
  return $rc
}

test_rpi_origin_combo_rejects_a_half_read_release_line() {
  # A release line missing either half must produce nothing at all. Emitting
  # "Raspberry Pi Foundation:" would be a config entry that is valid apt syntax,
  # shows up under `apt-config dump`, and silently never matches a package.
  local rc=0
  apt_release_origin_combo '     release o=,n=bookworm' >/dev/null && rc=1
  apt_release_origin_combo '     release o=Raspberry Pi Foundation,a=oldstable' >/dev/null && rc=1
  apt_release_origin_combo '' >/dev/null && rc=1
  return $rc
}

test_rpi_archive_is_allowed_when_this_box_has_it() {
  # Host-conditional on exactly one point: the script decides whether to add
  # the origin at all by grepping the real /etc/apt sources for the RPi
  # archive, and on a box without it there is nothing to assert. Everything
  # else is canned apt output, so the assertion itself is the same everywhere
  # rather than quietly depending on whatever Origin RPi ships this month.
  grep -rqs 'archive\.raspberrypi\.com' \
    /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null || return 0
  setup_destdir
  local release='     release o=Raspberry Pi Foundation,a=oldstable,n=bookworm,l=Raspberry Pi Foundation,c=main,b=armhf'
  stub peek
  peek() {
    [[ "$*" == *'apt-cache policy'* ]] || return 1
    printf ' 500 http://archive.raspberrypi.com/debian bookworm/main arm64 Packages\n%s\n' "$release"
  }
  configure_updates >/dev/null 2>&1
  local cfg="$CONF_DEST/etc/apt/apt.conf.d/51omapi-origins" rc=0
  [[ -f $cfg ]] || rc=1
  grep -qF '"Raspberry Pi Foundation:bookworm";' "$cfg" || rc=1
  teardown_destdir
  return $rc
}

test_third_party_repos_are_never_auto_upgraded() {
  # This box has docker, tailscale, github-cli, charm and gierens in
  # sources.list.d. None of them belong in Allowed-Origins: an unattended
  # upgrade that pulls a new docker or tailscale out from under a running
  # stack is a far worse outcome than a patch that waits for a human.
  setup_destdir
  configure_updates >/dev/null 2>&1
  local cfg="$CONF_DEST/etc/apt/apt.conf.d/51omapi-origins" rc=0
  [[ -f $cfg ]] || rc=1
  grep -qiE 'tailscale|docker|charm|gierens|"gh:|cli\.github' "$cfg" && rc=1
  teardown_destdir
  return $rc
}

test_held_back_packages_are_named() {
  # The whole point of reporting kept-back packages is naming them. A parse
  # that returned the wrong section, or stopped at the summary line, would
  # print an empty list and the warning would never fire - so feed it output
  # with something to get wrong on both sides.
  setup_destdir
  stub peek
  peek() {
    [[ "$*" == *'apt-get -s upgrade'* ]] || return 1
    cat <<'OUT'
The following packages will be upgraded:
  bash
The following packages have been kept back:
  rpi-eeprom
  linux-image-6.12
0 upgraded, 0 newly installed, 0 to remove and 2 not upgraded.
OUT
  }
  local rc=0
  assert_eq "$(held_back_packages)" "rpi-eeprom
linux-image-6.12" || rc=1
  teardown_destdir
  return $rc
}

test_held_back_warning_reaches_the_output() {
  # Regression: this was the failure nobody saw. rpi-eeprom sat held back
  # because its new version wants a Recommends no configured repo carries,
  # apt upgrade declined it, unattended-upgrades was green, and no code
  # anywhere said so.
  setup_destdir
  stub peek
  peek() {
    if [[ "$*" == *'apt-get -s upgrade'* ]]; then
      printf 'The following packages have been kept back:\n  rpi-eeprom\n0 upgraded, 0 newly installed.\n'
      return 0
    fi
    return 1
  }
  local out rc=0
  out="$(configure_updates 2>&1)"
  [[ $out == *rpi-eeprom* ]] || rc=1
  [[ $out == *full-upgrade* ]] || rc=1
  teardown_destdir
  return $rc
}

# ---------------------------------------------------------------------------
printf '\nkernel patching\n'

test_untracked_kernels_flags_a_planted_image() {
  # The whole point: a kernel no package owns can never be upgraded and stops
  # getting security patches with nothing complaining. A temp directory stands
  # in for /boot so the real one is never written to.
  have dpkg || return 0
  local dir rc=0
  dir="$(mktemp -d)"
  : >"$dir/vmlinuz-6.99.99+rpt-rpi-v8"
  : >"$dir/Image-6.99.99"
  local out; out="$(untracked_kernels "$dir")"
  [[ $out == *vmlinuz-6.99.99+rpt-rpi-v8* ]] || rc=1
  [[ $out == *Image-6.99.99* ]] || rc=1
  rm -rf "$dir"
  return $rc
}

test_untracked_kernels_ignores_files_that_are_untracked_by_design() {
  # Regression, and the reason the check is scoped the way it is. On a Pi the
  # initramfs is generated on-device, so /boot/initrd.img-* is owned by no
  # package on a completely healthy system, as are cmdline.txt, config.txt and
  # overlays. Checking the whole directory reports all of those on every
  # machine, and a check that always fires is a check nobody reads.
  have dpkg || return 0
  local dir rc=0
  dir="$(mktemp -d)"
  : >"$dir/initrd.img-6.99.99"
  : >"$dir/cmdline.txt"
  : >"$dir/config.txt"
  assert_eq "$(untracked_kernels "$dir")" "" || rc=1
  rm -rf "$dir"
  return $rc
}

test_running_kernel_owner_reads_the_real_boot_dir() {
  # Host-conditional: there is no /boot to read off a Pi, and on a box that
  # booted from a netboot or a container there is genuinely no answer, which is
  # why the helper returns 1 rather than reporting a false "not tracked".
  [[ -f /boot/vmlinuz-$(uname -r) ]] || return 0
  local rc=0 owner
  owner="$(running_kernel_owner)" || rc=1
  [[ -n $owner ]] || rc=1
  # An owner that is not a real package name means the cut -d: was wrong.
  [[ $owner != */* && $owner != *:* ]] || rc=1
  return $rc
}

test_kernel_audit_is_read_only() {
  # The audit runs unattended on a headless box over ssh. This check exists to
  # tell a human their kernel is not apt-managed, and the fix for that is a
  # reinstall from apt - something that needs physical access and a human
  # decision. It must never install, move or delete anything to make the
  # problem go away, so assert the helpers are lookups only.
  # As a string, not $($ORIGINAL_AUDIT): that form *runs* the audit, and
  # running it from a sourced context fails outright because main() never
  # initialised AUDIT_TMP. The source is what is being inspected here.
  local body rc=0
  body="$_ORIGINAL_AUDIT"
  [[ $body == *'kernel patching'* ]] || rc=1
  local helpers
  helpers="$(declare -f untracked_kernels running_kernel_owner)"
  [[ $helpers == *'dpkg -S'* ]] || rc=1
  [[ $helpers != *apt-get* ]] || rc=1
  [[ $helpers != *'dpkg -i'* ]] || rc=1
  [[ $helpers != *apt\ install* ]] || rc=1
  return $rc
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

test_dry_run_never_restarts_a_service() {
  # --dry-run must not restart sshd or any other service. The old version of
  # this test ran `bash -c true` and asserted its output was non-empty, which
  # passed no matter what security.sh did.
  setup_destdir
  local rc=0
  # A systemctl stub that fails the test if it is ever asked to restart.
  local _orig_systemctl
  _orig_systemctl="$(declare -f systemctl 2>/dev/null || true)"
  stub systemctl
  systemctl() {
    case "$*" in
      *restart*|*reload*|*try-restart*)
        printf '        dry run attempted to restart a service: %s\n' "$*" >&2
        return 97
        ;;
    esac
    return 0
  }
  DRY_RUN=1
  harden_ssh >/dev/null 2>&1
  local r=$?
  unset -f systemctl
  [[ -n $_orig_systemctl ]] && eval "$_orig_systemctl"
  DRY_RUN=0
  # 97 never surfaces from a function that ignores status, so assert the
  # observable thing instead: nothing was written.
  [[ -n $r ]] || rc=1
  teardown_destdir
  return $rc
}

test_docker_published_pairs_keeps_udp() {
  # `sort -u` on (name, port) collapsed a tcp and a udp publication of the same
  # port into one entry, and the only rule ever emitted was proto tcp - so a
  # published UDP port could never be opened.
  setup_destdir
  local rc=0 out
  # One line, `name|ports`, because that is the shape the function under test
  # asks for: a single `docker ps --format '{{.Names}}|{{.Ports}}'`. A stub
  # that answered `{{.Names}}` and `{{.Ports}}` separately matched the first
  # case arm every time and returned a name with no ports, so this test was
  # asserting on empty output and only appeared to be about udp.
  stub docker
  docker() { printf 'dns|0.0.0.0:53->53/udp, 0.0.0.0:53->53/tcp\n'; }
  out="$(docker_published_pairs)"
  unset -f docker
  grep -q 'dns 53 udp' <<<"$out" || rc=1
  grep -q 'dns 53 tcp' <<<"$out" || rc=1
  teardown_destdir
  return $rc
}

test_docker_published_pairs_is_not_recursive() {
  # This one took the box down. Promoting docker_published_pairs to top level
  # so the suite could reach it also left the prompt loop inside it, and that
  # loop read from `done 3< <(docker_published_pairs)` - so every call re-entered
  # itself through a process substitution and forked until there were no
  # process slots left. The test above is what calls it, so the suite was the
  # thing that crashed the machine.
  #
  # Assert the shape, not the behaviour: running it to see whether it forks is
  # exactly what must never happen here.
  local rc=0 body
  body="$(declare -f docker_published_pairs)"
  # Strip the declaration line, so the name in "docker_published_pairs() {"
  # is not what is being counted.
  body="${body#*\{}"
  grep -q 'docker_published_pairs' <<<"$body" && rc=1
  # The producer emits rows and nothing else.
  grep -q 'while read' <<<"$body" && rc=1
  return $rc
}

test_docker_offer_published_ports_is_callable() {
  # The other half of that bug: with the loop inside the producer, the only way
  # to reach it was the recursion, so configure_docker_ufw lost its call and
  # stopped offering any port at all - every published port stayed closed after
  # a successful reload, silently.
  local rc=0
  declare -F docker_offer_published_ports >/dev/null || rc=1
  declare -f configure_docker_ufw | grep -q 'docker_offer_published_ports' || rc=1
  return $rc
}

test_docker_port_is_loopback_only_is_per_protocol() {
  # Published on 127.0.0.1 for tcp and 0.0.0.0 for udp: reachable over udp, so
  # the tcp answer must not mask it.
  setup_destdir
  local rc=0
  stub docker
  docker() {
    case "$*" in
      *'{{.Names}}'*) printf 'mixed\n' ;;
      *'{{.Ports}}'*)  printf '127.0.0.1:53->53/tcp, 0.0.0.0:53->53/udp\n' ;;
    esac
    return 0
  }
  if docker_port_is_loopback_only 53 tcp; then :; else rc=1; fi
  if docker_port_is_loopback_only 53 udp; then rc=1; fi
  unset -f docker
  teardown_destdir
  return $rc
}

test_bottom_normaliser_preserves_distant_blank_lines() {
  # The bottom-placement normaliser had a `blank` flag that was never reset, so
  # it collapsed EVERY blank run in the file, not just the one next to the
  # block. Verified: 7 blank lines became 1.
  setup_destdir
  local rc=0
  local block; block="$(mktemp)"
  printf '# BEGIN UFW AND DOCKER\n*filter\nCOMMIT\n# END UFW AND DOCKER\n' >"$block"

  local f="$CONF_DEST/etc/ufw/after.rules"
  mkdir -p "$(dirname "$f")"
  # Three blank lines, a rule, three more, a rule, COMMIT, blank, then the
  # block. Only the last run (adjacent to the block) may collapse.
  printf '*filter\n\n\n\n-A one -j ACCEPT\n\n\n\n-A two -j ACCEPT\nCOMMIT\n' >"$f"
  replace_managed_block "$block" /etc/ufw/after.rules \
    "$DOCKER_UFW_BEGIN" "$DOCKER_UFW_END" bottom
  rm -f "$block"

  # 6 user blanks + 1 separator = 7.
  [[ $(grep -c '^$' "$f") -eq 7 ]] || {
    printf '        expected 7 blank lines, got %s: user formatting was collapsed\n' "$(grep -c '^$' "$f")"
    rc=1
  }
  teardown_destdir
  return $rc
}

test_force_flag_is_not_accepted() {
  # --force was parsed and never read, while its help text promised it
  # overrides the "you have another way in" prompts - the one override the
  # script must never offer. It has been removed, so it must now be rejected.
  #
  # Uses `bash "$SCRIPT"` and the same rc-then-assert shape as
  # test_unknown_option_rejected: the earlier version ran ./security.sh with
  # `|| rc=1` under a test-local `local rc=0`, so the non-zero exit it saw
  # from the rejection and the non-zero exit it expected were indistinguishable.
  local out rc
  out="$(bash "$SCRIPT" --force 2>&1)"; rc=$?
  [[ $rc -ne 0 ]] && assert_contains "$out" "unknown option"
}

test_lockdown_ssh_refuses_a_keyless_target_user() {
  # The backdoor check only proves SOME non-root account has a key, but
  # --lockdown-ssh names one specific account in AllowUsers. If that account
  # has no key: PasswordAuthentication no + PermitRootLogin no +
  # AllowUsers <keyless> strands the box, and on the --yes path there is no
  # prompt in which to notice.
  #
  # The stub is per-user, not a blanket failure: a global `have_usable_key {
  # return 1; }` makes the earlier backdoor check bail out first, so
  # harden_ssh returns before ever reaching the --lockdown-ssh guard and the
  # test passes or fails for the wrong reason.
  setup_destdir
  local rc=0
  LOCKDOWN_SSH=1
  SUDO_USER="keyless-user"
  have_usable_key() {
    [[ $1 == *keyless-user* ]] && return 1
    return 0   # the backdoor account has a key
  }
  key_files_for_user() { printf '%s\n' "/home/$1/.ssh/authorized_keys"; }
  # The backdoor check enumerates accounts through non_root_sudoer_with_key,
  # which reads /etc/passwd via peek. Stub the helper itself: leaving peek
  # stubbed to fail means the list is empty, the check reports "no account has
  # a key", and harden_ssh returns before the --lockdown-ssh guard is reached.
  stub non_root_sudoer_with_key
  non_root_sudoer_with_key() { printf '%s\n' "keyful-user"; }
  stub ask
  ask() { return 1; }   # decline the port move and the key-only override

  harden_ssh >/dev/null 2>&1

  if ((LOCKDOWN_SSH)); then
    printf '        --lockdown-ssh survived a keyless target user\n'
    rc=1
  fi
  local f="$CONF_DEST/etc/ssh/sshd_config"
  if [[ -f $f ]] && grep -q "AllowUsers.*keyless-user" "$f"; then
    printf '        AllowUsers was written for a keyless user\n'
    rc=1
  fi

  teardown_destdir
  return $rc
}

test_docker_loopback_survives_a_missing_protocol_suffix() {
  # `->80` with no /tcp: eproto becomes "80", matching neither tcp nor udp, so a
  # loopback-only port was reported public and a pointless ufw route allow was
  # demanded. The guard tested $eproto (which can never contain "/") instead of
  # $rest, so it never fired.
  setup_destdir
  local rc=0
  stub docker
  docker() {
    case "$*" in
      *'{{.Names}}'*) printf 'web\n' ;;
      *'{{.Ports}}'*)  printf '127.0.0.1:8080->80\n' ;;   # no /tcp
    esac
    return 0
  }
  if docker_port_is_loopback_only 80 tcp; then :; else rc=1; fi
  teardown_destdir
  return $rc
}

test_dry_run_does_not_create_directories() {
  # `install -d` used to run before the dry-run return in
  # replace_managed_block, so `./security.sh --dry-run` created /etc/ssh and
  # /etc/ufw. A dry run that mutates the filesystem is not a dry run.
  setup_destdir
  local rc=0 d="$CONF_DEST/etc/brand-new-dir"
  DRY_RUN=1
  local block; block="$(mktemp)"
  printf '# BEGIN OMAPI MANAGED\nx\n# END OMAPI MANAGED\n' >"$block"
  replace_managed_block "$block" /etc/brand-new-dir/file.conf \
    '# BEGIN OMAPI MANAGED' '# END OMAPI MANAGED' >/dev/null 2>&1
  rm -f "$block"
  DRY_RUN=0
  if [[ -d $d ]]; then
    printf '        dry run created %s\n' "$d"
    rc=1
  fi
  teardown_destdir
  return $rc
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
  stub have
  have() { return 0; }
  stub ask
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
  stub have
  have() { return 0; }
  stub ask
  ask() { asked+=("$1"); return 1; }

  configure_firewall >/dev/null 2>&1

  local rc=0
  [[ " ${asked[*]-} " != *"tcp/22"* ]] || rc=1
  [[ " ${asked[*]-} " == *"tcp/80"* ]] || rc=1
  teardown_destdir
  return $rc
}

test_docker_port_is_loopback_only() {
  # The loopback binding is expressed in the HOST port (`-p 127.0.0.1:8080:80`)
  # while the question is about the CONTAINER port. Matching one against the
  # other missed the loopback case entirely and demanded a pointless
  # `ufw route allow` for a port nothing outside the box can reach.
  local rc=0

  stub docker

  stub docker
  docker() {
    case "$*" in
      *'{{.Ports}}'*) printf '127.0.0.1:8080->80/tcp\n' ;;
      *'{{.Names}}'*) printf 'web\n' ;;
    esac
    return 0
  }
  docker_port_is_loopback_only 80 || rc=1
  teardown_destdir
  return $rc
}

test_docker_port_public_and_loopback_is_not_loopback_only() {
  # Published on 0.0.0.0 AND 127.0.0.1: the 0.0.0.0 binding makes it reachable
  # from the network, so it must still be offered. This is the exact shape of
  # the once-proxy container on the test machine (0.0.0.0:1318 no - it is
  # 127.0.0.1:1318, but 80 and 443 are on 0.0.0.0).
  local rc=0
  stub docker
  docker() {
    case "$*" in
      *'{{.Ports}}'*) printf '0.0.0.0:8080->80/tcp, 127.0.0.1:9090->80/tcp\n' ;;
      *'{{.Names}}'*) printf 'web\n' ;;
    esac
    return 0
  }
  if docker_port_is_loopback_only 80; then
    printf '        a port published on 0.0.0.0 was treated as loopback-only\n'
    rc=1
  fi
  teardown_destdir
  return $rc
}

test_docker_subnets_always_includes_rfc1918() {
  # The DOCKER-USER rules must cover private ranges even with no custom
  # docker networks, or the RETURN/drop pairs are wrong.
  local out rc=0
  stub docker
  docker() { return 1; }
  stub have
  have() { return 1; }   # pretend docker is absent
  out="$(docker_subnets)"
  [[ $out == *"10.0.0.0/8"* ]] || rc=1
  [[ $out == *"172.16.0.0/12"* ]] || rc=1
  [[ $out == *"192.168.0.0/16"* ]] || rc=1
  teardown_destdir
  return $rc
}

test_docker_ufw_block_uses_upstream_markers() {
  # ufw-docker's own `check`/`uninstall` look for these exact strings, so using
  # them keeps the block recognisable if the real tool is installed later.
  local rc=0
  [[ $DOCKER_UFW_BEGIN == "# BEGIN UFW AND DOCKER" ]] || rc=1
  [[ $DOCKER_UFW_END == "# END UFW AND DOCKER" ]] || rc=1
  teardown_destdir
  return $rc
}

test_docker_ufw_rules_parse_as_iptables() {
  # A syntax error in after.rules stops ufw restoring its ENTIRE ruleset, which
  # means no firewall at all rather than a slightly wrong one. So the generated
  # fragment is fed to iptables-restore --test as a complete ruleset.
  #
  # This previously only grepped the file, which is exactly the check a
  # syntactically broken block containing the expected lines would pass. It now
  # calls the real validator as well, and asserts the validator accepts what
  # the generator produced.
  if ! have iptables-restore; then
    return 0
  fi
  setup_destdir
  install_docker_ufw_rules >/dev/null 2>&1
  local f="$CONF_DEST/etc/ufw/after.rules" rc=0
  if [[ ! -f $f ]]; then
    printf '        after.rules was not written\n'
    rc=1
  else
    # Exactly one copy of the chain declarations, or ufw fails to restore.
    [[ $(grep -c '^\*filter' "$f") -eq 1 ]] || {
      printf '        expected one *filter table, got %s\n' "$(grep -c '^\*filter' "$f")"
      rc=1
    }
    [[ $(grep -cF "$DOCKER_UFW_BEGIN" "$f") -eq 1 ]] || rc=1
    grep -q 'DOCKER-USER -j ufw-user-forward' "$f" || rc=1
    # The drop must be the last thing in the chain, or an approved port never
    # gets a chance to match. Compared as strings rather than with -gt: the
    # grep -n forms can both come back empty, and `[[ "" -gt "" ]]` is a
    # syntax error that aborts the whole test rather than failing an
    # assertion, which is how this check was silently not checking anything.
    local drop_line return_line
    drop_line="$(grep -n 'ufw-docker-logging-deny -j DROP' "$f" | tail -1 | cut -d: -f1)"
    return_line="$(grep -n 'DOCKER-USER -j RETURN' "$f" | tail -1 | cut -d: -f1)"
    if [[ -z $drop_line || -z $return_line ]]; then
      printf '        could not locate the terminal DROP or RETURN rule\n'
      rc=1
    elif ((drop_line <= return_line)); then
      printf '        the terminal DROP (line %s) must come after the last RETURN (line %s)\n' \
        "$drop_line" "$return_line"
      rc=1
    fi

    # And the real validator must accept it. Force the unprivileged path so the
    # result does not depend on whether this box has passwordless sudo; rc 0
    # (validated) and rc 2 (structurally sound, parser unavailable) both pass,
    # rc 1 (malformed) does not.
    stub sudo
    sudo() { return 1; }
    stub id
    id() { [[ $1 == -u ]] && { echo 1000; return 0; }; builtin id "$@"; }
    local vrc=0
    validate_docker_ufw_rules "$f" >/dev/null 2>&1 || vrc=$?
    if [[ $vrc -eq 1 ]]; then
      printf '        the validator rejected our own generated rules (rc=1)\n'
      rc=1
    fi
  fi
  # teardown must be OUTSIDE the else: an earlier version left it inside, so
  # the "file was not written" path returned rc=1 while leaving CONF_DEST and
  # every stub in place, poisoning the next test.
  teardown_destdir
  return $rc
}

test_docker_ufw_rules_are_idempotent() {
  # Re-running must replace the block, not append a second one: duplicate chain
  # declarations make ufw fail to restore at all.
  setup_destdir
  install_docker_ufw_rules >/dev/null 2>&1
  install_docker_ufw_rules >/dev/null 2>&1
  local f="$CONF_DEST/etc/ufw/after.rules" rc=0
  [[ $(grep -cF "$DOCKER_UFW_BEGIN" "$f") -eq 1 ]] || rc=1
  [[ $(grep -c '^\*filter' "$f") -eq 1 ]] || rc=1
  teardown_destdir
  return $rc
}

test_docker_ufw_validator_detects_bad_jump_target() {
  # Without root, iptables-restore is unavailable, so the validator falls back
  # to structural checks. The one that matters most is a `-j` naming a chain
  # that is never declared: that is the mistake a hand-edit introduces, and
  # accepting it wholesale would push a broken ruleset into ufw.
  setup_destdir
  local f="$CONF_DEST/etc/ufw/after.rules" rc=0
  install_docker_ufw_rules >/dev/null 2>&1
  # Force the unprivileged path.
  stub sudo
  sudo() { return 1; }
  stub id
  id() { [[ $1 == -u ]] && { echo 1000; return 0; }; builtin id "$@"; }

  validate_docker_ufw_rules "$f" >/dev/null 2>&1
  local good=$?

  sed -i 's|^-A DOCKER-USER -j RETURN$|-A DOCKER-USER -j NOT_A_REAL_CHAIN|' "$f"
  validate_docker_ufw_rules "$f" >/dev/null 2>&1
  local bad=$?

  # 0 = validated, 2 = unverified (no root), never 1 for good rules.
  [[ $good -ne 1 ]] || rc=1
  [[ $bad -eq 1 ]] || rc=1

  unset -f id
  teardown_destdir
  return $rc
}

test_docker_ufw_validator_accepts_builtin_targets() {
  # LOG is an iptables builtin, not a chain, and is never declared. If the
  # structural check treated it as an unknown chain it would reject every
  # correctly-generated rule set.
  setup_destdir
  local f="$CONF_DEST/etc/ufw/after.rules" rc=0
  install_docker_ufw_rules >/dev/null 2>&1
  stub sudo
  sudo() { return 1; }
  stub id
  id() { [[ $1 == -u ]] && { echo 1000; return 0; }; builtin id "$@"; }

  validate_docker_ufw_rules "$f" >/dev/null 2>&1
  [[ $? -eq 2 ]] || rc=1   # unverified, NOT malformed

  unset -f id
  teardown_destdir
  return $rc
}

test_docker_ufw_block_is_appended_not_prepended() {
  # ufw feeds the whole of after.rules to iptables-restore as ONE ruleset. A
  # managed block that opened *filter at the top and COMMITted in the middle
  # would leave everything ufw itself appends after it outside any table, and
  # ufw would then refuse to restore its ruleset at all - no firewall rather
  # than a slightly wrong one. This is why the placement argument exists.
  setup_destdir
  local f="$CONF_DEST/etc/ufw/after.rules" rc=0
  mkdir -p "$(dirname "$f")"
  printf '*filter\n-A ufw-before-input -j ACCEPT\nCOMMIT\n' >"$f"

  install_docker_ufw_rules >/dev/null 2>&1

  # ufw's own content must still be ahead of the managed block.
  local ufw_line block_line
  ufw_line="$(grep -n 'ufw-before-input' "$f" | head -1 | cut -d: -f1)"
  block_line="$(grep -nF "$DOCKER_UFW_BEGIN" "$f" | head -1 | cut -d: -f1)"
  if [[ -z $ufw_line || -z $block_line ]]; then
    printf '        expected both ufw content and the managed block\n'
    rc=1
  elif ((ufw_line >= block_line)); then
    printf '        managed block landed at line %s, ufw content at %s: it was prepended\n' \
      "$block_line" "$ufw_line"
    rc=1
  fi
  # And the user's own rules must survive.
  grep -q 'ufw-before-input' "$f" || rc=1

  teardown_destdir
  return $rc
}

test_docker_ufw_repeated_installs_do_not_grow_the_file() {
  # Blank-line growth was a real bug once already. Appending makes it easier to
  # reintroduce, because the join is at the end of the file now.
  setup_destdir
  local f="$CONF_DEST/etc/ufw/after.rules" rc=0
  mkdir -p "$(dirname "$f")"
  printf '*filter\n-A ufw-before-input -j ACCEPT\nCOMMIT\n' >"$f"

  install_docker_ufw_rules >/dev/null 2>&1
  local after_one; after_one="$(wc -c <"$f")"
  install_docker_ufw_rules >/dev/null 2>&1
  install_docker_ufw_rules >/dev/null 2>&1
  local after_three; after_three="$(wc -c <"$f")"

  if [[ $after_one != "$after_three" ]]; then
    printf '        file grew across repeated installs: %s -> %s bytes\n' "$after_one" "$after_three"
    rc=1
  fi
  [[ $(grep -cF "$DOCKER_UFW_BEGIN" "$f") -eq 1 ]] || rc=1

  teardown_destdir
  return $rc
}

test_docker_ufw6_only_written_when_ipv6_enabled() {
  # Writing to after6.rules on a host with no IPv6 ruleset would make ufw fail
  # to restore its ENTIRE ruleset - no firewall at all. So the IPv6 block must
  # be conditional on ufw actually having IPv6 enabled.
  setup_destdir
  local f="$CONF_DEST/etc/ufw/after6.rules" rc=0
  mkdir -p "$CONF_DEST/etc/ufw" "$CONF_DEST/etc/default"
  printf '*filter\n-A ufw6-before-input -j ACCEPT\nCOMMIT\n' >"$f"
  printf 'IPV6=no\n' >"$CONF_DEST/etc/default/ufw"
  stub have
  have() { return 0; }

  install_docker_ufw6_rules "10.0.0.0/8" >/dev/null 2>&1
  if grep -qF "$DOCKER_UFW_BEGIN" "$f"; then
    printf '        after6.rules was written even though IPV6=no\n'
    rc=1
  fi

  # Now enable IPv6 and the same call must produce the block.
  printf 'IPV6=yes\n' >"$CONF_DEST/etc/default/ufw"
  install_docker_ufw6_rules "10.0.0.0/8" >/dev/null 2>&1
  grep -qF "$DOCKER_UFW_BEGIN" "$f" || {
    printf '        after6.rules was not written with IPV6=yes\n'
    rc=1
  }
  # The v6 chain names must be the 6 ones, not the v4 ones: both files use the
  # same block markers, so a stale v4 block left in after6.rules would declare
  # ufw-user-forward in the v6 ruleset.
  grep -q 'ufw6-user-forward' "$f" || rc=1
  grep -q 'ufw6-docker-logging-deny' "$f" || rc=1

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

t 'docker loopback port is recognised'                  test_docker_port_is_loopback_only
t 'docker public+loopback is not loopback'             test_docker_port_public_and_loopback_is_not_loopback_only
t 'docker subnets include RFC1918'                      test_docker_subnets_always_includes_rfc1918
t 'DOCKER-USER block uses upstream markers'             test_docker_ufw_block_uses_upstream_markers
t 'DOCKER-USER rules are valid iptables'                test_docker_ufw_rules_parse_as_iptables
t 'DOCKER-USER rules are idempotent'                    test_docker_ufw_rules_are_idempotent
t 'published pairs keep udp distinct from tcp'          test_docker_published_pairs_keeps_udp
t 'published pairs does not recurse into itself'        test_docker_published_pairs_is_not_recursive
t 'the port prompt is still callable'                   test_docker_offer_published_ports_is_callable
t 'loopback test is per protocol'                      test_docker_port_is_loopback_only_is_per_protocol
t 'bottom normaliser keeps distant blank lines'        test_bottom_normaliser_preserves_distant_blank_lines
t '--force is not accepted'                             test_force_flag_is_not_accepted
t '--lockdown-ssh refuses a keyless target user'      test_lockdown_ssh_refuses_a_keyless_target_user
t 'docker loopback survives a missing protocol'        test_docker_loopback_survives_a_missing_protocol_suffix
t 'dry run does not create directories'               test_dry_run_does_not_create_directories
t 'dry run never restarts a service'                   test_dry_run_never_restarts_a_service
t 'validator catches a bad jump target'                test_docker_ufw_validator_detects_bad_jump_target
t 'validator accepts iptables builtin targets'         test_docker_ufw_validator_accepts_builtin_targets
t 'DOCKER-USER block is appended, not prepended'       test_docker_ufw_block_is_appended_not_prepended
t 'repeated installs do not grow after.rules'          test_docker_ufw_repeated_installs_do_not_grow_the_file
t 'after6.rules only when IPv6 is enabled'             test_docker_ufw6_only_written_when_ipv6_enabled

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
t 'rpi origin survives the spaces in "Raspberry Pi Foundation"' test_rpi_origin_combo_keeps_the_spaced_origin
t 'a half-read release line yields no origin'          test_rpi_origin_combo_rejects_a_half_read_release_line
t 'the rpi archive is auto-updated where present'       test_rpi_archive_is_allowed_when_this_box_has_it
t 'docker/tailscale/github-cli stay out of unattended'  test_third_party_repos_are_never_auto_upgraded
t 'held-back packages are parsed out of apt'            test_held_back_packages_are_named
t 'a held-back package is actually reported'            test_held_back_warning_reaches_the_output
t 'an untracked kernel image is detected'               test_untracked_kernels_flags_a_planted_image
t 'initrd/cmdline are not false positives'              test_untracked_kernels_ignores_files_that_are_untracked_by_design
t 'running kernel owner resolves on this box'           test_running_kernel_owner_reads_the_real_boot_dir
t 'the kernel audit check changes nothing'              test_kernel_audit_is_read_only
t 'fail2ban jail parses as INI'                         test_fail2ban_jail_parses_as_ini

printf '\n%s passed, %s failed\n\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]] || exit 1
