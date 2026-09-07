#!/usr/bin/env bash
# Shared, side-effect-free helpers for local-ai-setup shell entry points.
# Keep this file compatible with Bash 3.2 so the hermetic suite also runs on
# the Bash version bundled with macOS. Do not enable shell options here: the
# caller owns its execution policy.

local_ai_config_get() {
  local config_file="$1" key="$2" fallback="${3:-}" value=""
  if [[ -f "$config_file" && ! -L "$config_file" ]]; then
    value="$(awk -v key="$key" '
      index($0, key "=") == 1 {
        sub(/^[^=]*=/, "")
        value = $0
      }
      END { if (value != "") print value }
    ' "$config_file")"
  fi
  if [[ -n "$value" ]]; then
    printf '%s' "$value"
  else
    printf '%s' "$fallback"
  fi
}

local_ai_file_size() {
  stat -c%s "$1" 2>/dev/null || stat -f%z "$1" 2>/dev/null
}

local_ai_file_uid() {
  stat -c%u "$1" 2>/dev/null || stat -f%u "$1" 2>/dev/null
}

local_ai_file_mode() {
  stat -c%a "$1" 2>/dev/null || stat -f%Lp "$1" 2>/dev/null
}

local_ai_file_identity() {
  # Device, inode, bytes, mtime, and ctime bind a verification receipt to the
  # exact file instance without re-reading a multi-gigabyte artifact. Keep the
  # sub-second timestamps: second-resolution fields can miss a same-size
  # overwrite performed immediately after verification.
  stat -Lc '%d:%i:%s:%y:%z' "$1" 2>/dev/null || \
    stat -f '%d:%i:%z:%Fm:%Fc' "$1" 2>/dev/null
}

local_ai_semver_from_text() {
  local text="$1"
  if [[ "$text" =~ ([0-9]+\.[0-9]+\.[0-9]+) ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
  fi
}

local_ai_help_has_option() {
  local help_text="$1" option="$2"
  # Match a complete CLI token. In particular, --reasoning must not match
  # --reasoning-effort, and --fit-target must not match --fit-target-extra.
  awk -v option="$option" '
    {
      for (i = 1; i <= NF; i++) {
        token = $i
        gsub(/^[[(<{,;|]+/, "", token)
        gsub(/[])}>),;|=].*$/, "", token)
        if (token == option) found = 1
      }
    }
    END { exit(found ? 0 : 1) }
  ' <<< "$help_text"
}

local_ai_api_key_valid() {
  local key="$1"
  [[ "$key" =~ ^[A-Za-z0-9._~-]{32,}$ ]]
}

local_ai_api_key_from_file() {
  local key_file="$1" key
  [[ -f "$key_file" && ! -L "$key_file" && -s "$key_file" ]] || return 1
  key="$(<"$key_file")"
  local_ai_api_key_valid "$key" || return 1
  printf '%s' "$key"
}

local_ai_curl_authenticated() {
  local key_file="$1" key
  shift
  key="$(local_ai_api_key_from_file "$key_file")" || return 1
  # Supplying the header through curl's stdin config keeps the bearer token out
  # of argv and therefore out of ps and /proc command-line views.
  curl --config - "$@" <<EOF
header = "Authorization: Bearer ${key}"
EOF
}
