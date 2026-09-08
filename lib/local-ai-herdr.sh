#!/usr/bin/env bash
# Pinned, private Herdr runtime and opt-in agent integration. Importing is read-only.

local_ai_herdr_root() {
  printf '%s\n' "${XDG_DATA_HOME:-$HOME/.local/share}/local-ai/herdr"
}

local_ai_herdr_binary() {
  printf '%s/bin/herdr\n' "$(local_ai_herdr_root)"
}

local_ai_herdr_config_dir() {
  printf '%s\n' "${HERDR_CONFIG_DIR:-$LOCAL_AI_CONFIG_DIR/herdr}"
}

local_ai_herdr_require_python() {
  command -v python3 >/dev/null 2>&1 && return 0
  if [[ "${1:-}" == install ]]; then
    need_arch
    local_ai_install_packages python || die 'Could not install Python for Herdr workspaces; resolve the Omarchy package/update error and retry'
    command -v python3 >/dev/null 2>&1 && return 0
  fi
  die "python3 is required for Herdr workspaces; run '$0 herdr' to install the prerequisite"
}

local_ai_herdr_path_safe() {
  # Do not follow a user-owned symlink at any level while installing files.
  local path="$1"
  [[ "$path" == /* && "$path" != *[[:cntrl:]]* ]] || return 1
  case "$path/" in */../*|*/./*) return 1 ;; esac
  while [[ "$path" != / ]]; do
    [[ ! -L "$path" ]] || return 1
    [[ ! -e "$path" || -d "$path" ]] || return 1
    path="$(dirname -- "$path")"
  done
}

local_ai_herdr_file_owned_or_absent() {
  local path="$1" marker="$2"
  local_ai_herdr_path_safe "$(dirname -- "$path")" || return 1
  [[ -e "$path" || -L "$path" ]] || return 0
  [[ -f "$path" && ! -L "$path" ]] && grep -qxF -- "$marker" "$path"
}

local_ai_herdr_read_lock() {
  local lock="${HERDR_LOCK:-$SCRIPT_DIR/herdr.lock}" row extra count
  [[ -f "$lock" && ! -L "$lock" ]] || die "Missing regular Herdr release lock: $lock"
  count="$(awk -F '|' -v version="${HERDR_VERSION:-0.9.0}" '$0 !~ /^#/ && $1 == version && $2 == "Linux" && $3 == "x86_64" {n++} END {print n+0}' "$lock")"
  [[ "$count" == 1 ]] || die "HERDR_VERSION=${HERDR_VERSION:-0.9.0} needs exactly one Linux x86_64 artifact in herdr.lock"
  row="$(awk -F '|' -v version="${HERDR_VERSION:-0.9.0}" '$0 !~ /^#/ && $1 == version && $2 == "Linux" && $3 == "x86_64" {print}' "$lock")"
  IFS='|' read -r HERDR_LOCK_VERSION HERDR_LOCK_OS HERDR_LOCK_ARCH HERDR_LOCK_URL HERDR_LOCK_BYTES HERDR_LOCK_SHA extra <<< "$row"
  [[ -z "$extra" && "$HERDR_LOCK_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$HERDR_LOCK_BYTES" =~ ^[1-9][0-9]*$ && "$HERDR_LOCK_SHA" =~ ^[0-9a-f]{64}$ ]] || die 'Invalid Herdr artifact lock fields'
  [[ "$HERDR_LOCK_URL" == "https://github.com/herdrdev/herdr/releases/download/v${HERDR_LOCK_VERSION}/herdr-linux-x86_64" ]] || die 'Herdr lock must reference the exact upstream release asset'
}

local_ai_herdr_artifact_matches() {
  local path="$1" bytes="$2" sha="$3" actual
  [[ -f "$path" && ! -L "$path" ]] || return 1
  [[ "$(local_ai_file_size "$path")" == "$bytes" ]] || return 1
  actual="$(sha256sum "$path" | awk '{print $1}')" || return 1
  [[ "$actual" == "$sha" ]]
}

local_ai_herdr_receipt_valid() {
  local binary="$1" receipt="$2" version bytes sha extra
  [[ -f "$receipt" && ! -L "$receipt" && -x "$binary" ]] || return 1
  [[ "$(sed -n '1p' "$receipt")" == '# Managed by local-ai-setup: Herdr runtime receipt' ]] || return 1
  [[ "$(wc -l < "$receipt" | tr -d ' ')" == 2 ]] || return 1
  IFS='|' read -r version bytes sha extra < <(sed -n '2p' "$receipt")
  [[ -z "$extra" && "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$bytes" =~ ^[1-9][0-9]*$ && "$sha" =~ ^[0-9a-f]{64}$ ]] || return 1
  local_ai_herdr_artifact_matches "$binary" "$bytes" "$sha"
}

local_ai_herdr_install_runtime() (
  # An isolated transaction owns its traps; callers retain their lifecycle lock.
  set -e
  local upgrade="${1:-0}" root binary receipt stage='' touched=0 committed=0 had_binary=0
  root="$(local_ai_herdr_root)"
  binary="$root/bin/herdr"
  receipt="$root/bin/.local-ai-herdr.receipt"
  local_ai_herdr_read_lock
  [[ "$(uname -s)" == "$HERDR_LOCK_OS" && "$(uname -m)" == "$HERDR_LOCK_ARCH" ]] || die 'Pinned Herdr runtime requires Linux x86_64 (Framework Desktop)'
  need_arch
  command -v curl >/dev/null 2>&1 || die "curl not found; run '$0 install'"
  command -v sha256sum >/dev/null 2>&1 || die "sha256sum not found; run '$0 install'"
  local_ai_herdr_path_safe "$root/bin" || die "Symlinked or non-directory Herdr runtime path preserved: $root/bin"
  if [[ -e "$binary" || -L "$binary" || -e "$receipt" || -L "$receipt" ]]; then
    local_ai_herdr_receipt_valid "$binary" "$receipt" || die "User-owned or modified Herdr runtime preserved: $binary (inspect its receipt before replacing it)"
    had_binary=1
    if (( upgrade == 0 )); then
      if local_ai_herdr_artifact_matches "$binary" "$HERDR_LOCK_BYTES" "$HERDR_LOCK_SHA"; then
        ok "Pinned Herdr ${HERDR_LOCK_VERSION} already installed"
        exit 0
      fi
      die "A different managed Herdr release is installed; run '$0 herdr-upgrade' to install ${HERDR_LOCK_VERSION} explicitly"
    fi
  fi
  mkdir -p "$root/bin"
  stage="$(mktemp -d "$root/.install.XXXXXX")" || die 'Could not stage Herdr runtime'
  herdr_install_cleanup() {
    local rc=$? recovery_failed=0
    trap - EXIT HUP INT TERM
    if (( touched && ! committed )); then
      if (( had_binary )); then
        mv -f -- "$stage/prior-herdr" "$binary" || recovery_failed=1
        mv -f -- "$stage/prior-receipt" "$receipt" || recovery_failed=1
      else
        rm -f -- "$binary" "$receipt" || recovery_failed=1
      fi
    fi
    if (( recovery_failed )); then
      warn "Herdr rollback was incomplete; inspect recovery files in $stage"
      rc=1
    else
      rm -rf -- "$stage"
    fi
    exit "$rc"
  }
  trap herdr_install_cleanup EXIT
  trap 'exit 130' HUP INT TERM
  info "Downloading checksum-pinned Herdr ${HERDR_LOCK_VERSION}"
  curl --fail --location --proto '=https' --tlsv1.2 --retry 3 --output "$stage/herdr" "$HERDR_LOCK_URL" || die 'Herdr download failed; the prior runtime is unchanged'
  local_ai_herdr_artifact_matches "$stage/herdr" "$HERDR_LOCK_BYTES" "$HERDR_LOCK_SHA" || die 'Herdr size/SHA-256 verification failed; the prior runtime is unchanged'
  chmod 700 "$stage/herdr" || die 'Could not protect the staged Herdr runtime'
  local version_output
  version_output="$("$stage/herdr" --version 2>/dev/null)" || die 'Verified Herdr artifact could not report its version'
  [[ "$(local_ai_semver_from_text "$version_output")" == "$HERDR_LOCK_VERSION" ]] || die "Herdr reports '$version_output'; expected $HERDR_LOCK_VERSION"
  printf '%s\n%s|%s|%s\n' '# Managed by local-ai-setup: Herdr runtime receipt' "$HERDR_LOCK_VERSION" "$HERDR_LOCK_BYTES" "$HERDR_LOCK_SHA" > "$stage/receipt" || die 'Could not stage the Herdr receipt'
  chmod 600 "$stage/receipt" || die 'Could not protect the Herdr receipt'
  if (( had_binary )); then
    cp -p -- "$binary" "$stage/prior-herdr" || die 'Could not snapshot the prior Herdr runtime'
    cp -p -- "$receipt" "$stage/prior-receipt" || die 'Could not snapshot the prior Herdr receipt'
  fi
  touched=1
  mv -f -- "$stage/herdr" "$binary" || die 'Could not install the staged Herdr runtime'
  mv -f -- "$stage/receipt" "$receipt" || die 'Could not install the staged Herdr receipt'
  committed=1
  ok "Installed verified Herdr ${HERDR_LOCK_VERSION} at $binary"
)

local_ai_herdr_write_launcher() {
  local kind="$1" path="$LOCAL_BIN_DIR/local-ai-$1" stage binary config_dir
  local marker='# Managed by local-ai-setup: Herdr launcher'
  if ! local_ai_herdr_file_owned_or_absent "$path" "$marker"; then
    warn "User-owned Herdr launcher preserved: $path"
    return 0
  fi
  mkdir -p "$LOCAL_BIN_DIR"
  stage="$(mktemp "$LOCAL_BIN_DIR/.local-ai-${kind}.XXXXXX")" || die "Could not stage $path"
  binary="$(local_ai_herdr_binary)"
  config_dir="$(local_ai_herdr_config_dir)"
  {
    printf '%s\n' '#!/usr/bin/env bash' "$marker" 'set -euo pipefail'
    printf 'export LOCAL_AI_CONFIG_DIR=%q\n' "$LOCAL_AI_CONFIG_DIR"
    printf 'export SETUP_ENV=%q\n' "$SETUP_ENV"
    printf 'export KEY_FILE=%q\n' "$KEY_FILE"
    printf 'export LOCAL_BIN_DIR=%q\n' "$LOCAL_BIN_DIR"
    printf 'export OMP_AGENT_DIR=%q\n' "$OMP_AGENT_DIR"
    printf 'export XDG_DATA_HOME=%q\n' "${XDG_DATA_HOME:-$HOME/.local/share}"
    printf 'export XDG_CONFIG_HOME=%q\n' "${XDG_CONFIG_HOME:-$HOME/.config}"
    printf 'export HERDR_CONFIG_DIR=%q\n' "$config_dir"
    printf 'export HERDR_CONFIG_PATH=%q\n' "$config_dir/config.toml"
    printf 'export HERDR_VERSION=%q\n' "${HERDR_VERSION:-0.9.0}"
    printf '%s\n' 'export HERDR_SESSION=local-ai'
    printf '%s\n' '# Agent launchers load fresh credentials; a persistent server must not retain them.'
    printf '%s\n' 'unset LLAMA_API_KEY LLAMA_BASE_URL LLAMA_CPP_BASE_URL'
    printf 'export PATH=%q:"$PATH"\n' "$LOCAL_BIN_DIR"
    if [[ "$kind" == herdr ]]; then
      printf 'binary=%q\n' "$binary"
      printf '%s\n' '[[ -x "$binary" ]] || { echo "Herdr is missing; run local-ai herdr." >&2; exit 1; }'
      printf '%s\n' 'exec "$binary" --session local-ai "$@"'
    else
      printf 'script=%q\n' "$SCRIPT_DIR/scripts/local-ai-workspace.py"
      printf '%s\n' '[[ -f "$script" ]] || { echo "Local AI checkout moved; rerun local-ai herdr-config from its new location." >&2; exit 1; }'
      printf '%s\n' 'exec python3 "$script" "$@"'
    fi
  } > "$stage"
  chmod 700 "$stage" || { rm -f -- "$stage"; die "Could not protect $path"; }
  mv -f -- "$stage" "$path" || { rm -f -- "$stage"; die "Could not install $path"; }
}

local_ai_herdr_install_skill() {
  local agent_root="$1" source="${HERDR_SKILL_SOURCE:-$SCRIPT_DIR/assets/herdr/SKILL.md}" path stage
  local marker='<!-- Managed by local-ai-setup: Herdr skill -->'
  path="$agent_root/skills/local-ai-herdr/SKILL.md"
  [[ -f "$source" && ! -L "$source" ]] || die "Missing Herdr coordination skill: $source"
  if ! local_ai_herdr_file_owned_or_absent "$path" "$marker"; then
    warn "Custom or symlinked Herdr skill preserved: $path"
    return 0
  fi
  mkdir -p "$(dirname -- "$path")"
  stage="$(mktemp "${path}.XXXXXX")" || die "Could not stage $path"
  cat "$source" > "$stage" || { rm -f -- "$stage"; die "Could not read Herdr skill: $source"; }
  grep -qxF -- "$marker" "$stage" || printf '\n%s\n' "$marker" >> "$stage"
  chmod 600 "$stage" || { rm -f -- "$stage"; die "Could not protect $path"; }
  mv -f -- "$stage" "$path" || { rm -f -- "$stage"; die "Could not install $path"; }
}

local_ai_herdr_install_hook() (
  set -e
  local agent="$1" agent_root="$2" name source path receipt prior_sha current_sha stage
  local touched=0 committed=0 had_prior=0
  local marker='# Managed by local-ai-setup: Herdr integration receipt'
  case "$agent" in
    omp) name=herdr-omp-agent-state.ts ;;
    pi) name=herdr-agent-state.ts ;;
    *) die "Unsupported Herdr hook target: $agent" ;;
  esac
  source="$SCRIPT_DIR/assets/herdr/integrations/$agent/herdr-agent-state.ts"
  path="$agent_root/extensions/$name"
  receipt="$agent_root/extensions/.${name}.local-ai-receipt"
  [[ -f "$source" && ! -L "$source" ]] || die "Missing vendored Herdr integration: $source"
  if ! local_ai_herdr_path_safe "$agent_root/extensions"; then
    warn "Symlinked Herdr integration directory preserved: $agent_root/extensions"
    exit 0
  fi
  if [[ -e "$path" || -L "$path" || -e "$receipt" || -L "$receipt" ]]; then
    if [[ -f "$path" && ! -L "$path" && -f "$receipt" && ! -L "$receipt" ]] &&
       [[ "$(sed -n '1p' "$receipt")" == "$marker" ]]; then
      prior_sha="$(sed -n '2p' "$receipt")"
      current_sha="$(sha256sum "$path" | awk '{print $1}')"
      if [[ "$prior_sha" =~ ^[0-9a-f]{64}$ && "$prior_sha" == "$current_sha" && "$(wc -l < "$receipt" | tr -d ' ')" == 2 ]]; then
        had_prior=1
      fi
    fi
    if (( had_prior == 0 )); then
      warn "Custom or modified Herdr integration preserved: $path"
      exit 0
    fi
  fi
  mkdir -p "$agent_root/extensions"
  stage="$(mktemp -d "$agent_root/extensions/.herdr-hook.XXXXXX")" || die 'Could not stage Herdr integration'
  herdr_hook_cleanup() {
    local rc=$? recovery_failed=0
    trap - EXIT HUP INT TERM
    if (( touched && ! committed )); then
      if (( had_prior )); then
        mv -f -- "$stage/prior-hook" "$path" || recovery_failed=1
        mv -f -- "$stage/prior-receipt" "$receipt" || recovery_failed=1
      else
        rm -f -- "$path" "$receipt" || recovery_failed=1
      fi
    fi
    if (( recovery_failed )); then
      warn "Herdr hook rollback was incomplete; inspect recovery files in $stage"
      rc=1
    else
      rm -rf -- "$stage"
    fi
    exit "$rc"
  }
  trap herdr_hook_cleanup EXIT
  trap 'exit 130' HUP INT TERM
  cp -- "$source" "$stage/hook" || die 'Could not stage the Herdr lifecycle hook'
  current_sha="$(sha256sum "$stage/hook" | awk '{print $1}')"
  printf '%s\n%s\n' "$marker" "$current_sha" > "$stage/receipt" || die 'Could not stage the Herdr hook receipt'
  chmod 600 "$stage/hook" "$stage/receipt" || die 'Could not protect the Herdr hook and receipt'
  if (( had_prior )); then
    cp -p -- "$path" "$stage/prior-hook" || die 'Could not snapshot the prior Herdr hook'
    cp -p -- "$receipt" "$stage/prior-receipt" || die 'Could not snapshot the prior Herdr hook receipt'
  fi
  touched=1
  mv -f -- "$stage/hook" "$path" || die 'Could not install the staged Herdr hook'
  mv -f -- "$stage/receipt" "$receipt" || die 'Could not install the staged Herdr hook receipt'
  committed=1
)

cmd_herdr_config() {
  [[ $# == 0 ]] || die "Usage: $0 herdr-config"
  local config_dir path stage
  local marker='# Managed by local-ai-setup: Herdr configuration'
  local_ai_herdr_require_python
  local_ai_herdr_path_safe "$LOCAL_BIN_DIR" || die "Symlinked or non-directory Herdr launcher directory preserved: $LOCAL_BIN_DIR"
  [[ "$OMP_AGENT_DIR" != "${PI_AGENT_DIR:-$HOME/.pi/agent}" ]] || die 'OMP and pi require separate agent directories for Herdr lifecycle hooks'
  config_dir="$(local_ai_herdr_config_dir)"
  local_ai_herdr_path_safe "$config_dir" || die "Symlinked or non-directory Herdr config path preserved: $config_dir"
  path="$config_dir/config.toml"
  if ! local_ai_herdr_file_owned_or_absent "$path" "$marker"; then
    warn "Custom Herdr configuration preserved: $path"
    path="$path.local-ai-setup.example"
    local_ai_herdr_file_owned_or_absent "$path" "$marker" || die "Custom generated-example path preserved: $path"
  fi
  mkdir -p "$config_dir"
  chmod 700 "$config_dir"
  stage="$(mktemp "$config_dir/.config.XXXXXX")" || die 'Could not stage Herdr configuration'
  cat > "$stage" <<'EOF'
# Managed by local-ai-setup: Herdr configuration
# Use the current Omarchy terminal palette without changing its theme.
onboarding = false

[theme]
name = "terminal"

[server]
# Give agents a usable PTY before a terminal UI attaches.
headless_cols = 160
headless_rows = 50

[session]
# Keep saved layouts, but explicitly restart agents through our authenticated
# launcher instead of automatically resuming native agent sessions on restore.
resume_agents_on_restore = false

[update]
# Runtime and lifecycle hooks are reviewed and pinned by this project.
version_check = false
manifest_check = false

[experimental]
# Layout persistence does not require saving pane transcripts to disk.
pane_history = false
EOF
  chmod 600 "$stage" || { rm -f -- "$stage"; die 'Could not protect Herdr configuration'; }
  mv -f -- "$stage" "$path" || { rm -f -- "$stage"; die 'Could not install Herdr configuration'; }
  local_ai_herdr_write_launcher herdr
  local_ai_herdr_write_launcher workspace
  write_agent_launcher pi local-ai-pi
  local_ai_herdr_install_skill "$OMP_AGENT_DIR"
  local_ai_herdr_install_skill "${PI_AGENT_DIR:-$HOME/.pi/agent}"
  local_ai_herdr_install_hook omp "$OMP_AGENT_DIR" || return $?
  local_ai_herdr_install_hook pi "${PI_AGENT_DIR:-$HOME/.pi/agent}" || return $?
  ok 'Herdr launchers, terminal theme, and local coordination skills are ready'
}

cmd_herdr() {
  [[ $# == 0 ]] || die "Usage: $0 herdr"
  local_ai_herdr_require_python install
  local_ai_herdr_install_runtime 0 || return $?
  cmd_herdr_config
}

cmd_herdr_upgrade() {
  [[ $# == 0 ]] || die "Usage: $0 herdr-upgrade"
  local_ai_herdr_require_python install
  local_ai_herdr_install_runtime 1 || return $?
  cmd_herdr_config
}
