#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
ENGINE="$ROOT/setup-qwen38-pi.sh"
TEST_TMP="$(mktemp -d "${TMPDIR:-/tmp}/local-ai-runtime-safety-test.XXXXXX")"

# shellcheck source=../lib/assert.sh
source "$ROOT/tests/lib/assert.sh"

cleanup() {
  [[ "$TEST_TMP" == */local-ai-runtime-safety-test.* ]] || return 1
  rm -rf -- "$TEST_TMP"
}
trap cleanup EXIT

export HOME="$TEST_TMP/home"
export MODEL_LOCK="$ROOT/models.lock"
export LOCAL_AI_CONFIG_DIR="$TEST_TMP/config"
export SETUP_ENV="$TEST_TMP/config/setup.env"
export LOCAL_AI_SETUP_LIB_ONLY=1
# shellcheck source=../../setup-qwen38-pi.sh
source "$ENGINE"

run_removal_guard() {
  local mock_state="$1" mock_main_pid="$2" mock_load_state="${3:-loaded}"
  (
    systemctl() {
      case "$*" in
        '--user show llama-server.service --property=LoadState --value')
          [[ -z "$mock_load_state" ]] || printf '%s\n' "$mock_load_state"
          ;;
        '--user is-active llama-server.service')
          [[ -z "$mock_state" ]] || printf '%s\n' "$mock_state"
          [[ "$mock_state" == active ]]
          ;;
        '--user show llama-server.service --property=MainPID --value')
          [[ -z "$mock_main_pid" ]] || printf '%s\n' "$mock_main_pid"
          ;;
        *) return 1 ;;
      esac
    }
    require_router_stopped_for_removal
  )
}

expect_success "removal accepts a fully inactive zero-PID unit" run_removal_guard inactive 0
expect_success "removal accepts a failed zero-PID unit" run_removal_guard failed 0
expect_failure "removal rejects an active unit" run_removal_guard active 42
expect_failure "removal rejects an activating unit" run_removal_guard activating 0
expect_failure "removal rejects a deactivating unit" run_removal_guard deactivating 0
expect_failure "removal rejects an unknown unit state" run_removal_guard unknown 0
expect_failure "removal rejects a missing unit state" run_removal_guard '' 0
expect_failure "removal rejects an inactive unit with a live MainPID" run_removal_guard inactive 42
expect_failure "removal rejects an unverifiable MainPID" run_removal_guard inactive ''
expect_success "removal accepts a unit that has never been installed" run_removal_guard '' '' not-found
expect_failure "removal fails closed when LoadState is unqueryable" run_removal_guard '' '' ''

run_unload_state() {
  local mock_state="$1"
  (
    router_model_state() { printf '%s\n' "$mock_state"; }
    router_post_model_action() { return 0; }
    router_wait_model_state() { return 0; }
    router_unload_model qwen3.8-27b 10
  )
}

expect_success "unload accepts a confirmed unloaded state" run_unload_state unloaded
expect_success "unload accepts a confirmed absent state" run_unload_state absent
expect_success "unload acts on a confirmed loaded state" run_unload_state loaded
expect_failure "unload rejects an unknown state" run_unload_state unknown
expect_failure "unload rejects an empty state query" run_unload_state ''

expect_success "default perf prompt fits the minimum everyday context" \
  perf_prompt_budget_valid 32768 4096
expect_success "large perf prompt fits when its production context has headroom" \
  perf_prompt_budget_valid 131072 32768
expect_failure "max prompt is rejected at the minimum everyday context" \
  perf_prompt_budget_valid 32768 32768
expect_failure "token/output reserve is enforced at the exact boundary" \
  perf_prompt_budget_valid 32768 15873

CTX=32768 CODER_CTX=32768 SENIOR_CTX=65536
expect_success "minimum-context everyday metadata keeps prompt headroom" \
  test "$(tier_output_tokens everyday)" = 28672
expect_success "minimum-context coder metadata keeps prompt headroom" \
  test "$(tier_output_tokens coder)" = 28672
expect_success "minimum-context senior metadata keeps prompt headroom" \
  test "$(tier_output_tokens senior)" = 61440

cookie_bin="$TEST_TMP/cookie-bin"
mkdir -p "$cookie_bin"
cat > "$cookie_bin/ps" <<'EOF'
#!/usr/bin/env bash
[[ "${LC_ALL:-}" == C ]] || exit 91
printf 'Sat Aug 29 12:34:56 2026\n'
EOF
chmod 755 "$cookie_bin/ps"
cookie="$(LC_ALL=fr_FR.UTF-8 PATH="$cookie_bin:$PATH" process_start_cookie 12345)"
[[ "$cookie" == 'Sat Aug 29 12:34:56 2026' ]] || \
  test_fail "operation-lock process identity was locale-dependent"
test_pass "operation-lock process identity uses a stable locale"

firewalld_marker="$TEST_TMP/firewalld-ufw-called"
run_firewalld_guard() (
  systemctl() { [[ "$*" == 'is-active --quiet firewalld' ]]; }
  ufw() { : > "$firewalld_marker"; return 0; }
  configure_firewall
)
expect_failure "active firewalld fails closed instead of accepting an unverifiable override" \
  run_firewalld_guard
[[ ! -e "$firewalld_marker" ]] || \
  test_fail "firewalld guard reached UFW mutation"

printf 'Runtime safety unit tests passed.\n'
