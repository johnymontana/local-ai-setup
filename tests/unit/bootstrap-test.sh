#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib/assert.sh"
TEST_TMP="$(mktemp -d "${TMPDIR:-/tmp}/local-ai-bootstrap-test.XXXXXX")"
trap 'rm -rf -- "$TEST_TMP"' EXIT
export HOME="$TEST_TMP/home" LOCAL_AI_SETUP_LIB_ONLY=1
source "$ROOT/setup-qwen38-pi.sh"
events="$TEST_TMP/events"
cmd_check() { echo check >> "$events"; [[ ${VALID_HOST:-1} == 1 ]]; }
save_config() { echo save >> "$events"; }
cmd_install() { echo packages >> "$events"; }
system_reboot_required() { [[ ${PENDING_REBOOT:-0} == 1 ]]; }
cmd_model() { echo "model $*" >> "$events"; }
cmd_service() { echo service >> "$events"; }
cmd_agent() { echo agent >> "$events"; }
cmd_herdr() { echo herdr >> "$events"; }
cmd_desktop() { echo desktop >> "$events"; }

cmd_all >/dev/null
assert_eq $'check\nsave\npackages\nmodel everyday\nservice\nagent\nherdr\ndesktop' "$(cat "$events")" 'fresh install reaches workspaces and desktop after a ready baseline'
: > "$events"
HERDR_ENABLED=0 cmd_all >/dev/null
assert_eq $'check\nsave\npackages\nmodel everyday\nservice\nagent\ndesktop' "$(cat "$events")" 'Herdr opt-out preserves the agent and desktop baseline'
: > "$events"
set +e
(set -e; VALID_HOST=0; cmd_all) > "$TEST_TMP/host.log" 2>&1
rc=$?
set -e
[[ $rc != 0 ]] || test_fail 'unsupported host accepted'
assert_eq check "$(cat "$events")" 'unsupported host rejected before persistent setup'
: > "$events"
set +e
(set -e; PENDING_REBOOT=1; cmd_all) > "$TEST_TMP/reboot.log" 2>&1
rc=$?
set -e
[[ $rc != 0 ]] || test_fail 'pending reboot accepted'
assert_eq $'check\nsave\npackages' "$(cat "$events")" 'reboot gate stops downloads, model loads and desktop success'
printf 'Bootstrap unit tests passed.\n'
