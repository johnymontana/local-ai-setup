#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib/assert.sh"
TEST_TMP="$(mktemp -d "${TMPDIR:-/tmp}/local-ai-desktop-test.XXXXXX")"
trap 'rm -rf -- "$TEST_TMP"' EXIT
export HOME="$TEST_TMP/home"
export XDG_DATA_HOME="$TEST_TMP/desktop data"
export LOCAL_AI_CONFIG_DIR="$TEST_TMP/config"
export LOCAL_BIN_DIR="$TEST_TMP/bin with spaces"
export LOCAL_AI_SETUP_LIB_ONLY=1
mkdir -p "$HOME"
source "$ROOT/setup-qwen38-pi.sh"

cmd_desktop > "$TEST_TMP/install.log"
applications="$XDG_DATA_HOME/applications"
[[ -x "$LOCAL_BIN_DIR/local-ai" ]] || test_fail 'local-ai command was not installed'
assert_file_contains "$applications/local-ai.desktop" '^Name=Local AI$' 'application search entry installed'
assert_file_contains "$applications/local-ai-logs.desktop" '--desktop logs$' 'logs entry delegates to configured terminal'
assert_file_contains "$applications/local-ai.desktop" '^Terminal=false$' 'terminal is selected by Omarchy launcher'
assert_file_not_contains "$applications/local-ai.desktop" 'LLAMA_API_KEY|llama.key' 'desktop entries contain no credentials'
LOCAL_AI_SETUP_LIB_ONLY=0 "$LOCAL_BIN_DIR/local-ai" show-config > "$TEST_TMP/config.out"
assert_file_contains "$TEST_TMP/config.out" 'AGENT[[:space:]]*= omp' 'installed command resolves checkout through paths with spaces'
cmd_desktop >/dev/null
[[ $(find "$applications" -type f | wc -l | tr -d ' ') == 2 ]] || test_fail 'repeat installation created duplicate launchers'
test_pass 'desktop installation is repeatable'

printf '%s\n' 'personal launcher' > "$applications/local-ai-logs.desktop"
cp "$LOCAL_BIN_DIR/local-ai" "$TEST_TMP/wrapper.before"
if (cmd_desktop > "$TEST_TMP/conflict.log" 2>&1); then test_fail 'desktop overwrote a user entry'; fi
cmp "$LOCAL_BIN_DIR/local-ai" "$TEST_TMP/wrapper.before" || test_fail 'desktop changed wrapper before validating all destinations'
assert_eq 'personal launcher' "$(cat "$applications/local-ai-logs.desktop")" 'user launcher preserved on install conflict'
cmd_desktop_remove >/dev/null
[[ ! -e "$LOCAL_BIN_DIR/local-ai" && ! -e "$applications/local-ai.desktop" ]] || test_fail 'managed entries remain after removal'
assert_eq 'personal launcher' "$(cat "$applications/local-ai-logs.desktop")" 'desktop removal preserves user launcher'

rm "$applications/local-ai-logs.desktop"
printf 'private target\n' > "$TEST_TMP/target"
ln -s "$TEST_TMP/target" "$applications/local-ai.desktop"
if (cmd_desktop > "$TEST_TMP/symlink.log" 2>&1); then test_fail 'desktop accepted a symlink destination'; fi
cmd_desktop_remove >/dev/null
[[ -L "$applications/local-ai.desktop" ]] || test_fail 'desktop removed user symlink'
assert_eq 'private target' "$(cat "$TEST_TMP/target")" 'symlink targets remain untouched'

# Exercise argument forwarding, without opening any window or contacting API.
mkdir -p "$TEST_TMP/mock-bin"
cat > "$TEST_TMP/mock-bin/omarchy-launch-tui" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$DESKTOP_ARGS"
EOF
chmod 755 "$TEST_TMP/mock-bin/omarchy-launch-tui"
DESKTOP_ARGS="$TEST_TMP/args" PATH="$TEST_TMP/mock-bin:$PATH" bash "$ROOT/local-ai" --desktop logs
assert_eq "$(printf 'bash\n%s/local-ai\nlogs' "$ROOT")" "$(cat "$TEST_TMP/args")" 'Omarchy terminal receives separate literal arguments'
expect_failure 'desktop mode rejects arbitrary command execution' bash "$ROOT/local-ai" --desktop 'touch anything'
expect_failure 'desktop escaping rejects newlines' local_ai_desktop_exec_quote $'unsafe\nName=Injected'
assert_eq '"a\\\\b\\"c\\$d\\`e%%f"' "$(local_ai_desktop_exec_quote 'a\b"c$d`e%f')" 'desktop escaping protects reserved characters'

LOCAL_AI_SETUP_LIB_ONLY=0 bash "$ROOT/local-ai" desktop extra > "$TEST_TMP/arity.log" 2>&1 && test_fail 'desktop accepts extra arguments'
test_pass 'desktop command validates arity before mutation'
printf 'Desktop integration tests passed.\n'
