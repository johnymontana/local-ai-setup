#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
ENGINE="$ROOT/setup-qwen38-pi.sh"

# This suite intentionally loads real models. tests/run.sh calls it only when
# the operator opts in with RUN_LOCAL_AI_E2E=1 on the target workstation.
[[ "${RUN_LOCAL_AI_E2E:-0}" == 1 ]] || {
  printf 'Hardware E2E skipped (set RUN_LOCAL_AI_E2E=1).\n'
  exit 0
}
command -v pacman >/dev/null 2>&1 || {
  printf 'error: hardware E2E targets the configured Arch workstation.\n' >&2
  exit 1
}
command -v jq >/dev/null 2>&1 || {
  printf 'error: jq is required for hardware E2E.\n' >&2
  exit 1
}

"$ENGINE" plan >/dev/null
status_json="$("$ENGINE" status --json)"
jq -e '
  .schemaVersion == 1 and
  .service.state == "active" and
  .service.api == "authenticated" and
  .service.authEnforced == true and
  (.models | type) == "array"
' <<< "$status_json" >/dev/null || {
  printf 'error: router is not active and authenticated according to status --json.\n' >&2
  exit 1
}

mapfile -t installed_tiers < <(jq -r '.models[] | select(.artifacts == "installed") | .tier' <<< "$status_json")
(( ${#installed_tiers[@]} > 0 )) || {
  printf 'error: no complete tier is installed for hardware E2E.\n' >&2
  exit 1
}

for tier in "${installed_tiers[@]}"; do
  printf 'Hardware smoke: %s\n' "$tier"
  "$ENGINE" smoke "$tier" >/dev/null
  if [[ "${RUN_LOCAL_AI_PERF_E2E:-0}" == 1 ]]; then
    printf 'Hardware production perf: %s\n' "$tier"
    "$ENGINE" perf "$tier" >/dev/null
  fi
done

final_status="$("$ENGINE" status --json)"
jq -e '.service.api == "authenticated" and .service.authEnforced == true' \
  <<< "$final_status" >/dev/null
printf 'Hardware end-to-end tests passed for %d installed tier(s).\n' "${#installed_tiers[@]}"
