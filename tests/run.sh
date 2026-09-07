#!/usr/bin/env bash
set -euo pipefail

TESTS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$TESTS_DIR/.." && pwd)"

usage() {
  cat <<'EOF'
Usage: tests/run.sh [syntax|offline|all]

  syntax  Parse every repository shell script with bash -n.
  offline Run unit, integration, and end-to-end suites with offline fixtures
          (default).
  all     Run offline checks, plus tests/hardware/*.sh when
          RUN_LOCAL_AI_E2E=1.

The offline target must not require network access, sudo, systemd, or model files.
EOF
}

run_syntax() {
  local script
  local -a scripts=()

  while IFS= read -r -d '' script; do
    scripts+=("$script")
  done < <(find "$REPO_ROOT" \
    -path "$REPO_ROOT/.git" -prune -o \
    -type f -name '*.sh' -print0 | sort -z)

  if ((${#scripts[@]} == 0)); then
    printf 'No shell scripts found.\n' >&2
    return 1
  fi

  bash -n "${scripts[@]}"
  printf 'Shell syntax: %d files passed.\n' "${#scripts[@]}"
}

run_offline() {
  run_syntax
  run_group unit
  run_group integration
  run_group e2e
}

run_group() {
  local group="$1" test_file found=0
  local -a tests=()

  [[ -d $TESTS_DIR/$group ]] || return 0
  while IFS= read -r -d '' test_file; do
    found=1
    tests+=("$test_file")
  done < <(find "$TESTS_DIR/$group" -maxdepth 1 -type f -name '*-test.sh' -print0 | sort -z)

  (( found == 1 )) || return 0
  for test_file in "${tests[@]}"; do
    printf 'Running %s/%s\n' "$group" "$(basename "$test_file")"
    bash "$test_file"
  done
}

run_hardware() {
  local test_file found=0
  local -a tests=()

  if [[ ${RUN_LOCAL_AI_E2E:-0} != 1 ]]; then
    printf 'Hardware end-to-end tests skipped (set RUN_LOCAL_AI_E2E=1 to enable).\n'
    return 0
  fi

  if [[ ! -d $TESTS_DIR/hardware ]]; then
    printf 'No hardware end-to-end tests are defined.\n'
    return 0
  fi

  while IFS= read -r -d '' test_file; do
    found=1
    tests+=("$test_file")
  done < <(find "$TESTS_DIR/hardware" -maxdepth 1 -type f -name '*-test.sh' -print0 | sort -z)

  if (( found == 0 )); then
    printf 'No hardware end-to-end tests are defined.\n'
    return 0
  fi

  for test_file in "${tests[@]}"; do
    bash "$test_file"
  done
}

case ${1:-offline} in
  syntax)
    (($# == 1)) || { usage >&2; exit 2; }
    run_syntax
    ;;
  offline)
    (($# <= 1)) || { usage >&2; exit 2; }
    run_offline
    ;;
  all)
    (($# == 1)) || { usage >&2; exit 2; }
    run_offline
    run_hardware
    ;;
  -h|--help|help)
    (($# == 1)) || { usage >&2; exit 2; }
    usage
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
