#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
TEST_TMP="$(mktemp -d "${TMPDIR:-/tmp}/local-ai-agent-isolation-test.XXXXXX")"
cleanup() {
  [[ "$TEST_TMP" == */local-ai-agent-isolation-test.* ]] || return 1
  rm -rf -- "$TEST_TMP"
}
trap cleanup EXIT
# shellcheck source=../lib/assert.sh
source "$ROOT/tests/lib/assert.sh"

export HOME="$TEST_TMP/home"
export XDG_DATA_HOME="$TEST_TMP/data home"
export OMARCHY_PATH="$TEST_TMP/omarchy"
export LOCAL_AI_CONFIG_DIR="$TEST_TMP/config"
export LOCAL_AI_OS_RELEASE="$TEST_TMP/os-release"
export LOCAL_BIN_DIR="$HOME/.local/bin"
export LOCAL_AI_SETUP_LIB_ONLY=1
export EVENT_LOG="$TEST_TMP/events.log"
export PATH="$LOCAL_BIN_DIR:$PATH"
mkdir -p "$HOME" "$OMARCHY_PATH" "$LOCAL_BIN_DIR" "$LOCAL_AI_CONFIG_DIR"
printf 'test\n' > "$OMARCHY_PATH/version"
printf 'ID=arch\nPRETTY_NAME="Arch Linux"\n' > "$LOCAL_AI_OS_RELEASE"
: > "$EVENT_LOG"

# These model Omarchy's lazy mise launchers. Even --version is a mutation, so
# no installation, status lookup, or managed wrapper may invoke them.
for agent in pi omp; do
  cat > "$LOCAL_BIN_DIR/$agent" <<'EOF'
#!/usr/bin/env bash
printf 'omarchy-stub|%s|%s\n' "${0##*/}" "$*" >> "$EVENT_LOG"
exit 91
EOF
  chmod +x "$LOCAL_BIN_DIR/$agent"
done
original_stubs="$(cksum "$LOCAL_BIN_DIR/pi" "$LOCAL_BIN_DIR/omp")"

# shellcheck source=../../setup-qwen38-pi.sh
source "$ROOT/setup-qwen38-pi.sh"

event() { printf '%s\n' "$*" >> "$EVENT_LOG"; }
reset_events() { : > "$EVENT_LOG"; }
add_bashrc_line() { :; }
set_managed_shell_export() { :; }
add_api_key_export() { :; }
remove_legacy_shell_export() { :; }
MOCK_MODELS=0
tier_available() { (( MOCK_MODELS )); }

write_mock_agent() {
  local binary="$1" version="$2"
  mkdir -p "$(dirname "$binary")"
  cat > "$binary" <<EOF
#!/usr/bin/env bash
printf 'private|%s|%s\\n' "\${0##*/}" "\$*" >> "\$EVENT_LOG"
if [[ "\${1:-}" == --version ]]; then printf '%s\\n' '$version'; fi
EOF
  chmod +x "$binary"
}
npm() {
  event "npm|$*"
  local prefix=''
  while (( $# )); do
    if [[ "$1" == --prefix ]]; then prefix="$2"; shift; fi
    shift
  done
  [[ -n "$prefix" ]] || return 1
  write_mock_agent "$prefix/bin/pi" "$PI_VERSION"
}
bun() {
  event "bun|$*|bin=$BUN_INSTALL_BIN|global=$BUN_INSTALL_GLOBAL_DIR"
  write_mock_agent "$BUN_INSTALL_BIN/omp" "$OMP_VERSION"
}

private="$XDG_DATA_HOME/local-ai/agents"
assert_eq '' "$(omp_binary)" "Omarchy omp stub does not count as a pinned install"
assert_eq '' "$(local_ai_agent_binary pi)" "Omarchy pi stub does not count as a pinned install"
(
  export LOCAL_AI_MANAGE_LIB_ONLY=1
  # shellcheck source=../../manage.sh
  source "$ROOT/manage.sh"
  expect_failure "manager reports missing private agent despite global stub" agent_binary omp
)
assert_eq '' "$(<"$EVENT_LOG")" "read-only agent resolution never executes Omarchy stubs"

AGENT=pi
reset_events
cmd_pi >/dev/null
assert_eq "$(printf '%s\n' \
  "npm|install --global --prefix $private --ignore-scripts @earendil-works/pi-coding-agent@$PI_VERSION" \
  'private|pi|--version')" "$(<"$EVENT_LOG")" \
  "pi installs and validates the pinned package inside the private prefix"
assert_eq "$private/bin/pi" "$(local_ai_agent_binary pi)" \
  "pi resolver finds the private install"

AGENT=omp
reset_events
cmd_omp >/dev/null
assert_eq "$(printf '%s\n' \
  "bun|install --global --ignore-scripts @oh-my-pi/pi-coding-agent@$OMP_VERSION|bin=$private/bin|global=$private/bun" \
  'private|omp|--version')" "$(<"$EVENT_LOG")" \
  "OMP installs and validates inside private Bun directories"
assert_eq "$private/bin/omp" "$(omp_binary)" "OMP resolver finds the private install"

for agent in pi omp; do
  AGENT="$agent"
  reset_events
  cmd_agent_upgrade "$agent" >/dev/null
  if [[ "$agent" == pi ]]; then
    expected_install="npm|install --global --prefix $private --ignore-scripts @earendil-works/pi-coding-agent@$PI_VERSION"
  else
    expected_install="bun|install --global --ignore-scripts @oh-my-pi/pi-coding-agent@$OMP_VERSION|bin=$private/bin|global=$private/bun"
  fi
  assert_eq "$(printf '%s\n' "$expected_install" "private|$agent|--version")" \
    "$(<"$EVENT_LOG")" \
    "explicit $agent upgrade replaces and validates only its private pinned package"
done
assert_eq "$original_stubs" "$(cksum "$LOCAL_BIN_DIR/pi" "$LOCAL_BIN_DIR/omp")" \
  "install and upgrade preserve both Omarchy launcher files"

# Both entry points must use the same private runtime and fail closed if it
# disappears. The version on the ordinary Omarchy PATH must never substitute.
printf '%s\n' 'local-ai-test-key-12345678901234567890123456789' > "$KEY_FILE"
MOCK_MODELS=1
AGENT=omp
write_agent_launcher >/dev/null
write_omp_launchers >/dev/null
for launcher in local-ai-agent omp-everyday; do
  reset_events
  "$LOCAL_BIN_DIR/$launcher" example >/dev/null
  assert_file_contains "$EVENT_LOG" '^private\|omp\|' \
    "$launcher executes the private OMP runtime"
  assert_file_not_contains "$EVENT_LOG" '^omarchy-stub' \
    "$launcher never dispatches to Omarchy's moving version"
done

# Remote sessions use the same pinned runtime, including an explicit AGENT
# override, even when a tmux server's environment predates installation.
session_helper="$TEST_TMP/ai-session"
write_session_helper "$session_helper"
chmod +x "$session_helper"
mkdir -p "$HOME/.config/local-ai" "$TEST_TMP/project"
cp "$KEY_FILE" "$HOME/.config/local-ai/llama.key"
printf 'AGENT=omp\nPORT=8181\n' > "$HOME/.config/local-ai/setup.env"
cat > "$LOCAL_BIN_DIR/tmux" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  has-session) exit 1 ;;
  send-keys)
    printf 'session-port|%s\n' "$LLAMA_BASE_URL" >> "$EVENT_LOG"
    bash -c "$4"
    ;;
esac
EOF
chmod +x "$LOCAL_BIN_DIR/tmux"
for agent in omp pi; do
  reset_events
  AGENT="$agent" "$session_helper" "$TEST_TMP/project" >/dev/null
  assert_eq "$(printf '%s\n' 'session-port|http://127.0.0.1:8181' "private|$agent|")" \
    "$(<"$EVENT_LOG")" \
    "remote $agent session uses the private runtime and saved router port"
done

rm -f -- "$private/bin/omp"
reset_events
expect_failure "selected launcher rejects a missing private runtime" "$LOCAL_BIN_DIR/local-ai-agent"
expect_failure "tier launcher rejects a missing private runtime" "$LOCAL_BIN_DIR/omp-everyday"
expect_failure "remote session rejects a missing private runtime" \
  env AGENT=omp "$session_helper" "$TEST_TMP/project"
assert_eq '' "$(<"$EVENT_LOG")" "missing private runtime never falls back to global Omarchy stubs"

printf 'Agent isolation unit tests passed.\n'
