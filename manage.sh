#!/usr/bin/env bash
#
# manage.sh — interactive control panel for the local multi-model coding stack.
# Every action delegates to setup-qwen38-pi.sh and remains scriptable directly.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE="$HERE/setup-qwen38-pi.sh"
COMMON_LIB="$HERE/lib/local-ai-common.sh"
[[ -r "$COMMON_LIB" ]] || { echo "Can't find lib/local-ai-common.sh next to manage.sh" >&2; exit 1; }
# shellcheck source=lib/local-ai-common.sh
source "$COMMON_LIB"
LOCAL_AI_CONFIG_DIR="${LOCAL_AI_CONFIG_DIR:-$HOME/.config/local-ai}"
SETUP_ENV="${SETUP_ENV:-$LOCAL_AI_CONFIG_DIR/setup.env}"
KEY_FILE="${KEY_FILE:-$LOCAL_AI_CONFIG_DIR/llama.key}"
LOCAL_BIN_DIR="${LOCAL_BIN_DIR:-$HOME/.local/bin}"
UNIT_NAME="llama-server.service"

[[ -f "$ENGINE" ]] || { echo "Can't find setup-qwen38-pi.sh next to manage.sh" >&2; exit 1; }
[[ -x "$ENGINE" ]] || chmod +x "$ENGINE" 2>/dev/null || true

# ------------------------------- styling ------------------------------------

if [[ -t 1 ]]; then
  B=$'\033[1m'; DIM=$'\033[2m'; R=$'\033[0m'
  GRN=$'\033[1;32m'; YLW=$'\033[1;33m'; RED=$'\033[1;31m'; ORG=$'\033[38;5;208m'
else
  B=""; DIM=""; R=""; GRN=""; YLW=""; RED=""; ORG=""
fi

cfg() {  # read one persisted key, else print the fallback ($2)
  local k="$1" def="${2:-}" value=""
  value="$(local_ai_config_get "$SETUP_ENV" "$k" "")"
  # Match the engine's legacy migration so the panel never displays a saved
  # value that the engine silently interprets differently.
  if [[ "$k" == REASONING_EFFORT && "$value" == none ]]; then value=medium; fi
  if [[ "$k" == MODELS_MAX && "$value" =~ ^[0-9]+$ ]] && (( value > 1 )); then value=1; fi
  if [[ -n "$value" ]]; then printf '%s' "$value"; else printf '%s' "$def"; fi
}

pause() { read -r -p $'\n'"${DIM}Press Enter to continue…${R}" _ || true; }
warn() { printf '%swarn%s %s\n' "$YLW" "$R" "$*"; }

ENGINE_OK=0
ENGINE_RC=0
engine() {  # surface a failure without killing the control-panel loop
  echo "${DIM}\$ ./setup-qwen38-pi.sh $*${R}"
  if "$ENGINE" "$@"; then
    ENGINE_OK=1
    ENGINE_RC=0
  else
    ENGINE_RC=$?
    ENGINE_OK=0
    warn "'$*' exited ${ENGINE_RC} — review the output above."
  fi
  return 0
}

# Download a prospective everyday quant without changing saved desired state.
# Only the two validated quant names can reach this helper; no eval is used.
engine_quant() {
  local quant="$1"; shift
  echo "${DIM}\$ QUANT=${quant} ./setup-qwen38-pi.sh $*${R}"
  if QUANT="$quant" "$ENGINE" "$@"; then
    ENGINE_OK=1
    ENGINE_RC=0
  else
    ENGINE_RC=$?
    ENGINE_OK=0
    warn "QUANT=${quant} '$*' exited ${ENGINE_RC} — saved configuration was not changed."
  fi
  return 0
}

# ------------------------------- status line --------------------------------

agent_now() { cfg AGENT omp; }

svc_state() {
  if systemctl --user is-active --quiet "$UNIT_NAME" 2>/dev/null; then
    echo "active"
  else
    echo "inactive"
  fi
}

svc_startup_state() {
  if systemctl --user is-enabled --quiet "$UNIT_NAME" 2>/dev/null; then
    echo "enabled"
  else
    echo "disabled"
  fi
}

protected_probe_code() {
  local port="$1" key="${2:-}"
  if [[ -n "$key" ]]; then
    local_ai_curl_authenticated "$KEY_FILE" --silent --output /dev/null \
      --write-out '%{http_code}' --max-time 3 -H 'Content-Type: application/json' \
      -d '{"model":"__local_ai_auth_probe__","messages":[]}' \
      "http://127.0.0.1:${port}/v1/chat/completions" 2>/dev/null
  else
    curl --silent --output /dev/null --write-out '%{http_code}' --max-time 3 \
      -H 'Content-Type: application/json' \
      -d '{"model":"__local_ai_auth_probe__","messages":[]}' \
      "http://127.0.0.1:${port}/v1/chat/completions" 2>/dev/null
  fi
}

authenticated_catalog_code() {
  local port="$1"
  local_ai_curl_authenticated "$KEY_FILE" --silent --output /dev/null \
    --write-out '%{http_code}' --max-time 3 \
    "http://127.0.0.1:${port}/v1/models?autoload=0" 2>/dev/null
}

api_state() {
  local port="${1:-$(cfg PORT 8080)}" key="" unauth_code auth_code catalog_code
  command -v curl >/dev/null 2>&1 || { echo "down"; return; }

  # A green state requires both halves of the claim: the protected endpoint
  # rejects a keyless request, and the same endpoint accepts our local key.
  unauth_code="$(protected_probe_code "$port" || true)"
  case "$unauth_code" in
    000|'') echo "down"; return ;;
    401|403) ;;
    5??) echo "error"; return ;;
    *) echo "insecure"; return ;;
  esac

  key="$(local_ai_api_key_from_file "$KEY_FILE" 2>/dev/null || true)"
  [[ -n "$key" ]] || { echo "unauthorized"; return; }
  auth_code="$(protected_probe_code "$port" "$key" || true)"
  case "$auth_code" in
    000|'') echo "down"; return ;;
    401|403) echo "unauthorized"; return ;;
    400|404|422|2??) ;;
    *) echo "error"; return ;;
  esac

  # Confirm a useful authenticated request succeeds without loading a model.
  catalog_code="$(authenticated_catalog_code "$port" "$key" || true)"
  case "$catalog_code" in
    2??) echo "authenticated" ;;
    000|'') echo "down" ;;
    401|403) echo "unauthorized" ;;
    *) echo "error" ;;
  esac
}

STATUS_JSON=""
refresh_status_snapshot() {
  STATUS_JSON=""
  command -v jq >/dev/null 2>&1 || return 1
  local candidate
  candidate="$("$ENGINE" status --json 2>/dev/null)" || return 1
  jq -e 'type == "object"' >/dev/null 2>&1 <<< "$candidate" || return 1
  STATUS_JSON="$candidate"
}

snapshot_text() {
  local filter="$1" fallback="${2:-}"
  local value=""
  if [[ -n "$STATUS_JSON" ]]; then
    value="$(jq -r "$filter // empty" <<< "$STATUS_JSON" 2>/dev/null || true)"
  fi
  [[ -n "$value" && "$value" != null ]] && printf '%s' "$value" || printf '%s' "$fallback"
}

snapshot_models() {
  [[ -n "$STATUS_JSON" ]] || return 1
  jq -r '
    [(.models // [])[]? |
      (.tier // "?") as $tier |
      (if (.artifacts | type) == "object" then (.artifacts.state // "unknown")
       else (.artifacts // "unknown") end) as $artifacts |
      (if (.runtime | type) == "object" then (.runtime.state // "unknown")
       else (.runtime // "unknown") end) as $runtime |
      (.artifactProgress.doneBytes // 0) as $done |
      (.artifactProgress.totalBytes // 0) as $total |
      (if $artifacts == "partial" and $total > 0
       then "\($artifacts):\((($done * 100 / $total) | floor))%"
       else $artifacts end) as $artifactDisplay |
      "\($tier):\($artifactDisplay)/\($runtime)"] | join("  ")
  ' <<< "$STATUS_JSON" 2>/dev/null
}

snapshot_load_modes() {
  [[ -n "$STATUS_JSON" ]] || return 1
  jq -r '
    (.config.loadModes // {}) | to_entries |
    map("\(.key):\(.value)") | join(",")
  ' <<< "$STATUS_JSON" 2>/dev/null
}

snapshot_tier_artifacts() {
  local tier="$1"
  [[ -n "$STATUS_JSON" ]] || return 1
  jq -r --arg tier "$tier" \
    'first((.models // [])[]? | select(.tier == $tier) | .artifacts) // "unknown"' \
    <<< "$STATUS_JSON" 2>/dev/null
}

snapshot_installed_count() {
  [[ -n "$STATUS_JSON" ]] || return 1
  jq -r '[((.models // [])[]?) | select(.artifacts == "installed")] | length' \
    <<< "$STATUS_JSON" 2>/dev/null
}

colored_api_state() {
  case "$1" in
    authenticated) printf '%s%s%s' "$GRN" "$1" "$R" ;;
    down) printf '%s%s%s' "$YLW" "$1" "$R" ;;
    *) printf '%s%s%s' "$RED" "$1" "$R" ;;
  esac
}

agent_binary() {
  local agent="$1" found
  found="$(command -v "$agent" 2>/dev/null || true)"
  if [[ -n "$found" ]]; then
    printf '%s\n' "$found"
  elif [[ -x "$LOCAL_BIN_DIR/$agent" ]]; then
    printf '%s\n' "$LOCAL_BIN_DIR/$agent"
  else
    return 1
  fi
}

banner() {
  local a s startup api api_display abin loaded models routing startup_tier kv load_modes reboot snapshot_api snapshot_auth service_port
  local everyday_ctx coder_ctx senior_ctx
  refresh_status_snapshot || true
  a="$(agent_now)"; s="$(svc_state)"; startup="$(svc_startup_state)"
  service_port="$(snapshot_text '.service.port' "$(cfg PORT 8080)")"
  snapshot_api="$(snapshot_text '.service.api' '')"
  snapshot_auth="$(snapshot_text '.service.authEnforced' false)"
  case "$snapshot_api" in
    authenticated) [[ "$snapshot_auth" == true ]] && api=authenticated || api=insecure ;;
    insecure|unauthorized|down|error) api="$snapshot_api" ;;
    *) api="$(api_state "$service_port")" ;;
  esac
  api_display="$(colored_api_state "$api")"
  if agent_binary "$a" >/dev/null; then abin="installed"; else abin="${RED}not installed${R}"; fi
  loaded="$(snapshot_text '.loadedModel' none)"
  models="$(snapshot_models || true)"
  [[ -n "$models" ]] || models="status unavailable"
  routing="$(snapshot_text '.config.routingProfile' "$(cfg ROUTING_PROFILE sticky)")"
  startup_tier="$(snapshot_text '.config.startupTier' "$(cfg STARTUP_TIER everyday)")"
  kv="$(snapshot_text '.config.kvCacheProfile' "$(cfg KV_CACHE_PROFILE f16)")"
  load_modes="$(snapshot_load_modes || true)"
  [[ -n "$load_modes" ]] || load_modes="everyday:$(cfg LOAD_MODE_EVERYDAY none),coder:$(cfg LOAD_MODE_CODER mmap),senior:$(cfg LOAD_MODE_SENIOR mmap)"
  reboot="$(snapshot_text '.system.rebootRequired' false)"
  everyday_ctx="$(snapshot_text '.config.contexts.everyday' "$(cfg CTX 131072)")"
  coder_ctx="$(snapshot_text '.config.contexts.coder' "$(cfg CODER_CTX 40960)")"
  senior_ctx="$(snapshot_text '.config.contexts.senior' "$(cfg SENIOR_CTX 131072)")"
  clear 2>/dev/null || true
  cat <<EOF
${ORG}${B}  local-ai · multi-model control panel${R}
${DIM}  Qwen 3.8 everyday · Qwen3-Coder-Next specialist · Qwen3.5-122B senior${R}

   agent    ${B}${a}${R}  (${abin})
   current  server=$( [[ "$s" == active ]] && echo "${GRN}${s}${R}" || echo "${YLW}${s}${R}" )/${startup}  api=${api_display}:${service_port}  loaded=${loaded}
   models   ${models}
   desired routing=${routing}  startup=${startup_tier}  max-resident=$(cfg MODELS_MAX 1)  port=$(cfg PORT 8080)
   context  everyday=${everyday_ctx}  coder=${coder_ctx}  senior=${senior_ctx}  kv=${kv}
   loading  ${load_modes}
   everyday quant=$(cfg QUANT UD-Q4_K_XL)  reasoning=$(cfg REASONING_EFFORT medium)$( [[ "$reboot" == true ]] && echo "  ${YLW}reboot required${R}" || true )
EOF
}

# --------------------------------- actions ----------------------------------

choose_agent() {
  banner
  cat <<EOF

${B}Choose your coding agent${R}

   ${B}1)${R} omp  ${DIM}— primary UI: LSP, debugger, subagents, task-role routing${R}
   ${B}2)${R} pi   ${DIM}— lightweight manual/diagnostic fallback${R}
   ${B}b)${R} back
EOF
  local c y target=""; read -r -p $'\n'"select [1/2/b]: " c || return 0
  case "$c" in
    1) target=omp ;;
    2) target=pi ;;
    *) return 0 ;;
  esac
  read -r -p "Validate/install ${target} before selecting it? [Y/n] " y || true
  if [[ "${y:-Y}" =~ ^[Nn]$ ]]; then
    warn "Selection unchanged; the manager will not select an unvalidated agent."
    pause
    return 0
  fi
  engine "$target"
  if (( ENGINE_OK )); then
    engine save-config "AGENT=${target}"
    if (( ENGINE_OK )); then
      # Direct `pi`/`omp` installs deliberately do not change the persisted
      # selection. Re-enter through `agent` after saving so local-ai-agent,
      # routing, and shell integration are generated from the new selection.
      engine agent
      (( ENGINE_OK )) || warn "${target} is selected, but its managed launcher could not be refreshed; run './setup-qwen38-pi.sh agent'."
    fi
  else
    warn "${target} was not selected because its install/validation did not complete."
  fi
  pause
}

upgrade_agent() {
  banner
  cat <<EOF

${B}Upgrade an installed coding agent${R}

   ${B}1)${R} omp  ${DIM}— replace with configured OMP_VERSION=$(cfg OMP_VERSION 18.0.10)${R}
   ${B}2)${R} pi   ${DIM}— replace with configured PI_VERSION=$(cfg PI_VERSION 0.84.4)${R}
   ${B}b)${R} back
EOF
  local c answer target=""
  read -r -p $'\n'"select [1/2/b]: " c || return 0
  case "$c" in
    1) target=omp ;;
    2) target=pi ;;
    *) return 0 ;;
  esac
  warn "This explicitly replaces ${target} with the configured pinned release; ordinary install commands leave existing binaries untouched."
  read -r -p "Upgrade ${target} now? [y/N] " answer || true
  [[ "$answer" =~ ^[Yy]$ ]] || { warn "Agent upgrade skipped."; pause; return 0; }
  engine agent-upgrade "$target"
  pause
}

plan_and_apply() {
  local prompt="${1:-Apply the desired state now? [Y/n] }" default_yes="${2:-1}" answer
  engine plan
  (( ENGINE_OK )) || {
    warn "Preflight failed; the running stack was not changed."
    return 0
  }
  read -r -p "$prompt" answer || true
  if [[ "$answer" =~ ^[Nn]$ || ( -z "$answer" && "$default_yes" == 0 ) ]]; then
    warn "Desired settings are saved but not applied; choose Plan or Apply when ready."
    return 0
  fi
  engine apply
  if (( ENGINE_OK == 0 )); then
    warn "Apply failed; inspect the plan/error above before retrying."
    return 0
  fi
}

run_model_maintenance() {
  local action="$1"; shift
  local answer was_active=0
  systemctl --user is-active --quiet "$UNIT_NAME" 2>/dev/null && was_active=1 || true
  if (( was_active )); then
    warn "${action} requires a short router stop; requests pause until the new model state is applied."
    read -r -p "Run the locked stop → operation → apply transaction? [y/N] " answer || true
  else
    warn "${action} changes managed files; a successful operation will be applied and start the router."
    read -r -p "Run the locked maintenance transaction? [y/N] " answer || true
  fi
  [[ "$answer" =~ ^[Yy]$ ]] || { warn "Model maintenance skipped."; return 0; }
  case "$action" in
    model-remove) engine model-maintain remove "$@" ;;
    model-prune) engine model-maintain prune "$@" ;;
    *) warn "Unknown maintenance action: $action"; ENGINE_OK=0; return 0 ;;
  esac
  (( ENGINE_OK )) || \
    warn "Maintenance did not complete; if artifacts changed, the engine deliberately left the router stopped for a safe retry."
}

prepare_startup_tier_removal() {
  local tier="$1" current fallback=none candidate answer
  current="$(cfg STARTUP_TIER everyday)"
  [[ "$current" == "$tier" ]] || return 0
  refresh_status_snapshot || {
    warn "Could not determine a safe replacement startup tier; removal was not attempted."
    return 1
  }
  for candidate in everyday coder senior; do
    [[ "$candidate" != "$tier" ]] || continue
    if [[ "$(snapshot_tier_artifacts "$candidate" || true)" == installed ]]; then
      fallback="$candidate"
      break
    fi
  done
  warn "${tier} is the configured startup tier. It must be replaced in the live preset before its files are removed."
  read -r -p "Switch startup to ${fallback}, apply it now, then continue? [y/N] " answer || true
  [[ "$answer" =~ ^[Yy]$ ]] || { warn "Removal skipped; startup remains ${tier}."; return 1; }
  engine save-config "STARTUP_TIER=${fallback}"
  (( ENGINE_OK )) || return 1
  engine plan
  (( ENGINE_OK )) || return 1
  engine apply
  (( ENGINE_OK )) || {
    warn "The startup transition did not activate; ${tier} files were not touched."
    return 1
  }
}

model_menu() {
  banner
  cat <<EOF

${B}Model team${R}  ${DIM}(current artifact/runtime state is shown in Status)${R}

   ${B}1)${R} Show current model/router status
   ${B}2)${R} Download everyday    ${DIM}Qwen 3.8 27B; implementation + vision${R}
   ${B}3)${R} Download specialist ${DIM}Qwen3-Coder-Next; repo/tool/debug work${R}
   ${B}4)${R} Download senior     ${DIM}Qwen3.5-122B; architecture + hard reviews${R}
   ${B}5)${R} Download all three  ${DIM}~133/144 GiB payload; ~138/149 GiB free with default reserve${R}
   ${B}6)${R} Verify installed files (SHA-256)
   ${B}7)${R} Plan and apply model/routing changes
   ${B}8)${R} Remove one tier safely
   ${B}9)${R} Prune inactive quant/artifacts
   ${B}b)${R} back
EOF
  local c action="" tier=""
  read -r -p $'\n'"select: " c || return 0
  case "$c" in
    1) engine status ;;
    2) action=everyday ;;
    3) action=coder ;;
    4) action=senior ;;
    5) action=all ;;
    6) engine model-verify ;;
    7) plan_and_apply ;;
    8)
      read -r -p "tier to remove [everyday/coder/senior]: " tier || true
      case "$tier" in
        everyday|coder|senior)
          refresh_status_snapshot || true
          if [[ "$(snapshot_tier_artifacts "$tier" || true)" == installed ]] && \
             [[ "$(snapshot_installed_count || true)" == 1 ]]; then
            warn "${tier} is the last complete tier; removing it would leave no runnable router."
            warn "Use the direct teardown commands if taking the whole stack offline intentionally."
            ENGINE_OK=0
          else
            if prepare_startup_tier_removal "$tier"; then
              run_model_maintenance model-remove "$tier"
            else
              ENGINE_OK=0
            fi
          fi
          ;;
        *) warn "Expected everyday, coder, or senior."; ENGINE_OK=0 ;;
      esac
      ;;
    9)
      run_model_maintenance model-prune
      ;;
    *) return 0 ;;
  esac
  if [[ -n "$action" ]]; then
    engine model "$action"
    (( ENGINE_OK )) || { pause; return; }
    echo
    plan_and_apply "Apply the downloaded model and role routing now? [Y/n] "
  fi
  pause
}

change_quant() {
  local old="$1" requested="$2" answer
  case "$requested" in
    UD-Q4_K_XL|Q8_0) ;;
    *) warn "Quant must be UD-Q4_K_XL or Q8_0."; ENGINE_OK=0; return 0 ;;
  esac
  if [[ "$requested" == "$old" ]]; then
    warn "${requested} is already the desired everyday quant."
    return 0
  fi

  echo
  echo "The saved quant remains ${old} until ${requested} is fully downloaded and verified."
  read -r -p "Download ${requested} before switching? [y/N] " answer || true
  [[ "$answer" =~ ^[Yy]$ ]] || { warn "Quant selection unchanged."; return 0; }

  engine_quant "$requested" model everyday
  (( ENGINE_OK )) || return 0
  engine save-config "QUANT=${requested}"
  (( ENGINE_OK )) || {
    warn "The verified download remains on disk, but desired quant is still ${old}."
    return 0
  }
  plan_and_apply "Apply ${requested} to the router now? [Y/n] "
}

profile_menu() {
  banner
  cat <<EOF

${B}Routing, startup, memory, and download profiles${R}

   ${B}1)${R} routing profile   now: $(cfg ROUTING_PROFILE sticky) ${DIM}sticky | balanced | quality${R}
   ${B}2)${R} startup tier      now: $(cfg STARTUP_TIER everyday) ${DIM}everyday | coder | senior | none${R}
   ${B}3)${R} KV cache          now: $(cfg KV_CACHE_PROFILE f16) ${DIM}f16 | q8${R}
   ${B}4)${R} per-tier loading  ${DIM}none | mmap | mlock | mmap+mlock | dio${R}
   ${B}5)${R} download jobs     now: $(cfg DOWNLOAD_JOBS 2) ${DIM}1-4 concurrent artifacts${R}
   ${B}6)${R} disk reserve      now: $(cfg DISK_RESERVE_GIB 5) GiB
   ${B}b)${R} back
EOF
  local c v pair="" tier="" mode="" apply_needed=1
  read -r -p $'\n'"select: " c || return 0
  case "$c" in
    1)
      read -r -p "routing profile [sticky/balanced/quality]: " v || true
      case "$v" in sticky|balanced|quality) pair="ROUTING_PROFILE=$v" ;; *) warn "Expected sticky, balanced, or quality." ;; esac
      ;;
    2)
      read -r -p "startup tier [everyday/coder/senior/none]: " v || true
      case "$v" in everyday|coder|senior|none) pair="STARTUP_TIER=$v" ;; *) warn "Expected everyday, coder, senior, or none." ;; esac
      ;;
    3)
      read -r -p "KV cache profile [f16/q8]: " v || true
      case "$v" in f16|q8) pair="KV_CACHE_PROFILE=$v" ;; *) warn "Expected f16 or q8." ;; esac
      ;;
    4)
      read -r -p "tier [everyday/coder/senior]: " tier || true
      read -r -p "load mode [none/mmap/mlock/mmap+mlock/dio]: " mode || true
      case "$mode" in none|mmap|mlock|mmap+mlock|dio) ;; *) warn "Unknown load mode."; mode="" ;; esac
      if [[ -n "$mode" ]]; then
        case "$tier" in
          everyday) pair="LOAD_MODE_EVERYDAY=$mode" ;;
          coder) pair="LOAD_MODE_CODER=$mode" ;;
          senior) pair="LOAD_MODE_SENIOR=$mode" ;;
          *) warn "Expected everyday, coder, or senior." ;;
        esac
      fi
      ;;
    5)
      read -r -p "parallel download jobs [1-4]: " v || true
      [[ "$v" =~ ^[1-4]$ ]] && pair="DOWNLOAD_JOBS=$v" || warn "Download jobs must be 1-4."
      apply_needed=0
      ;;
    6)
      read -r -p "free disk reserve in GiB [1-128]: " v || true
      [[ "$v" =~ ^[0-9]+$ ]] && (( v >= 1 && v <= 128 )) && pair="DISK_RESERVE_GIB=$v" || warn "Disk reserve must be 1-128 GiB."
      apply_needed=0
      ;;
    *) return 0 ;;
  esac
  [[ -n "$pair" ]] || { pause; return 0; }
  engine save-config "$pair"
  if (( ENGINE_OK && apply_needed )); then
    plan_and_apply
  elif (( ENGINE_OK )); then
    echo "Saved. This setting affects future downloads and does not restart the router."
  fi
  pause
}

tune_config() {
  banner
  cat <<EOF

${B}Tune configuration${R}  ${DIM}(applied on the next service restart)${R}

   ${B}1)${R} everyday reasoning  now: $(cfg REASONING_EFFORT medium)       ${DIM}xhigh | medium | low${R}
   ${B}2)${R} everyday context    now: $(cfg CTX 131072)
   ${B}3)${R} specialist context  now: $(cfg CODER_CTX 40960)
   ${B}4)${R} senior context      now: $(cfg SENIOR_CTX 131072) ${DIM}reduce first on OOM${R}
   ${B}5)${R} everyday quant      now: $(cfg QUANT UD-Q4_K_XL) ${DIM}UD-Q4_K_XL | Q8_0${R}
   ${B}6)${R} MTP draft tokens    now: $(cfg DRAFT_N 4) ${DIM}1-8; AMD recommends 4${R}
   ${B}7)${R} profiles            ${DIM}routing · startup · KV/load · download/disk${R}
       ${DIM}resident models are locked to the safe value 1 in this manager${R}
   ${B}b)${R} back
EOF
  local c v pair=""; ENGINE_OK=0; read -r -p $'\n'"select: " c || return 0
  case "$c" in
    1)
      read -r -p "everyday reasoning [xhigh/medium/low]: " v || true
      case "$v" in xhigh|medium|low) pair="REASONING_EFFORT=$v" ;; *) warn "Expected xhigh, medium, or low." ;; esac
      ;;
    2)
      read -r -p "everyday context (tokens): " v || true
      [[ "$v" =~ ^[0-9]+$ ]] && (( v >= 32768 && v <= 262144 )) && pair="CTX=$v" || warn "Context must be 32768-262144."
      ;;
    3)
      read -r -p "specialist context (tokens): " v || true
      [[ "$v" =~ ^[0-9]+$ ]] && (( v >= 32768 && v <= 262144 )) && pair="CODER_CTX=$v" || warn "Context must be 32768-262144."
      ;;
    4)
      read -r -p "senior context (tokens): " v || true
      [[ "$v" =~ ^[0-9]+$ ]] && (( v >= 65536 && v <= 262144 )) && pair="SENIOR_CTX=$v" || warn "Context must be 65536-262144."
      ;;
    5)
      read -r -p "quant [UD-Q4_K_XL/Q8_0]: " v || true
      change_quant "$(cfg QUANT UD-Q4_K_XL)" "$v"
      pause
      return 0
      ;;
    6)
      read -r -p "MTP draft tokens: " v || true
      [[ "$v" =~ ^[0-9]+$ ]] && (( v >= 1 && v <= 8 )) && pair="DRAFT_N=$v" || warn "Draft tokens must be 1-8."
      ;;
    7)
      profile_menu
      return 0
      ;;
    *) return 0 ;;
  esac
  [[ -n "$pair" ]] || { pause; return 0; }
  engine save-config "$pair"
  (( ENGINE_OK )) || { pause; return; }
  echo
  plan_and_apply
  pause
}

run_smoke() {
  local tier
  read -r -p "tier [everyday/coder/senior] (default: everyday): " tier || true
  tier="${tier:-everyday}"
  case "$tier" in everyday|coder|senior) engine smoke "$tier" ;; *) warn "Expected everyday, coder, or senior." ;; esac
  pause
}

run_perf() {
  local tier
  read -r -p "tier [everyday/coder/senior] (default: everyday): " tier || true
  tier="${tier:-everyday}"
  case "$tier" in
    everyday|coder|senior)
      warn "Perf temporarily unloads/swaps model residency; other local clients may stall. It sends two ${PERF_PROMPT_WORDS:-4096}-word requests, each with a 30-minute timeout."
      engine perf "$tier"
      ;;
    *) warn "Expected everyday, coder, or senior." ;;
  esac
  pause
}

run_raw_bench() {
  local tier answer was_active=0
  read -r -p "raw tier [everyday/coder/senior] (default: everyday): " tier || true
  tier="${tier:-everyday}"
  case "$tier" in everyday|coder|senior) ;; *) warn "Expected everyday, coder, or senior."; pause; return 0 ;; esac

  systemctl --user is-active --quiet "$UNIT_NAME" 2>/dev/null && was_active=1 || true
  if (( was_active )); then
    warn "Raw llama-bench must stop the active router; Perf keeps the service running but still swaps model residency."
    read -r -p "Run the locked stop → benchmark → restore transaction? [y/N] " answer || true
    [[ "$answer" =~ ^[Yy]$ ]] || { warn "Raw benchmark skipped."; pause; return 0; }
  fi
  engine bench "$tier" --manage-service
  (( ENGINE_OK )) || warn "Raw benchmark or service restoration failed; inspect the engine output above."
  pause
}

main_menu() {
  banner
  cat <<EOF

   ${B}1)${R} Full baseline setup    ${DIM}packages → everyday model → router → selected agent${R}
   ${B}2)${R} Model team / routing   ${DIM}download, verify, and assign roles${R}
   ${B}3)${R} Choose agent           ${DIM}omp primary ⇄ pi fallback${R}
   ${B}4)${R} Install selected agent
   ${B}u)${R} Upgrade an agent       ${DIM}explicit pinned replacement${R}
   ${B}5)${R} Plan and apply desired state
   ${B}6)${R} Tune configuration     ${DIM}per-model context/reasoning · quant · MTP${R}
   ${B}7)${R} Remote access          ${DIM}optional/deferred LAN-only SSH + mosh${R}
   ${B}8)${R} Harden SSH             ${DIM}switch to key-only auth${R}
   ${B}9)${R} Install LSP servers    ${DIM}omp IDE features${R}
   ${B}g)${R} Kernel GTT tweak       ${DIM}optional after baseline; never automatic${R}
   ${B}p)${R} Plan current → desired ${B}s)${R} Status          ${B}t)${R} Smoke/load test
   ${B}b)${R} Router performance     ${B}r)${R} Raw benchmark   ${B}c)${R} Show config
   ${B}q)${R} Quit
EOF
  local c; read -r -p $'\n'"select: " c || { echo; exit 0; }
  case "$c" in
    1) engine all; pause ;;
    2) model_menu ;;
    3) choose_agent ;;
    4) engine agent; pause ;;
    u|U) upgrade_agent ;;
    5) plan_and_apply; pause ;;
    6) tune_config ;;
    7) engine remote; pause ;;
    8) engine ssh-harden; pause ;;
    9) engine omp-lsp; pause ;;
    g|G) engine kernel-tweaks; pause ;;
    p|P) engine plan; pause ;;
    s|S) engine status; pause ;;
    t|T) run_smoke ;;
    b|B) run_perf ;;
    r|R) run_raw_bench ;;
    c|C) engine show-config; pause ;;
    q|Q) exit 0 ;;
    *) ;;
  esac
}

# ---------------------------------- loop ------------------------------------

if [[ "${LOCAL_AI_MANAGE_LIB_ONLY:-0}" != 1 ]]; then
  while true; do main_menu; done
fi
