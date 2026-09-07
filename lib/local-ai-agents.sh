#!/usr/bin/env bash
# Omarchy provides moving mise launchers for pi and omp in ~/.local/bin.
# Keep this project's pinned agents in a private prefix without invoking those
# launchers (even --version can install software). Importing is read-only.

local_ai_private_agent_dir() {
  printf '%s\n' "${XDG_DATA_HOME:-$HOME/.local/share}/local-ai/agents"
}

local_ai_agent_prefix() {
  if local_ai_is_omarchy; then
    local_ai_private_agent_dir
  else
    printf '%s\n' "$HOME/.local"
  fi
}

local_ai_agent_bin_dir() {
  if local_ai_is_omarchy; then
    printf '%s/bin\n' "$(local_ai_private_agent_dir)"
  else
    printf '%s\n' "$LOCAL_BIN_DIR"
  fi
}

local_ai_agent_bun_dir() {
  if local_ai_is_omarchy; then
    printf '%s/bun\n' "$(local_ai_private_agent_dir)"
  else
    printf '%s\n' "$HOME/.local/share/bun/install/global"
  fi
}

local_ai_agent_binary() {
  local agent="$1" private found
  case "$agent" in pi|omp) ;; *) return 1 ;; esac
  private="$(local_ai_private_agent_dir)/bin/$agent"
  if local_ai_is_omarchy; then
    if [[ -x "$private" ]]; then printf '%s\n' "$private"; fi
    # An absent private runtime is uninstalled, regardless of Omarchy's stubs.
    return 0
  elif [[ -x "$LOCAL_BIN_DIR/$agent" ]]; then
    printf '%s\n' "$LOCAL_BIN_DIR/$agent"
  else
    found="$(command -v "$agent" 2>/dev/null || true)"
    [[ -z "$found" ]] || printf '%s\n' "$found"
  fi
}
