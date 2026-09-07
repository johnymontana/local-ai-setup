#!/usr/bin/env bash
# Offline suites describe their own OS. A real Omarchy host's global version
# marker and command stubs must not select a private runtime or install tools.
# Platform-specific tests explicitly replace this with their Arch os-release.
export LOCAL_AI_OS_RELEASE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../fixtures" && pwd)/os-release"

# Mark TEST_TMP for export even when a suite creates it after sourcing assert.
# Child engine processes may resolve fixture executables, never real agents or
# Omarchy's lazy mise wrappers. Other host tools (bash, jq, etc.) remain usable.
export TEST_TMP
command() {
  if [[ $# == 2 && "$1" == -v ]]; then
    case "$2" in
      pi|omp|omarchy|omarchy-update)
        local candidate
        candidate="$(builtin command -v "$2" 2>/dev/null)" || return 1
        if [[ "$candidate" == "$2" && "$(type -t "$2")" == function ]]; then
          printf '%s\n' "$candidate"
        elif [[ -n "${TEST_TMP:-}" && "$candidate" == "$TEST_TMP/"* ]]; then
          printf '%s\n' "$candidate"
        else
          return 1
        fi
        return 0
        ;;
    esac
  fi
  builtin command "$@"
}
export -f command
