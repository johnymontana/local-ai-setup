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
assert_file_contains "$applications/local-ai-workspaces.desktop" '^Name=Local AI Workspaces$' 'workspace entry is discoverable in application search'
assert_file_contains "$applications/local-ai-workspaces.desktop" '--desktop workspace$' 'workspace entry delegates to configured terminal'
assert_file_contains "$applications/local-ai.desktop" '^Terminal=false$' 'terminal is selected by Omarchy launcher'
assert_file_not_contains "$applications/local-ai.desktop" 'LLAMA_API_KEY|llama.key' 'desktop entries contain no credentials'
LOCAL_AI_SETUP_LIB_ONLY=0 "$LOCAL_BIN_DIR/local-ai" show-config > "$TEST_TMP/config.out"
assert_file_contains "$TEST_TMP/config.out" 'AGENT[[:space:]]*= omp' 'installed command resolves checkout through paths with spaces'
cmd_desktop >/dev/null
[[ $(find "$applications" -type f | wc -l | tr -d ' ') == 3 ]] || test_fail 'repeat installation created duplicate launchers'
test_pass 'desktop installation is repeatable'

cp "$applications/local-ai-workspaces.desktop" "$TEST_TMP/workspaces.before"
cp "$applications/local-ai.desktop" "$TEST_TMP/menu.before"
cp "$LOCAL_BIN_DIR/local-ai" "$TEST_TMP/wrapper.before"
printf '%s\n' 'personal workspace launcher' > "$applications/local-ai-workspaces.desktop"
if (cmd_desktop > "$TEST_TMP/workspace-conflict.log" 2>&1); then test_fail 'desktop overwrote a user workspace entry'; fi
cmp "$LOCAL_BIN_DIR/local-ai" "$TEST_TMP/wrapper.before" || test_fail 'desktop changed wrapper before checking workspace destination'
cmp "$applications/local-ai.desktop" "$TEST_TMP/menu.before" || test_fail 'desktop changed menu before checking workspace destination'
cmd_desktop_remove >/dev/null
assert_eq 'personal workspace launcher' "$(cat "$applications/local-ai-workspaces.desktop")" 'desktop removal preserves user workspace entry'
cp "$TEST_TMP/workspaces.before" "$applications/local-ai-workspaces.desktop"
cmd_desktop >/dev/null

printf '%s\n' 'personal launcher' > "$applications/local-ai-logs.desktop"
cp "$LOCAL_BIN_DIR/local-ai" "$TEST_TMP/wrapper.before"
if (cmd_desktop > "$TEST_TMP/conflict.log" 2>&1); then test_fail 'desktop overwrote a user entry'; fi
cmp "$LOCAL_BIN_DIR/local-ai" "$TEST_TMP/wrapper.before" || test_fail 'desktop changed wrapper before validating all destinations'
assert_eq 'personal launcher' "$(cat "$applications/local-ai-logs.desktop")" 'user launcher preserved on install conflict'
cmd_desktop_remove >/dev/null
[[ ! -e "$LOCAL_BIN_DIR/local-ai" && ! -e "$applications/local-ai.desktop" && ! -e "$applications/local-ai-workspaces.desktop" ]] || test_fail 'managed entries remain after removal'
assert_eq 'personal launcher' "$(cat "$applications/local-ai-logs.desktop")" 'desktop removal preserves user launcher'

rm "$applications/local-ai-logs.desktop"
printf 'private target\n' > "$TEST_TMP/target"
ln -s "$TEST_TMP/target" "$applications/local-ai.desktop"
if (cmd_desktop > "$TEST_TMP/symlink.log" 2>&1); then test_fail 'desktop accepted a symlink destination'; fi
cmd_desktop_remove >/dev/null
[[ -L "$applications/local-ai.desktop" ]] || test_fail 'desktop removed user symlink'
assert_eq 'private target' "$(cat "$TEST_TMP/target")" 'symlink targets remain untouched'
rm "$applications/local-ai.desktop"
ln -s "$TEST_TMP/target" "$applications/local-ai-workspaces.desktop"
if (cmd_desktop > "$TEST_TMP/workspace-symlink.log" 2>&1); then test_fail 'desktop accepted a symlink workspace destination'; fi
[[ ! -e "$LOCAL_BIN_DIR/local-ai" ]] || test_fail 'desktop wrote wrapper before validating workspace symlink'
cmd_desktop_remove >/dev/null
[[ -L "$applications/local-ai-workspaces.desktop" ]] || test_fail 'desktop removed user workspace symlink'
assert_eq 'private target' "$(cat "$TEST_TMP/target")" 'workspace symlink targets remain untouched'

# Exercise argument forwarding, without opening any window or contacting API.
mkdir -p "$TEST_TMP/mock-bin"
cat > "$TEST_TMP/mock-bin/omarchy-launch-tui" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$DESKTOP_ARGS"
EOF
chmod 755 "$TEST_TMP/mock-bin/omarchy-launch-tui"
DESKTOP_ARGS="$TEST_TMP/args" PATH="$TEST_TMP/mock-bin:$PATH" bash "$ROOT/local-ai" --desktop logs
assert_eq "$(printf 'bash\n%s/local-ai\nlogs' "$ROOT")" "$(cat "$TEST_TMP/args")" 'Omarchy terminal receives separate literal arguments'
DESKTOP_ARGS="$TEST_TMP/args" PATH="$TEST_TMP/mock-bin:$PATH" bash "$ROOT/local-ai" --desktop workspace
assert_eq "$(printf 'bash\n%s/local-ai\nworkspace\nopen\n%s\n--profile\nops' "$ROOT" "$ROOT")" "$(cat "$TEST_TMP/args")" 'desktop opens operations in the retained checkout without an agent command'
expect_failure 'desktop mode rejects arbitrary command execution' bash "$ROOT/local-ai" --desktop 'touch anything'
expect_failure 'desktop escaping rejects newlines' local_ai_desktop_exec_quote $'unsafe\nName=Injected'
assert_eq '"a\\\\b\\"c\\$d\\`e%%f"' "$(local_ai_desktop_exec_quote 'a\b"c$d`e%f')" 'desktop escaping protects reserved characters'

# Workspace dispatch bypasses the mutating setup engine and preserves project
# names and arguments literally. No Herdr daemon, window or real Python runs.
cat > "$TEST_TMP/mock-bin/python3" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$WORKSPACE_ARGS"
exit "${WORKSPACE_RC:-0}"
EOF
chmod 755 "$TEST_TMP/mock-bin/python3"
WORKSPACE_ARGS="$TEST_TMP/args" PATH="$TEST_TMP/mock-bin:$PATH" bash "$ROOT/local-ai" workspace
assert_eq "$(printf '%s/scripts/local-ai-workspace.py\nopen\n%s' "$ROOT" "$PWD")" "$(cat "$TEST_TMP/args")" 'bare workspace opens the current directory'
project_arg="$TEST_TMP/project with spaces; literal"
WORKSPACE_ARGS="$TEST_TMP/args" PATH="$TEST_TMP/mock-bin:$PATH" \
  bash "$ROOT/local-ai" workspace open "$project_arg" --profile golf --no-attach
assert_eq "$(printf '%s/scripts/local-ai-workspace.py\nopen\n%s\n--profile\ngolf\n--no-attach' "$ROOT" "$project_arg")" "$(cat "$TEST_TMP/args")" 'workspace forwards project and profile arguments literally'
for workspace_command in list attach status; do
  WORKSPACE_ARGS="$TEST_TMP/args" PATH="$TEST_TMP/mock-bin:$PATH" \
    bash "$ROOT/local-ai" workspace "$workspace_command"
  assert_eq "$(printf '%s/scripts/local-ai-workspace.py\n%s' "$ROOT" "$workspace_command")" "$(cat "$TEST_TMP/args")" "workspace forwards $workspace_command without installer mutation"
done
workspace_rc=0
WORKSPACE_RC=23 WORKSPACE_ARGS="$TEST_TMP/args" PATH="$TEST_TMP/mock-bin:$PATH" \
  bash "$ROOT/local-ai" workspace status || workspace_rc=$?
assert_eq 23 "$workspace_rc" 'workspace preserves the orchestration exit status'
cat > "$LOCAL_BIN_DIR/local-ai-workspace" <<'EOF'
#!/usr/bin/env bash
# Managed by local-ai-setup: Herdr launcher
printf '%s\n' managed-helper "$@" > "$WORKSPACE_ARGS"
exit 0
EOF
chmod +x "$LOCAL_BIN_DIR/local-ai-workspace"
WORKSPACE_ARGS="$TEST_TMP/args" PATH="$TEST_TMP/mock-bin:$PATH" \
  bash "$ROOT/local-ai" workspace open "$project_arg" --profile golf
assert_eq "$(printf 'managed-helper\nopen\n%s\n--profile\ngolf' "$project_arg")" "$(cat "$TEST_TMP/args")" \
  'workspace uses the installed helper that retains custom configuration roots'

LOCAL_AI_SETUP_LIB_ONLY=0 bash "$ROOT/local-ai" desktop extra > "$TEST_TMP/arity.log" 2>&1 && test_fail 'desktop accepts extra arguments'
test_pass 'desktop command validates arity before mutation'
printf 'Desktop integration tests passed.\n'
