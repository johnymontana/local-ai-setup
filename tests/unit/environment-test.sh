#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/local-ai-environment-test.XXXXXX")"
trap 'rm -rf -- "$TEST_ROOT"' EXIT
export TEST_TMP="$TEST_ROOT/fixture"
export HOME="$TEST_TMP/home" LOCAL_BIN_DIR="$TEST_TMP/local-bin"
export LOCAL_AI_CONFIG_DIR="$TEST_TMP/config" MODELS_DIR="$TEST_TMP/models"
export CANARY_LOG="$TEST_ROOT/canary.log"
mkdir -p "$HOME" "$TEST_ROOT/host-bin" "$TEST_TMP/bin"
: > "$CANARY_LOG"
source "$ROOT/tests/lib/assert.sh"
source "$ROOT/lib/local-ai-platform.sh"
source "$ROOT/lib/local-ai-agents.sh"

# Simulate an actual host's lazy agent launchers outside the fixture root.
unset -f pi omp omarchy omarchy-update 2>/dev/null || true
for name in pi omp omarchy omarchy-update; do
  cat > "$TEST_ROOT/host-bin/$name" <<'EOF'
#!/usr/bin/env bash
printf 'host executable invoked: %s\n' "$0" >> "$CANARY_LOG"
exit 92
EOF
  chmod +x "$TEST_ROOT/host-bin/$name"
done
export PATH="$TEST_ROOT/host-bin:$PATH"
for name in pi omp omarchy omarchy-update; do
  expect_failure "offline lookup ignores host $name" command -v "$name"
done
assert_eq '' "$(local_ai_agent_binary omp)" "generic fixture never resolves a host OMP launcher"
assert_eq '' "$(local_ai_agent_binary pi)" "generic fixture never resolves a host pi launcher"
assert_eq '' "$(<"$CANARY_LOG")" "host detection never invokes lazy launchers"
assert_eq "$(builtin command -v bash)" "$(command -v bash)" \
  "ordinary command lookup retains Bash builtin behavior"

# Fixture binaries retain their exact output, including unsupported versions.
cat > "$TEST_TMP/bin/omp" <<'EOF'
#!/usr/bin/env bash
printf 'omp 18.0.100\n'
EOF
chmod +x "$TEST_TMP/bin/omp"
export PATH="$TEST_TMP/bin:$PATH"
assert_eq "$TEST_TMP/bin/omp" "$(command -v omp)" "fixture OMP binary remains discoverable"
assert_eq 'omp 18.0.100' "$("$(local_ai_agent_binary omp)" --version)" \
  "fixture version output is preserved exactly"
if bash "$ROOT/setup-qwen38-pi.sh" routing > "$TEST_ROOT/routing.out" 2>&1; then
  test_fail 'wrong fixture OMP version was accepted'
fi
assert_file_contains "$TEST_ROOT/routing.out" 'does not match the supported pinned version 18.0.10' \
  "child engine still enforces the fixture's exact OMP version"
assert_eq '' "$(<"$CANARY_LOG")" "child engine never executes a host agent"

omarchy() { return 0; }
assert_eq omarchy "$(command -v omarchy)" "platform tests can provide explicit command functions"
printf 'Offline environment unit tests passed.\n'
