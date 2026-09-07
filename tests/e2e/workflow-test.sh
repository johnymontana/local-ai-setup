#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
ENGINE="$ROOT/setup-qwen38-pi.sh"
TEST_TMP="$(mktemp -d "${TMPDIR:-/tmp}/local-ai-workflow-test.XXXXXX")"

# shellcheck source=../lib/assert.sh
source "$ROOT/tests/lib/assert.sh"

cleanup() {
  [[ "$TEST_TMP" == */local-ai-workflow-test.* ]] || return 1
  rm -rf -- "$TEST_TMP"
}
trap cleanup EXIT

lock_file="$TEST_TMP/models.lock"
models_dir="$TEST_TMP/models"
config_dir="$TEST_TMP/config"
local_bin="$TEST_TMP/local-bin"
omp_dir="$TEST_TMP/omp"
unit_dir="$TEST_TMP/units"
mock_bin="$TEST_TMP/mock-bin"
systemctl_state="$TEST_TMP/systemctl.state"
systemctl_log="$TEST_TMP/systemctl.log"
router_state="$TEST_TMP/router-model.state"
perf_count="$TEST_TMP/perf-request.count"
runtime_tmp="$TEST_TMP/runtime-tmp"
mkdir -p "$models_dir" "$mock_bin" "$runtime_tmp"
printf 'inactive\n' > "$systemctl_state"
printf 'qwen3.8-27b\n' > "$router_state"
printf '0\n' > "$perf_count"
: > "$systemctl_log"

# Rebuild the production manifest with byte-sized content but preserve all row,
# split-shard, variant, ID, and kind relationships.
: > "$lock_file"
while IFS='|' read -r tier variant id model_dir repo revision remote _bytes _sha kind; do
  [[ -z "$tier" || "$tier" == \#* ]] && continue
  content="fixture|${tier}|${variant}|${remote}"
  bytes="$(printf '%s' "$content" | wc -c | tr -d ' ')"
  sha="$(printf '%s' "$content" | sha256sum | awk '{print $1}')"
  printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
    "$tier" "$variant" "$id" "$model_dir" "$repo" "$revision" "$remote" \
    "$bytes" "$sha" "$kind" >> "$lock_file"

  # Install exactly the selected variants for all three tiers. The alternative
  # everyday Q8 row remains in the lock but absent on disk.
  if [[ "$tier" != everyday || "$variant" != Q8_0 ]]; then
    mkdir -p "$models_dir/$model_dir"
    printf '%s' "$content" > "$models_dir/$model_dir/${remote##*/}"
  fi
done < "$ROOT/models.lock"

cat > "$mock_bin/llama-server" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == --help ]]; then
  echo '--models-preset --models-max --models-autoload --api-key-file --load-mode --flash-attn --cache-reuse --stop-timeout --spec-type --spec-draft-model --spec-draft-n-max --reasoning --reasoning-effort --reasoning-preserve --no-context-shift --cache-type-k --cache-type-v --spec-draft-type-k --spec-draft-type-v'
elif [[ "${1:-}" == --version ]]; then
  printf '%s\n' "${LLAMA_VERSION_OVERRIDE:-mock-llama-v1}"
else
  echo 'mock llama-server'
fi
EOF
cat > "$mock_bin/omp" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == --version ]]; then printf 'omp 18.0.10\n'; else exit 0; fi
EOF
cat > "$mock_bin/systemd-analyze" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$mock_bin/loginctl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$mock_bin/systemctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${SYSTEMCTL_LOG:?}"
state="$(<"${SYSTEMCTL_STATE:?}")"
case "$*" in
  '--user is-active llama-server.service')
    printf '%s\n' "$state"
    [[ "$state" == active ]]
    ;;
  '--user is-active --quiet llama-server.service')
    [[ "$state" == active ]]
    ;;
  '--user show llama-server.service --property=MainPID --value')
    if [[ "$state" == active ]]; then printf '999999\n'; else printf '0\n'; fi
    ;;
  '--user is-enabled --quiet llama-server.service')
    [[ "$state" == active ]]
    ;;
  '--user show llama-server.service --property=LoadState --value')
    printf 'loaded\n'
    ;;
  '--user restart llama-server.service'|'--user start llama-server.service')
    if [[ "${SIGNAL_RESTART:-0}" == 1 && ! -e "${SIGNAL_MARKER:?}" ]]; then
      : > "$SIGNAL_MARKER"
      kill -TERM "$PPID"
      /bin/sleep 0.05
      exit 143
    fi
    printf 'active\n' > "$SYSTEMCTL_STATE"
    ;;
  '--user stop llama-server.service')
    printf 'inactive\n' > "$SYSTEMCTL_STATE"
    ;;
  '--user --no-pager status llama-server.service')
    printf 'mock llama-server.service is %s\n' "$state"
    ;;
  *) exit 0 ;;
esac
EOF
cat > "$mock_bin/curl" <<'EOF'
#!/usr/bin/env bash
config_stdin=0
output_file=''
payload=''
write_out=0
url=''
while (( $# )); do
  case "$1" in
    --config)
      [[ "${2:-}" != - ]] || config_stdin=1
      shift 2
      ;;
    --output|-o)
      output_file="${2:-}"
      shift 2
      ;;
    --write-out)
      write_out=1
      shift 2
      ;;
    -d|--data|--data-raw)
      payload="${2:-}"
      shift 2
      ;;
    -H|--header|--max-time)
      shift 2
      ;;
    --silent|--show-error|--fail-with-body)
      shift
      ;;
    http://*)
      url="$1"
      shift
      ;;
    *) shift ;;
  esac
done
if (( config_stdin )); then cat >/dev/null; fi

case "$url" in
  */health)
    (( write_out == 0 )) || printf '200'
    exit 0
    ;;
  */models/load|*/models/unload)
    model="$(jq -r '.model' <<< "$payload")"
    if [[ "$url" == */models/load ]]; then
      printf '%s\n' "$model" > "$ROUTER_MODEL_STATE"
    elif [[ "$(<"$ROUTER_MODEL_STATE")" == "$model" ]]; then
      printf 'none\n' > "$ROUTER_MODEL_STATE"
    fi
    exit 0
    ;;
  *'/v1/models?autoload=0'|*/v1/models)
    if [[ "${BAD_CATALOG:-0}" == 1 ]]; then
      printf '%s' '{"unrelated":true}'
      (( write_out == 0 )) || printf '\n200'
      exit 0
    fi
    loaded="$(<"$ROUTER_MODEL_STATE")"
    catalog="$(jq -cn --arg loaded "$loaded" '
      {object:"list",data:[
        {id:"qwen3.8-27b",status:{value:(if $loaded=="qwen3.8-27b" then "loaded" elif $loaded=="sleeping:qwen3.8-27b" then "sleeping" else "unloaded" end),progress:1}},
        {id:"coder",status:{value:(if $loaded=="coder" then "loaded" elif $loaded=="sleeping:coder" then "sleeping" else "unloaded" end),progress:1}},
        {id:"qwen3.5-122b-a10b",status:{value:(if $loaded=="qwen3.5-122b-a10b" then "loaded" elif $loaded=="sleeping:qwen3.5-122b-a10b" then "sleeping" else "unloaded" end),progress:1}}
      ]}')"
    printf '%s' "$catalog"
    (( write_out == 0 )) || printf '\n200'
    exit 0
    ;;
  */v1/chat/completions)
    if [[ "$payload" == *'__local_ai_auth_probe__'* ]]; then
      if (( config_stdin )); then printf '404'; else printf '401'; fi
      exit 0
    fi
    if [[ -n "$output_file" ]]; then
      count="$(<"$PERF_REQUEST_COUNT")"
      count=$((count + 1))
      printf '%s\n' "$count" > "$PERF_REQUEST_COUNT"
      if [[ "${PERF_FAIL_WARM:-0}" == 1 && "$count" -ge 2 ]]; then
        exit 22
      fi
      if [[ "$output_file" == - ]]; then
        printf '%s\n' 'data: {"choices":[{"delta":{"role":"assistant","content":""}}]}'
        /bin/sleep "${PERF_FIRST_EVENT_DELAY:-0}"
        cat <<'DATA'
data: {"choices":[{"delta":{"content":"READY"}}],"usage":{"prompt_tokens":512,"completion_tokens":32},"timings":{"prompt_n":512,"predicted_n":32,"predicted_per_second":24.5}}
data: [DONE]
DATA
        printf '\n__LOCAL_AI_TIMING__200|0.010|0.050\n'
      else
        cat > "$output_file" <<'DATA'
data: {"choices":[{"delta":{"content":"READY"}}],"usage":{"prompt_tokens":512,"completion_tokens":32},"timings":{"prompt_n":512,"predicted_n":32,"predicted_per_second":24.5}}
data: [DONE]
DATA
        printf '200|0.010|0.050'
      fi
    else
      printf '%s\n' '{"choices":[{"message":{"role":"assistant","content":"READY"}}]}'
    fi
    exit 0
    ;;
esac
exit 2
EOF
chmod 755 "$mock_bin/llama-server" "$mock_bin/omp" "$mock_bin/systemd-analyze" \
  "$mock_bin/loginctl" "$mock_bin/systemctl" "$mock_bin/curl"

engine() {
  env HOME="$TEST_TMP/home" PATH="$mock_bin:$PATH" \
    MODEL_LOCK="$lock_file" LOCAL_AI_CONFIG_DIR="$config_dir" \
    MODELS_DIR="$models_dir" LOCAL_BIN_DIR="$local_bin" OMP_AGENT_DIR="$omp_dir" \
    UNIT_DIR="$unit_dir" SYSTEMCTL_STATE="$systemctl_state" SYSTEMCTL_LOG="$systemctl_log" \
    ROUTER_MODEL_STATE="$router_state" PERF_REQUEST_COUNT="$perf_count" \
    SIGNAL_RESTART="${SIGNAL_RESTART:-0}" SIGNAL_MARKER="$TEST_TMP/signal-restart.marker" \
    PERF_FIRST_EVENT_DELAY="${PERF_FIRST_EVENT_DELAY:-0}" BAD_CATALOG="${BAD_CATALOG:-0}" \
    SERVICE_HEALTHCHECK=1 SERVICE_READY_TIMEOUT=10 PERF_PROMPT_WORDS="${PERF_PROMPT_WORDS:-512}" \
    TMPDIR="$runtime_tmp" \
    PERF_HISTORY_FILE="$config_dir/perf-history.jsonl" "$ENGINE" "$@"
}

plan_output="$TEST_TMP/plan.txt"
engine plan > "$plan_output"
assert_file_contains "$plan_output" 'OMP roles: base=qwen3.8-27b task=qwen3.8-27b' \
  "workflow plan resolves sticky routing"
[[ ! -e "$config_dir/setup.env" && ! -e "$config_dir/models.ini" ]] || \
  test_fail "workflow plan wrote desired or active state"
test_pass "workflow plan is non-mutating"

engine apply >/dev/null
[[ -f "$config_dir/setup.env" && -f "$config_dir/models.ini" ]] || \
  test_fail "workflow apply omitted persisted or generated configuration"
[[ -f "$omp_dir/models.yml" && -f "$omp_dir/config.yml" ]] || \
  test_fail "workflow apply omitted OMP routing"
assert_file_contains "$local_bin/local-ai-agent" '^export PI_NO_TITLE=1$' \
  "same-shell selected-agent launcher suppresses title requests"
assert_file_contains "$config_dir/setup.env" '^ROUTING_PROFILE=sticky$' \
  "workflow apply persists the routing profile"
assert_file_contains "$config_dir/models.ini" '^load-on-startup = true$' \
  "workflow apply configures the startup tier"
assert_file_contains "$omp_dir/config.yml" '^  task: llamacpp/qwen3.8-27b$' \
  "workflow apply keeps sticky task routing on base"
[[ "$(<"$systemctl_state")" == active ]] || test_fail "workflow apply did not activate the service"
test_pass "workflow apply activates service and OMP desired state"

# Selecting pi does not uninstall OMP. If a tier disappears, apply must still
# refresh an existing managed OMP pair/wrapper set so the documented fallback
# cannot retain a launcher that deterministically routes to a missing model.
senior_probe_rel="$(awk -F'|' '$1=="senior" {n=split($7,p,"/"); print $4 "/" p[n]; exit}' "$lock_file")"
mv -- "$models_dir/$senior_probe_rel" "$models_dir/$senior_probe_rel.saved"
AGENT=pi engine apply >/dev/null
[[ ! -e "$local_bin/omp-senior" && ! -L "$local_bin/omp-senior" ]] || \
  test_fail "pi-selected apply retained a stale managed senior launcher"
if grep -q 'id: qwen3.5-122b-a10b' "$omp_dir/models.yml"; then
  test_fail "pi-selected apply retained an absent senior provider"
fi
mv -- "$models_dir/$senior_probe_rel.saved" "$models_dir/$senior_probe_rel"
AGENT=omp engine apply >/dev/null
[[ -x "$local_bin/omp-senior" ]] || test_fail "restored senior tier did not recreate its managed launcher"
test_pass "pi-selected apply keeps managed OMP fallback routing current"

service_before="$(sha256sum "$config_dir/models.ini" "$local_bin/llama-qwen38-server" \
  "$unit_dir/llama-server.service")"
rm -f "$TEST_TMP/signal-restart.marker"
if SIGNAL_RESTART=1 CTX=65536 engine service >/dev/null 2>&1; then
  test_fail "interrupted direct service update returned success"
fi
service_after="$(sha256sum "$config_dir/models.ini" "$local_bin/llama-qwen38-server" \
  "$unit_dir/llama-server.service")"
[[ "$service_after" == "$service_before" ]] || \
  test_fail "interrupted direct service update did not restore all active service files"
[[ "$(<"$systemctl_state")" == active ]] || \
  test_fail "interrupted direct service update did not restore the active unit state"
test_pass "direct service updates roll back files and unit state on signals"

apply_before="$(sha256sum "$config_dir/setup.env" "$config_dir/models.ini" \
  "$local_bin/llama-qwen38-server" "$unit_dir/llama-server.service" \
  "$omp_dir/models.yml" "$omp_dir/config.yml")"
rm -f "$TEST_TMP/signal-restart.marker"
if SIGNAL_RESTART=1 CTX=65536 engine apply >/dev/null 2>&1; then
  test_fail "interrupted service activation returned successful apply"
fi
apply_after="$(sha256sum "$config_dir/setup.env" "$config_dir/models.ini" \
  "$local_bin/llama-qwen38-server" "$unit_dir/llama-server.service" \
  "$omp_dir/models.yml" "$omp_dir/config.yml")"
[[ "$apply_after" == "$apply_before" ]] || \
  test_fail "interrupted apply did not restore desired, routing, and service files"
[[ "$(<"$systemctl_state")" == active ]] || test_fail "interrupted apply did not restore active service state"
test_pass "workflow apply rolls back an interrupted service activation"

managed_before="$(sha256sum "$config_dir/setup.env" "$config_dir/models.ini" \
  "$omp_dir/models.yml" "$omp_dir/config.yml")"
engine status --json > "$TEST_TMP/status.json"
jq -e '.service.api=="authenticated" and .loadedModel=="qwen3.8-27b" and
  ([.models[] | select(.artifacts=="installed")]|length)==3' \
  "$TEST_TMP/status.json" >/dev/null || test_fail "workflow status reported incorrect runtime state"
managed_after="$(sha256sum "$config_dir/setup.env" "$config_dir/models.ini" \
  "$omp_dir/models.yml" "$omp_dir/config.yml")"
[[ "$managed_after" == "$managed_before" ]] || test_fail "workflow status mutated managed state"
engine smoke everyday >/dev/null
test_pass "workflow status is observational and smoke owns generation"

BAD_CATALOG=1 engine status --json > "$TEST_TMP/bad-catalog-status.json"
jq -e '.service.api=="error" and .catalog==null' "$TEST_TMP/bad-catalog-status.json" >/dev/null || \
  test_fail "status authenticated an unrelated JSON listener without a router catalog"
service_before_bad_catalog="$(sha256sum "$config_dir/models.ini" "$local_bin/llama-qwen38-server" \
  "$unit_dir/llama-server.service")"
if BAD_CATALOG=1 STARTUP_TIER=none engine service >/dev/null 2>&1; then
  test_fail "startup-tier none committed against an unrelated authenticated listener"
fi
service_after_bad_catalog="$(sha256sum "$config_dir/models.ini" "$local_bin/llama-qwen38-server" \
  "$unit_dir/llama-server.service")"
[[ "$service_after_bad_catalog" == "$service_before_bad_catalog" ]] || \
  test_fail "unrelated-listener service failure did not restore the active service trio"
[[ "$(<"$systemctl_state")" == active ]] || \
  test_fail "unrelated-listener service failure did not restore active state"
test_pass "service and status require the expected authenticated router catalog"

# Start from coder so a normal everyday perf run must restore a different model.
printf 'coder\n' > "$router_state"
printf '0\n' > "$perf_count"
PERF_FIRST_EVENT_DELAY=0.10 engine perf everyday >/dev/null
[[ "$(<"$router_state")" == coder ]] || test_fail "perf did not restore prior model residency"
jq -e '.schemaVersion==3 and .tier=="everyday" and .loadMode=="none" and
  .kvCacheProfile=="f16" and .context==131072 and .mtpDraftTokens==4 and
  .promptWords==512 and .promptTokens==512 and .reasoningEffort=="medium" and
  .variant=="UD-Q4_K_XL" and (.artifactSetDigest | length)==64 and
  (.runtimeIdentity.llamaServerVersion | length)>0 and
  (.runtimeIdentity.kernelRelease | length)>0 and
  .cold.httpCode==200 and .warm.httpCode==200 and
  .cold.responseStartSeconds==0.01 and .cold.ttftSeconds>=0.08' \
  "$config_dir/perf-history.jsonl" >/dev/null || \
  test_fail "perf history omitted production-profile metrics"
test_pass "production perf records event TTFT (not header time) and restores residency"

# Sleeping is not equivalent to loaded, and the router exposes no public
# transition that can reconstruct a sleeping process. Refuse before mutation
# instead of waking it and claiming exact residency restoration.
printf 'sleeping:coder\n' > "$router_state"
sleep_history_lines="$(wc -l < "$config_dir/perf-history.jsonl" | tr -d ' ')"
if engine perf everyday >/dev/null 2>&1; then
  test_fail "perf accepted a sleeping pre-state it cannot restore exactly"
fi
[[ "$(<"$router_state")" == sleeping:coder ]] || \
  test_fail "sleeping-state perf guard mutated router residency"
[[ "$(wc -l < "$config_dir/perf-history.jsonl" | tr -d ' ')" == "$sleep_history_lines" ]] || \
  test_fail "sleeping-state perf guard appended history"
test_pass "production perf refuses non-restorable sleeping residency"

perf_artifact="$(jq -r '.artifactSetDigest' "$config_dir/perf-history.jsonl")"
perf_compare() {
  local words="$1" effort="$2"
  env HOME="$TEST_TMP/home" PATH="$mock_bin:$PATH" MODEL_LOCK="$lock_file" \
    LOCAL_AI_CONFIG_DIR="$config_dir" MODELS_DIR="$models_dir" LOCAL_BIN_DIR="$local_bin" \
    OMP_AGENT_DIR="$omp_dir" UNIT_DIR="$unit_dir" LOCAL_AI_SETUP_LIB_ONLY=1 \
    LLAMA_VERSION_OVERRIDE="${LLAMA_VERSION_OVERRIDE:-}" \
    PERF_HISTORY_FILE="$config_dir/perf-history.jsonl" bash -c \
    'source "$1"; perf_last_comparable everyday qwen3.8-27b 131072 4 UD-Q4_K_XL "$2" "$3" "$4"' \
    _ "$ENGINE" "$perf_artifact" "$words" "$effort"
}
[[ "$(perf_compare 1024 medium)" == null ]] || \
  test_fail "perf compared runs with different prompt sizes"
[[ "$(perf_compare 512 low)" == null ]] || \
  test_fail "perf compared runs with different reasoning effort"
[[ "$(LLAMA_VERSION_OVERRIDE=mock-llama-v2 perf_compare 512 medium)" == null ]] || \
  test_fail "perf compared runs across different llama.cpp builds"
jq -e '.schemaVersion==3' >/dev/null <<< "$(perf_compare 512 medium)" || \
  test_fail "perf failed to find an actually comparable history row"
test_pass "performance comparisons include prompt and reasoning profiles"

# Desired-state edits must never be mislabeled as the live benchmark profile.
# The active preset remains at 131072 until apply, so perf must refuse a saved
# 65536 context rather than load the old preset and record the new label.
engine save-config CTX=65536 >/dev/null
printf 'coder\n' > "$router_state"
history_lines="$(wc -l < "$config_dir/perf-history.jsonl" | tr -d ' ')"
if engine perf everyday >/dev/null 2>&1; then
  test_fail "perf accepted desired settings that were not active"
fi
[[ "$(<"$router_state")" == coder ]] || test_fail "stale-profile perf changed residency"
[[ "$(wc -l < "$config_dir/perf-history.jsonl" | tr -d ' ')" == "$history_lines" ]] || \
  test_fail "stale-profile perf appended a mislabeled history record"
engine save-config CTX=131072 >/dev/null
test_pass "production perf requires the desired preset to be active"

printf 'coder\n' > "$router_state"
printf '0\n' > "$perf_count"
engine perf everyday --keep >/dev/null
[[ "$(<"$router_state")" == qwen3.8-27b ]] || test_fail "perf --keep restored the previous model"
test_pass "perf --keep leaves its target resident"

printf 'coder\n' > "$router_state"
printf '0\n' > "$perf_count"
if PERF_FAIL_WARM=1 engine perf everyday >/dev/null 2>&1; then
  test_fail "perf warm-request failure returned success"
fi
[[ "$(<"$router_state")" == coder ]] || test_fail "failed perf did not restore prior residency"
[[ "$(wc -l < "$config_dir/perf-history.jsonl" | tr -d ' ')" == 2 ]] || \
  test_fail "failed perf appended an incomplete history record"
test_pass "failed production perf restores residency without partial history"
if find "$runtime_tmp" -maxdepth 1 -type d -name 'local-ai-perf.*' | grep -q .; then
  test_fail "failed perf leaked response timing sidecars or its scratch directory"
fi
test_pass "failed performance requests clean all scratch sidecars"

printf 'coder\n' > "$router_state"
printf '0\n' > "$perf_count"
if PERF_FAIL_WARM=1 engine perf everyday --keep >/dev/null 2>&1; then
  test_fail "failed perf --keep returned success"
fi
[[ "$(<"$router_state")" == coder ]] || \
  test_fail "failed perf --keep did not restore prior residency"
test_pass "perf --keep takes effect only after a fully successful run"

printf 'Offline workflow end-to-end tests passed.\n'
