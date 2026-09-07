#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
ENGINE="$ROOT/setup-qwen38-pi.sh"
TEST_TMP="$(mktemp -d "${TMPDIR:-/tmp}/local-ai-command-test.XXXXXX")"

# shellcheck source=../lib/assert.sh
source "$ROOT/tests/lib/assert.sh"

cleanup() {
  [[ "$TEST_TMP" == */local-ai-command-test.* ]] || return 1
  rm -rf -- "$TEST_TMP"
}
trap cleanup EXIT

mock_bin="$TEST_TMP/bin"
mkdir -p "$mock_bin"
cat > "$mock_bin/systemctl" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == '--user is-active llama-server.service' ]]; then
  printf 'inactive\n'
  exit 3
fi
if [[ "$*" == '--user is-active --quiet llama-server.service' ]]; then
  exit 3
fi
exit 0
EOF
cat > "$mock_bin/curl" <<'EOF'
#!/usr/bin/env bash
printf 'status attempted an API request for an inactive managed service\n' >&2
exit 99
EOF
chmod 755 "$mock_bin/systemctl" "$mock_bin/curl"

engine() {
  env HOME="$TEST_TMP/home" PATH="$mock_bin:$PATH" \
    MODEL_LOCK="$ROOT/models.lock" LOCAL_AI_CONFIG_DIR="$TEST_TMP/config" \
    MODELS_DIR="$TEST_TMP/models" LOCAL_BIN_DIR="$TEST_TMP/local-bin" \
    OMP_AGENT_DIR="$TEST_TMP/omp" UNIT_DIR="$TEST_TMP/units" \
    "$ENGINE" "$@"
}

for help_form in no-args help short-help long-help; do
  help_output="$TEST_TMP/help-${help_form}.txt"
  case "$help_form" in
    no-args) engine > "$help_output" ;;
    help) engine help > "$help_output" ;;
    short-help) engine -h > "$help_output" ;;
    long-help) engine --help > "$help_output" ;;
  esac
  grep -q '^Usage: .*setup-qwen38-pi.sh <command> \[arguments\]$' "$help_output" || \
    test_fail "$help_form did not print command usage"
done
test_pass "no-argument and explicit help contract"

for help_token in \
  'model-catalog' 'model-verify [tier|all]' 'model-remove <tier>' \
  'model-prune [--yes]' 'model-maintain remove <tier>' \
  'plan | apply | show-config | save-config KEY=VALUE' \
  'status [--json]' 'bench [tier] [--manage-service]' \
  'perf [tier] [--keep]' 'perf-history [tier|all]' \
  'agent-upgrade [pi|omp]' 'kernel-tweaks | remote | ssh-harden'; do
  grep -Fq -- "$help_token" "$TEST_TMP/help-long-help.txt" || \
    test_fail "help omitted command contract: $help_token"
done
test_pass "help enumerates lifecycle, operations, agent, and system contracts"

plan_output="$TEST_TMP/plan.txt"
if engine plan > "$plan_output"; then
  test_fail "plan succeeded despite having no complete tier"
fi
assert_file_contains "$plan_output" 'read-only; no files or services were changed' \
  "plan labels its non-mutating behavior"
assert_file_contains "$plan_output" 'agent=omp routing=sticky models-max=1 KV=f16' \
  "plan reports safe resolved defaults"
assert_file_contains "$plan_output" 'base=\(blocked: install a complete tier\)' \
  "plan reports a missing-tier blocker without writing"

status_output="$TEST_TMP/status.json"
engine status --json > "$status_output"
jq -e '.schemaVersion==1 and .service.state=="inactive" and
  .service.api=="down" and .service.authEnforced==false and
  .loadedModel==null and (.models|length)==3' "$status_output" >/dev/null || \
  test_fail "read-only status could not report an inactive service"
test_pass "plan and status are read-only with an absent runtime"

show_config_output="$TEST_TMP/show-config.txt"
engine show-config > "$show_config_output"
assert_file_contains "$show_config_output" '^.*Effective configuration \(environment > .*setup.env > defaults\):$' \
  "show-config labels environment/saved/default precedence accurately"

export PERF_HISTORY_FILE="$TEST_TMP/perf-history.jsonl"
cat > "$PERF_HISTORY_FILE" <<'EOF'
{"schemaVersion":3,"timestamp":"2026-08-28T12:00:00Z","tier":"senior","id":"qwen3.5-122b-a10b","variant":"MXFP4_MOE","artifactSetDigest":"000000000000eeee","routingProfile":"quality","loadMode":"mmap","kvCacheProfile":"q8","context":131072,"mtpDraftTokens":0,"promptWords":4096,"reasoningEffort":"medium","loadSeconds":14.5,"cold":{"totalSeconds":20.0},"warm":{"totalSeconds":8.0,"tokensPerSecond":19.5},"runtime":"loaded","runtimeIdentity":{"llamaServerVersion":"llama-server 9999","kernelRelease":"6.18.4-test","gttPagesLimit":"30146560"}}
{"schemaVersion":3,"timestamp":"2026-08-29T12:00:00Z","tier":"everyday","id":"qwen3.8-27b","variant":"UD-Q4_K_XL","artifactSetDigest":"abcdef1234567890","routingProfile":"sticky","loadMode":"none","kvCacheProfile":"f16","context":131072,"mtpDraftTokens":4,"promptWords":4096,"reasoningEffort":"medium","loadSeconds":2.5,"cold":{"totalSeconds":4.0},"warm":{"totalSeconds":2.0,"tokensPerSecond":54.0},"runtime":"loaded","runtimeIdentity":{"llamaServerVersion":"llama-server 9999","kernelRelease":"6.18.4-test","gttPagesLimit":"30146560"}}
EOF
history_output="$TEST_TMP/perf-history.txt"
engine perf-history everyday > "$history_output"
assert_file_contains "$history_output" 'everyday.*id=qwen3.8-27b.*variant=UD-Q4_K_XL.*artifact=abcdef123456' \
  "perf-history renders model and artifact identity"
assert_file_contains "$history_output" 'profile=sticky/none/f16/ctx131072/mtp4/words4096/reasoning-medium' \
  "perf-history renders workload identity"
assert_file_contains "$history_output" 'runtime=llama-server 9999.*kernel=6.18.4-test.*gtt-pages=30146560' \
  "perf-history renders recorded runtime identity keys"
unset PERF_HISTORY_FILE

# Each misuse must be rejected by its own parser before reaching packages,
# downloads, systemd mutation, agent installation, or model generation.
expect_failure "help rejects extra arguments" engine help extra
expect_failure "all rejects extra arguments" engine all extra
expect_failure "check rejects extra arguments" engine check extra
expect_failure "install rejects extra arguments" engine install extra
expect_failure "model rejects excess arguments" engine model everyday --yes extra
expect_failure "model-catalog rejects extra arguments" engine model-catalog extra
expect_failure "model-verify rejects extra arguments" engine model-verify everyday extra
expect_failure "model-remove requires a tier" engine model-remove
expect_failure "model-remove rejects excess arguments" engine model-remove everyday --yes extra
expect_failure "model-prune rejects unknown options" engine model-prune --force
expect_failure "model-maintain requires an operation" engine model-maintain
expect_failure "model-maintain rejects unknown operations" engine model-maintain verify everyday
expect_failure "service rejects extra arguments" engine service extra
expect_failure "agent rejects extra arguments" engine agent extra
expect_failure "agent-upgrade rejects excess arguments" engine agent-upgrade omp extra
expect_failure "pi rejects extra arguments" engine pi extra
expect_failure "omp rejects extra arguments" engine omp extra
expect_failure "omp-lsp rejects extra arguments" engine omp-lsp extra
expect_failure "routing rejects unknown options" engine routing --unknown
expect_failure "plan rejects extra arguments" engine plan extra
expect_failure "apply rejects extra arguments" engine apply extra
expect_failure "kernel-tweaks rejects extra arguments" engine kernel-tweaks extra
expect_failure "remote rejects extra arguments" engine remote extra
expect_failure "ssh-harden rejects extra arguments" engine ssh-harden extra
expect_failure "bench rejects excess arguments" engine bench everyday extra
expect_failure "perf rejects excess arguments" engine perf everyday --keep extra
expect_failure "perf-history rejects excess arguments" engine perf-history everyday extra
expect_failure "status rejects tier arguments" engine status everyday
expect_failure "smoke rejects excess arguments" engine smoke everyday extra
expect_failure "show-config rejects extra arguments" engine show-config extra
expect_failure "save-config requires an assignment" engine save-config
expect_failure "unknown commands are rejected" engine launch-everything

for path in "$TEST_TMP/home" "$TEST_TMP/config" "$TEST_TMP/models" \
    "$TEST_TMP/local-bin" "$TEST_TMP/omp" "$TEST_TMP/units"; do
  [[ ! -e "$path" ]] || test_fail "command-contract checks mutated $path"
done
test_pass "help, plan, status, and arity failures do not mutate managed state"

printf 'Command-contract integration tests passed.\n'
