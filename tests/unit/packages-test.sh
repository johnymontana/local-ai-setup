#!/usr/bin/env bash
# The package step is the first mutation a fresh workstation reaches, and a
# single wrong name aborts the whole install. Prove that `install` requests the
# CPU backend that the configured channel actually offers, and never both names
# at once: `ggml` provides and conflicts with `ggml-cpu`, so a transaction
# naming both fails with "unresolvable package conflicts detected".
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib/assert.sh"
TEST_TMP="$(mktemp -d "${TMPDIR:-/tmp}/local-ai-packages-test.XXXXXX")"
trap 'rm -rf -- "$TEST_TMP"' EXIT
export HOME="$TEST_TMP/home" LOCAL_AI_SETUP_LIB_ONLY=1
mkdir -p "$HOME"
source "$ROOT/setup-qwen38-pi.sh"

requested="$TEST_TMP/requested"
need_arch() { :; }
system_reboot_required() { return 0; }
local_ai_install_packages() { printf '%s\n' "$*" > "$requested"; }

install_request() {
  : > "$requested"
  cmd_install >/dev/null 2>&1
  cat "$requested"
}

local_ai_cpu_backend_packages() { printf '%s\n' ggml-cpu; }
assert_eq \
  'llama-cpp ggml ggml-cpu ggml-vulkan vulkan-radeon vulkan-icd-loader vulkan-tools curl jq python nodejs npm bun pciutils' \
  "$(install_request)" \
  'a split channel installs the separate CPU backend beside the base package'

local_ai_cpu_backend_packages() { :; }
assert_eq \
  'llama-cpp ggml ggml-vulkan vulkan-radeon vulkan-icd-loader vulkan-tools curl jq python nodejs npm bun pciutils' \
  "$(install_request)" \
  'a merged channel installs the base package alone, without a conflicting name'

# Both names in one transaction is the exact failure this resolution prevents.
case " $(install_request) " in
  *" ggml "*" ggml-cpu "*|*" ggml-cpu "*" ggml "*)
    test_fail 'install requested conflicting ggml and ggml-cpu packages together' ;;
esac
test_pass 'install never requests conflicting ggml package names together'

# An unresolvable backend must stop before the privileged transaction rather
# than falling back to a guessed package name.
: > "$requested"
local_ai_cpu_backend_packages() { warn 'fixture backend resolution failed'; return 1; }
if (cmd_install) >"$TEST_TMP/unresolved.out" 2>&1; then
  test_fail 'install continued without resolving the required CPU backend'
fi
[[ ! -s "$requested" ]] || test_fail 'install mutated packages after a failed backend resolution'
assert_file_contains "$TEST_TMP/unresolved.out" 'ggml CPU backend' \
  'a failed backend resolution names the missing runtime dependency'

printf 'Package resolution unit tests passed.\n'
