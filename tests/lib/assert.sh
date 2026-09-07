#!/usr/bin/env bash

# shellcheck source=environment.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/environment.sh"

test_fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

test_pass() {
  printf 'ok - %s\n' "$*"
}

expect_success() {
  local label="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    test_pass "$label"
  else
    test_fail "$label"
  fi
}

expect_failure() {
  local label="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    test_fail "$label"
  else
    test_pass "$label"
  fi
}

assert_eq() {
  local expected="$1" actual="$2" label="$3"
  [[ "$actual" == "$expected" ]] || \
    test_fail "$label (expected '$expected', got '$actual')"
  test_pass "$label"
}

assert_file_contains() {
  local file="$1" pattern="$2" label="$3"
  grep -Eq -- "$pattern" "$file" || test_fail "$label"
  test_pass "$label"
}

assert_file_not_contains() {
  local file="$1" pattern="$2" label="$3"
  if grep -Eq -- "$pattern" "$file"; then
    test_fail "$label"
  fi
  test_pass "$label"
}
