#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib/assert.sh"
TEST_TMP="$(mktemp -d "${TMPDIR:-/tmp}/local-ai-herdr-install-test.XXXXXX")"
TEST_TMP="$(cd "$TEST_TMP" && pwd -P)"
trap 'rm -rf -- "$TEST_TMP"' EXIT
export HOME="$TEST_TMP/home"
export XDG_DATA_HOME="$TEST_TMP/data with spaces"
export XDG_CONFIG_HOME="$TEST_TMP/session config"
export LOCAL_AI_CONFIG_DIR="$TEST_TMP/config"
export LOCAL_BIN_DIR="$TEST_TMP/local bin"
export OMP_AGENT_DIR="$TEST_TMP/omp"
export HERDR_LOCK="$TEST_TMP/herdr.lock"
export HERDR_SKILL_SOURCE="$TEST_TMP/SKILL.md"
export LOCAL_AI_SETUP_LIB_ONLY=1
export ARG_LOG="$TEST_TMP/arguments"
mkdir -p "$HOME"
printf '%s\n' '---' 'name: local-ai-herdr' 'description: Local coordination fixture.' '---' 'Use serial model turns.' > "$HERDR_SKILL_SOURCE"
source "$ROOT/setup-qwen38-pi.sh"
source "$ROOT/lib/local-ai-herdr.sh"
need_arch() { :; }
uname() { case "$1" in -s) echo Linux ;; -m) echo x86_64 ;; *) command uname "$@" ;; esac; }

payload="$TEST_TMP/download"
download_log="$TEST_TMP/download.log"
write_payload() {
  local version="$1"
  cat > "$payload" <<EOF
#!/usr/bin/env bash
set -euo pipefail
if [[ "\${1:-}" == --version ]]; then echo 'herdr $version'; exit 0; fi
printf '%s\\n' "\$@" > "\$ARG_LOG"
printf '%s\\n' "\$HERDR_CONFIG_PATH" "\$HERDR_SESSION" "\$HERDR_VERSION" >> "\$ARG_LOG"
printf '%s|%s|%s\\n' "\${LLAMA_API_KEY-unset}" "\${LLAMA_BASE_URL-unset}" "\${LLAMA_CPP_BASE_URL-unset}" >> "\$ARG_LOG"
printf '%s\\n' "\$XDG_CONFIG_HOME" >> "\$ARG_LOG"
EOF
}
write_lock() {
  local version="$1" bytes sha
  bytes="$(local_ai_file_size "$payload")"
  sha="$(sha256sum "$payload" | awk '{print $1}')"
  printf '%s|Linux|x86_64|https://github.com/herdrdev/herdr/releases/download/v%s/herdr-linux-x86_64|%s|%s\n' "$version" "$version" "$bytes" "$sha" > "$HERDR_LOCK"
}
curl() {
  local target=''
  printf '%s\n' "$*" >> "$download_log"
  while (( $# )); do
    if [[ "$1" == --output ]]; then target="$2"; shift; fi
    shift
  done
  [[ -n "$target" ]] || return 1
  cp "$payload" "$target"
}
run_ok() {
  local label="$1" rc; shift
  set +e
  (set -e; "$@") > "$TEST_TMP/check.log" 2>&1
  rc=$?
  set -e
  if (( rc != 0 )); then cat "$TEST_TMP/check.log" >&2; test_fail "$label"; fi
  test_pass "$label"
}
run_bad() {
  local label="$1" rc; shift
  set +e
  (set -e; "$@") > "$TEST_TMP/check.log" 2>&1
  rc=$?
  set -e
  if (( rc == 0 )); then cat "$TEST_TMP/check.log" >&2; test_fail "$label"; fi
  test_pass "$label"
}

python_install_case() {
  command() {
    if [[ "$*" == '-v python3' ]]; then [[ -f "$TEST_TMP/python-installed" ]]; return; fi
    builtin command "$@"
  }
  local_ai_install_packages() {
    [[ "$*" == python ]] || return 1
    : > "$TEST_TMP/python-installed"
  }
  local_ai_herdr_require_python install
}
run_ok 'missing Python is installed through the Omarchy package helper' python_install_case
[[ -f "$TEST_TMP/python-installed" ]] || test_fail 'Python installation was not requested'
python_config_missing() {
  command() {
    if [[ "$*" == '-v python3' ]]; then return 1; fi
    builtin command "$@"
  }
  cmd_herdr_config
}
run_bad 'config-only setup gives an actionable missing-Python error' python_config_missing
assert_file_contains "$TEST_TMP/check.log" 'python3 is required.*herdr' 'missing-Python message identifies the installation command'
[[ ! -e "$LOCAL_AI_CONFIG_DIR" ]] || test_fail 'missing Python mutated configuration'

HERDR_VERSION=0.9.0
write_payload "$HERDR_VERSION"
write_lock "$HERDR_VERSION"
run_ok 'Herdr installs a verified private runtime and configuration offline' cmd_herdr
binary="$(local_ai_herdr_binary)"
receipt="$(dirname "$binary")/.local-ai-herdr.receipt"
config="$(local_ai_herdr_config_dir)/config.toml"
[[ -x "$binary" && -x "$LOCAL_BIN_DIR/local-ai-herdr" && -x "$LOCAL_BIN_DIR/local-ai-workspace" ]] || test_fail 'Herdr runtime or wrappers missing'
[[ -x "$LOCAL_BIN_DIR/local-ai-pi" ]] || test_fail 'explicit pi launcher missing'
assert_file_contains "$LOCAL_BIN_DIR/local-ai-pi" 'selected agent launcher \(pi\)' 'Herdr provides an explicit authenticated pi launcher'
run_ok 'Herdr receipt verifies the exact installed bytes' local_ai_herdr_receipt_valid "$binary" "$receipt"
assert_file_contains "$download_log" '--proto =https.*https://github.com/herdrdev/herdr/releases/download/v0.9.0/herdr-linux-x86_64' 'Herdr downloads only the pinned HTTPS release'
assert_file_contains "$config" '^name = "terminal"$' 'Herdr inherits the Omarchy terminal palette'
assert_file_contains "$config" '^headless_cols = 160$' 'headless agent panes receive a usable terminal width'
assert_file_contains "$config" '^resume_agents_on_restore = false$' 'Herdr restores layouts without automatically resuming agent requests'
assert_file_contains "$config" '^manifest_check = false$' 'Herdr detection manifests stay pinned with the release'
assert_file_contains "$config" '^pane_history = false$' 'Herdr does not persist terminal transcripts by default'
for agent_root in "$OMP_AGENT_DIR" "$HOME/.pi/agent"; do
  assert_file_contains "$agent_root/skills/local-ai-herdr/SKILL.md" 'Use serial model turns' 'Herdr coordination skill installed in an isolated agent root'
done
cmp "$ROOT/assets/herdr/integrations/omp/herdr-agent-state.ts" "$OMP_AGENT_DIR/extensions/herdr-omp-agent-state.ts" || test_fail 'OMP lifecycle hook differs from pinned source'
cmp "$ROOT/assets/herdr/integrations/pi/herdr-agent-state.ts" "$HOME/.pi/agent/extensions/herdr-agent-state.ts" || test_fail 'pi lifecycle hook differs from pinned source'
test_pass 'OMP and pi lifecycle hooks retain the exact upstream bytes'
run_ok 'Herdr installation is repeatable' cmd_herdr
assert_eq 1 "$(wc -l < "$download_log" | tr -d ' ')" 'repeat installation does not redownload or execute a PATH runtime'

XDG_CONFIG_HOME="$TEST_TMP/stale" LLAMA_API_KEY=stale-secret LLAMA_BASE_URL=http://stale LLAMA_CPP_BASE_URL=http://stale \
  "$LOCAL_BIN_DIR/local-ai-herdr" pane read 'pane with spaces' '; touch unwanted'
assert_eq "$(printf '%s\n' --session local-ai pane read 'pane with spaces' '; touch unwanted' "$config" local-ai 0.9.0 'unset|unset|unset' "$XDG_CONFIG_HOME")" "$(cat "$ARG_LOG")" 'scoped launcher preserves its session root and literal arguments while removing stale daemon credentials'
assert_file_not_contains "$LOCAL_BIN_DIR/local-ai-workspace" 'stale-secret' 'workspace launcher contains no API secret'

prior="$(sha256sum "$binary" "$receipt")"
printf 'corrupt' >> "$payload"
run_bad 'wrong download size is rejected before replacing active Herdr' cmd_herdr_upgrade
assert_eq "$prior" "$(sha256sum "$binary" "$receipt")" 'size failure preserves the active runtime and receipt'
write_payload 9.9.9
run_bad 'wrong download digest is rejected before executing the artifact' cmd_herdr_upgrade
assert_file_contains "$TEST_TMP/check.log" 'SHA-256 verification failed' 'same-size corrupt downloads fail digest verification'
assert_eq "$prior" "$(sha256sum "$binary" "$receipt")" 'digest failure preserves the active runtime and receipt'
write_payload 0.9.0
HERDR_VERSION=0.9.1
write_lock "$HERDR_VERSION"
run_bad 'checksum-valid binary with the wrong version is rejected' cmd_herdr_upgrade
assert_file_contains "$TEST_TMP/check.log" 'expected 0.9.1' 'version mismatch identifies the required pinned release'
assert_eq "$prior" "$(sha256sum "$binary" "$receipt")" 'version failure preserves the active runtime and receipt'
write_payload "$HERDR_VERSION"
write_lock "$HERDR_VERSION"
downloads_before="$(wc -l < "$download_log")"
run_bad 'normal install requires an explicit upgrade for another managed release' cmd_herdr
assert_eq "$downloads_before" "$(wc -l < "$download_log")" 'normal install does not fetch an upgrade'

mv() {
  if [[ -f "$TEST_TMP/fail-receipt" && "$*" == *'/receipt '*'.local-ai-herdr.receipt' ]]; then
    rm "$TEST_TMP/fail-receipt"
    return 1
  fi
  command mv "$@"
}
: > "$TEST_TMP/fail-receipt"
run_bad 'failed receipt promotion rolls back the already-promoted runtime' cmd_herdr_upgrade
assert_eq "$prior" "$(sha256sum "$binary" "$receipt")" 'runtime and receipt roll back as one pair'
unset -f mv
run_ok 'explicit upgrade replaces and verifies the managed release' cmd_herdr_upgrade
assert_eq 'herdr 0.9.1' "$("$binary" --version)" 'explicit upgrade selects the locked version'

printf '\n# personal runtime edit\n' >> "$binary"
modified="$(sha256sum "$binary")"
run_bad 'modified private runtime is preserved even during an explicit upgrade' cmd_herdr_upgrade
assert_eq "$modified" "$(sha256sum "$binary")" 'custom runtime bytes remain unchanged'
rm "$binary" "$receipt"
printf 'personal binary\n' > "$TEST_TMP/user-runtime"
ln -s "$TEST_TMP/user-runtime" "$binary"
run_bad 'symlinked runtime is preserved' cmd_herdr
[[ -L "$binary" ]] || test_fail 'runtime symlink was replaced'
assert_eq 'personal binary' "$(cat "$TEST_TMP/user-runtime")" 'runtime symlink target remains unchanged'

printf '# personal theme\n[theme]\nname="nord"\n' > "$config"
printf '# personal launcher\n' > "$LOCAL_BIN_DIR/local-ai-herdr"
printf 'personal skill\n' > "$OMP_AGENT_DIR/skills/local-ai-herdr/SKILL.md"
printf '// personal hook\n' > "$OMP_AGENT_DIR/extensions/herdr-omp-agent-state.ts"
run_ok 'Herdr configuration refresh preserves custom files' cmd_herdr_config
assert_file_contains "$config" 'name="nord"' 'custom Herdr theme remains active'
assert_file_contains "$config.local-ai-setup.example" '^name = "terminal"$' 'managed Herdr configuration is available as an example'
assert_eq '# personal launcher' "$(cat "$LOCAL_BIN_DIR/local-ai-herdr")" 'custom Herdr launcher remains untouched'
assert_eq 'personal skill' "$(cat "$OMP_AGENT_DIR/skills/local-ai-herdr/SKILL.md")" 'custom coordination skill remains untouched'
assert_eq '// personal hook' "$(cat "$OMP_AGENT_DIR/extensions/herdr-omp-agent-state.ts")" 'modified lifecycle hook remains untouched'

rm "$HOME/.pi/agent/extensions/herdr-agent-state.ts"
ln -s "$TEST_TMP/user-runtime" "$HOME/.pi/agent/extensions/herdr-agent-state.ts"
run_ok 'Herdr config preserves symlinked lifecycle hooks' cmd_herdr_config
[[ -L "$HOME/.pi/agent/extensions/herdr-agent-state.ts" ]] || test_fail 'pi hook symlink replaced'
mkdir "$TEST_TMP/user-skills"
rm -rf "$HOME/.pi/agent/skills"
ln -s "$TEST_TMP/user-skills" "$HOME/.pi/agent/skills"
run_ok 'Herdr config preserves a symlinked skill parent' cmd_herdr_config
[[ ! -e "$TEST_TMP/user-skills/local-ai-herdr" ]] || test_fail 'installer wrote through skill parent symlink'

HERDR_VERSION=0.9.9
run_bad 'unpinned Herdr versions are rejected' local_ai_herdr_read_lock
run_bad 'herdr installation rejects extra arguments' cmd_herdr extra
run_bad 'herdr upgrade rejects extra arguments' cmd_herdr_upgrade extra
run_bad 'herdr configuration rejects extra arguments' cmd_herdr_config extra
printf 'Herdr install integration tests passed.\n'
