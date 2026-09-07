#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
ENGINE="$ROOT/setup-qwen38-pi.sh"
TEST_TMP="$(mktemp -d "${TMPDIR:-/tmp}/local-ai-user-config-test.XXXXXX")"

# shellcheck source=../lib/assert.sh
source "$ROOT/tests/lib/assert.sh"

cleanup() {
  [[ "$TEST_TMP" == */local-ai-user-config-test.* ]] || return 1
  rm -rf -- "$TEST_TMP"
}
trap cleanup EXIT

file_mode() {
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"
}

export HOME="$TEST_TMP/home"
export LOCAL_AI_CONFIG_DIR="$TEST_TMP/config"
export MODELS_DIR="$TEST_TMP/models"
export LOCAL_AI_SETUP_LIB_ONLY=1
mkdir -p "$HOME"

# shellcheck source=../../setup-qwen38-pi.sh
source "$ENGINE"

ensure_pi_settings >/dev/null
pi_settings="$HOME/.pi/agent/settings.json"
[[ -f "$pi_settings" && ! -L "$pi_settings" ]] || \
  test_fail "starter pi settings were not installed as a regular file"
jq -e '.enableInstallTelemetry==false and .enableAnalytics==false and
  .compaction.enabled==true' "$pi_settings" >/dev/null || \
  test_fail "starter pi settings are not valid local-first JSON"
assert_eq 600 "$(file_mode "$pi_settings")" \
  "starter pi settings are private"

printf '%s\n' '{"user":"custom-pi"}' > "$pi_settings"
chmod 640 "$pi_settings"
ensure_pi_settings >/dev/null
assert_eq '{"user":"custom-pi"}' "$(<"$pi_settings")" \
  "existing pi settings content is preserved"
assert_eq 640 "$(file_mode "$pi_settings")" \
  "existing pi settings mode is preserved"

pi_target="$TEST_TMP/user-pi-target.json"
printf '%s\n' 'central-pi-policy' > "$pi_target"
rm -f -- "$pi_settings"
ln -s "$pi_target" "$pi_settings"
ensure_pi_settings >/dev/null
[[ -L "$pi_settings" ]] || test_fail "pi settings symlink was replaced"
assert_eq 'central-pi-policy' "$(<"$pi_target")" \
  "pi settings symlink target is not followed"
rm -f -- "$pi_settings"
pi_missing_target="$TEST_TMP/missing-pi-target.json"
ln -s "$pi_missing_target" "$pi_settings"
ensure_pi_settings >/dev/null
[[ -L "$pi_settings" && ! -e "$pi_missing_target" ]] || \
  test_fail "dangling pi settings symlink was followed or replaced"
test_pass "dangling pi settings symlink is preserved"

ensure_tmux_config >/dev/null
tmux_config="$HOME/.tmux.conf"
[[ -f "$tmux_config" && ! -L "$tmux_config" ]] || \
  test_fail "starter tmux config was not installed as a regular file"
grep -q '^set -g mouse on' "$tmux_config" || \
  test_fail "starter tmux config is missing the managed baseline"
assert_eq 600 "$(file_mode "$tmux_config")" \
  "starter tmux config is private"

printf '%s\n' 'set -g status off' > "$tmux_config"
chmod 644 "$tmux_config"
ensure_tmux_config >/dev/null
assert_eq 'set -g status off' "$(<"$tmux_config")" \
  "existing tmux config content is preserved"
assert_eq 644 "$(file_mode "$tmux_config")" \
  "existing tmux config mode is preserved"

tmux_target="$TEST_TMP/user-tmux-target.conf"
printf '%s\n' 'central-tmux-policy' > "$tmux_target"
rm -f -- "$tmux_config"
ln -s "$tmux_target" "$tmux_config"
ensure_tmux_config >/dev/null
[[ -L "$tmux_config" ]] || test_fail "tmux config symlink was replaced"
assert_eq 'central-tmux-policy' "$(<"$tmux_target")" \
  "tmux config symlink target is not followed"
rm -f -- "$tmux_config"
tmux_missing_target="$TEST_TMP/missing-tmux-target.conf"
ln -s "$tmux_missing_target" "$tmux_config"
ensure_tmux_config >/dev/null
[[ -L "$tmux_config" && ! -e "$tmux_missing_target" ]] || \
  test_fail "dangling tmux config symlink was followed or replaced"
test_pass "dangling tmux config symlink is preserved"

printf 'User-config preservation unit tests passed.\n'
