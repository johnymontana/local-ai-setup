#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
ENGINE="$ROOT/setup-qwen38-pi.sh"
TEST_TMP="$(mktemp -d "${TMPDIR:-/tmp}/local-ai-system-transaction-test.XXXXXX")"
# shellcheck source=../lib/environment.sh
source "$ROOT/tests/lib/environment.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$*"; }
file_mode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"; }

cleanup() {
  [[ "$TEST_TMP" == */local-ai-system-transaction-test.* ]] || return 1
  rm -rf -- "$TEST_TMP"
}
trap cleanup EXIT

platform_bin="$TEST_TMP/platform-bin"
mkdir -p "$platform_bin"
printf 'ID=arch\nPRETTY_NAME="Arch Linux"\n' > "$TEST_TMP/os-release"
printf 'MemTotal:       131766528 kB\n' > "$TEST_TMP/meminfo"
cat > "$platform_bin/omarchy" <<'EOF'
#!/usr/bin/env bash
# Platform detection must never launch the system updater.
exit 88
EOF
cat > "$platform_bin/uname" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  -s) printf 'Linux\n' ;;
  -m) printf 'x86_64\n' ;;
  -r) printf '6.18.4-omarchy-fixture\n' ;;
  *) exec /usr/bin/uname "$@" ;;
esac
EOF
cat > "$platform_bin/getconf" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == PAGESIZE ]]; then printf '4096\n'; else exec /usr/bin/getconf "$@"; fi
EOF
chmod 755 "$platform_bin/omarchy" "$platform_bin/uname" "$platform_bin/getconf"

ssh_bin="$TEST_TMP/ssh-bin"
ssh_tmp="$TEST_TMP/ssh-tmp"
ssh_home="$TEST_TMP/ssh-home"
ssh_dir="$TEST_TMP/sshd_config.d"
ssh_dropin="$ssh_dir/20-local-ai-lan.conf"
ssh_log="$TEST_TMP/ssh-systemctl.log"
ssh_keygen_log="$TEST_TMP/ssh-keygen.log"
ssh_signal_marker="$TEST_TMP/ssh-signal.marker"
ssh_rm_marker="$TEST_TMP/ssh-rm.marker"
mkdir -p "$ssh_bin" "$ssh_tmp" "$ssh_dir"
: > "$ssh_log"
: > "$ssh_keygen_log"

cat > "$ssh_bin/sudo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == install ]]; then
  shift
  args=()
  while (( $# )); do
    case "$1" in
      -o|-g) shift 2 ;;
      *) args+=("$1"); shift ;;
    esac
  done
  exec /usr/bin/install "${args[@]}"
fi
exec "$@"
EOF
cat > "$ssh_bin/systemctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${SSH_SYSTEMCTL_LOG:?}"
case "$*" in
  'show sshdgenkeys.service --property=LoadState --value')
    if [[ "${SSH_KEY_UNIT_MISSING:-0}" == 1 ]]; then printf 'not-found\n'; else printf 'loaded\n'; fi
    exit 0
    ;;
  'start sshdgenkeys.service') exit 0 ;;
  'show sshd --property=ActiveState --value')
    if [[ -n "${SSH_DAEMON_STATE:-}" ]]; then
      printf '%s\n' "$SSH_DAEMON_STATE"
    elif [[ "${SSH_DAEMON_INACTIVE:-0}" == 1 ]]; then
      printf 'inactive\n'
    else
      printf 'active\n'
    fi
    exit 0
    ;;
  'is-active --quiet sshd')
    [[ "${SSH_DAEMON_INACTIVE:-0}" != 1 ]] || exit 3
    exit 0
    ;;
  'reload sshd'|'restart sshd')
    if [[ "${SSH_SIGNAL_ON_RELOAD:-0}" == 1 && ! -e "${SSH_SIGNAL_MARKER:?}" ]]; then
      : > "$SSH_SIGNAL_MARKER"
      kill -TERM "$PPID"
      /bin/sleep 0.05
      exit 143
    fi
    exit 0
    ;;
esac
exit 0
EOF
cat > "$ssh_bin/sshd" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  -t) exit 0 ;;
  -T)
    printf '%s\n' \
      'passwordauthentication no' \
      'kbdinteractiveauthentication no' \
      'pubkeyauthentication yes' \
      'authenticationmethods any' \
      'permitrootlogin no' \
      "allowusers $(id -un)" \
      'x11forwarding no' \
      'allowagentforwarding no' \
      'maxauthtries 3' \
      "authorizedkeysfile ${MOCK_SSH_AUTH_KEYS:-.ssh/authorized_keys}"
    ;;
esac
EOF
cat > "$ssh_bin/ssh-keygen" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'ssh-keygen %s\n' "$*" >> "${SSH_KEYGEN_LOG:?}"
case "${1:-}" in
  -A) exit 0 ;;
  -lf) printf '256 SHA256:fixture local-ai-test (ED25519)\n'; exit 0 ;;
esac
exit 1
EOF
cat > "$ssh_bin/pacman" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$ssh_bin/getent" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == passwd && "${2:-}" == "$(id -un)" ]] || exit 2
printf '%s:x:%s:%s:Local AI Test:%s:/bin/bash\n' \
  "$(id -un)" "$(id -u)" "$(id -g)" "${HOME:?}"
EOF
cat > "$ssh_bin/rm" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${FAIL_SSH_CANDIDATE_RM:-0}" == 1 && ! -e "${SSH_RM_MARKER:?}" ]]; then
  for arg in "$@"; do
    case "$arg" in
      "${SSH_CANDIDATE_DIR:?}"/tmp.*)
        : > "$SSH_RM_MARKER"
        exit 77
        ;;
    esac
  done
fi
exec /bin/rm "$@"
EOF
chmod 755 "$ssh_bin/sudo" "$ssh_bin/systemctl" "$ssh_bin/sshd" "$ssh_bin/ssh-keygen" \
  "$ssh_bin/pacman" "$ssh_bin/getent" "$ssh_bin/rm"

ssh_env=(
  HOME="$ssh_home" PATH="$platform_bin:$ssh_bin:$PATH" TMPDIR="$ssh_tmp"
  LOCAL_AI_OS_RELEASE="$TEST_TMP/os-release"
  MODEL_LOCK="$ROOT/models.lock" LOCAL_AI_CONFIG_DIR="$TEST_TMP/ssh-config"
  SSHD_DROPIN="$ssh_dropin" SSH_SYSTEMCTL_LOG="$ssh_log"
  SSH_KEYGEN_LOG="$ssh_keygen_log"
  SSH_SIGNAL_MARKER="$ssh_signal_marker" SSH_RM_MARKER="$ssh_rm_marker"
  SSH_CANDIDATE_DIR="$ssh_tmp" LOCAL_AI_SETUP_LIB_ONLY=1
)

ssh_prior="$TEST_TMP/ssh-prior"
printf '%s\n' \
  '# Generated by setup-qwen38-pi.sh (remote / ssh-harden). LAN-only SSH policy.' \
  'prior-active-policy' > "$ssh_prior"
chmod 0600 "$ssh_prior"
cp "$ssh_prior" "$ssh_dropin"
rm -f "$ssh_signal_marker"
set +e
env "${ssh_env[@]}" SSH_SIGNAL_ON_RELOAD=1 \
  bash -c 'source "$1"; write_sshd_dropin no no' _ "$ENGINE" \
  >"$TEST_TMP/ssh-signal.out" 2>&1
ssh_rc=$?
set -e
[[ "$ssh_rc" == 130 ]] || fail "signaled SSH update returned $ssh_rc instead of 130"
cmp -s "$ssh_prior" "$ssh_dropin" || fail "signaled SSH update did not restore the prior drop-in"
[[ "$(file_mode "$ssh_dropin")" == "$(file_mode "$ssh_prior")" ]] || \
  fail "signaled SSH update did not restore the prior drop-in mode"
[[ "$(grep -Ec '^(reload|restart) sshd$' "$ssh_log")" -ge 2 ]] || \
  fail "signaled SSH update did not re-apply the restored policy to the active daemon"
grep -q '^start sshdgenkeys.service$' "$ssh_log" || \
  fail "SSH update did not use the available host-key generation unit"
[[ -z "$(find "$ssh_dir" -name '.local-ai-backup.*' -print -quit)" ]] || \
  fail "signaled SSH rollback retained a temporary root backup"
[[ -z "$(find "$ssh_tmp" -type f -print -quit)" ]] || \
  fail "signaled SSH rollback retained a local candidate"
pass "SSH TERM rollback restores the active file and daemon policy"

rm -f "$ssh_dropin" "$ssh_signal_marker"
: > "$ssh_log"
set +e
env "${ssh_env[@]}" SSH_SIGNAL_ON_RELOAD=1 \
  bash -c 'source "$1"; write_sshd_dropin no no' _ "$ENGINE" \
  >"$TEST_TMP/ssh-signal-absent.out" 2>&1
ssh_rc=$?
set -e
[[ "$ssh_rc" == 130 ]] || fail "signaled first SSH policy returned $ssh_rc instead of 130"
[[ ! -e "$ssh_dropin" ]] || fail "signaled SSH update retained a drop-in that was originally absent"
pass "SSH TERM rollback restores an originally absent drop-in"

cp "$ssh_prior" "$ssh_dropin"
rm -f "$ssh_rm_marker"
: > "$ssh_log"
set +e
env "${ssh_env[@]}" FAIL_SSH_CANDIDATE_RM=1 \
  bash -c '
    source "$1"
    rm() {
      local arg
      if [[ ! -e "$SSH_RM_MARKER" ]]; then
        for arg in "$@"; do
          case "$arg" in
            "$SSH_CANDIDATE_DIR"/tmp.*) : > "$SSH_RM_MARKER"; exit 77 ;;
          esac
        done
      fi
      /bin/rm "$@"
    }
    write_sshd_dropin no no
  ' _ "$ENGINE" \
  >"$TEST_TMP/ssh-exit.out" 2>&1
ssh_rc=$?
set -e
[[ "$ssh_rc" == 77 ]] || fail "unexpected SSH transaction exit returned $ssh_rc instead of 77"
cmp -s "$ssh_prior" "$ssh_dropin" || fail "SSH EXIT trap did not restore the prior drop-in"
if grep -Eq '^(reload|restart) sshd$' "$ssh_log"; then
  fail "SSH EXIT rollback reloaded a daemon that had not seen the staged policy"
fi
[[ -z "$(find "$ssh_dir" -name '.local-ai-backup.*' -print -quit)" ]] || \
  fail "SSH EXIT rollback retained a temporary root backup"
[[ -z "$(find "$ssh_tmp" -type f -print -quit)" ]] || \
  fail "SSH EXIT rollback retained a local candidate"
pass "SSH EXIT rollback restores a file changed before daemon reload"

rm -f "$ssh_dropin"
: > "$ssh_log"
: > "$ssh_keygen_log"
env "${ssh_env[@]}" SSH_DAEMON_INACTIVE=1 SSH_KEY_UNIT_MISSING=1 \
  bash -c 'source "$1"; write_sshd_dropin no no' _ "$ENGINE" \
  >"$TEST_TMP/ssh-first-run.out" 2>&1
[[ -f "$ssh_dropin" ]] || fail "first-run SSH policy was not installed after host-key generation"
grep -q '^ssh-keygen -A$' "$ssh_keygen_log" || \
  fail "first-run SSH policy did not fall back to ssh-keygen -A when the Arch unit was absent"
unexpected_sshd_calls="$(grep -E '^(start|reload|restart) sshd$' "$ssh_log" || true)"
[[ -z "$unexpected_sshd_calls" ]] || \
  fail "first-run host-key preparation opened or reloaded an inactive SSH daemon: $unexpected_sshd_calls"
pass "first-run SSH host keys are generated without opening the port"

mkdir -p "$ssh_home/.ssh"
printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFixture local-ai-test\n' > \
  "$ssh_home/.ssh/authorized_keys"
cp "$ssh_prior" "$ssh_dropin"
: > "$ssh_keygen_log"
set +e
env "${ssh_env[@]}" MOCK_SSH_AUTH_KEYS='.ssh/ignored_keys' \
  bash -c 'source "$1"; cmd_ssh_harden' _ "$ENGINE" \
  >"$TEST_TMP/ssh-authorized-ignored.out" 2>&1
ssh_rc=$?
set -e
[[ "$ssh_rc" != 0 ]] || fail "ssh-harden accepted an effective policy that ignores the checked authorized_keys"
cmp -s "$ssh_prior" "$ssh_dropin" || fail "rejected AuthorizedKeysFile policy changed the SSH drop-in"
if grep -q '^ssh-keygen -lf ' "$ssh_keygen_log"; then
  fail "ssh-harden validated key contents before proving sshd uses that file"
fi
pass "ssh-harden rejects an ignored authorized_keys path before key validation"

for accepted_keys_path in '.ssh/authorized_keys' '%h/.ssh/authorized_keys'; do
  cp "$ssh_prior" "$ssh_dropin"
  env "${ssh_env[@]}" MOCK_SSH_AUTH_KEYS="$accepted_keys_path" \
    bash -c 'source "$1"; cmd_ssh_harden' _ "$ENGINE" \
    >"$TEST_TMP/ssh-authorized-home.out" 2>&1
  grep -q '^PasswordAuthentication no$' "$ssh_dropin" || \
    fail "ssh-harden rejected the effective $accepted_keys_path path"
done
pass "ssh-harden accepts relative and %h authorized_keys paths"

kernel_bin="$TEST_TMP/kernel-bin"
kernel_root="$TEST_TMP/kernel-root"
kernel_modprobe="$kernel_root/etc/modprobe.d"
kernel_target="$kernel_modprobe/ttm.conf"
kernel_legacy="$kernel_modprobe/99-strix-halo-llm.conf"
kernel_log="$TEST_TMP/kernel.log"
kernel_signal_marker="$TEST_TMP/kernel-signal.marker"
mkdir -p "$kernel_bin" "$kernel_modprobe"
: > "$kernel_log"

cat > "$kernel_bin/sudo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
mapped=()
for arg in "$@"; do
  case "$arg" in
    /etc/modprobe.d) mapped+=("${KERNEL_ROOT:?}/etc/modprobe.d") ;;
    /etc/modprobe.d/*) mapped+=("${KERNEL_ROOT:?}${arg}") ;;
    *) mapped+=("$arg") ;;
  esac
done
if [[ "${mapped[0]}" == grep ]]; then
  set +e
  "${mapped[@]}" | sed "s|${KERNEL_ROOT:?}/etc/modprobe.d|/etc/modprobe.d|g"
  rc=${PIPESTATUS[0]}
  exit "$rc"
fi
exec "${mapped[@]}"
EOF
cat > "$kernel_bin/pacman" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$kernel_bin/limine-mkinitcpio" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'limine-mkinitcpio\n' >> "${KERNEL_LOG:?}"
if [[ "${KERNEL_SIGNAL_IN_REBUILD:-0}" == 1 && ! -e "${KERNEL_SIGNAL_MARKER:?}" ]]; then
  : > "$KERNEL_SIGNAL_MARKER"
  kill -TERM "$PPID"
  /bin/sleep 0.05
  exit 143
fi
if [[ "${KERNEL_FAIL_FIRST_REBUILD:-0}" == 1 && ! -e "${KERNEL_SIGNAL_MARKER:?}" ]]; then
  : > "$KERNEL_SIGNAL_MARKER"
  printf 'fixture UKI rebuild failure\n' >&2
  exit 77
fi
exit 0
EOF
chmod 755 "$kernel_bin/sudo" "$kernel_bin/pacman" "$kernel_bin/limine-mkinitcpio"

kernel_env=(
  HOME="$TEST_TMP/kernel-home" PATH="$platform_bin:$kernel_bin:$PATH"
  LOCAL_AI_OS_RELEASE="$TEST_TMP/os-release" LOCAL_AI_MEMINFO="$TEST_TMP/meminfo"
  MODEL_LOCK="$ROOT/models.lock" LOCAL_AI_CONFIG_DIR="$TEST_TMP/kernel-config"
  KERNEL_ROOT="$kernel_root" KERNEL_LOG="$kernel_log"
  KERNEL_SIGNAL_MARKER="$kernel_signal_marker" LOCAL_AI_SETUP_LIB_ONLY=1
)

kernel_target_prior="$TEST_TMP/kernel-target-prior"
kernel_legacy_prior="$TEST_TMP/kernel-legacy-prior"
printf 'options ttm pages_limit=16777216\n' > "$kernel_target_prior"
cat > "$kernel_legacy_prior" <<'EOF'
# Generated by setup-qwen38-pi.sh
options amdgpu gttsize=120795955200
options ttm pages_limit=30146560 page_pool_size=30146560
EOF
chmod 0640 "$kernel_target_prior"
chmod 0600 "$kernel_legacy_prior"
cp "$kernel_target_prior" "$kernel_target"
cp "$kernel_legacy_prior" "$kernel_legacy"
rm -f "$kernel_signal_marker"
: > "$kernel_log"
set +e
env "${kernel_env[@]}" KERNEL_SIGNAL_IN_REBUILD=1 \
  bash -c 'source "$1"; cmd_kernel_tweaks' _ "$ENGINE" <<< 'y' \
  >"$TEST_TMP/kernel-signal.out" 2>&1
kernel_rc=$?
set -e
[[ "$kernel_rc" == 130 ]] || { cat "$TEST_TMP/kernel-signal.out" >&2; fail "signaled kernel tweak returned $kernel_rc instead of 130"; }
cmp -s "$kernel_target_prior" "$kernel_target" || fail "kernel TERM rollback did not restore ttm.conf"
cmp -s "$kernel_legacy_prior" "$kernel_legacy" || fail "kernel TERM rollback did not restore the legacy policy"
[[ "$(file_mode "$kernel_target")" == "$(file_mode "$kernel_target_prior")" ]] || \
  fail "kernel TERM rollback did not restore the ttm.conf mode"
[[ "$(file_mode "$kernel_legacy")" == "$(file_mode "$kernel_legacy_prior")" ]] || \
  fail "kernel TERM rollback did not restore the legacy policy mode"
[[ "$(grep -c '^limine-mkinitcpio$' "$kernel_log")" == 2 ]] || fail "kernel TERM rollback did not rebuild Omarchy UKIs"
pass "kernel TERM rollback restores both policies and Omarchy UKIs"

rm -f "$kernel_target"
cp "$kernel_legacy_prior" "$kernel_legacy"
: > "$kernel_log"
set +e
env "${kernel_env[@]}" KERNEL_EXIT_AFTER_LEGACY=1 \
  bash -c 'source "$1"; ok(){ exit 72; }; cmd_kernel_tweaks' _ "$ENGINE" <<< 'y' \
  >"$TEST_TMP/kernel-exit.out" 2>&1
kernel_rc=$?
set -e
[[ "$kernel_rc" == 72 ]] || fail "unexpected kernel transaction exit returned $kernel_rc instead of 72"
[[ ! -e "$kernel_target" ]] || fail "kernel EXIT rollback retained a target that was originally absent"
cmp -s "$kernel_legacy_prior" "$kernel_legacy" || fail "kernel EXIT rollback did not restore the legacy policy"
grep -q '^limine-mkinitcpio$' "$kernel_log" || fail "kernel EXIT rollback did not rebuild Omarchy UKIs"
pass "kernel EXIT rollback restores an absent target and legacy policy"

rm -f "$kernel_target" "$kernel_legacy"
kernel_central="$kernel_modprobe/central-ttm.conf"
printf 'central-policy\n' > "$kernel_central"
ln -s "$kernel_central" "$kernel_target"
: > "$kernel_log"
set +e
env "${kernel_env[@]}" bash -c 'source "$1"; cmd_kernel_tweaks' _ "$ENGINE" <<< 'y' \
  >"$TEST_TMP/kernel-symlink.out" 2>&1
kernel_rc=$?
set -e
[[ "$kernel_rc" != 0 ]] || fail "kernel tweak accepted a symlinked ttm.conf"
[[ -L "$kernel_target" ]] || fail "kernel tweak replaced a symlinked ttm.conf"
grep -qx 'central-policy' "$kernel_central" || fail "kernel tweak modified the symlink target"
if [[ -s "$kernel_log" ]]; then fail "kernel tweak rebuilt boot images after rejecting a symlink"; fi
pass "kernel transaction preserves symlinked policy ownership"

rm -f "$kernel_target" "$kernel_central" "$kernel_signal_marker"
cp "$kernel_target_prior" "$kernel_target"
cp "$kernel_legacy_prior" "$kernel_legacy"
: > "$kernel_log"
if env "${kernel_env[@]}" KERNEL_FAIL_FIRST_REBUILD=1 \
  bash -c 'source "$1"; cmd_kernel_tweaks' _ "$ENGINE" <<< 'y' \
  >"$TEST_TMP/kernel-rebuild-failure.out" 2>&1; then
  fail "kernel tweak accepted a failed Limine rebuild"
fi
cmp -s "$kernel_target_prior" "$kernel_target" || fail "failed Limine rebuild did not restore ttm.conf"
cmp -s "$kernel_legacy_prior" "$kernel_legacy" || fail "failed Limine rebuild did not restore legacy policy"
[[ "$(grep -c '^limine-mkinitcpio$' "$kernel_log")" == 2 ]] || fail "failed rebuild was not followed by a rollback rebuild"
grep -q 'fixture UKI rebuild failure' "$TEST_TMP/kernel-rebuild-failure.out" || fail "Limine failure output was hidden"
pass "Limine failure restores both policies, rebuilds prior UKIs, and preserves failure output"

rm -f "$kernel_target" "$kernel_legacy" "$kernel_signal_marker"
: > "$kernel_log"
env "${kernel_env[@]}" bash -c 'source "$1"; cmd_kernel_tweaks' _ "$ENGINE" <<< 'y' \
  >"$TEST_TMP/kernel-success.out" 2>&1 || { cat "$TEST_TMP/kernel-success.out" >&2; fail "Omarchy kernel tweak failed"; }
grep -qx 'options ttm pages_limit=30146560' "$kernel_target" || fail "Omarchy tweak changed the 115 GiB memory optimization"
[[ "$(grep -c '^limine-mkinitcpio$' "$kernel_log")" == 1 ]] || fail "successful tweak did not rebuild Limine exactly once"
[[ "$(file_mode "$kernel_target")" == 644 ]] || fail "generated TTM policy is not readable by initramfs tools"
grep -q 'System > Reboot' "$TEST_TMP/kernel-success.out" || fail "kernel tweak did not provide Omarchy reboot guidance"
pass "Omarchy tweak preserves 115 GiB tuning and rebuilds Limine before manual reboot"

printf 'System transaction tests passed.\n'
