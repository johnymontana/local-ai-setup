#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
ENGINE="$ROOT/setup-qwen38-pi.sh"
TEST_TMP="$(mktemp -d "${TMPDIR:-/tmp}/local-ai-config-test.XXXXXX")"
export ROOT ENGINE TEST_TMP

# shellcheck source=../lib/assert.sh
source "$ROOT/tests/lib/assert.sh"

cleanup() {
  [[ "$TEST_TMP" == */local-ai-config-test.* ]] || return 1
  rm -rf -- "$TEST_TMP"
}
trap cleanup EXIT

validate_environment() (
  export HOME="$TEST_TMP/home"
  export MODEL_LOCK="$ROOT/models.lock"
  export LOCAL_AI_CONFIG_DIR="$TEST_TMP/config"
  export MODELS_DIR="${MODELS_DIR:-$TEST_TMP/models}"
  export LOCAL_AI_SETUP_LIB_ONLY=1
  # shellcheck source=../../setup-qwen38-pi.sh
  source "$ENGINE"
)

expect_success "documented configuration defaults validate" validate_environment

for profile in sticky balanced quality; do
  expect_success "routing profile '$profile' validates" \
    env ROUTING_PROFILE="$profile" bash -c "$(declare -f validate_environment); validate_environment"
done
expect_failure "unknown routing profile is rejected" \
  env ROUTING_PROFILE=automatic bash -c "$(declare -f validate_environment); validate_environment"

for tier in everyday coder senior none; do
  expect_success "startup tier '$tier' validates" \
    env STARTUP_TIER="$tier" bash -c "$(declare -f validate_environment); validate_environment"
done

for mode in none mmap mlock mmap+mlock dio; do
  expect_success "load mode '$mode' validates" \
    env LOAD_MODE_EVERYDAY="$mode" bash -c "$(declare -f validate_environment); validate_environment"
done
expect_failure "undocumented auto load mode is rejected" \
  env LOAD_MODE_EVERYDAY=auto bash -c "$(declare -f validate_environment); validate_environment"

for profile in f16 q8; do
  expect_success "KV cache profile '$profile' validates" \
    env KV_CACHE_PROFILE="$profile" bash -c "$(declare -f validate_environment); validate_environment"
done
expect_failure "unknown KV cache profile is rejected" \
  env KV_CACHE_PROFILE=q4 bash -c "$(declare -f validate_environment); validate_environment"

expect_success "maximum native context validates" \
  env CTX=262144 CODER_CTX=262144 SENIOR_CTX=262144 \
    bash -c "$(declare -f validate_environment); validate_environment"
expect_failure "context above native maximum is rejected" \
  env CTX=262145 bash -c "$(declare -f validate_environment); validate_environment"
expect_success "tier-specific minimum contexts keep output ceilings valid" \
  env CTX=32768 CODER_CTX=32768 SENIOR_CTX=65536 \
    bash -c "$(declare -f validate_environment); validate_environment"
expect_failure "everyday context below its output ceiling is rejected" \
  env CTX=32767 bash -c "$(declare -f validate_environment); validate_environment"
expect_failure "coder context below its output ceiling is rejected" \
  env CODER_CTX=32767 bash -c "$(declare -f validate_environment); validate_environment"
expect_failure "senior context below its output ceiling is rejected" \
  env SENIOR_CTX=65535 bash -c "$(declare -f validate_environment); validate_environment"
expect_success "DRAFT_N lower bound validates" \
  env DRAFT_N=1 bash -c "$(declare -f validate_environment); validate_environment"
expect_success "DRAFT_N upper bound validates" \
  env DRAFT_N=8 bash -c "$(declare -f validate_environment); validate_environment"
expect_failure "DRAFT_N zero is rejected" \
  env DRAFT_N=0 bash -c "$(declare -f validate_environment); validate_environment"
expect_failure "DRAFT_N above eight is rejected" \
  env DRAFT_N=9 bash -c "$(declare -f validate_environment); validate_environment"

expect_success "safe single-resident default validates" \
  env MODELS_MAX=1 bash -c "$(declare -f validate_environment); validate_environment"
expect_failure "multiple residents are rejected on the 128 GiB target" \
  env MODELS_MAX=2 bash -c "$(declare -f validate_environment); validate_environment"
expect_failure "legacy unsafe residency escape cannot persist a risky service" \
  env MODELS_MAX=2 ALLOW_UNSAFE_MODELS_MAX=1 \
    bash -c "$(declare -f validate_environment); validate_environment"

expect_success "single download worker validates" \
  env DOWNLOAD_JOBS=1 bash -c "$(declare -f validate_environment); validate_environment"
expect_success "maximum bounded download workers validate" \
  env DOWNLOAD_JOBS=4 bash -c "$(declare -f validate_environment); validate_environment"
expect_failure "zero download workers are rejected" \
  env DOWNLOAD_JOBS=0 bash -c "$(declare -f validate_environment); validate_environment"
expect_failure "download concurrency above four is rejected" \
  env DOWNLOAD_JOBS=5 bash -c "$(declare -f validate_environment); validate_environment"

expect_success "controlled tests may explicitly disable service health checks" \
  env SERVICE_HEALTHCHECK=0 bash -c "$(declare -f validate_environment); validate_environment"
expect_failure "unknown service health-check values fail closed" \
  env SERVICE_HEALTHCHECK=typo bash -c "$(declare -f validate_environment); validate_environment"
expect_failure "relative model directories are rejected" \
  env MODELS_DIR=relative/models bash -c "$(declare -f validate_environment); validate_environment"
expect_failure "systemd-significant dollar signs are rejected in model paths" \
  env MODELS_DIR='/tmp/models$bad' bash -c "$(declare -f validate_environment); validate_environment"
expect_failure "systemd-significant backslashes are rejected in model paths" \
  env MODELS_DIR='/tmp/models\bad' bash -c "$(declare -f validate_environment); validate_environment"

printf 'Configuration unit tests passed.\n'
