#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
ENGINE="$ROOT/setup-qwen38-pi.sh"
TEST_TMP="$(mktemp -d "${TMPDIR:-/tmp}/local-ai-operations-test.XXXXXX")"

# shellcheck source=../lib/assert.sh
source "$ROOT/tests/lib/assert.sh"

cleanup() {
  [[ "$TEST_TMP" == */local-ai-operations-test.* ]] || return 1
  rm -rf -- "$TEST_TMP"
}
trap cleanup EXIT

lock_file="$TEST_TMP/models.lock"
models_dir="$TEST_TMP/models"
config_dir="$TEST_TMP/config"
runtime_dir="$TEST_TMP/runtime"
local_bin="$TEST_TMP/local-bin"
omp_dir="$TEST_TMP/omp"
unit_dir="$TEST_TMP/units"
mock_bin="$TEST_TMP/mock-bin"
systemctl_log="$TEST_TMP/systemctl.log"
mkdir -p "$models_dir" "$mock_bin" "$runtime_dir"
chmod 700 "$runtime_dir"
: > "$lock_file"
: > "$systemctl_log"

while IFS='|' read -r tier variant id model_dir repo revision remote _bytes _sha kind; do
  [[ -z "$tier" || "$tier" == \#* ]] && continue
  content="fixture|${tier}|${variant}|${remote}"
  bytes="$(printf '%s' "$content" | wc -c | tr -d ' ')"
  sha="$(printf '%s' "$content" | sha256sum | awk '{print $1}')"
  printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
    "$tier" "$variant" "$id" "$model_dir" "$repo" "$revision" "$remote" \
    "$bytes" "$sha" "$kind" >> "$lock_file"
  if [[ "$tier" != everyday || "$variant" != Q8_0 ]]; then
    mkdir -p "$models_dir/$model_dir"
    printf '%s' "$content" > "$models_dir/$model_dir/${remote##*/}"
  fi
done < "$ROOT/models.lock"

cat > "$mock_bin/llama-server" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == --help ]]; then
  echo '--models-preset --models-max --models-autoload --api-key-file --load-mode --flash-attn --cache-reuse --stop-timeout --spec-type --spec-draft-model --spec-draft-n-max --reasoning --reasoning-effort --reasoning-preserve --no-context-shift --cache-type-k --cache-type-v --spec-draft-type-k --spec-draft-type-v'
else
  echo 'mock llama-server'
fi
EOF
cat > "$mock_bin/systemctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${SYSTEMCTL_LOG:?}"
if [[ "${FAIL_RESTART:-0}" == 1 && "$*" == '--user restart llama-server.service' ]]; then exit 1; fi
if [[ -n "${MOCK_SERVICE_STATE_OVERRIDE:-}" ]]; then
  case "$*" in
    '--user show llama-server.service --property=LoadState --value') printf 'loaded\n'; exit 0 ;;
    '--user is-active --quiet llama-server.service') [[ "$MOCK_SERVICE_STATE_OVERRIDE" == active ]]; exit ;;
    '--user is-active llama-server.service')
      printf '%s\n' "$MOCK_SERVICE_STATE_OVERRIDE"
      [[ "$MOCK_SERVICE_STATE_OVERRIDE" == active ]]
      exit
      ;;
    '--user show llama-server.service --property=MainPID --value') printf '999999\n'; exit 0 ;;
  esac
fi
if [[ -n "${MOCK_SERVICE_STATE_FILE:-}" ]]; then
  state="$(cat "$MOCK_SERVICE_STATE_FILE" 2>/dev/null || printf 'inactive')"
  case "$*" in
    '--user stop llama-server.service') printf 'inactive\n' > "$MOCK_SERVICE_STATE_FILE"; exit 0 ;;
    '--user start llama-server.service'|'--user restart llama-server.service')
      printf 'active\n' > "$MOCK_SERVICE_STATE_FILE"; exit 0 ;;
    '--user is-active --quiet llama-server.service') [[ "$state" == active ]]; exit ;;
    '--user is-active llama-server.service') printf '%s\n' "$state"; [[ "$state" == active ]]; exit ;;
    '--user show llama-server.service --property=LoadState --value') printf 'loaded\n'; exit 0 ;;
    '--user show llama-server.service --property=MainPID --value')
      [[ "$state" == active ]] && printf '999999\n' || printf '0\n'
      exit 0
      ;;
  esac
fi
if [[ "$*" == '--user show llama-server.service --property=MainPID --value' ]]; then
  if [[ "${MOCK_SERVICE_INACTIVE:-0}" == 1 ]]; then
    printf '%s\n' "${MOCK_MAIN_PID:-0}"
  else
    printf '%s\n' "${MOCK_MAIN_PID:-999999}"
  fi
  exit 0
fi
if [[ "${MOCK_SERVICE_INACTIVE:-0}" == 1 ]]; then
  case "$*" in
    '--user is-active --quiet llama-server.service') exit 3 ;;
    '--user is-active llama-server.service') printf 'inactive\n'; exit 3 ;;
  esac
fi
if [[ "$*" == '--user is-active llama-server.service' ]]; then
  if [[ "${MOCK_POST_RESTART_FAILED:-0}" == 1 ]]; then printf 'failed\n'; exit 3; fi
  printf 'active\n'; exit 0
fi
if [[ "$*" == '--user show llama-server.service --property=LoadState --value' ]]; then
  printf 'loaded\n'; exit 0
fi
if [[ "$*" == '--user show llama-server.service --property=MainPID --value' ]]; then
  printf '0\n'; exit 0
fi
exit 0
EOF
cat > "$mock_bin/systemd-analyze" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$mock_bin/loginctl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$mock_bin/sleep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$mock_bin/curl" <<'EOF'
#!/usr/bin/env bash
config_stdin=0
url=''
while (( $# )); do
  case "$1" in
    --config) [[ "${2:-}" != - ]] || config_stdin=1; shift 2 ;;
    --output|--write-out|-H|--max-time|-d) shift 2 ;;
    http://*) url="$1"; shift ;;
    *) shift ;;
  esac
done
if (( config_stdin )); then cat >/dev/null; fi
case "$url" in
  */health) printf '%s' "${READINESS_HEALTH_CODE:-503}" ;;
  */v1/chat/completions)
    if (( config_stdin )); then
      printf '404'
    elif [[ "${READINESS_AUTH_INSECURE:-0}" == 1 ]]; then
      printf '200'
    else
      printf '401'
    fi
    ;;
  *'/v1/models?autoload=0'|*/v1/models)
    [[ -z "${READINESS_CURL_DELAY:-}" ]] || /bin/sleep "$READINESS_CURL_DELAY"
    printf '%s\n' catalog >> "${READINESS_CATALOG_LOG:?}"
    jq -cn --arg state "${READINESS_STATE:-loaded}" \
      '{data:[
        {id:"qwen3.8-27b",status:{value:$state,failed:($state=="failed")}},
        {id:"coder",status:{value:"unloaded",failed:false}},
        {id:"qwen3.5-122b-a10b",status:{value:"unloaded",failed:false}}
      ]}'
    ;;
  *) exit 2 ;;
esac
EOF
chmod 755 "$mock_bin/llama-server" "$mock_bin/systemctl" "$mock_bin/systemd-analyze" \
  "$mock_bin/loginctl" "$mock_bin/sleep" "$mock_bin/curl"

readiness_log="$TEST_TMP/readiness-catalog.log"
: > "$readiness_log"

engine() {
  env HOME="$TEST_TMP/home" PATH="${TEST_EXTRA_BIN:-$mock_bin}:$mock_bin:$PATH" \
    XDG_RUNTIME_DIR="${TEST_RUNTIME_DIR:-$runtime_dir}" \
    MODEL_LOCK="$lock_file" LOCAL_AI_CONFIG_DIR="${TEST_CONFIG_DIR:-$config_dir}" \
    MODELS_DIR="${TEST_MODELS_DIR:-$models_dir}" LOCAL_BIN_DIR="$local_bin" \
    OMP_AGENT_DIR="$omp_dir" UNIT_DIR="$unit_dir" SYSTEMCTL_LOG="$systemctl_log" \
    READINESS_CATALOG_LOG="$readiness_log" "$ENGINE" "$@"
}

# True readiness: router-up alone is insufficient when a startup tier is set.
SERVICE_HEALTHCHECK=0 engine service >/dev/null
: > "$readiness_log"
SERVICE_HEALTHCHECK=1 SERVICE_READY_TIMEOUT=10 READINESS_STATE=loaded \
  engine service >/dev/null
[[ -s "$readiness_log" ]] || test_fail "service never checked startup-model readiness"
test_pass "service waits for its configured startup tier"

: > "$readiness_log"
SERVICE_HEALTHCHECK=1 SERVICE_READY_TIMEOUT=10 STARTUP_TIER=none \
  engine service >/dev/null
[[ "$(wc -l < "$readiness_log" | tr -d ' ')" == 1 ]] || \
  test_fail "startup-none skipped router identity or polled model readiness"
test_pass "startup-none validates router identity without warming a model"

service_before="$(sha256sum "$config_dir/models.ini" "$local_bin/llama-qwen38-server" \
  "$unit_dir/llama-server.service")"
if SERVICE_HEALTHCHECK=1 SERVICE_READY_TIMEOUT=10 STARTUP_TIER=none \
    READINESS_AUTH_INSECURE=1 CTX=65536 engine service >/dev/null 2>&1; then
  test_fail "startup-none accepted an unauthenticated port-conflicting API"
fi
[[ "$(sha256sum "$config_dir/models.ini" "$local_bin/llama-qwen38-server" \
  "$unit_dir/llama-server.service")" == "$service_before" ]] || \
  test_fail "startup-none auth failure did not roll back service files"
test_pass "startup-none still verifies the authenticated API wall"

if SERVICE_HEALTHCHECK=1 SERVICE_READY_TIMEOUT=10 STARTUP_TIER=none \
    MOCK_POST_RESTART_FAILED=1 CTX=65536 engine service >/dev/null 2>&1; then
  test_fail "service committed an authenticated same-catalog listener while its managed unit failed"
fi
[[ "$(sha256sum "$config_dir/models.ini" "$local_bin/llama-qwen38-server" \
  "$unit_dir/llama-server.service")" == "$service_before" ]] || \
  test_fail "failed managed-unit ownership check did not roll back service files"
test_pass "service readiness belongs to the stable managed unit"

# A direct service invocation must reject a transition before generating or
# chmodding the credential that the in-flight process may already be reading.
transition_config="$TEST_TMP/transition-config"
if TEST_CONFIG_DIR="$transition_config" SERVICE_HEALTHCHECK=0 \
    MOCK_SERVICE_STATE_OVERRIDE=activating engine service >/dev/null 2>&1; then
  test_fail "service accepted an activating unit"
fi
[[ ! -e "$transition_config/llama.key" ]] || \
  test_fail "service mutated its API key before proving a stable unit state"
test_pass "service checks stable unit state before credential mutation"

# Re-establish an everyday-startup baseline, then prove loading timeout and a
# failed model both restore every active service file.
SERVICE_HEALTHCHECK=1 SERVICE_READY_TIMEOUT=10 STARTUP_TIER=everyday READINESS_STATE=loaded \
  engine service >/dev/null
service_before="$(sha256sum "$config_dir/models.ini" "$local_bin/llama-qwen38-server" \
  "$unit_dir/llama-server.service")"
loading_started=$SECONDS
if SERVICE_HEALTHCHECK=1 SERVICE_READY_TIMEOUT=10 STARTUP_TIER=everyday \
    READINESS_STATE=loading READINESS_CURL_DELAY=2 CTX=65536 engine service >/dev/null 2>&1; then
  test_fail "permanent loading state passed readiness"
fi
loading_elapsed=$((SECONDS - loading_started))
(( loading_elapsed >= 9 && loading_elapsed <= 14 )) || \
  test_fail "10-second readiness deadline took ${loading_elapsed}s instead of honoring elapsed time"
[[ "$(sha256sum "$config_dir/models.ini" "$local_bin/llama-qwen38-server" \
  "$unit_dir/llama-server.service")" == "$service_before" ]] || \
  test_fail "loading timeout did not roll back service files"
if SERVICE_HEALTHCHECK=1 SERVICE_READY_TIMEOUT=10 STARTUP_TIER=everyday \
    READINESS_STATE=failed CTX=65536 engine service >/dev/null 2>&1; then
  test_fail "failed startup model passed readiness"
fi
[[ "$(sha256sum "$config_dir/models.ini" "$local_bin/llama-qwen38-server" \
  "$unit_dir/llama-server.service")" == "$service_before" ]] || \
  test_fail "failed startup model did not roll back service files"
test_pass "loading/failed readiness states roll back transactionally"

# A conflicting listener remains security-relevant even when the managed unit
# is inactive. Status must probe the port independently and expose it as
# insecure instead of trusting systemd state and claiming the API is down.
MOCK_SERVICE_INACTIVE=1 READINESS_AUTH_INSECURE=1 engine status --json > "$TEST_TMP/inactive-insecure-status.json"
jq -e '.service.state=="inactive" and .service.api=="insecure" and .service.authEnforced==false' \
  "$TEST_TMP/inactive-insecure-status.json" >/dev/null || \
  test_fail "inactive managed service masked a conflicting insecure listener"
test_pass "status probes port security independently of managed service state"

# A prospective split download may run concurrently, but never beyond the
# persisted 1..4 bound. The mock uses an atomic mkdir lock to record overlap.
download_bin="$TEST_TMP/download-bin"
parallel_models="$TEST_TMP/parallel-models"
parallel_config="$TEST_TMP/parallel-config"
mkdir -p "$download_bin" "$parallel_models"
cat > "$download_bin/curl" <<'EOF'
#!/usr/bin/env bash
dest=''
url=''
while (( $# )); do
  case "$1" in
    -o) dest="${2:-}"; shift 2 ;;
    http*) url="$1"; shift ;;
    *) shift ;;
  esac
done
while ! mkdir "$CURL_COUNTER_LOCK" 2>/dev/null; do /bin/sleep 0.01; done
active="$(<"$CURL_ACTIVE_FILE")"; active=$((active + 1)); printf '%s\n' "$active" > "$CURL_ACTIVE_FILE"
maximum="$(<"$CURL_MAX_FILE")"; (( active <= maximum )) || printf '%s\n' "$active" > "$CURL_MAX_FILE"
rmdir "$CURL_COUNTER_LOCK"
/bin/sleep 0.10
base="${dest%.part}"; base="${base##*/}"
row="$(awk -F'|' -v base="$base" '!/^#/ && NF {n=split($7,p,"/"); if(p[n]==base){print; exit}}' "$MODEL_LOCK")"
IFS='|' read -r tier variant _id _dir _repo _revision remote _bytes _sha _kind <<< "$row"
printf 'fixture|%s|%s|%s' "$tier" "$variant" "$remote" > "$dest"
while ! mkdir "$CURL_COUNTER_LOCK" 2>/dev/null; do /bin/sleep 0.01; done
active="$(<"$CURL_ACTIVE_FILE")"; printf '%s\n' "$((active - 1))" > "$CURL_ACTIVE_FILE"
rmdir "$CURL_COUNTER_LOCK"
EOF
chmod 755 "$download_bin/curl"
printf '0\n' > "$TEST_TMP/curl.active"
printf '0\n' > "$TEST_TMP/curl.max"
CURL_ACTIVE_FILE="$TEST_TMP/curl.active" CURL_MAX_FILE="$TEST_TMP/curl.max" \
CURL_COUNTER_LOCK="$TEST_TMP/curl.counter.lock" TEST_EXTRA_BIN="$download_bin" \
TEST_MODELS_DIR="$parallel_models" TEST_CONFIG_DIR="$parallel_config" \
DOWNLOAD_JOBS=2 engine model coder >/dev/null
[[ "$(<"$TEST_TMP/curl.max")" == 2 ]] || test_fail "split downloads did not honor DOWNLOAD_JOBS=2"
[[ "$(find "$parallel_models" -type f -name '*.gguf' | wc -l | tr -d ' ')" == 4 ]] || \
  test_fail "bounded split download did not install every coder shard"
test_pass "bounded parallel split downloads verify and install"

# Disk reserve is checked before curl gets a chance to create a partial file.
disk_bin="$TEST_TMP/disk-bin"
disk_models="$TEST_TMP/disk-models"
mkdir -p "$disk_bin" "$disk_models"
cat > "$disk_bin/df" <<'EOF'
#!/usr/bin/env bash
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
printf 'mock 100 99 1 99%% /mock\n'
EOF
cat > "$disk_bin/curl" <<'EOF'
#!/usr/bin/env bash
printf 'called\n' > "${DISK_CURL_CALLED:?}"
exit 99
EOF
chmod 755 "$disk_bin/df" "$disk_bin/curl"
if DISK_CURL_CALLED="$TEST_TMP/disk-curl.called" TEST_EXTRA_BIN="$disk_bin" \
    TEST_MODELS_DIR="$disk_models" TEST_CONFIG_DIR="$TEST_TMP/disk-config" \
    engine model everyday >/dev/null 2>&1; then
  test_fail "download ignored the configured free-space reserve"
fi
[[ ! -e "$TEST_TMP/disk-curl.called" ]] || test_fail "disk preflight ran after curl"
test_pass "aggregate disk reserve blocks downloads before network mutation"

# Independent mutating invocations sharing the same model/config roots must not
# race on .part files, service activation, or router residency.
lock_bin="$TEST_TMP/lock-bin"
lock_models="$TEST_TMP/lock-models"
lock_config="$TEST_TMP/lock-config"
lock_ready="$TEST_TMP/lock.ready"
lock_release="$TEST_TMP/lock.release"
mkdir -p "$lock_bin" "$lock_models"
cat > "$lock_bin/curl" <<'EOF'
#!/usr/bin/env bash
dest=''
while (( $# )); do
  case "$1" in -o) dest="${2:-}"; shift 2 ;; *) shift ;; esac
done
: > "${LOCK_READY:?}"
while [[ ! -e "${LOCK_RELEASE:?}" ]]; do /bin/sleep 0.01; done
base="${dest%.part}"; base="${base##*/}"
row="$(awk -F'|' -v base="$base" '!/^#/ && NF {n=split($7,p,"/"); if(p[n]==base){print; exit}}' "$MODEL_LOCK")"
IFS='|' read -r tier variant _id _dir _repo _revision remote _bytes _sha _kind <<< "$row"
printf 'fixture|%s|%s|%s' "$tier" "$variant" "$remote" > "$dest"
EOF
chmod 755 "$lock_bin/curl"
LOCK_READY="$lock_ready" LOCK_RELEASE="$lock_release" TEST_EXTRA_BIN="$lock_bin" \
TEST_MODELS_DIR="$lock_models" TEST_CONFIG_DIR="$lock_config" DOWNLOAD_JOBS=1 \
  engine model everyday > "$TEST_TMP/lock-first.log" 2>&1 &
lock_first_pid=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [[ -e "$lock_ready" ]] && break
  /bin/sleep 0.05
done
[[ -e "$lock_ready" ]] || test_fail "first mutation never reached its lock-held download"
different_lock_models="$TEST_TMP/different-lock-models"
mkdir -p "$different_lock_models"
if TEST_MODELS_DIR="$different_lock_models" TEST_CONFIG_DIR="$lock_config" \
    engine save-config PORT=9090 > "$TEST_TMP/lock-second.log" 2>&1; then
  sed 's/^/lock-first: /' "$TEST_TMP/lock-first.log" >&2 || true
  sed 's/^/lock-second: /' "$TEST_TMP/lock-second.log" >&2 || true
  test_fail "concurrent mutation bypassed the process-wide operation lock"
fi
grep -q 'Another local-AI mutation is already running' "$TEST_TMP/lock-second.log" || \
  { sed 's/^/lock-second: /' "$TEST_TMP/lock-second.log" >&2; test_fail "concurrent mutation did not report the lock owner clearly"; }
: > "$lock_release"
wait "$lock_first_pid" || \
  { sed 's/^/lock-first: /' "$TEST_TMP/lock-first.log" >&2; test_fail "lock-owning download failed after release"; }
test_pass "per-user lifecycle lock rejects concurrency across different model roots"

# TERM must not release the lifecycle lock while descendant curl workers are
# still alive. Two parallel workers continuously grow distinct .part files;
# after the setup process exits, both PIDs and all byte growth must be gone.
signal_download_bin="$TEST_TMP/signal-download-bin"
signal_models="$TEST_TMP/signal-models"
signal_config="$TEST_TMP/signal-config"
signal_workers="$TEST_TMP/signal-workers.pids"
signal_runtime="$TEST_TMP/signal-runtime"
mkdir -p "$signal_download_bin" "$signal_models" "$signal_runtime"
chmod 700 "$signal_runtime"
: > "$signal_workers"
cat > "$signal_download_bin/curl" <<'EOF'
#!/usr/bin/env bash
dest=''
while (( $# )); do
  case "$1" in -o) dest="${2:-}"; shift 2 ;; *) shift ;; esac
done
printf '%s\n' "$$" >> "${SIGNAL_WORKERS:?}"
while :; do
  printf x >> "$dest"
  /bin/sleep 0.02
done
EOF
chmod 755 "$signal_download_bin/curl"
# Exercise a caller with an inherited XDG runtime different from TMPDIR.
# The fixture must explicitly select its lock directory on Linux as well.
SIGNAL_WORKERS="$signal_workers" TEST_EXTRA_BIN="$signal_download_bin" \
TEST_MODELS_DIR="$signal_models" TEST_CONFIG_DIR="$signal_config" DOWNLOAD_JOBS=2 \
XDG_RUNTIME_DIR="$runtime_dir" TMPDIR="$signal_runtime" TEST_RUNTIME_DIR="$signal_runtime" \
  engine model coder > "$TEST_TMP/signal-download.log" 2>&1 &
signal_setup_pid=$!
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  [[ "$(wc -l < "$signal_workers" | tr -d ' ')" -ge 2 ]] && break
  /bin/sleep 0.05
done
[[ "$(wc -l < "$signal_workers" | tr -d ' ')" -ge 2 ]] || \
  test_fail "parallel signal test never started two curl descendants"
signal_lock="$signal_runtime/local-ai-setup-$(id -u).lock"
signal_owner="$(sed -n '1p' "$signal_lock/pid" 2>/dev/null || true)"
[[ "$signal_owner" =~ ^[0-9]+$ ]] || test_fail "signal test could not identify the operation-lock owner"
kill -TERM "$signal_owner"
set +e
wait "$signal_setup_pid"
signal_setup_rc=$?
set -e
[[ "$signal_setup_rc" == 130 ]] || test_fail "TERM during download returned $signal_setup_rc instead of 130"
signal_size_before="$(find "$signal_models" -type f -name '*.part' -exec wc -c {} + 2>/dev/null | awk '{sum+=$1} END{print sum+0}')"
while IFS= read -r worker_pid; do
  [[ -n "$worker_pid" ]] || continue
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    kill -0 "$worker_pid" 2>/dev/null || break
    worker_state="$(ps -o stat= -p "$worker_pid" 2>/dev/null | awk '{print $1; exit}' || true)"
    [[ "$worker_state" != Z* ]] || break
    /bin/sleep 0.05
  done
  # Some macOS CI sandboxes deny process-state inspection for an already
  # orphaned child. When state is observable, only a zombie may remain; the
  # byte-stability and immediate-retry assertions below prove no live writer
  # even when ps cannot classify it.
  if kill -0 "$worker_pid" 2>/dev/null; then
    worker_state="$(ps -o stat= -p "$worker_pid" 2>/dev/null | awk '{print $1; exit}' || true)"
    [[ -z "$worker_state" || "$worker_state" == Z* ]] || \
      test_fail "live curl descendant $worker_pid survived interruption cleanup"
  fi
done < "$signal_workers"
signal_size_after="$(find "$signal_models" -type f -name '*.part' -exec wc -c {} + 2>/dev/null | awk '{sum+=$1} END{print sum+0}')"
[[ "$signal_size_after" == "$signal_size_before" ]] || \
  test_fail "a descendant continued writing partial files after lock release"
[[ ! -e "$signal_lock" ]] || test_fail "interrupted download did not release its operation lock"

# A retry immediately owns the same partials exclusively and can finish them.
printf '0\n' > "$TEST_TMP/signal-curl.active"
printf '0\n' > "$TEST_TMP/signal-curl.max"
CURL_ACTIVE_FILE="$TEST_TMP/signal-curl.active" CURL_MAX_FILE="$TEST_TMP/signal-curl.max" \
CURL_COUNTER_LOCK="$TEST_TMP/signal-curl.counter.lock" TEST_EXTRA_BIN="$download_bin" \
TEST_MODELS_DIR="$signal_models" TEST_CONFIG_DIR="$signal_config" DOWNLOAD_JOBS=2 \
TEST_RUNTIME_DIR="$signal_runtime" \
  engine model coder >/dev/null
[[ "$(find "$signal_models" -type f -name '*.gguf' | wc -l | tr -d ' ')" == 4 ]] || \
  test_fail "retry after interrupted parallel download did not complete the tier"
test_pass "signal cleanup terminates download descendants before lock release"

# Pruning/removal operate only on exact manifest-owned paths and require a
# stopped router. User files and symlink targets remain untouched.
q8_row="$(awk -F'|' '$1=="everyday" && $2=="Q8_0" {print; exit}' "$lock_file")"
IFS='|' read -r q8_tier q8_variant _ _ _ _ q8_remote _ _ _ <<< "$q8_row"
q8_path="$models_dir/$(awk -F'|' '$1=="everyday" && $2=="Q8_0" {print $4; exit}' "$lock_file")/${q8_remote##*/}"
printf 'fixture|%s|%s|%s' "$q8_tier" "$q8_variant" "$q8_remote" > "$q8_path"
everyday_main="$(awk -F'|' '$1=="everyday" && $2=="UD-Q4_K_XL" && $10=="main" {n=split($7,p,"/"); print $4 "/" p[n]; exit}' "$lock_file")"
external_target="$TEST_TMP/user-owned-target"
printf 'preserve\n' > "$external_target"
ln -s "$external_target" "$models_dir/${everyday_main}.part"
custom_file="$(dirname "$q8_path")/user-not-in-manifest.gguf"
printf 'preserve\n' > "$custom_file"
if MOCK_SERVICE_INACTIVE=1 engine model-remove everyday --yes >/dev/null 2>&1; then
  test_fail "model-remove deleted the configured startup tier"
fi
[[ -f "$models_dir/$everyday_main" ]] || test_fail "startup-tier refusal changed its artifacts"
test_pass "model-remove requires a startup transition before deletion"
if engine model-remove senior --yes >/dev/null 2>&1; then
  test_fail "model-remove unlinked files while the router was active"
fi

# Every prune candidate is preflighted before the first rename. Put an
# unexpected directory at the later Q8 path and ensure the earlier managed
# partial symlink remains in place when the set is rejected.
rm -f -- "$q8_path"
mkdir "$q8_path"
if MOCK_SERVICE_INACTIVE=1 engine model-prune --yes >/dev/null 2>&1; then
  test_fail "model-prune accepted an unexpected directory at a managed path"
fi
[[ -L "$models_dir/${everyday_main}.part" && -d "$q8_path" ]] || \
  test_fail "model-prune changed an earlier candidate before a later preflight failure"
rmdir "$q8_path"
printf 'fixture|%s|%s|%s' "$q8_tier" "$q8_variant" "$q8_remote" > "$q8_path"
MOCK_SERVICE_INACTIVE=1 engine model-prune --yes >/dev/null
[[ ! -e "$q8_path" && ! -L "$models_dir/${everyday_main}.part" ]] || \
  test_fail "model-prune retained an unselected quant or managed partial"
[[ "$(<"$external_target")" == preserve && "$(<"$custom_file")" == preserve ]] || \
  test_fail "model-prune followed a symlink or removed an unowned file"
senior_dir="$models_dir/$(awk -F'|' '$1=="senior" {print $4; exit}' "$lock_file")"

# Removal performs the same all-path preflight for a multi-shard tier.
senior_first="$(find "$senior_dir" -maxdepth 1 -type f -name '*.gguf' | sort | head -1)"
senior_last="$(find "$senior_dir" -maxdepth 1 -type f -name '*.gguf' | sort | tail -1)"
mv -- "$senior_last" "${senior_last}.saved"
mkdir "$senior_last"
if MOCK_SERVICE_INACTIVE=1 engine model-remove senior --yes >/dev/null 2>&1; then
  test_fail "model-remove accepted an unexpected directory in a shard set"
fi
[[ -f "$senior_first" && -d "$senior_last" ]] || \
  test_fail "model-remove changed an earlier shard before a later preflight failure"
rmdir "$senior_last"
mv -- "${senior_last}.saved" "$senior_last"

# A signal after the first staged rename restores that shard before exiting;
# no partial namespace or quarantine suffix may remain.
remove_signal_bin="$TEST_TMP/remove-signal-bin"
remove_mv_count="$TEST_TMP/remove-mv-count"
senior_expected_count="$(find "$senior_dir" -maxdepth 1 -type f -name '*.gguf' | wc -l | tr -d ' ')"
mkdir -p "$remove_signal_bin"
printf '0\n' > "$remove_mv_count"
cat > "$remove_signal_bin/mv" <<'EOF'
#!/usr/bin/env bash
/bin/mv "$@" || exit $?
count="$(<"${REMOVE_MV_COUNT:?}")"
count=$((count + 1))
printf '%s\n' "$count" > "$REMOVE_MV_COUNT"
if (( count == 1 )); then
  kill -TERM "$PPID"
fi
EOF
chmod 755 "$remove_signal_bin/mv"
set +e
REMOVE_MV_COUNT="$remove_mv_count" TEST_EXTRA_BIN="$remove_signal_bin" \
  MOCK_SERVICE_INACTIVE=1 engine model-remove senior --yes >/dev/null 2>&1
remove_signal_rc=$?
set -e
[[ "$remove_signal_rc" == 130 ]] || \
  test_fail "signal during staged model removal returned $remove_signal_rc instead of 130"
[[ "$(find "$senior_dir" -maxdepth 1 -type f -name '*.gguf' | wc -l | tr -d ' ')" == "$senior_expected_count" ]] || \
  test_fail "signal rollback restored only part of the senior shard set"
while IFS= read -r senior_path; do
  [[ -f "$senior_path" ]] || test_fail "signal rollback did not restore $senior_path"
done < <(find "$senior_dir" -maxdepth 1 -type f -name '*.gguf' | sort)
if find "$senior_dir" -maxdepth 1 -name '*.local-ai-remove.*' | grep -q .; then
  test_fail "signal rollback left a quarantined senior shard"
fi

MOCK_SERVICE_INACTIVE=1 engine model-remove senior --yes >/dev/null
if find "$senior_dir" -maxdepth 1 -type f -name '*.gguf' 2>/dev/null | grep -q .; then
  test_fail "model-remove retained a managed senior shard"
fi
test_pass "model prune/remove enforce stopped-router and manifest ownership"

# The manager-facing maintenance command owns the complete stop -> mutation ->
# apply/restore lifecycle under one engine lock. A no-op restores the prior
# active service; a committed deletion followed by an apply failure must leave
# it stopped rather than restart a preset that references removed files.
maintenance_state="$TEST_TMP/maintenance-service.state"
printf 'active\n' > "$maintenance_state"
q8_partial="${q8_path}.part"
printf 'partial\n' > "$q8_partial"
printf 'n\n' | MOCK_SERVICE_STATE_FILE="$maintenance_state" AGENT=pi \
  engine model-maintain prune >/dev/null
[[ "$(<"$maintenance_state")" == active && -f "$q8_partial" ]] || \
  test_fail "cancelled composite maintenance changed artifacts or failed to restore the service"

: > "$systemctl_log"
if MOCK_SERVICE_STATE_FILE="$maintenance_state" FAIL_RESTART=1 AGENT=pi \
    engine model-maintain prune --yes >/dev/null 2>&1; then
  test_fail "composite maintenance succeeded after its apply restart failed"
fi
[[ ! -e "$q8_partial" && "$(<"$maintenance_state")" == inactive ]] || \
  test_fail "failed post-removal apply restarted a stale service or restored deleted bytes"
grep -q -- '--user stop llama-server.service' "$systemctl_log" || \
  test_fail "composite maintenance did not stop the active router"

printf 'partial\n' > "$q8_partial"
printf 'active\n' > "$maintenance_state"
MOCK_SERVICE_STATE_FILE="$maintenance_state" AGENT=pi \
  engine model-maintain prune --yes >/dev/null
[[ ! -e "$q8_partial" && "$(<"$maintenance_state")" == active ]] || \
  test_fail "successful composite maintenance did not apply desired state and restore service availability"
test_pass "model maintenance serializes no-op, success, and changed-state failure paths"

# The optional managed raw-benchmark mode similarly preserves the prior
# service state without exposing an unlocked stop/start window to the manager.
bench_bin="$TEST_TMP/bench-bin"
bench_log="$TEST_TMP/bench.log"
mkdir -p "$bench_bin"
cat > "$bench_bin/llama-bench" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == --help ]]; then
  printf '%s\n' '--load-mode --fit-target'
  exit 0
fi
printf '%s\n' "$*" >> "${BENCH_LOG:?}"
[[ "${BENCH_FAIL:-0}" != 1 ]]
EOF
chmod 755 "$bench_bin/llama-bench"
printf 'active\n' > "$maintenance_state"
: > "$systemctl_log"
BENCH_LOG="$bench_log" TEST_EXTRA_BIN="$bench_bin" \
  MOCK_SERVICE_STATE_FILE="$maintenance_state" engine bench everyday --manage-service >/dev/null
[[ "$(<"$maintenance_state")" == active ]] || test_fail "managed benchmark did not restore an active router"
grep -q -- '--user stop llama-server.service' "$systemctl_log" && \
  grep -q -- '--user start llama-server.service' "$systemctl_log" || \
  test_fail "managed benchmark did not own the stop/start transaction"

: > "$systemctl_log"
if BENCH_FAIL=1 BENCH_LOG="$bench_log" TEST_EXTRA_BIN="$bench_bin" \
    MOCK_SERVICE_STATE_FILE="$maintenance_state" engine bench everyday --manage-service >/dev/null 2>&1; then
  test_fail "managed benchmark hid a llama-bench failure"
fi
[[ "$(<"$maintenance_state")" == active ]] || \
  test_fail "failed managed benchmark did not restore the prior service"
test_pass "managed raw benchmark restores service state on success and failure"

# A stale running kernel is visible in plan and blocks service activation before
# any systemctl mutation. A mock pacman plus absent running-kernel module tree
# exercises the Arch reboot predicate without touching /run or /etc.
reboot_bin="$TEST_TMP/reboot-bin"
mkdir -p "$reboot_bin"
cat > "$reboot_bin/pacman" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod 755 "$reboot_bin/pacman"
plan_before="$(sha256sum "$config_dir/models.ini" "$local_bin/llama-qwen38-server" \
  "$unit_dir/llama-server.service")"
if TEST_EXTRA_BIN="$reboot_bin" engine plan > "$TEST_TMP/reboot-plan.txt"; then
  test_fail "plan succeeded despite a pending reboot gate"
fi
grep -q 'gate: reboot required before apply/service' "$TEST_TMP/reboot-plan.txt" || \
  test_fail "plan omitted the reboot gate"
if ! AGENT=pi ALLOW_PENDING_REBOOT=1 TEST_EXTRA_BIN="$reboot_bin" engine plan > "$TEST_TMP/reboot-plan-bypass.txt"; then
  test_fail "documented ALLOW_PENDING_REBOOT override could not resolve plan"
fi
grep -q 'explicitly bypassed' "$TEST_TMP/reboot-plan-bypass.txt" || \
  test_fail "plan did not surface the unsafe pending-reboot override"
[[ "$(sha256sum "$config_dir/models.ini" "$local_bin/llama-qwen38-server" \
  "$unit_dir/llama-server.service")" == "$plan_before" ]] || test_fail "reboot-gated plan mutated service files"
systemctl_lines="$(wc -l < "$systemctl_log" | tr -d ' ')"
if TEST_EXTRA_BIN="$reboot_bin" engine service >/dev/null 2>&1; then
  test_fail "service activation ignored the pending reboot gate"
fi
[[ "$(wc -l < "$systemctl_log" | tr -d ' ')" == "$systemctl_lines" ]] || \
  test_fail "reboot-gated service reached systemctl"
test_pass "pending reboot blocks runtime activation without mutation"

printf 'Operational integration tests passed.\n'
