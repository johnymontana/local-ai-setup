#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
TEST_TMP="$(mktemp -d "${TMPDIR:-/tmp}/local-ai-platform-test.XXXXXX")"
trap 'rm -rf -- "$TEST_TMP"' EXIT
source "$ROOT/tests/lib/assert.sh"
source "$ROOT/lib/local-ai-platform.sh"

export HOME="$TEST_TMP/home" OMARCHY_PATH="$TEST_TMP/omarchy"
export LOCAL_AI_OS_RELEASE="$TEST_TMP/os-release"
mkdir -p "$HOME" "$OMARCHY_PATH"
printf 'ID=arch\nPRETTY_NAME="Arch Linux"\n' > "$LOCAL_AI_OS_RELEASE"
warn() { printf '%s\n' "$*" >&2; }
uname() {
  case "$1" in
    -s) printf '%s\n' "${MOCK_SYSTEM:-Linux}" ;;
    -m) printf '%s\n' "${MOCK_MACHINE:-x86_64}" ;;
    *) command uname "$@" ;;
  esac
}
omarchy() { test_fail "detection launched an Omarchy command"; }
pacman() {
  printf 'pacman %s\n' "$*" >> "$TEST_TMP/packages.log"
  case "$1" in
    -Qu)
      case "${MOCK_UPDATES:-none}" in
        pending) printf 'linux 6.18.4-1 -> 6.19.1-1\n' ;;
        error) printf 'fixture package database error\n' >&2; return 1 ;;
        none) return 1 ;;
      esac
      ;;
    -Si)
      if [[ "${MOCK_PACKAGE_MISSING:-0}" == 1 ]]; then
        printf 'fixture package unavailable in selected channel\n' >&2
        return 1
      fi
      ;;
    -S)
      if [[ "${MOCK_INSTALL_FAILED:-0}" == 1 ]]; then
        printf 'fixture package transaction failure\n' >&2
        return 1
      fi
      ;;
    *) test_fail "unexpected package operation: $*" ;;
  esac
}
sudo() {
  printf 'sudo %s\n' "$*" >> "$TEST_TMP/packages.log"
  "$@"
}

assert_eq 'arch' "$(local_ai_os_release_value ID)" 'Omarchy retains the Arch os-release ID'
assert_eq 'Omarchy Linux (Arch base)' "$(local_ai_platform_name)" 'platform name detects Omarchy without executing its commands'
assert_eq 'omarchy update' "$(local_ai_omarchy_update_command)" 'current Omarchy CLI update guidance'
(
  unset -f omarchy
  omarchy-update() { test_fail 'detection launched legacy updater'; }
  assert_eq 'omarchy-update' "$(local_ai_omarchy_update_command)" 'legacy Omarchy CLI update guidance'
  local_ai_is_omarchy || test_fail 'legacy Omarchy was not detected'
)
(
  unset -f omarchy
  printf '4.0.0\n' > "$OMARCHY_PATH/version"
  local_ai_is_omarchy || test_fail 'Omarchy installation marker was not detected'
  assert_eq 'Update > Omarchy in the Omarchy menu (Super + Space)' "$(local_ai_omarchy_update_command)" 'menu fallback when updater is outside PATH'
)

# Executable text in os-release is printed literally and never sourced.
printf 'PRETTY_NAME="$(touch %s)"\nID=arch\n' "$TEST_TMP/unsafe-marker" > "$LOCAL_AI_OS_RELEASE"
local_ai_os_release_value PRETTY_NAME >/dev/null
[[ ! -e "$TEST_TMP/unsafe-marker" ]] || test_fail 'os-release was executed'
test_pass 'os-release is parsed as data'

if (( EUID != 0 )); then
  : > "$TEST_TMP/packages.log"
  local_ai_install_packages llama-cpp ggml-cpu ggml-vulkan >"$TEST_TMP/install.out" 2>&1 || {
    cat "$TEST_TMP/install.out" >&2
    test_fail 'package installation failed on a synchronized Omarchy fixture'
  }
  assert_file_contains "$TEST_TMP/packages.log" '^sudo pacman -S --needed --noconfirm -- llama-cpp ggml-cpu ggml-vulkan$' 'coupled runtime packages install together without refreshing or upgrading'
  assert_file_not_contains "$TEST_TMP/packages.log" 'pacman -S[^[:space:]]*[yu]' 'package helper never initiates a system update'

  for scenario in pending error missing transaction; do
    : > "$TEST_TMP/packages.log"
    if (
      case "$scenario" in
        pending|error) MOCK_UPDATES="$scenario" ;;
        missing) MOCK_PACKAGE_MISSING=1 ;;
        transaction) MOCK_INSTALL_FAILED=1 ;;
      esac
      local_ai_install_packages llama-cpp ggml-cpu ggml-vulkan
    ) >"$TEST_TMP/$scenario.out" 2>&1; then
      test_fail "$scenario package failure was accepted"
    fi
    assert_file_contains "$TEST_TMP/$scenario.out" 'omarchy update' "$scenario failure directs recovery through Omarchy updates"
    if [[ "$scenario" != transaction ]]; then
      assert_file_not_contains "$TEST_TMP/packages.log" '^sudo ' "$scenario preflight failure makes no privileged change"
    fi
  done
  assert_file_contains "$TEST_TMP/error.out" 'fixture package database error' 'package database failure output is preserved'
  assert_file_contains "$TEST_TMP/missing.out" 'fixture package unavailable' 'missing-package failure output is preserved'
  assert_file_contains "$TEST_TMP/transaction.out" 'fixture package transaction failure' 'package transaction failure output is preserved'
else
  expect_failure 'system mutation rejects root invocation' local_ai_require_omarchy
fi

if (MOCK_SYSTEM=Darwin; local_ai_require_omarchy) >"$TEST_TMP/non-linux.out" 2>&1; then
  test_fail 'non-Linux system was accepted'
fi
if (MOCK_MACHINE=aarch64; local_ai_require_omarchy) >"$TEST_TMP/non-x86.out" 2>&1; then
  test_fail 'non-x86 hardware was accepted'
fi
printf 'ID=debian\nPRETTY_NAME="Debian"\n' > "$LOCAL_AI_OS_RELEASE"
expect_failure 'Omarchy command alone does not identify a non-Arch OS' local_ai_is_omarchy
if local_ai_require_omarchy >"$TEST_TMP/non-arch.out" 2>&1; then
  test_fail 'non-Arch system was accepted'
fi
test_pass 'system mutations require the Omarchy Linux x86_64 target'

limine-mkinitcpio() { printf 'limine-mkinitcpio %s\n' "$*" >> "$TEST_TMP/boot.log"; }
mkinitcpio() { test_fail 'traditional mkinitcpio bypassed the Limine UKI pipeline'; }
: > "$TEST_TMP/packages.log"
local_ai_rebuild_boot_images
assert_file_contains "$TEST_TMP/boot.log" '^limine-mkinitcpio $' 'boot-image rebuild uses the Omarchy Limine UKI pipeline'
assert_file_contains "$TEST_TMP/packages.log" '^sudo limine-mkinitcpio$' 'Limine boot-image rebuild is privileged explicitly'
