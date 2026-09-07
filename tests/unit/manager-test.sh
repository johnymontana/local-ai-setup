#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
TEST_TMP="$(mktemp -d "${TMPDIR:-/tmp}/local-ai-manager-test.XXXXXX")"
EVENT_LOG="$TEST_TMP/events.log"

# shellcheck source=../lib/assert.sh
source "$ROOT/tests/lib/assert.sh"

cleanup() {
  [[ "$TEST_TMP" == */local-ai-manager-test.* ]] || return 1
  rm -rf -- "$TEST_TMP"
}
trap cleanup EXIT

export HOME="$TEST_TMP/home"
export LOCAL_AI_CONFIG_DIR="$TEST_TMP/config"
export LOCAL_AI_MANAGE_LIB_ONLY=1

# shellcheck source=../../manage.sh
source "$ROOT/manage.sh"

reset_events() {
  : > "$EVENT_LOG"
}

event() {
  printf '%s\n' "$*" >> "$EVENT_LOG"
}

# A quant switch must verify/download the prospective artifact before it
# persists desired state. Applying is considered only after both steps pass.
MOCK_QUANT_OK=1
MOCK_ENGINE_OK=1
engine_quant() {
  event "quant|$*"
  ENGINE_OK=$MOCK_QUANT_OK
  ENGINE_RC=$((MOCK_QUANT_OK == 1 ? 0 : 1))
  return 0
}
engine() {
  event "engine|$*"
  ENGINE_OK=$MOCK_ENGINE_OK
  ENGINE_RC=$((MOCK_ENGINE_OK == 1 ? 0 : 1))
  return 0
}
plan_and_apply() {
  event "plan-and-apply|${1:-}"
  return 0
}
pause() { return 0; }
banner() { return 0; }

# Agent selection validates the prospective target, persists it, then
# regenerates the selected launcher from persisted state. Merely installing a
# fallback must not leave local-ai-agent pointing at the old choice.
reset_events
MOCK_ENGINE_OK=1
choose_agent <<< $'2\ny' >/dev/null
expected_agent_events="$(printf '%s\n' \
  'engine|pi' \
  'engine|save-config AGENT=pi' \
  'engine|agent')"
assert_eq "$expected_agent_events" "$(<"$EVENT_LOG")" \
  "agent selection regenerates the launcher after persistence"

reset_events
upgrade_agent <<< $'2\ny' >/dev/null
assert_eq 'engine|agent-upgrade pi' "$(<"$EVENT_LOG")" \
  "manager exposes the explicit pinned agent-upgrade path"

reset_events
change_quant UD-Q4_K_XL Q8_0 <<< 'y' >/dev/null
expected_quant_events="$(printf '%s\n' \
  'quant|Q8_0 model everyday' \
  'engine|save-config QUANT=Q8_0' \
  'plan-and-apply|Apply Q8_0 to the router now? [Y/n] ')"
assert_eq "$expected_quant_events" "$(<"$EVENT_LOG")" \
  "quant change downloads, persists, then offers plan/apply"

reset_events
MOCK_QUANT_OK=0
change_quant UD-Q4_K_XL Q8_0 <<< 'y' >/dev/null
assert_eq 'quant|Q8_0 model everyday' "$(<"$EVENT_LOG")" \
  "failed prospective quant leaves saved state untouched"

assert_profile_events() {
  local input="$1" expected="$2" label="$3"
  reset_events
  profile_menu <<< "$input" >/dev/null
  assert_eq "$expected" "$(<"$EVENT_LOG")" "$label"
}

assert_profile_events $'1\nquality' \
  $'engine|save-config ROUTING_PROFILE=quality\nplan-and-apply|' \
  "routing profile persists and offers apply"
assert_profile_events $'2\nnone' \
  $'engine|save-config STARTUP_TIER=none\nplan-and-apply|' \
  "startup profile persists and offers apply"
assert_profile_events $'3\nq8' \
  $'engine|save-config KV_CACHE_PROFILE=q8\nplan-and-apply|' \
  "KV profile persists and offers apply"
assert_profile_events $'4\nsenior\ndio' \
  $'engine|save-config LOAD_MODE_SENIOR=dio\nplan-and-apply|' \
  "per-tier load mode persists and offers apply"
assert_profile_events $'5\n4' \
  'engine|save-config DOWNLOAD_JOBS=4' \
  "download concurrency persists without restarting"
assert_profile_events $'6\n12' \
  'engine|save-config DISK_RESERVE_GIB=12' \
  "disk reserve persists without restarting"

reset_events
perf_output="$(run_perf <<< 'senior')"
assert_eq 'engine|perf senior' "$(<"$EVENT_LOG")" \
  "manager delegates production perf to the engine"
grep -q 'temporarily unloads/swaps model residency' <<< "$perf_output" || \
  test_fail "manager perf path did not warn about client disruption"
test_pass "manager perf path warns about client disruption"

# Raw llama-bench service state is owned by one engine transaction; the manager
# may inspect state for confirmation but never stops/starts outside that lock.
systemctl() {
  event "systemctl|$*"
  case "$*" in
    '--user is-active --quiet llama-server.service') return 0 ;;
    *) return 1 ;;
  esac
}

for bench_result in success failure; do
  reset_events
  if [[ "$bench_result" == success ]]; then MOCK_ENGINE_OK=1; else MOCK_ENGINE_OK=0; fi
  run_raw_bench <<< $'coder\ny' >/dev/null
  expected_bench_events="$(printf '%s\n' \
    'systemctl|--user is-active --quiet llama-server.service' \
    'engine|bench coder --manage-service')"
  assert_eq "$expected_bench_events" "$(<"$EVENT_LOG")" \
    "raw benchmark delegates one locked service transaction after $bench_result"
done

# Removing the configured startup tier must first move the live service to an
# installed fallback; deletion is never attempted against the active preset.
refresh_status_snapshot() {
  STATUS_JSON='{"models":[{"tier":"everyday","artifacts":"installed"},{"tier":"coder","artifacts":"installed"},{"tier":"senior","artifacts":"absent"}]}'
  return 0
}
reset_events
MOCK_ENGINE_OK=1
prepare_startup_tier_removal everyday <<< 'y' >/dev/null
expected_startup_events="$(printf '%s\n' \
  'engine|save-config STARTUP_TIER=coder' \
  'engine|plan' \
  'engine|apply')"
assert_eq "$expected_startup_events" "$(<"$EVENT_LOG")" \
  "startup-tier removal applies a safe installed fallback first"

# Model maintenance follows the same rule: one engine command owns stop,
# artifact mutation, apply, and conditional restoration under one lock.
for maintenance_result in success failure; do
  reset_events
  if [[ "$maintenance_result" == success ]]; then MOCK_ENGINE_OK=1; else MOCK_ENGINE_OK=0; fi
  run_model_maintenance model-prune <<< 'y' >/dev/null
  expected_maintenance_events="$(printf '%s\n' \
    'systemctl|--user is-active --quiet llama-server.service' \
    'engine|model-maintain prune')"
  assert_eq "$expected_maintenance_events" "$(<"$EVENT_LOG")" \
    "manager delegates one locked maintenance transaction after $maintenance_result"
done

# A freshly installed Omarchy system can open the menu before gum or desktop
# launchers exist. Piped input must keep working even when gum is on PATH.
gum() {
  event "unexpected-gum|$*"
  return 1
}
reset_events
MOCK_ENGINE_OK=1
main_menu <<< 'd' >/dev/null
assert_eq 'engine|desktop' "$(<"$EVENT_LOG")" \
  "plain menu installs app launchers through the engine"
reset_events
main_menu <<< 'X' >/dev/null
assert_eq 'engine|desktop-remove' "$(<"$EVENT_LOG")" \
  "plain menu removes app launchers through the engine"
reset_events
NO_COLOR=1 LOCAL_AI_MENU=plain main_choice <<< 's' >/dev/null
assert_eq s "$MENU_CHOICE" "plain menu retains the status shortcut"
assert_eq '' "$(<"$EVENT_LOG")" "noninteractive menu never starts gum"
expect_failure "plain menu exits cleanly on end of input" main_menu </dev/null
expect_failure "plain menu supports quitting" main_menu <<< 'q'

# The chooser label is a display value, never executable input. Only complete
# known labels dispatch, and Escape/Ctrl-C must not choose a default action.
(
  use_gum_menu() { return 0; }
  GUM_SELECTION='d) Add app launchers'
  GUM_RESULT=0
  gum() {
    (( GUM_RESULT == 0 )) || return "$GUM_RESULT"
    printf '%s\n' "$GUM_SELECTION"
  }
  reset_events
  main_menu >/dev/null
  assert_eq 'engine|desktop' "$(<"$EVENT_LOG")" \
    "gum selection dispatches the corresponding engine command"
  for cancellation in empty interrupted unknown; do
    reset_events
    case "$cancellation" in
      empty) GUM_SELECTION=''; GUM_RESULT=0 ;;
      interrupted) GUM_SELECTION='1) Install local AI'; GUM_RESULT=130 ;;
      unknown) GUM_SELECTION='1) Unexpected option'; GUM_RESULT=0 ;;
    esac
    expect_failure "gum $cancellation choice exits the menu" main_menu
    assert_eq '' "$(<"$EVENT_LOG")" \
      "gum $cancellation choice never starts an engine action"
  done
)

printf 'Manager unit tests passed.\n'
