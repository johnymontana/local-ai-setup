#!/usr/bin/env bash
# User-owned desktop integration. Omarchy's package files, theme and bindings
# remain the source of desktop defaults; these entries use its terminal helper.

local_ai_desktop_owned_or_absent() {
  local path="$1"
  [[ -e "$path" || -L "$path" ]] || return 0
  [[ ! -L "$path" && -f "$path" ]] &&
    grep -qxF '# Managed by local-ai-setup: desktop integration' "$path"
}

local_ai_desktop_exec_quote() {
  # Exec follows desktop-entry escaping, not shell quoting. Reject control
  # characters; double backslashes for the string parser before Exec parsing.
  local value="$1"
  [[ "$value" != *[[:cntrl:]]* ]] || return 1
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//\$/\\\$}"
  value="${value//\`/\\\`}"
  value="${value//\\/\\\\}"
  value="${value//%/%%}"
  printf '"%s"' "$value"
}

cmd_desktop() {
  local applications="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
  local launcher="$LOCAL_BIN_DIR/local-ai" path stage quoted_exec name action
  [[ "$applications" == /* && "$launcher" == /* ]] || die 'Desktop paths must be absolute.'
  quoted_exec="$(local_ai_desktop_exec_quote "$launcher")" || die 'Desktop paths cannot contain control characters.'
  for path in "$launcher" "$applications/local-ai.desktop" "$applications/local-ai-logs.desktop"; do
    local_ai_desktop_owned_or_absent "$path" || die "User-owned path preserved: $path. Move it before running desktop."
  done
  [[ -f "$SCRIPT_DIR/local-ai" ]] || die "Missing local-ai entry point in $SCRIPT_DIR"
  mkdir -p "$LOCAL_BIN_DIR" "$applications"
  stage="$(mktemp "$LOCAL_BIN_DIR/.local-ai-desktop.XXXXXX")"
  {
    printf '%s\n' '#!/usr/bin/env bash' '# Managed by local-ai-setup: desktop integration' 'set -euo pipefail'
    printf 'export LOCAL_AI_CONFIG_DIR=%q\n' "$LOCAL_AI_CONFIG_DIR"
    printf 'export SETUP_ENV=%q\n' "$SETUP_ENV"
    printf 'export LOCAL_BIN_DIR=%q\n' "$LOCAL_BIN_DIR"
    printf 'export XDG_DATA_HOME=%q\n' "${XDG_DATA_HOME:-$HOME/.local/share}"
    printf 'repo=%q\n' "$SCRIPT_DIR"
    printf '%s\n' '[[ -f "$repo/local-ai" ]] || { echo "Local AI checkout moved. Run desktop from its new location." >&2; exit 1; }'
    printf '%s\n' 'exec bash "$repo/local-ai" "$@"'
  } > "$stage"
  chmod 700 "$stage"
  mv -- "$stage" "$launcher"
  for action in menu logs; do
    if [[ "$action" == menu ]]; then
      name='Local AI'; path="$applications/local-ai.desktop"
    else
      name='Local AI Logs'; path="$applications/local-ai-logs.desktop"
    fi
    stage="$(mktemp "$applications/.local-ai-desktop.XXXXXX")"
    cat > "$stage" <<EOF
# Managed by local-ai-setup: desktop integration
[Desktop Entry]
Version=1.0
Type=Application
Name=$name
Comment=Local coding on your Framework Desktop
Exec=/usr/bin/bash $quoted_exec --desktop $action
Icon=utilities-terminal
Terminal=false
Categories=Development;Utility;
Keywords=LLM;Qwen;coding;Omarchy;
EOF
    chmod 644 "$stage"
    mv -- "$stage" "$path"
  done
  if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database "$applications" || warn 'Desktop cache refresh failed; the launchers are installed.'
  fi
  ok "Desktop ready. Search for Local AI, or run $launcher in a terminal."
  info "Keep this checkout at $SCRIPT_DIR; rerun desktop if you move it."
}

cmd_desktop_remove() {
  local applications="${XDG_DATA_HOME:-$HOME/.local/share}/applications" path
  for path in "$LOCAL_BIN_DIR/local-ai" "$applications/local-ai.desktop" "$applications/local-ai-logs.desktop"; do
    if [[ -e "$path" || -L "$path" ]]; then
      if local_ai_desktop_owned_or_absent "$path"; then
        rm -f -- "$path"
      else
        warn "User-owned path preserved: $path"
      fi
    fi
  done
  if [[ -d "$applications" ]] && command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database "$applications" || warn 'Desktop cache refresh failed.'
  fi
  ok 'Removed managed desktop launchers. Models, service and coding agents are still installed.'
}
