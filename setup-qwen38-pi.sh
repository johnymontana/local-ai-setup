#!/usr/bin/env bash
#
# setup-qwen38-pi.sh
#
# Repeatable, pinned multi-model setup for local agentic coding on a Framework
# Desktop (AMD Ryzen AI Max+ 395 "Strix Halo", 128GB unified RAM), Arch Linux:
#
#   everyday  Qwen 3.8 27B          implementation loop + vision
#   coder     Qwen3-Coder-Next      repository/tool/debug specialist
#   senior    Qwen3.5-122B-A10B     architecture, planning, difficult review
#
# llama.cpp serves one model at a time through router presets. omp maps task
# roles to the three aliases; pi remains a lightweight/manual fallback.
#
# Tip: run `./manage.sh` for a friendly interactive menu over all of this.
#
# Usage:
#   ./setup-qwen38-pi.sh all              # check + install + model + service + agent
#   ./setup-qwen38-pi.sh check            # verify hardware/OS prerequisites
#   ./setup-qwen38-pi.sh install          # install Arch packages
#   ./setup-qwen38-pi.sh model            # download everyday model (back-compatible)
#   ./setup-qwen38-pi.sh model coder      # optional coding specialist (~45 GiB)
#   ./setup-qwen38-pi.sh model senior     # optional senior engineer (~70 GiB)
#   ./setup-qwen38-pi.sh model all        # explicitly download all three tiers
#   ./setup-qwen38-pi.sh model-catalog    # roles, sizes, and installed state
#   ./setup-qwen38-pi.sh model-verify     # SHA-256 verify installed artifacts
#   ./setup-qwen38-pi.sh model-remove TIER # remove one exact managed tier (service must be stopped)
#   ./setup-qwen38-pi.sh model-prune      # remove partial/unselected managed artifacts
#   ./setup-qwen38-pi.sh service          # write + enable systemd user service
#   ./setup-qwen38-pi.sh agent            # install the selected coding agent (pi or omp)
#   ./setup-qwen38-pi.sh pi               # force-install the pi agent (https://pi.dev)
#   ./setup-qwen38-pi.sh omp              # force-install oh-my-pi / omp (https://omp.sh)
#   ./setup-qwen38-pi.sh omp-lsp          # OPTIONAL: install common LSP servers for omp
#   ./setup-qwen38-pi.sh kernel-tweaks    # OPTIONAL: raise GPU-addressable memory (needs reboot)
#   ./setup-qwen38-pi.sh remote           # LAN-only SSH/mosh access + agent-session tmux helper
#   ./setup-qwen38-pi.sh ssh-harden       # disable SSH password auth once keys are installed
#   ./setup-qwen38-pi.sh routing          # install/update omp's task-role mapping
#   ./setup-qwen38-pi.sh bench [tier]     # llama-bench sanity benchmark
#   ./setup-qwen38-pi.sh perf [tier]      # cold-load + warm API performance check
#   ./setup-qwen38-pi.sh status [--json]  # non-mutating service/model status
#   ./setup-qwen38-pi.sh smoke [tier]     # authenticated chat/model-load smoke test
#   ./setup-qwen38-pi.sh plan             # show resolved changes without writing
#   ./setup-qwen38-pi.sh apply            # apply service + OMP routing configuration
#   ./setup-qwen38-pi.sh show-config      # print effective configuration
#   ./setup-qwen38-pi.sh save-config K=V  # persist tunables (e.g. AGENT=omp REASONING_EFFORT=xhigh)
#
# Tunables (env vars; persisted in ~/.config/local-ai/setup.env, all optional):
#   AGENT=omp               coding agent to install/use: pi | omp
#   QUANT=UD-Q4_K_XL        quant to download/serve (UD-Q4_K_XL | Q8_0)
#   CTX=131072              everyday context window
#   CODER_CTX=40960         coding-specialist context (official local default)
#   SENIOR_CTX=131072       senior context (reduce first if memory is tight)
#   PORT=8080               llama-server port
#   MODELS_DIR=~/llm/models GGUF storage location
#   REASONING_EFFORT=medium xhigh | medium | low  (Qwen3.8 thinking budget)
#   DRAFT_N=4               MTP draft tokens (AMD recommends 4 on Ryzen AI Max)
#   MODELS_MAX=1            resident model processes (1 is safe with the senior)
#   ROUTING_PROFILE=sticky  sticky | balanced | quality
#   STARTUP_TIER=everyday   everyday | coder | senior | none
#   LOAD_MODE_EVERYDAY=none none | mmap | mlock | mmap+mlock | dio
#   LOAD_MODE_CODER=mmap    per-tier model loading mode
#   LOAD_MODE_SENIOR=mmap   per-tier model loading mode
#   KV_CACHE_PROFILE=f16    f16 | q8 (q8 roughly halves attention KV storage)
#   DISK_RESERVE_GIB=5      free space retained after managed downloads
#   DOWNLOAD_JOBS=2         bounded parallel artifact downloads (1-4)
#   GTT_GIB=115             GPU-addressable memory target for kernel-tweaks
#   LAN_CIDR=...            home subnet for the firewall (default: auto-detected)
#
# Environment-only operational controls (never persisted):
#   ALLOW_PENDING_REBOOT=1     bypass the stale kernel/TTM runtime gate
#   SERVICE_READY_TIMEOUT=600  maximum model load/readiness wait in seconds
#   PERF_PROMPT_WORDS=4096     production perf-check prompt size (512-32768)
#
# Precedence for tunables: explicit env var  >  saved setup.env  >  built-in default.
# Mutating commands are explicit. Managed writes are staged/retry-safe where
# practical and preserve user-owned paths, but commands may download, restart,
# or change system state as documented below.

set -euo pipefail

# ----------------------------- configuration --------------------------------

# Keep the artifact catalog separate from executable code so every remote byte,
# including split GGUF shards, is reviewable and cryptographically locked.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
COMMON_LIB="$SCRIPT_DIR/lib/local-ai-common.sh"
[[ -r "$COMMON_LIB" ]] || { printf 'error: missing shared helper library: %s\n' "$COMMON_LIB" >&2; exit 1; }
# shellcheck source=lib/local-ai-common.sh
source "$COMMON_LIB"
MODEL_LOCK="${MODEL_LOCK:-$SCRIPT_DIR/models.lock}"
LOCAL_AI_CONFIG_DIR="${LOCAL_AI_CONFIG_DIR:-$HOME/.config/local-ai}"
SETUP_ENV="${SETUP_ENV:-$LOCAL_AI_CONFIG_DIR/setup.env}"
PRESET_FILE="${PRESET_FILE:-$LOCAL_AI_CONFIG_DIR/models.ini}"
KEY_FILE="${KEY_FILE:-$LOCAL_AI_CONFIG_DIR/llama.key}"
LOCAL_BIN_DIR="${LOCAL_BIN_DIR:-$HOME/.local/bin}"
OMP_AGENT_DIR="${OMP_AGENT_DIR:-${PI_CODING_AGENT_DIR:-$HOME/.omp/agent}}"

CONFIG_KEYS="AGENT QUANT CTX CODER_CTX SENIOR_CTX PORT MODELS_DIR REASONING_EFFORT DRAFT_N MODELS_MAX ROUTING_PROFILE STARTUP_TIER LOAD_MODE_EVERYDAY LOAD_MODE_CODER LOAD_MODE_SENIOR KV_CACHE_PROFILE DISK_RESERVE_GIB DOWNLOAD_JOBS GTT_GIB PI_VERSION OMP_VERSION"
CONFIG_ENV_EXPLICIT_KEYS=" "
for _config_key in $CONFIG_KEYS; do
  if printenv "$_config_key" >/dev/null 2>&1; then
    CONFIG_ENV_EXPLICIT_KEYS="${CONFIG_ENV_EXPLICIT_KEYS}${_config_key} "
  fi
done
REASONING_EFFORT_WAS_EXPLICIT=0
[[ -z "${REASONING_EFFORT+x}" ]] || REASONING_EFFORT_WAS_EXPLICIT=1
MODELS_MAX_WAS_EXPLICIT=0
[[ -z "${MODELS_MAX+x}" ]] || MODELS_MAX_WAS_EXPLICIT=1

config_key_allowed() {
  case " $CONFIG_KEYS " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}

config_key_was_environment_explicit() {
  case "$CONFIG_ENV_EXPLICIT_KEYS" in *" $1 "*) return 0 ;; *) return 1 ;; esac
}

reload_persisted_config_under_lock() {
  # The script may have waited behind another short mutation after initially
  # reading setup.env. Re-merge the now-current file while holding the per-user
  # lifecycle lock so an unrelated concurrent save cannot be lost. Explicit
  # environment values retain their documented highest precedence.
  [[ ! -L "$SETUP_ENV" ]] || die "Refusing symlinked setup config: $SETUP_ENV"
  [[ ! -e "$SETUP_ENV" || -f "$SETUP_ENV" ]] || \
    die "Refusing non-regular setup config: $SETUP_ENV"
  if [[ -f "$SETUP_ENV" ]]; then
    local key value
    while IFS='=' read -r key value; do
      config_key_allowed "$key" || continue
      config_key_was_environment_explicit "$key" && continue
      printf -v "$key" '%s' "$value"
    done < "$SETUP_ENV"
  fi
  if ! config_key_was_environment_explicit REASONING_EFFORT && [[ "$REASONING_EFFORT" == none ]]; then
    REASONING_EFFORT=medium
    LEGACY_REASONING_MIGRATED=1
  fi
  if ! config_key_was_environment_explicit MODELS_MAX && [[ "$MODELS_MAX" =~ ^[0-9]+$ ]] && (( MODELS_MAX > 1 )); then
    MODELS_MAX=1
    LEGACY_MODELS_MAX_MIGRATED=1
  fi
  validate_config
}

# Load persisted tunables as fallbacks (never overriding an explicit env var).
# Refuse a symlink because save-config atomically owns this exact private file;
# following a link here could overwrite an unrelated dotfile later.
[[ ! -L "$SETUP_ENV" ]] || { printf 'error: refusing symlinked setup config: %s\n' "$SETUP_ENV" >&2; exit 1; }
[[ ! -e "$SETUP_ENV" || -f "$SETUP_ENV" ]] || {
  printf 'error: refusing non-regular setup config: %s\n' "$SETUP_ENV" >&2
  exit 1
}
if [[ -f "$SETUP_ENV" ]]; then
  while IFS='=' read -r _k _v; do
    config_key_allowed "$_k" || continue
    config_key_was_environment_explicit "$_k" || printf -v "$_k" '%s' "$_v"
  done < "$SETUP_ENV"
fi

AGENT="${AGENT:-omp}"
QUANT="${QUANT:-UD-Q4_K_XL}"
CTX="${CTX:-131072}"
CODER_CTX="${CODER_CTX:-40960}"
SENIOR_CTX="${SENIOR_CTX:-131072}"
PORT="${PORT:-8080}"
MODELS_DIR="${MODELS_DIR:-$HOME/llm/models}"
REASONING_EFFORT="${REASONING_EFFORT:-medium}"
DRAFT_N="${DRAFT_N:-4}"
MODELS_MAX="${MODELS_MAX:-1}"
ROUTING_PROFILE="${ROUTING_PROFILE:-sticky}"
STARTUP_TIER="${STARTUP_TIER:-everyday}"
LOAD_MODE_EVERYDAY="${LOAD_MODE_EVERYDAY:-none}"
LOAD_MODE_CODER="${LOAD_MODE_CODER:-mmap}"
LOAD_MODE_SENIOR="${LOAD_MODE_SENIOR:-mmap}"
KV_CACHE_PROFILE="${KV_CACHE_PROFILE:-f16}"
DISK_RESERVE_GIB="${DISK_RESERVE_GIB:-5}"
DOWNLOAD_JOBS="${DOWNLOAD_JOBS:-2}"
GTT_GIB="${GTT_GIB:-115}"
PI_VERSION="${PI_VERSION:-0.84.4}"
OMP_VERSION="${OMP_VERSION:-18.0.10}"
ALLOW_PENDING_REBOOT="${ALLOW_PENDING_REBOOT:-0}"
SERVICE_READY_TIMEOUT="${SERVICE_READY_TIMEOUT:-600}"
SERVICE_HEALTHCHECK="${SERVICE_HEALTHCHECK:-1}"
PERF_PROMPT_WORDS="${PERF_PROMPT_WORDS:-4096}"

# Older revisions exposed MODELS_MAX=2/3 as a normal persisted tuning option.
# Repair only that saved fallback so users can still run `save-config`/`apply`;
# an explicit environment/CLI value remains subject to the hard safety gate.
LEGACY_MODELS_MAX_MIGRATED=0
if (( MODELS_MAX_WAS_EXPLICIT == 0 )) && [[ "$MODELS_MAX" =~ ^[0-9]+$ ]] && (( MODELS_MAX > 1 )); then
  MODELS_MAX=1
  LEGACY_MODELS_MAX_MIGRATED=1
fi

# Older revisions persisted REASONING_EFFORT=none, which current Qwen 3.8 and
# llama.cpp no longer accept as an effort value. Migrate only the saved legacy
# fallback; an explicitly supplied invalid value should still fail validation.
LEGACY_REASONING_MIGRATED=0
if (( REASONING_EFFORT_WAS_EXPLICIT == 0 )) && [[ "$REASONING_EFFORT" == none ]]; then
  REASONING_EFFORT=medium
  LEGACY_REASONING_MIGRATED=1
fi

# Keep Qwen family names in reasoning-model IDs exposed to clients. OMP uses the
# ID when it applies model-family compatibility and thinking-level rules;
# generic aliases can otherwise receive `high`, which Qwen 3.8 does not accept.
EVERYDAY_ID="qwen3.8-27b"
# OMP's llama.cpp discovery currently marks every Qwen-bearing ID as a
# reasoning model. Keep the official non-thinking Coder-Next behind a neutral
# router ID and declare its tokenizer metadata explicitly below.
CODER_ID="coder"
SENIOR_ID="qwen3.5-122b-a10b"

LAUNCHER="$LOCAL_BIN_DIR/llama-qwen38-server"
UNIT_DIR="${UNIT_DIR:-$HOME/.config/systemd/user}"
UNIT_NAME="llama-server.service"
VERIFY_RECEIPT_DIR="${VERIFY_RECEIPT_DIR:-$LOCAL_AI_CONFIG_DIR/verified-models}"

# ------------------------------- helpers ------------------------------------

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m ok\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarn\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror\033[0m %s\n' "$*" >&2; exit 1; }

# Persist the current tunables so the menu and every subcommand agree.
save_config() {
  local config_parent tmp k
  config_parent="$(dirname "$SETUP_ENV")"
  [[ ! -L "$SETUP_ENV" ]] || die "Refusing symlinked setup config: $SETUP_ENV"
  [[ ! -e "$SETUP_ENV" || -f "$SETUP_ENV" ]] || \
    die "Refusing non-regular setup config: $SETUP_ENV"
  mkdir -p "$config_parent"
  chmod 700 "$config_parent"
  tmp="$(mktemp "$config_parent/.setup.env.XXXXXX")" || die "Could not stage setup configuration"
  { for k in $CONFIG_KEYS; do
      if [[ "$k" == MODELS_MAX ]] && (( MODELS_MAX > 1 )); then
        printf 'MODELS_MAX=1\n'
      else
        printf '%s=%s\n' "$k" "${!k}"
      fi
    done
  } > "$tmp" || { rm -f -- "$tmp"; die "Could not write staged setup configuration"; }
  chmod 600 "$tmp" || { rm -f -- "$tmp"; die "Could not protect staged setup configuration"; }
  mv -- "$tmp" "$SETUP_ENV" || { rm -f -- "$tmp"; die "Could not atomically install setup configuration"; }
}

validate_config() {
  case "$AGENT" in pi|omp) ;; *) die "AGENT must be pi or omp (got: $AGENT)" ;; esac
  case "$QUANT" in UD-Q4_K_XL|Q8_0) ;; *) die "QUANT must be UD-Q4_K_XL or Q8_0 (got: $QUANT)" ;; esac
  case "$REASONING_EFFORT" in xhigh|medium|low) ;; *) die "REASONING_EFFORT must be xhigh, medium, or low" ;; esac
  case "$ROUTING_PROFILE" in sticky|balanced|quality) ;; *) die "ROUTING_PROFILE must be sticky, balanced, or quality" ;; esac
  case "$STARTUP_TIER" in everyday|coder|senior|none) ;; *) die "STARTUP_TIER must be everyday, coder, senior, or none" ;; esac
  local load_mode
  for load_mode in "$LOAD_MODE_EVERYDAY" "$LOAD_MODE_CODER" "$LOAD_MODE_SENIOR"; do
    case "$load_mode" in none|mmap|mlock|mmap+mlock|dio) ;;
      *) die "Per-tier load modes must be one of: none, mmap, mlock, mmap+mlock, dio (got: $load_mode)" ;;
    esac
  done
  case "$KV_CACHE_PROFILE" in f16|q8) ;; *) die "KV_CACHE_PROFILE must be f16 or q8" ;; esac
  case "$ALLOW_PENDING_REBOOT" in 0|1) ;; *) die "ALLOW_PENDING_REBOOT must be 0 or 1" ;; esac
  case "$SERVICE_HEALTHCHECK" in 0|1) ;;
    *) die "SERVICE_HEALTHCHECK must be 0 or 1 (0 is reserved for controlled tests)" ;;
  esac
  [[ "$SERVICE_READY_TIMEOUT" =~ ^[0-9]+$ ]] && (( SERVICE_READY_TIMEOUT >= 10 && SERVICE_READY_TIMEOUT <= 3600 )) || \
    die "SERVICE_READY_TIMEOUT must be 10-3600 seconds"
  [[ "$PERF_PROMPT_WORDS" =~ ^[0-9]+$ ]] && (( PERF_PROMPT_WORDS >= 512 && PERF_PROMPT_WORDS <= 32768 )) || \
    die "PERF_PROMPT_WORDS must be 512-32768"
  local n
  for n in CTX CODER_CTX SENIOR_CTX PORT DRAFT_N MODELS_MAX DISK_RESERVE_GIB DOWNLOAD_JOBS GTT_GIB; do
    [[ "${!n}" =~ ^[0-9]+$ ]] && (( ${!n} > 0 )) || die "$n must be a positive integer (got: ${!n})"
  done
  for n in CTX CODER_CTX SENIOR_CTX; do
    (( ${!n} <= 262144 )) || die "$n must be <= the models' 262144-token native context (got: ${!n})"
  done
  (( CTX >= 32768 )) || die "CTX must be 32768-262144 so OMP's 32768-token output ceiling fits the context"
  (( CODER_CTX >= 32768 )) || die "CODER_CTX must be 32768-262144 so OMP's 32768-token output ceiling fits the context"
  (( SENIOR_CTX >= 65536 )) || die "SENIOR_CTX must be 65536-262144 so OMP's 65536-token output ceiling fits the context"
  (( DRAFT_N <= 8 )) || die "DRAFT_N must be 1-8 (AMD recommends 4 on Ryzen AI Max)"
  (( PORT <= 65535 )) || die "PORT must be <= 65535"
  (( MODELS_MAX == 1 )) || \
    die "MODELS_MAX is fixed at 1 on this 128 GiB target; multiple resident coder/senior weights can exhaust RAM before KV, runtime, desktop, and OS memory."
  (( DISK_RESERVE_GIB <= 128 )) || die "DISK_RESERVE_GIB must be 1-128"
  (( DOWNLOAD_JOBS <= 4 )) || die "DOWNLOAD_JOBS must be 1-4"
  (( GTT_GIB >= 64 && GTT_GIB <= 115 )) || die "GTT_GIB must be 64-115 on this 128 GiB target"
  [[ "$PI_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "PI_VERSION must be an exact x.y.z release"
  [[ "$OMP_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "OMP_VERSION must be an exact x.y.z release"
  [[ "$MODELS_DIR" == /* ]] || die "MODELS_DIR must be an absolute path (got: $MODELS_DIR)"
  [[ "$MODELS_DIR" != *$'\n'* ]] || die "MODELS_DIR may not contain newlines"
  [[ "$MODELS_DIR$LAUNCHER" != *%* && "$MODELS_DIR$LAUNCHER" != *\"* && \
     "$MODELS_DIR$LAUNCHER" != *'$'* && "$MODELS_DIR$LAUNCHER" != *\\* && \
     "$MODELS_DIR$LAUNCHER" != *$'\r'* && "$MODELS_DIR$LAUNCHER" != *$'\n'* ]] || \
    die "MODELS_DIR/HOME may not contain quotes, percent signs, dollar signs, backslashes, or control characters (systemd safety)"
}

tier_variant() {
  case "$1" in
    everyday) printf '%s\n' "$QUANT" ;;
    coder)    printf '%s\n' Q4_K_M ;;
    senior)   printf '%s\n' MXFP4_MOE ;;
    *)        die "Unknown model tier '$1' (expected everyday | coder | senior | all)" ;;
  esac
}

tier_label() {
  case "$1" in
    everyday) echo "Qwen 3.8 27B (everyday implementer + vision)" ;;
    coder)    echo "Qwen3-Coder-Next 80B-A3B (coding specialist)" ;;
    senior)   echo "Qwen3.5-122B-A10B (senior engineer / architect)" ;;
  esac
}

# Rows for a tier and its selected variant, with common ALL artifacts included.
model_rows() {
  local tier="$1" variant
  variant="$(tier_variant "$tier")"
  awk -F'|' -v t="$tier" -v v="$variant" '
    !/^#/ && NF && $1 == t && ($2 == v || $2 == "ALL") { print }
  ' "$MODEL_LOCK"
}

manifest_tier_rows() {
  local tier="$1"
  awk -F'|' -v t="$tier" '!/^#/ && NF && $1 == t && !seen[$7]++ { print }' "$MODEL_LOCK"
}

manifest_field() {
  local tier="$1" field="$2"
  model_rows "$tier" | awk -F'|' -v f="$field" 'NR == 1 { print $f; exit }'
}

tier_id()  { manifest_field "$1" 3; }
tier_dir() { printf '%s/%s\n' "$MODELS_DIR" "$(manifest_field "$1" 4)"; }

tier_file() {
  local tier="$1" kind="$2" line remote
  line=$(model_rows "$tier" | awk -F'|' -v k="$kind" '$10 == k { print; exit }')
  [[ -n "$line" ]] || return 1
  IFS='|' read -r _ _ _ _ _ _ remote _ _ _ <<< "$line"
  printf '%s/%s\n' "$(tier_dir "$tier")" "${remote##*/}"
}

# GNU coreutils is used on the Arch target, while the offline regression suite
# also runs on macOS. Keep size checks identical on both `stat` variants.
file_size() {
  local_ai_file_size "$1"
}

# Bind verification receipts to file metadata that changes when an artifact is
# replaced or modified. GNU stat is used on Arch; the BSD form keeps offline
# tests and planning usable from macOS.
file_identity() {
  local_ai_file_identity "$1"
}

verification_receipt_path() {
  local tier="$1" expected_sha="$2"
  printf '%s/%s-%s.receipt\n' "$VERIFY_RECEIPT_DIR" "$tier" "$expected_sha"
}

write_verification_receipt() {
  local tier="$1" file="$2" expected_bytes="$3" expected_sha="$4" identity receipt tmp
  identity="$(file_identity "$file")" || return 1
  mkdir -p "$VERIFY_RECEIPT_DIR" || return 1
  chmod 700 "$VERIFY_RECEIPT_DIR" || return 1
  receipt="$(verification_receipt_path "$tier" "$expected_sha")"
  tmp="$(mktemp "$VERIFY_RECEIPT_DIR/.receipt.XXXXXX")" || return 1
  printf 'v1|%s|%s|%s|%s\n' "$file" "$expected_bytes" "$expected_sha" "$identity" > "$tmp" || {
    rm -f -- "$tmp"
    return 1
  }
  chmod 600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -- "$tmp" "$receipt"
}

verification_receipt_valid() {
  local tier="$1" file="$2" expected_bytes="$3" expected_sha="$4" identity receipt expected
  [[ -f "$file" && ! -L "$file" ]] || return 1
  [[ "$(file_size "$file")" == "$expected_bytes" ]] || return 1
  identity="$(file_identity "$file")" || return 1
  receipt="$(verification_receipt_path "$tier" "$expected_sha")"
  [[ -f "$receipt" && ! -L "$receipt" ]] || return 1
  expected="v1|${file}|${expected_bytes}|${expected_sha}|${identity}"
  [[ "$(<"$receipt")" == "$expected" ]]
}

clear_verification_receipt() {
  local tier="$1" expected_sha="$2" receipt
  receipt="$(verification_receipt_path "$tier" "$expected_sha")"
  [[ ! -e "$receipt" && ! -L "$receipt" ]] || rm -f -- "$receipt"
}

array_contains() {
  local needle="$1" item
  shift
  for item in "$@"; do [[ "$item" == "$needle" ]] && return 0; done
  return 1
}

tier_available() {
  local tier="$1" _variant _id _dir _repo _rev remote _bytes _sha _kind found=0 file
  while IFS='|' read -r _tier _variant _id _dir _repo _rev remote _bytes _sha _kind; do
    found=1
    file="$(tier_dir "$tier")/${remote##*/}"
    [[ -f "$file" && ! -L "$file" ]] || return 1
    [[ "$(file_size "$file")" == "$_bytes" ]] || return 1
  done < <(model_rows "$tier")
  (( found == 1 ))
}

human_bytes() {
  awk -v b="$1" 'BEGIN { printf "%.1f GiB", b / 1073741824 }'
}

validate_manifest() {
  [[ -r "$MODEL_LOCK" ]] || die "Model lock file not found: $MODEL_LOCK"
  local bad=0 count=0 tier variant id dir repo rev remote bytes sha kind
  awk -F'|' '!/^#/ && NF && NF != 10 { exit 1 }' "$MODEL_LOCK" || bad=1
  awk -F'|' '
    !/^#/ && NF {
      n = split($7, p, "/"); key = $1 SUBSEP p[n]
      if (seen[key]++) exit 1
    }
  ' "$MODEL_LOCK" || bad=1
  while IFS='|' read -r tier variant id dir repo rev remote bytes sha kind; do
    [[ -z "$tier" || "$tier" == \#* ]] && continue
    count=$((count + 1))
    case "$tier" in everyday|coder|senior) ;; *) bad=1 ;; esac
    [[ "$variant" =~ ^[A-Z0-9_-]+$ ]] || bad=1
    [[ "$id" =~ ^[a-z][a-z0-9.-]*$ ]] || bad=1
    [[ "$dir" =~ ^[A-Za-z0-9._-]+$ ]] || bad=1
    [[ "$repo" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || bad=1
    [[ "$remote" =~ ^[A-Za-z0-9._/-]+$ && "$remote" != /* && "$remote" != .. && "$remote" != ../* && "$remote" != */../* && "$remote" != */.. ]] || bad=1
    [[ "$rev" =~ ^[0-9a-f]{40}$ ]] || bad=1
    if [[ "$bytes" =~ ^[0-9]+$ ]]; then (( bytes > 0 )) || bad=1; else bad=1; fi
    [[ "$sha" =~ ^[0-9a-f]{64}$ ]] || bad=1
    case "$kind" in main|draft|mmproj) ;; *) bad=1 ;; esac
  done < "$MODEL_LOCK"

  local tier_name expected_main expected_draft expected_mmproj actual
  for tier_name in everyday coder senior; do
    case "$tier_name" in
      everyday) expected_main=1; expected_draft=1; expected_mmproj=1 ;;
      coder) expected_main=4; expected_draft=0; expected_mmproj=0 ;;
      senior) expected_main=3; expected_draft=0; expected_mmproj=0 ;;
    esac
    actual="$(model_rows "$tier_name" | awk -F'|' '
      $10 == "main" { m++ } $10 == "draft" { d++ } $10 == "mmproj" { p++ }
      END { printf "%d %d %d", m, d, p }
    ')"
    [[ "$actual" == "$expected_main $expected_draft $expected_mmproj" ]] || bad=1
    [[ "$(awk -F'|' -v t="$tier_name" '
      !/^#/ && NF && $1 == t {
        if (!($3 in ids)) { ids[$3] = 1; ni++ }
        if (!($4 in dirs)) { dirs[$4] = 1; nd++ }
      }
      END { print ni + 0, nd + 0 }
    ' "$MODEL_LOCK")" == "1 1" ]] || bad=1
    case "$tier_name" in
      everyday) [[ "$(tier_id "$tier_name")" == "$EVERYDAY_ID" ]] || bad=1 ;;
      coder) [[ "$(tier_id "$tier_name")" == "$CODER_ID" ]] || bad=1 ;;
      senior) [[ "$(tier_id "$tier_name")" == "$SENIOR_ID" ]] || bad=1 ;;
    esac
  done
  [[ "$(awk -F'|' '
    !/^#/ && NF && $1 == "everyday" {
      if ($2 == "UD-Q4_K_XL" && $10 == "main") q4++
      else if ($2 == "Q8_0" && $10 == "main") q8++
      else if ($2 == "ALL" && $10 == "draft") d++
      else if ($2 == "ALL" && $10 == "mmproj") p++
      else bad++
    }
    END { printf "%d %d %d %d %d", q4, q8, d, p, bad }
  ' "$MODEL_LOCK")" == "1 1 1 1 0" ]] || bad=1
  (( count == 11 && bad == 0 )) || die "Malformed model lock file: $MODEL_LOCK"
}

need_arch() {
  command -v pacman >/dev/null 2>&1 || die "pacman not found — this script targets Arch Linux."
  [[ $EUID -ne 0 ]] || die "Run as your normal user, not root (sudo is used where needed)."
}

validate_config
validate_manifest
(( LEGACY_REASONING_MIGRATED == 0 )) || \
  warn "Migrated saved REASONING_EFFORT=none to medium; use OMP's per-request Off control to disable thinking. The next save/all run will persist the migration." >&2
(( LEGACY_MODELS_MAX_MIGRATED == 0 )) || \
  warn "Migrated saved MODELS_MAX>1 to the enforced safe value 1; the next save/apply/all run will persist it." >&2

# ------------------------------- subcommands --------------------------------

cmd_check() {
  info "Checking hardware and OS"

  if lspci -nn 2>/dev/null | grep -qi 'radeon 8060s\|1150\|strix'; then
    ok "AMD Strix Halo iGPU (Radeon 8060S / gfx1151) detected"
  else
    warn "Could not positively identify a Strix Halo iGPU via lspci — continuing anyway."
  fi

  local mem_kb mem_gib
  mem_kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
  mem_gib=$((mem_kb / 1024 / 1024))
  if (( mem_gib >= 100 )); then
    ok "System RAM: ${mem_gib} GiB"
  else
    warn "System RAM is ${mem_gib} GiB — this guide assumes the 128GB configuration."
  fi

  local kver
  kver=$(uname -r)
  if [[ "$(printf '%s\n' "6.18.4" "${kver%%-*}" | sort -V | head -1)" == "6.18.4" ]]; then
    ok "Kernel ${kver} (>= 6.18.4)"
  else
    warn "Kernel ${kver} is older than AMD's current 6.18.4 minimum for RDNA 3.5 on non-Ubuntu distributions — run sudo pacman -Syu."
  fi

  if command -v pacman >/dev/null 2>&1 && command -v llama-server >/dev/null 2>&1; then
    if pacman -Q ggml-cpu >/dev/null 2>&1; then
      ok "ggml-cpu backend installed"
    else
      warn "ggml-cpu is MISSING — model loads will fail with 'no CPU backend found'. Fix: sudo pacman -Syu ggml-cpu"
    fi
  fi

  if command -v vulkaninfo >/dev/null 2>&1; then
    if vulkaninfo --summary 2>/dev/null | grep -qi 'radv'; then
      ok "Vulkan (RADV) driver active"
    else
      warn "vulkaninfo did not report a RADV device — run 'install' first, then re-check."
    fi
  else
    warn "vulkan-tools not installed yet — run 'install' first, then re-check."
  fi

  local groups
  groups="$(id -nG 2>/dev/null || true)"
  if [[ " $groups " == *" render "* || " $groups " == *" video "* ]]; then
    ok "User belongs to a GPU device group (render/video)"
  else
    warn "User is not in render/video. If /dev/dri is inaccessible, add the user"
    warn "to those groups and fully log out/in before starting the service."
  fi

  info "Current GPU-addressable (GTT) memory:"
  if [[ -r /sys/module/ttm/parameters/pages_limit ]]; then
    local pages gib
    pages=$(cat /sys/module/ttm/parameters/pages_limit)
    gib=$((pages * 4 / 1024 / 1024))
    echo "    ttm pages_limit = ${pages} pages (~${gib} GiB)"
    if (( gib < 80 )); then
      echo "    (Fine for everyday/coder. The senior model benefits from the opt-in ${GTT_GIB} GiB limit.)"
    fi
  else
    echo "    ttm module not loaded yet (normal before first GPU use)"
  fi
}

cmd_install() {
  need_arch
  info "Installing Arch packages (llama.cpp + Vulkan backend + tooling)"
  # Note: ggml-cpu is NOT optional — llama.cpp needs the CPU backend as its
  # base even when inference runs entirely on Vulkan. Without it, model loads
  # fail with "make_cpu_buft_list: no CPU backend found".
  # Arch does not support partial upgrades. Refresh and complete the system
  # upgrade before installing the tightly coupled llama.cpp/ggml packages.
  sudo pacman -Syu --needed --noconfirm \
    llama-cpp ggml-cpu ggml-vulkan \
    vulkan-radeon vulkan-icd-loader vulkan-tools \
    curl jq nodejs npm bun

  ok "Installed. llama-server: $(command -v llama-server || echo 'NOT FOUND')"
  llama-server --version 2>&1 | head -2 || true

  if system_reboot_required && [[ "$ALLOW_PENDING_REBOOT" != 1 ]]; then
    warn "The package/kernel/TTM state now requires a reboot; skipping GPU initialization until the new runtime is active."
    warn "Reboot, then continue with '$0 model everyday' or '$0 all'."
    return 0
  fi

  info "GPU devices visible to llama.cpp:"
  llama-server --list-devices 2>/dev/null || warn "Could not list devices (a reboot after first GPU driver install can help)."
}

tier_required_bytes() {
  model_rows "$1" | awk -F'|' '{ total += $8 } END { printf "%.0f\n", total }'
}

tier_download_bytes() {
  local tier="$1" _t _v _id _dir _repo _rev remote bytes _sha _kind
  local dest part part_bytes=0 total=0
  while IFS='|' read -r _t _v _id _dir _repo _rev remote bytes _sha _kind; do
    dest="$(tier_dir "$tier")/${remote##*/}"
    part="${dest}.part"
    [[ -e "$dest" ]] && continue
    part_bytes=0
    [[ ! -e "$part" ]] || part_bytes="$(file_size "$part")"
    (( part_bytes >= bytes )) || total=$((total + bytes - part_bytes))
  done < <(model_rows "$tier")
  printf '%s\n' "$total"
}

tier_any_file() {
  local tier="$1" _t _v _id _dir _repo _rev remote _bytes _sha _kind
  while IFS='|' read -r _t _v _id _dir _repo _rev remote _bytes _sha _kind; do
    [[ -e "$(tier_dir "$tier")/${remote##*/}" || -L "$(tier_dir "$tier")/${remote##*/}" ||
       -e "$(tier_dir "$tier")/${remote##*/}.part" || -L "$(tier_dir "$tier")/${remote##*/}.part" ]] && return 0
  done < <(model_rows "$tier")
  return 1
}

tier_manifest_any_file() {
  local tier="$1" _t _v _id _dir _repo _rev remote _bytes _sha _kind file
  while IFS='|' read -r _t _v _id _dir _repo _rev remote _bytes _sha _kind; do
    file="$(tier_dir "$tier")/${remote##*/}"
    [[ -e "$file" || -L "$file" || -e "${file}.part" || -L "${file}.part" ]] && return 0
  done < <(manifest_tier_rows "$tier")
  return 1
}

verify_artifact() {
  local file="$1" expected_bytes="$2" expected_sha="$3" actual_bytes actual_sha
  [[ -f "$file" && ! -L "$file" ]] || return 1
  actual_bytes=$(file_size "$file")
  [[ "$actual_bytes" == "$expected_bytes" ]] || return 1
  actual_sha=$(sha256sum "$file" | awk '{print $1}')
  [[ "$actual_sha" == "$expected_sha" ]]
}

verify_artifact_cached() {
  local tier="$1" file="$2" expected_bytes="$3" expected_sha="$4"
  verification_receipt_valid "$tier" "$file" "$expected_bytes" "$expected_sha" && return 0
  verify_artifact "$file" "$expected_bytes" "$expected_sha" || return 1
  write_verification_receipt "$tier" "$file" "$expected_bytes" "$expected_sha"
}

verify_tier_integrity() {
  local tier="$1" report="${2:-1}" mode="${3:-full}" failures=0 found=0
  local _t _v _id _dir _repo _rev remote bytes sha _kind file
  case "$mode" in full|cached) ;; *) die "Internal error: verification mode must be full or cached" ;; esac
  while IFS='|' read -r _t _v _id _dir _repo _rev remote bytes sha _kind; do
    found=1
    file="$(tier_dir "$tier")/${remote##*/}"
    if [[ ! -f "$file" ]]; then
      warn "MISSING $file"
      failures=$((failures + 1))
    elif [[ "$mode" == cached ]] && verify_artifact_cached "$tier" "$file" "$bytes" "$sha"; then
      [[ "$report" == 0 ]] || ok "verified receipt $file"
    elif [[ "$mode" == full ]] && verify_artifact "$file" "$bytes" "$sha"; then
      write_verification_receipt "$tier" "$file" "$bytes" "$sha" || {
        warn "Could not record verification receipt for $file"
        failures=$((failures + 1))
        continue
      }
      [[ "$report" == 0 ]] || ok "verified $file"
    else
      warn "FAILED $file"
      failures=$((failures + 1))
    fi
  done < <(model_rows "$tier")
  (( found == 1 && failures == 0 ))
}

download_artifact() {
  local url="$1" dest="$2" expected_bytes="$3" expected_sha="$4" tier="$5"
  command -v sha256sum >/dev/null 2>&1 || die "sha256sum is required (install coreutils)"

  [[ ! -L "$dest" ]] || die "Refusing symlinked artifact destination: $dest"
  [[ ! -L "${dest}.part" ]] || die "Refusing symlinked resume path: ${dest}.part"
  if [[ -e "$dest" && ! -f "$dest" ]]; then
    die "Artifact destination is not a regular file: $dest"
  fi

  if [[ -f "$dest" ]]; then
    if verify_artifact "$dest" "$expected_bytes" "$expected_sha"; then
      write_verification_receipt "$tier" "$dest" "$expected_bytes" "$expected_sha" || \
        die "Could not record verification receipt for $dest"
      ok "$(basename "$dest") already present (SHA-256 verified)"
      return 0
    fi
    die "Integrity mismatch: $dest. Move/remove it explicitly, then retry; it was not executed or replaced."
  fi

  if [[ -f "${dest}.part" ]]; then
    if verify_artifact "${dest}.part" "$expected_bytes" "$expected_sha"; then
      mv "${dest}.part" "$dest"
      write_verification_receipt "$tier" "$dest" "$expected_bytes" "$expected_sha" || \
        die "Could not record verification receipt for $dest"
      ok "$(basename "$dest") recovered from a complete verified .part file"
      return 0
    fi
    local part_bytes
    part_bytes="$(file_size "${dest}.part")"
    if (( part_bytes >= expected_bytes )); then
      die "Existing .part for $(basename "$dest") is complete/oversized but failed integrity verification. It was retained; inspect or move/remove it explicitly before retrying."
    fi
  elif [[ -e "${dest}.part" ]]; then
    die "Resume path is not a regular file: ${dest}.part"
  fi

  info "Fetching $(basename "$dest") (resumable; immutable revision)"
  curl --proto '=https' --proto-redir '=https' --tlsv1.2 -L --fail --retry 5 --retry-delay 5 \
    -C - -o "${dest}.part" "$url"

  if ! verify_artifact "${dest}.part" "$expected_bytes" "$expected_sha"; then
    local got_bytes got_sha
    got_bytes=$(file_size "${dest}.part" 2>/dev/null || echo 0)
    got_sha=$(sha256sum "${dest}.part" 2>/dev/null | awk '{print $1}')
    die "Verification failed for $(basename "$dest"): bytes=${got_bytes}/${expected_bytes}, sha256=${got_sha:-unavailable}. The .part file was retained for inspection."
  fi

  mv "${dest}.part" "$dest"
  write_verification_receipt "$tier" "$dest" "$expected_bytes" "$expected_sha" || \
    die "Could not record verification receipt for $dest"
  ok "$(basename "$dest") downloaded and SHA-256 verified"
}

ensure_download_space() {
  local dir="$1" download_bytes="$2" available_kb required_kb reserve_kb
  (( download_bytes > 0 )) || return 0
  mkdir -p "$dir"
  available_kb="$(df -Pk "$dir" | awk 'NR == 2 { print $4 }')"
  reserve_kb=$((DISK_RESERVE_GIB * 1024 * 1024))
  required_kb=$(((download_bytes + 1023) / 1024 + reserve_kb))
  (( available_kb >= required_kb )) || \
    die "Not enough free disk: need $(human_bytes "$download_bytes") of remaining downloads plus ${DISK_RESERVE_GIB} GiB reserve; df reports $((available_kb / 1024 / 1024)) GiB free."
}

download_tier() {
  local tier="$1" space_prechecked="${2:-0}" dir required download_bytes
  dir="$(tier_dir "$tier")"
  required="$(tier_required_bytes "$tier")"
  download_bytes="$(tier_download_bytes "$tier")"
  mkdir -p "$dir"
  (( space_prechecked == 1 )) || ensure_download_space "$dir" "$download_bytes"

  info "Downloading $(tier_label "$tier") — $(tier_variant "$tier"), $(human_bytes "$required")"
  local _tier _variant _id _model_dir repo revision remote bytes sha _kind dest url pid failed=0 queued=0
  local -a pids=()
  while IFS='|' read -r _tier _variant _id _model_dir repo revision remote bytes sha _kind; do
    dest="$dir/${remote##*/}"
    url="https://huggingface.co/${repo}/resolve/${revision}/${remote}"
    if (( DOWNLOAD_JOBS == 1 )); then
      download_artifact "$url" "$dest" "$bytes" "$sha" "$tier"
      continue
    fi
    ( download_artifact "$url" "$dest" "$bytes" "$sha" "$tier" ) &
    pids+=("$!")
    queued=$((queued + 1))
    if (( ${#pids[@]} >= DOWNLOAD_JOBS )); then
      for pid in "${pids[@]}"; do wait "$pid" || failed=1; done
      pids=()
      queued=0
      (( failed == 0 )) || die "One or more $tier artifact downloads failed; verified .part files were retained for resume."
    fi
  done < <(model_rows "$tier")
  # Bash 3.2 treats an empty-array expansion as an unbound variable under
  # `set -u`; the scalar guard keeps the macOS/offline path portable.
  if (( queued > 0 )); then
    for pid in "${pids[@]}"; do wait "$pid" || failed=1; done
  fi
  (( failed == 0 )) || die "One or more $tier artifact downloads failed; verified .part files were retained for resume."
}

cmd_model() {
  local tier="${1:-everyday}" answer="" all_bytes=0 item_bytes item_tier
  [[ $# -le 2 ]] || die "Usage: $0 model [everyday|coder|senior|all] [--yes]"
  if (( $# == 2 )); then
    [[ "$2" == --yes ]] || die "Usage: $0 model [everyday|coder|senior|all] [--yes]"
  fi
  if [[ "$tier" == all ]]; then
    for item_tier in everyday coder senior; do
      item_bytes="$(tier_download_bytes "$item_tier")"
      all_bytes=$((all_bytes + item_bytes))
    done
    echo "This downloads about $(human_bytes "$all_bytes") of remaining artifacts across all three tiers. The senior model"
    echo "also needs substantial GPU-addressable memory for full offload."
    if [[ "${YES:-0}" != 1 && "${2:-}" != "--yes" ]]; then
      read -r -p "Download all pinned artifacts? [y/N] " answer || true
      [[ "$answer" =~ ^[Yy]$ ]] || { warn "Skipped."; return 0; }
    fi
    ensure_download_space "$MODELS_DIR" "$all_bytes"
    for tier in everyday coder senior; do download_tier "$tier" 1; done
  else
    tier_variant "$tier" >/dev/null
    [[ "$tier" != senior ]] || warn "The senior tier is ~70 GiB before KV/runtime memory; run 'kernel-tweaks' only after baseline testing if full GPU offload is needed."
    download_tier "$tier"
  fi

  ok "Locked model artifacts are ready; run '$0 plan', then '$0 apply' to update the router and agent routing together."
  if systemctl --user is-active --quiet "$UNIT_NAME" 2>/dev/null; then
    warn "The router and agent launchers remain on their prior transactional configuration until you run '$0 apply'."
  fi
}

cmd_model_catalog() {
  info "Pinned model strategy (router keeps at most ${MODELS_MAX} resident)"
  local tier state bytes done total progress
  for tier in everyday coder senior; do
    if tier_available "$tier"; then state="installed"; elif tier_any_file "$tier"; then state="partial"; else state="not installed"; fi
    bytes="$(tier_required_bytes "$tier")"
    read -r done total < <(tier_artifact_progress "$tier")
    progress="$(awk -v d="$done" -v t="$total" 'BEGIN { if (t>0) printf "%.1f%%", d/t*100; else print "0.0%" }')"
    printf '    %-9s %-14s %-13s %-7s %s\n' "$tier" "$(human_bytes "$bytes")" "$state" "$progress" "$(tier_label "$tier")"
  done
  echo
  echo "    omp routing profile: ${ROUTING_PROFILE}"
  case "$ROUTING_PROFILE" in
    sticky)
      echo "      all roles stay on the base tier; use omp-coder/omp-senior at phase boundaries"
      ;;
    balanced)
      echo "      task -> coder when installed; plan/review roles stay on the base tier"
      ;;
    quality)
      echo "      task -> coder; slow/plan/advisor/designer -> senior when installed"
      ;;
  esac
  echo
  echo "    Download: $0 model everyday|coder|senior|all"
}

cmd_model_verify() {
  [[ $# -le 1 ]] || die "Usage: $0 model-verify [all|everyday|coder|senior]"
  local requested="${1:-all}" tier selected=0 failures=0
  case "$requested" in all|everyday|coder|senior) ;; *) die "Usage: $0 model-verify [all|everyday|coder|senior]" ;; esac
  command -v sha256sum >/dev/null 2>&1 || die "sha256sum is required (install coreutils)"
  for tier in everyday coder senior; do
    [[ "$requested" == all || "$requested" == "$tier" ]] || continue
    if [[ "$requested" != all ]] || tier_any_file "$tier"; then
      selected=1
      verify_tier_integrity "$tier" 1 || failures=$((failures + 1))
    fi
  done
  (( selected == 1 )) || die "No installed artifacts matched '$requested'"
  (( failures == 0 )) || die "$failures tier(s) are incomplete or failed verification"
  ok "All selected installed artifacts match models.lock"
}

confirm_destructive_model_action() {
  local prompt="$1" assume_yes="${2:-0}" answer=""
  if [[ "${YES:-0}" == 1 || "$assume_yes" == 1 ]]; then
    return 0
  fi
  read -r -p "$prompt [y/N] " answer || true
  [[ "$answer" =~ ^[Yy]$ ]]
}

require_router_fully_stopped() {
  local purpose="${1:-changing local model files}" state main_pid load_state
  load_state="$(systemctl --user show "$UNIT_NAME" --property=LoadState --value 2>/dev/null || true)"
  case "$load_state" in
    not-found) return 0 ;;
    loaded) ;;
    *) die "Could not prove whether $UNIT_NAME exists (LoadState: ${load_state:-unknown}); refusing to continue with $purpose." ;;
  esac
  state="$(systemctl --user is-active "$UNIT_NAME" 2>/dev/null || true)"
  case "$state" in
    inactive|failed) ;;
    active|activating|deactivating)
      die "Stop $UNIT_NAME and wait for it to become fully inactive before $purpose (current state: $state)."
      ;;
    *)
      die "Could not prove $UNIT_NAME is stopped (state: ${state:-unknown}); refusing to continue with $purpose."
      ;;
  esac
  main_pid="$(systemctl --user show "$UNIT_NAME" --property=MainPID --value 2>/dev/null || true)"
  [[ "$main_pid" =~ ^[0-9]+$ ]] || \
    die "Could not verify MainPID=0 for $UNIT_NAME; refusing to continue with $purpose."
  (( main_pid == 0 )) || \
    die "$UNIT_NAME still owns MainPID=$main_pid; wait for complete shutdown before removing model files."
}

require_router_stopped_for_removal() {
  require_router_fully_stopped "removing model files"
}

managed_user_service_active_flag() {
  local load_state state
  load_state="$(systemctl --user show "$UNIT_NAME" --property=LoadState --value 2>/dev/null || true)"
  case "$load_state" in
    not-found) printf '0\n'; return 0 ;;
    loaded) ;;
    *) return 1 ;;
  esac
  state="$(systemctl --user is-active "$UNIT_NAME" 2>/dev/null || true)"
  case "$state" in
    active) printf '1\n' ;;
    inactive|failed) printf '0\n' ;;
    *) return 1 ;;
  esac
}

quarantine_restore_moved() {
  # Called only from quarantine_remove_paths (including its signal trap). Bash's
  # dynamic scoping makes that function's local arrays/counters visible here.
  local restore_index
  while (( moved > 0 )); do
    moved=$((moved - 1))
    restore_index="$moved"
    if [[ -e "${staged[$restore_index]}" || -L "${staged[$restore_index]}" ]]; then
      if [[ -e "${originals[$restore_index]}" || -L "${originals[$restore_index]}" ]] || \
          ! mv -- "${staged[$restore_index]}" "${originals[$restore_index]}"; then
        rollback_failed=1
      fi
    fi
  done
  (( rollback_failed == 0 ))
}

quarantine_remove_signal_handler() {
  trap - HUP INT TERM
  warn "Model-file removal was interrupted; restoring the staged artifact set."
  quarantine_restore_moved || \
    warn "Removal rollback was incomplete; do not restart the router until every quarantine path is restored."
  exit 130
}

quarantine_remove_paths() {
  (( $# > 0 )) || return 0
  local token="local-ai-remove.$$.${RANDOM}" path parent destination i moved=0 rollback_failed=0 cleanup_failed=0
  local -a originals=("$@") staged=()

  # Validate every candidate before the first rename. This prevents a later
  # unexpected directory or unwritable parent from leaving an earlier shard
  # deleted while an old service preset still references the tier.
  for path in "${originals[@]}"; do
    [[ ( -f "$path" || -L "$path" ) && ! ( -d "$path" && ! -L "$path" ) ]] || {
      warn "Refusing unexpected non-file at managed artifact path: $path"
      return 1
    }
    parent="$(dirname "$path")"
    [[ -d "$parent" && -w "$parent" ]] || { warn "Managed artifact directory is not writable: $parent"; return 1; }
    destination="${path}.${token}"
    [[ ! -e "$destination" && ! -L "$destination" ]] || { warn "Removal quarantine path already exists: $destination"; return 1; }
    staged+=("$destination")
  done

  # A multi-shard tier is one logical removal. Until every rename succeeds,
  # HUP/INT/TERM restores the entire staged prefix before the command exits.
  trap 'quarantine_remove_signal_handler' HUP INT TERM
  for ((i = 0; i < ${#originals[@]}; i++)); do
    # Count the in-flight entry first. If the signal lands immediately after
    # mv(1)'s atomic rename but before the shell resumes, the trap still knows
    # that this destination may need restoring.
    moved=$((i + 1))
    if ! mv -- "${originals[$i]}" "${staged[$i]}"; then
      warn "Could not stage ${originals[$i]} for removal; restoring earlier paths."
      quarantine_restore_moved || \
        warn "Removal rollback was incomplete; do not restart the router until the staged paths are restored."
      trap - HUP INT TERM
      return 1
    fi
  done
  trap - HUP INT TERM

  # The active namespace is now committed atomically path-by-path. Cleanup
  # failure leaves clearly named recoverable quarantine files, but returns
  # success so callers regenerate routing instead of restarting a stale preset.
  for path in "${staged[@]}"; do
    rm -f -- "$path" || cleanup_failed=1
  done
  (( cleanup_failed == 0 )) || warn "Some quarantined files could not be unlinked; they remain beside the model with suffix .${token}."
}

cmd_model_remove() {
  local tier="${1:-}" assume_yes=0 answer file remote sha _t _v _id _dir _repo _rev _bytes _kind
  [[ $# -ge 1 && $# -le 2 ]] || die "Usage: $0 model-remove <everyday|coder|senior> [--yes]"
  case "$tier" in everyday|coder|senior) ;; *) die "Usage: $0 model-remove <everyday|coder|senior> [--yes]" ;; esac
  if (( $# == 2 )); then [[ "$2" == --yes ]] || die "Usage: $0 model-remove <everyday|coder|senior> [--yes]"; assume_yes=1; fi
  [[ "$STARTUP_TIER" != "$tier" ]] || \
    die "Refusing to remove configured STARTUP_TIER=$tier. Save and apply another installed startup tier (or none) first, then retry."
  require_router_stopped_for_removal

  local -a files=()
  while IFS='|' read -r _t _v _id _dir _repo _rev remote _bytes sha _kind; do
    file="$(tier_dir "$tier")/${remote##*/}"
    [[ ! -e "$file" && ! -L "$file" ]] || files+=("$file")
    [[ ! -e "${file}.part" && ! -L "${file}.part" ]] || files+=("${file}.part")
  done < <(manifest_tier_rows "$tier")
  (( ${#files[@]} > 0 )) || { warn "No managed $tier artifacts or partial downloads are present."; return 0; }
  echo "The following exact managed paths will be removed:"
  printf '  %s\n' "${files[@]}"
  confirm_destructive_model_action "Remove the $tier tier?" "$assume_yes" || { warn "Skipped."; return 0; }

  quarantine_remove_paths "${files[@]}" || die "No managed $tier path was intentionally removed; resolve the reported path error and retry."
  while IFS='|' read -r _t _v _id _dir _repo _rev remote _bytes sha _kind; do
    clear_verification_receipt "$tier" "$sha" || \
      warn "Could not remove a stale verification receipt for $tier; the artifact removal itself is already committed and remains successful."
  done < <(manifest_tier_rows "$tier")
  rmdir "$(tier_dir "$tier")" 2>/dev/null || true
  ok "Removed managed $tier artifacts; they are recoverable by re-downloading with '$0 model $tier'. Run '$0 apply' to remove the tier from the router and OMP routing."
}

cmd_model_prune() {
  [[ $# -le 1 ]] || die "Usage: $0 model-prune [--yes]"
  local assume_yes=0
  if (( $# == 1 )); then [[ "$1" == --yes ]] || die "Usage: $0 model-prune [--yes]"; assume_yes=1; fi
  require_router_stopped_for_removal
  local tier selected_variant variant remote sha file _t _id _dir _repo _rev _bytes _kind
  local -a files=() receipt_tiers=() receipt_shas=()
  for tier in everyday coder senior; do
    selected_variant="$(tier_variant "$tier")"
    while IFS='|' read -r _t variant _id _dir _repo _rev remote _bytes sha _kind; do
      file="$(tier_dir "$tier")/${remote##*/}"
      if [[ -e "${file}.part" || -L "${file}.part" ]]; then
        if (( ${#files[@]} == 0 )) || ! array_contains "${file}.part" "${files[@]}"; then
          files+=("${file}.part")
        fi
      fi
      if [[ "$variant" != ALL && "$variant" != "$selected_variant" && ( -e "$file" || -L "$file" ) ]]; then
        if (( ${#files[@]} == 0 )) || ! array_contains "$file" "${files[@]}"; then
          files+=("$file")
        fi
        receipt_tiers+=("$tier"); receipt_shas+=("$sha")
      fi
    done < <(manifest_tier_rows "$tier")
  done
  (( ${#files[@]} > 0 )) || { ok "No partial downloads or unselected managed quant artifacts to prune."; return 0; }
  echo "The following resumable partials/unselected managed artifacts will be removed:"
  printf '  %s\n' "${files[@]}"
  confirm_destructive_model_action "Prune these paths?" "$assume_yes" || { warn "Skipped."; return 0; }
  quarantine_remove_paths "${files[@]}" || die "No prune set was intentionally committed; resolve the reported path error and retry."
  local i
  for ((i = 0; i < ${#receipt_tiers[@]}; i++)); do
    clear_verification_receipt "${receipt_tiers[$i]}" "${receipt_shas[$i]}" || \
      warn "Could not remove a stale verification receipt; the prune itself is already committed and remains successful."
  done
  ok "Pruned ${#files[@]} exact managed path(s); full artifacts are recoverable from the locked revisions, while discarded partial bytes must be downloaded again."
}

managed_artifact_namespace_fingerprint() {
  local tier _t _v _id _dir _repo _rev remote _bytes _sha _kind path identity
  {
    for tier in everyday coder senior; do
      while IFS='|' read -r _t _v _id _dir _repo _rev remote _bytes _sha _kind; do
        for path in "$(tier_dir "$tier")/${remote##*/}" "$(tier_dir "$tier")/${remote##*/}.part"; do
          if [[ -L "$path" ]]; then
            printf 'L|%s|%s\n' "$path" "$(readlink "$path" 2>/dev/null || true)"
          elif [[ -e "$path" ]]; then
            identity="$(local_ai_file_identity "$path" 2>/dev/null || true)"
            printf 'F|%s|%s\n' "$path" "$identity"
          else
            printf 'M|%s\n' "$path"
          fi
        done
      done < <(manifest_tier_rows "$tier")
    done
  } | sha256sum | awk '{print $1}'
}

MODEL_MAINT_TXN_ARMED=0
MODEL_MAINT_TXN_WAS_ACTIVE=0
MODEL_MAINT_TXN_BEFORE=""

restore_model_maintenance_transaction() {
  (( MODEL_MAINT_TXN_ARMED )) || return 0
  local after="" failed=0
  after="$(managed_artifact_namespace_fingerprint 2>/dev/null || true)"
  if [[ -n "$MODEL_MAINT_TXN_BEFORE" && "$after" == "$MODEL_MAINT_TXN_BEFORE" ]]; then
    if (( MODEL_MAINT_TXN_WAS_ACTIVE )); then
      systemctl --user start "$UNIT_NAME" || failed=1
      (( failed )) || wait_for_managed_router_control_plane 30 || failed=1
    fi
  else
    warn "Managed artifact state changed or could not be proven unchanged; $UNIT_NAME remains stopped until Plan and Apply succeed."
  fi
  MODEL_MAINT_TXN_ARMED=0
  return "$failed"
}

model_maintenance_exit_handler() {
  local rc=$?
  trap - EXIT HUP INT TERM
  restore_model_maintenance_transaction || true
  exit "$rc"
}

model_maintenance_signal_handler() {
  trap - EXIT HUP INT TERM
  warn "Model maintenance was interrupted; restoring the prior router only when artifact state is unchanged."
  restore_model_maintenance_transaction || true
  exit 130
}

cmd_model_maintain() {
  local action="${1:-}" was_active after
  shift || true
  case "$action" in
    remove)
      [[ $# -ge 1 && $# -le 2 ]] || die "Usage: $0 model-maintain remove <everyday|coder|senior> [--yes]"
      ;;
    prune)
      [[ $# -le 1 ]] || die "Usage: $0 model-maintain prune [--yes]"
      ;;
    *) die "Usage: $0 model-maintain remove <tier> [--yes] | prune [--yes]" ;;
  esac
  was_active="$(managed_user_service_active_flag)" || \
    die "The router service is transitioning or unverifiable; wait for it to settle before model maintenance."
  MODEL_MAINT_TXN_BEFORE="$(managed_artifact_namespace_fingerprint)" || \
    die "Could not snapshot managed artifact state before maintenance"
  MODEL_MAINT_TXN_WAS_ACTIVE="$was_active"
  MODEL_MAINT_TXN_ARMED=1
  trap 'model_maintenance_exit_handler' EXIT
  trap 'model_maintenance_signal_handler' HUP INT TERM

  if (( was_active )); then
    systemctl --user stop "$UNIT_NAME" || die "Could not stop $UNIT_NAME; no model files were changed."
  fi
  require_router_stopped_for_removal
  case "$action" in
    remove) cmd_model_remove "$@" ;;
    prune) cmd_model_prune "$@" ;;
  esac

  # Lower-level quarantine helpers temporarily own signal traps. Reinstate the
  # transaction guard before deciding whether routing must be regenerated.
  trap 'model_maintenance_exit_handler' EXIT
  trap 'model_maintenance_signal_handler' HUP INT TERM
  after="$(managed_artifact_namespace_fingerprint)" || die "Could not verify artifact state after maintenance"
  if [[ "$after" == "$MODEL_MAINT_TXN_BEFORE" ]]; then
    restore_model_maintenance_transaction || die "Maintenance made no artifact change, but the prior router could not be restored"
    trap - EXIT HUP INT TERM
    ok "No managed artifact state changed; Apply was skipped."
    return 0
  fi

  # The prior preset is now stale. Apply while this command still owns the
  # process-wide lifecycle lock; any failure leaves the router stopped.
  cmd_plan || die "Artifacts changed, but the desired state is unresolved; the router remains stopped."
  cmd_apply
  MODEL_MAINT_TXN_ARMED=0
  trap - EXIT HUP INT TERM
  ok "Model maintenance and desired routing were applied under one lifecycle lock."
}

tier_load_mode() {
  case "$1" in
    everyday) printf '%s\n' "$LOAD_MODE_EVERYDAY" ;;
    coder)    printf '%s\n' "$LOAD_MODE_CODER" ;;
    senior)   printf '%s\n' "$LOAD_MODE_SENIOR" ;;
    *) return 1 ;;
  esac
}

tier_context() {
  case "$1" in
    everyday) printf '%s\n' "$CTX" ;;
    coder)    printf '%s\n' "$CODER_CTX" ;;
    senior)   printf '%s\n' "$SENIOR_CTX" ;;
    *) return 1 ;;
  esac
}

tier_output_tokens() {
  local tier="$1" context cap
  context="$(tier_context "$tier")"
  case "$tier" in
    everyday|coder) cap=32768 ;;
    senior) cap=65536 ;;
    *) return 1 ;;
  esac
  # Keep at least 4096 context tokens available for instructions, tool results,
  # and chat-template overhead even at the accepted minimum context.
  if (( context - 4096 < cap )); then
    printf '%s\n' "$((context - 4096))"
  else
    printf '%s\n' "$cap"
  fi
}

kv_cache_type() {
  case "$KV_CACHE_PROFILE" in
    f16) printf '%s\n' f16 ;;
    q8)  printf '%s\n' q8_0 ;;
  esac
}

effective_startup_tier() {
  if [[ "$STARTUP_TIER" != none ]] && tier_available "$STARTUP_TIER"; then
    printf '%s\n' "$STARTUP_TIER"
  else
    printf '%s\n' none
  fi
}

tier_load_on_startup() {
  [[ "$(effective_startup_tier)" == "$1" ]] && printf '%s\n' true || printf '%s\n' false
}

write_model_preset() {
  local target="${1:-$PRESET_FILE}"
  mkdir -p "$(dirname "$target")"
  [[ "$(dirname "$target")" != "$LOCAL_AI_CONFIG_DIR" ]] || chmod 700 "$LOCAL_AI_CONFIG_DIR"
  local tmp="${target}.tmp"
  {
    cat <<'EOF'
# Managed by local-ai-setup: llama.cpp model router preset.
version = 1

[*]
jinja = true
flash-attn = on
parallel = 1
cache-reuse = 256
stop-timeout = 60
EOF
    printf 'cache-type-k = %s\n' "$(kv_cache_type)"
    printf 'cache-type-v = %s\n' "$(kv_cache_type)"

    if tier_available everyday; then
      cat <<EOF

[${EVERYDAY_ID}]
model = $(tier_file everyday main)
load-mode = ${LOAD_MODE_EVERYDAY}
n-gpu-layers = all
mmproj = $(tier_file everyday mmproj)
spec-draft-model = $(tier_file everyday draft)
spec-type = draft-mtp
spec-draft-n-max = ${DRAFT_N}
spec-draft-type-k = $(kv_cache_type)
spec-draft-type-v = $(kv_cache_type)
ctx-size = ${CTX}
reasoning = on
reasoning-effort = ${REASONING_EFFORT}
reasoning-preserve = true
temp = 1.0
top-p = 0.95
top-k = 20
min-p = 0.0
presence-penalty = 0.0
load-on-startup = $(tier_load_on_startup everyday)
EOF
    fi

    if tier_available coder; then
      cat <<EOF

[${CODER_ID}]
model = $(tier_file coder main)
load-mode = ${LOAD_MODE_CODER}
n-gpu-layers = all
spec-type = none
ctx-size = ${CODER_CTX}
no-context-shift = true
reasoning = off
temp = 1.0
top-p = 0.95
top-k = 40
min-p = 0.0
load-on-startup = $(tier_load_on_startup coder)
EOF
    fi

    if tier_available senior; then
      cat <<EOF

[${SENIOR_ID}]
model = $(tier_file senior main)
load-mode = ${LOAD_MODE_SENIOR}
spec-type = none
ctx-size = ${SENIOR_CTX}
reasoning = on
temp = 0.6
top-p = 0.95
top-k = 20
min-p = 0.0
presence-penalty = 0.0
load-on-startup = $(tier_load_on_startup senior)
EOF
    fi
  } > "$tmp"
  chmod 600 "$tmp"
  mv "$tmp" "$target"
}

write_server_launcher() {
  local target="$1" server_bin="$2" quoted_server quoted_key quoted_preset
  printf -v quoted_server '%q' "$server_bin"
  printf -v quoted_key '%q' "$KEY_FILE"
  printf -v quoted_preset '%q' "$PRESET_FILE"
  cat > "$target" <<EOF
#!/usr/bin/env bash
# Managed by local-ai-setup. Model-specific flags live in the generated preset.
set -euo pipefail
exec ${quoted_server} \\
  --host 127.0.0.1 \\
  --port ${PORT} \\
  --api-key-file ${quoted_key} \\
  --models-preset ${quoted_preset} \\
  --models-max ${MODELS_MAX} \\
  --models-autoload
EOF
  chmod 700 "$target"
}

write_service_unit() {
  local target="$1" exec_path="$2"
  cat > "$target" <<EOF
# Managed by local-ai-setup: llama.cpp user service.
[Unit]
Description=llama.cpp multi-model router for local agentic coding

[Service]
ExecStart="${exec_path}"
Restart=on-failure
RestartSec=3
UMask=0077
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=read-only
ReadOnlyPaths="${MODELS_DIR}"
CacheDirectory=local-ai-llama
Environment=MESA_SHADER_CACHE_DIR=%C/local-ai-llama
PrivateTmp=true
ProtectControlGroups=true
ProtectKernelTunables=true
ProtectKernelModules=true
RestrictSUIDSGID=true
RestrictNamespaces=true
LockPersonality=true
DeviceAllow=char-drm rw

[Install]
WantedBy=default.target
EOF
}

managed_service_path_or_absent() {
  local path="$1" kind="$2"
  [[ ! -L "$path" ]] || return 1
  [[ -e "$path" ]] || return 0
  [[ -f "$path" ]] || return 1
  case "$kind" in
    preset) grep -q '^# Managed by local-ai-setup: llama.cpp model router preset[.]$' "$path" ;;
    launcher) grep -q '^# Managed by local-ai-setup[.] Model-specific flags live' "$path" ;;
    unit) grep -q '^# Managed by local-ai-setup: llama.cpp user service[.]$' "$path" ;;
    *) return 1 ;;
  esac
}

recognized_legacy_service_trio() {
  local preset="$PRESET_FILE" launcher="$LAUNCHER" unit="$UNIT_DIR/$UNIT_NAME"
  [[ ! -L "$preset" && ! -L "$launcher" && ! -L "$unit" &&
     -f "$preset" && -f "$launcher" && -f "$unit" ]] || return 1
  grep -q '^version = 1$' "$preset" &&
    grep -q '^\[\*\]$' "$preset" &&
    grep -q '^cache-reuse = 256$' "$preset" &&
    grep -q '^\[qwen3[.]8-27b\]$' "$preset" &&
    grep -q '^spec-type = draft-mtp$' "$preset" &&
    grep -q '^# Managed by local-ai-setup[.] Model-specific flags live' "$launcher" &&
    grep -q -- '--models-preset ' "$launcher" &&
    grep -q '^Description=llama[.]cpp multi-model router for local agentic coding$' "$unit" &&
    grep -q '^ProtectSystem=strict$' "$unit" &&
    grep -q '^ReadOnlyPaths=' "$unit" &&
    grep -q '^DeviceAllow=char-drm rw$' "$unit"
}

service_paths_owned_or_absent() {
  if managed_service_path_or_absent "$PRESET_FILE" preset &&
     managed_service_path_or_absent "$LAUNCHER" launcher &&
     managed_service_path_or_absent "$UNIT_DIR/$UNIT_NAME" unit; then
    return 0
  fi
  recognized_legacy_service_trio
}

restore_service_files() {
  local stage="$1" had_preset="$2" had_launcher="$3" had_unit="$4" failed=0
  if (( had_preset )); then cp -p "$stage/backup-preset" "$PRESET_FILE" || failed=1; else rm -f "$PRESET_FILE" || failed=1; fi
  if (( had_launcher )); then cp -p "$stage/backup-launcher" "$LAUNCHER" || failed=1; else rm -f "$LAUNCHER" || failed=1; fi
  if (( had_unit )); then cp -p "$stage/backup-unit" "$UNIT_DIR/$UNIT_NAME" || failed=1; else rm -f "$UNIT_DIR/$UNIT_NAME" || failed=1; fi
  (( failed == 0 ))
}

cleanup_service_stage() {
  local stage="$1"
  [[ "$stage" == "$LOCAL_AI_CONFIG_DIR"/.service-stage.* ]] || return 1
  rm -f -- "$stage/models.ini" "$stage/launcher" "$stage/verify.service" \
    "$stage/$UNIT_NAME" "$stage/backup-preset" "$stage/backup-launcher" "$stage/backup-unit"
  rmdir "$stage" 2>/dev/null || true
}

SERVICE_TXN_STAGE=""
SERVICE_TXN_ARMED=0
SERVICE_TXN_FILES_TOUCHED=0
SERVICE_TXN_HAD_PRESET=0
SERVICE_TXN_HAD_LAUNCHER=0
SERVICE_TXN_HAD_UNIT=0
SERVICE_TXN_WAS_ENABLED=0
SERVICE_TXN_WAS_ACTIVE=0

reset_service_transaction() {
  SERVICE_TXN_STAGE=""
  SERVICE_TXN_ARMED=0
  SERVICE_TXN_FILES_TOUCHED=0
  SERVICE_TXN_HAD_PRESET=0
  SERVICE_TXN_HAD_LAUNCHER=0
  SERVICE_TXN_HAD_UNIT=0
  SERVICE_TXN_WAS_ENABLED=0
  SERVICE_TXN_WAS_ACTIVE=0
}

rollback_service_transaction() {
  (( SERVICE_TXN_ARMED == 1 )) || return 0
  local failed=0
  if (( SERVICE_TXN_FILES_TOUCHED )); then
    restore_service_files "$SERVICE_TXN_STAGE" "$SERVICE_TXN_HAD_PRESET" \
      "$SERVICE_TXN_HAD_LAUNCHER" "$SERVICE_TXN_HAD_UNIT" || failed=1
    systemctl --user daemon-reload || failed=1
    if (( SERVICE_TXN_WAS_ENABLED )); then
      systemctl --user enable "$UNIT_NAME" >/dev/null 2>&1 || failed=1
    else
      systemctl --user disable "$UNIT_NAME" >/dev/null 2>&1 || failed=1
    fi
    if (( SERVICE_TXN_WAS_ACTIVE )); then
      systemctl --user restart "$UNIT_NAME" || failed=1
    else
      systemctl --user stop "$UNIT_NAME" >/dev/null 2>&1 || failed=1
    fi
  fi
  if (( failed == 0 )); then
    cleanup_service_stage "$SERVICE_TXN_STAGE"
    reset_service_transaction
  else
    warn "Service rollback was incomplete; backups remain in $SERVICE_TXN_STAGE."
  fi
  return "$failed"
}

service_transaction_exit_handler() {
  local rc=$?
  trap - EXIT HUP INT TERM
  rollback_service_transaction || true
  exit "$rc"
}

service_transaction_signal_handler() {
  trap - EXIT HUP INT TERM
  warn "Service update was interrupted; restoring the prior files and unit state."
  rollback_service_transaction || true
  exit 130
}

commit_service_transaction() {
  local committed_stage="$SERVICE_TXN_STAGE"
  # Readiness is the commit point. Disarm before deleting backups so no signal
  # can enter rollback after the recovery copies have been removed.
  SERVICE_TXN_ARMED=0
  trap - EXIT HUP INT TERM
  cleanup_service_stage "$committed_stage"
  reset_service_transaction
}

help_has_option() {
  local_ai_help_has_option "$1" "$2"
}

required_llama_server_options() {
  printf '%s\n' \
    --models-preset --models-max --models-autoload --api-key-file \
    --load-mode --flash-attn --cache-reuse --stop-timeout --spec-type \
    --spec-draft-model --spec-draft-n-max --reasoning --reasoning-effort \
    --reasoning-preserve --no-context-shift --cache-type-k --cache-type-v \
    --spec-draft-type-k --spec-draft-type-v
}

llama_server_preflight() {
  local server_bin server_help option
  server_bin="$(command -v llama-server 2>/dev/null || true)"
  [[ -n "$server_bin" && -x "$server_bin" ]] || return 1
  server_help="$("$server_bin" --help 2>&1 || true)"
  while IFS= read -r option; do
    help_has_option "$server_help" "$option" || return 2
  done < <(required_llama_server_options)
  printf '%s\n' "$server_bin"
}

managed_router_unit_owns_listener() {
  local state main_pid sockets
  state="$(systemctl --user is-active "$UNIT_NAME" 2>/dev/null || true)"
  [[ "$state" == active ]] || return 1
  main_pid="$(systemctl --user show "$UNIT_NAME" --property=MainPID --value 2>/dev/null || true)"
  [[ "$main_pid" =~ ^[0-9]+$ ]] && (( main_pid > 0 )) || return 1

  # On the target Linux host, bind readiness to the managed MainPID rather
  # than accepting a same-key llama.cpp process already occupying PORT. Tests
  # and non-Linux review hosts have no matching /proc entry and retain the
  # stable-unit check above.
  if [[ -d "/proc/$main_pid" ]] && command -v ss >/dev/null 2>&1; then
    sockets="$(ss -H -ltnp "sport = :${PORT}" 2>/dev/null || true)"
    grep -Eq "pid=${main_pid}([,)]|$)" <<< "$sockets" || return 1
  fi
}

cmd_service() {
  local server_bin preflight_rc startup_effective readiness_deadline remaining probe_timeout
  local service_was_active
  if system_reboot_required && [[ "$ALLOW_PENDING_REBOOT" != 1 ]]; then
    die "A reboot is required before safely restarting the local AI runtime. Reboot first, or use environment-only ALLOW_PENDING_REBOOT=1 after confirming the running kernel/TTM state is intentional."
  fi
  if server_bin="$(llama_server_preflight)"; then
    :
  else
    preflight_rc=$?
    if (( preflight_rc == 1 )); then
      die "llama-server not found — run: $0 install"
    fi
    die "llama-server is missing one or more required router/MTP/reasoning/cache options; complete a full Arch update before installing this service."
  fi

  command -v sha256sum >/dev/null 2>&1 || die "sha256sum is required (install coreutils)"
  local installed=0 tier
  for tier in everyday coder senior; do
    if tier_available "$tier"; then
      info "Verifying locked $tier artifacts before serving"
      verify_tier_integrity "$tier" 0 cached || die "$tier files do not match models.lock; refusing to serve them"
      installed=$((installed + 1))
      ok "$tier integrity verified"
    elif tier_any_file "$tier"; then
      warn "$tier has incomplete or wrong-sized files and will not be exposed"
    fi
  done
  (( installed > 0 )) || die "No complete model tier is installed — run: $0 model"
  if tier_manifest_any_file everyday && ! tier_available everyday; then
    die "Everyday artifacts exist but the selected QUANT=$QUANT set is incomplete. Complete '$0 model everyday' (or restore the matching QUANT) before applying a preset; another installed tier will not silently hide this selection change."
  fi
  if [[ "$STARTUP_TIER" != none ]] && ! tier_available "$STARTUP_TIER"; then
    die "STARTUP_TIER=$STARTUP_TIER is not completely installed. Install it, or explicitly save STARTUP_TIER=none before applying."
  fi
  startup_effective="$STARTUP_TIER"

  mkdir -p "$(dirname "$LAUNCHER")" "$UNIT_DIR" "$MODELS_DIR" "$LOCAL_AI_CONFIG_DIR"
  chmod 700 "$LOCAL_AI_CONFIG_DIR"
  service_paths_owned_or_absent || \
    die "Custom, symlinked, mixed, or non-regular service files were preserved. Move $PRESET_FILE, $LAUNCHER, and $UNIT_DIR/$UNIT_NAME explicitly before installing the managed trio."

  # Snapshot a stable unit state before touching even the credential. A unit
  # that is activating/deactivating may already be consuming the old key and
  # must settle before this transaction changes any runtime input.
  service_was_active="$(managed_user_service_active_flag)" || \
    die "$UNIT_NAME is transitioning or unverifiable; wait for it to settle before replacing service inputs."

  # A loopback origin still needs authentication: browser pages can otherwise
  # drive localhost APIs. llama-server reads the key from a 0600 file.
  [[ ! -L "$KEY_FILE" ]] || die "Refusing symlinked API key file: $KEY_FILE"
  if [[ -e "$KEY_FILE" && ! -f "$KEY_FILE" ]]; then
    die "Refusing non-regular API key path: $KEY_FILE"
  fi
  if [[ ! -s "$KEY_FILE" ]]; then
    local key_stage staged_key
    key_stage="$(mktemp "$(dirname "$KEY_FILE")/.llama.key.XXXXXX")" || die "Could not stage a new API key"
    if command -v openssl >/dev/null 2>&1; then
      openssl rand -hex 32 > "$key_stage" || { rm -f -- "$key_stage"; die "Could not generate a new API key"; }
    else
      if ! head -c32 /dev/urandom | od -An -tx1 | tr -d ' \n' > "$key_stage"; then
        rm -f -- "$key_stage"
        die "Could not generate a new API key"
      fi
    fi
    staged_key="$(<"$key_stage")"
    local_ai_api_key_valid "$staged_key" || { rm -f -- "$key_stage"; die "Generated API key failed validation"; }
    chmod 600 "$key_stage" || { rm -f -- "$key_stage"; die "Could not protect staged API key"; }
    mv -- "$key_stage" "$KEY_FILE" || { rm -f -- "$key_stage"; die "Could not atomically install the API key"; }
    ok "Generated llama API key at ${KEY_FILE}"
  else
    chmod 600 "$KEY_FILE"
    ok "Reusing existing llama API key at ${KEY_FILE}"
  fi
  local service_key
  service_key="$(local_ai_api_key_from_file "$KEY_FILE" 2>/dev/null || true)"
  [[ -n "$service_key" ]] || \
    die "Existing API key must contain at least 32 safe characters; replace $KEY_FILE with a token using A-Z, a-z, 0-9, dot, underscore, tilde, or hyphen."

  local stage_dir preset_stage launcher_stage unit_stage verify_unit
  stage_dir="$(mktemp -d "$LOCAL_AI_CONFIG_DIR/.service-stage.XXXXXX")" || die "Could not create service staging directory"
  reset_service_transaction
  SERVICE_TXN_STAGE="$stage_dir"
  SERVICE_TXN_ARMED=1
  trap 'service_transaction_exit_handler' EXIT
  trap 'service_transaction_signal_handler' HUP INT TERM
  preset_stage="$stage_dir/models.ini"
  launcher_stage="$stage_dir/launcher"
  unit_stage="$stage_dir/$UNIT_NAME"
  verify_unit="$stage_dir/verify.service"
  write_model_preset "$preset_stage"
  write_server_launcher "$launcher_stage" "$server_bin"
  write_service_unit "$verify_unit" "$launcher_stage"
  bash -n "$launcher_stage" || { cleanup_service_stage "$stage_dir"; die "Generated launcher failed syntax validation"; }
  if command -v systemd-analyze >/dev/null 2>&1; then
    systemd-analyze --user verify "$verify_unit" || { cleanup_service_stage "$stage_dir"; die "Generated systemd unit failed verification"; }
  fi
  write_service_unit "$unit_stage" "$LAUNCHER"

  local install_failed=0
  if [[ -e "$PRESET_FILE" ]]; then cp -p "$PRESET_FILE" "$stage_dir/backup-preset" || die "Could not back up $PRESET_FILE"; SERVICE_TXN_HAD_PRESET=1; fi
  if [[ -e "$LAUNCHER" ]]; then cp -p "$LAUNCHER" "$stage_dir/backup-launcher" || die "Could not back up $LAUNCHER"; SERVICE_TXN_HAD_LAUNCHER=1; fi
  if [[ -e "$UNIT_DIR/$UNIT_NAME" ]]; then cp -p "$UNIT_DIR/$UNIT_NAME" "$stage_dir/backup-unit" || die "Could not back up $UNIT_DIR/$UNIT_NAME"; SERVICE_TXN_HAD_UNIT=1; fi
  systemctl --user is-enabled --quiet "$UNIT_NAME" 2>/dev/null && SERVICE_TXN_WAS_ENABLED=1 || true
  SERVICE_TXN_WAS_ACTIVE="$service_was_active"

  # Arm file rollback before the first rename so interruption between any two
  # installs still restores the complete prior trio.
  SERVICE_TXN_FILES_TOUCHED=1
  mv "$preset_stage" "$PRESET_FILE" || install_failed=1
  (( install_failed )) || mv "$launcher_stage" "$LAUNCHER" || install_failed=1
  (( install_failed )) || mv "$unit_stage" "$UNIT_DIR/$UNIT_NAME" || install_failed=1
  if (( install_failed )); then
    rollback_service_transaction || true
    trap - EXIT HUP INT TERM
    die "Could not atomically install the staged service files"
  fi

  local activation_failed=0 health_code="" catalog_json startup_status=""
  systemctl --user daemon-reload || activation_failed=1
  (( activation_failed )) || systemctl --user enable "$UNIT_NAME" || activation_failed=1
  # enable --now does not restart an already-active unit; changed ports,
  # presets, contexts, and model limits require an explicit restart.
  (( activation_failed )) || systemctl --user restart "$UNIT_NAME" || activation_failed=1
  (( activation_failed )) || systemctl --user is-active --quiet "$UNIT_NAME" || activation_failed=1
  if (( activation_failed == 0 )) && [[ "$SERVICE_HEALTHCHECK" == 1 ]]; then
    readiness_deadline=$((SECONDS + 30))
    while (( SECONDS < readiness_deadline )); do
      remaining=$((readiness_deadline - SECONDS))
      probe_timeout=2; (( remaining >= probe_timeout )) || probe_timeout="$remaining"
      (( probe_timeout > 0 )) || break
      health_code="$(curl --silent --output /dev/null --write-out '%{http_code}' \
        --max-time "$probe_timeout" "http://127.0.0.1:${PORT}/health" 2>/dev/null || true)"
      case "$health_code" in 200|503) break ;; esac
      (( SECONDS < readiness_deadline )) && sleep 1
    done
    case "$health_code" in 200|503) ;; *) activation_failed=1 ;; esac
    # /health is intentionally unauthenticated and can belong to an unrelated
    # process on a conflicting port. Verify both the auth wall and our private
    # key before committing even when STARTUP_TIER=none skips model warmup.
    if (( activation_failed == 0 )) && ! require_authenticated_api_wall; then
      activation_failed=1
    fi
    # Even with no startup model, prove that the authenticated listener is the
    # llama.cpp router we just configured. A different keyed service on the
    # same port can satisfy /health plus a semantic 404 auth probe.
    if (( activation_failed == 0 )); then
      catalog_json="$(api_curl --max-time 5 "http://127.0.0.1:${PORT}/v1/models?autoload=0" 2>/dev/null || true)"
      if ! router_catalog_matches_installed_tiers "$catalog_json"; then
        activation_failed=1
      fi
    fi
    if (( activation_failed == 0 )) && [[ "$startup_effective" != none ]]; then
      # Router-up (503) is not model-ready. Wait for the configured warm tier to
      # reach a usable process state so `service` never reports a false ready.
      readiness_deadline=$((SECONDS + SERVICE_READY_TIMEOUT))
      while (( SECONDS < readiness_deadline )); do
        remaining=$((readiness_deadline - SECONDS))
        probe_timeout=5; (( remaining >= probe_timeout )) || probe_timeout="$remaining"
        (( probe_timeout > 0 )) || break
        catalog_json="$(api_curl --max-time "$probe_timeout" "http://127.0.0.1:${PORT}/v1/models?autoload=0" 2>/dev/null || true)"
        startup_status="$(jq -r --arg id "$(tier_id "$startup_effective")" \
          '.data[]? | select(.id == $id) | if (.status.failed // false) then "failed" else (.status.value // "unknown") end' \
          <<< "$catalog_json" 2>/dev/null | head -1)"
        case "$startup_status" in loaded|sleeping) health_code=200; break ;; failed) break ;; esac
        (( SECONDS < readiness_deadline )) && sleep 1
      done
      case "$startup_status" in
        loaded|sleeping) ;;
        *) activation_failed=1 ;;
      esac
    fi
    # Type=simple can briefly report a successful restart before the child
    # binds. Re-check the stable unit/MainPID after API readiness; on Linux,
    # also prove that MainPID owns the configured listening socket.
    if (( activation_failed == 0 )) && ! managed_router_unit_owns_listener; then
      activation_failed=1
    fi
  fi
  if (( activation_failed )); then
    warn "New router service failed activation/readiness; restoring the prior files."
    rollback_service_transaction || true
    trap - EXIT HUP INT TERM
    die "Router activation/readiness failed (health=${health_code:-unreachable}, startup=${startup_effective}:${startup_status:-not-ready}); prior configuration restored"
  fi
  commit_service_transaction
  info "Installed per-model preset, launcher, and unit transactionally"
  local me
  me="$(id -un)"
  loginctl enable-linger "$me" 2>/dev/null || sudo loginctl enable-linger "$me" || \
    warn "Could not enable lingering — the server will stop when you log out."

  ok "Service restarted with ${installed} installed tier(s); startup tier: ${startup_effective}. Logs: journalctl --user -fu ${UNIT_NAME}"
}

ensure_pi_settings() {
  # Starter global config — written only if you don't already have one, so your
  # own settings are never clobbered. Local-first defaults: telemetry off.
  local pidir="$HOME/.pi/agent" settings_path settings_tmp
  mkdir -p "$pidir"
  settings_path="$pidir/settings.json"
  if [[ ! -e "$settings_path" && ! -L "$settings_path" ]]; then
    settings_tmp="$(mktemp "$pidir/.settings.json.XXXXXX")" || die "Could not stage pi settings"
    cat > "$settings_tmp" <<'EOF'
{
  "enableInstallTelemetry": false,
  "enableAnalytics": false,
  "compaction": { "enabled": true, "keepRecentTokens": 24000 }
}
EOF
    chmod 600 "$settings_tmp" || { rm -f -- "$settings_tmp"; die "Could not protect staged pi settings"; }
    mv -- "$settings_tmp" "$settings_path" || { rm -f -- "$settings_tmp"; die "Could not atomically install pi settings"; }
    ok "wrote starter ~/.pi/agent/settings.json (telemetry off; auto-compaction on)"
  elif [[ ! -L "$settings_path" && -f "$settings_path" ]]; then
    ok "existing ~/.pi/agent/settings.json found — leaving it alone"
  else
    warn "Non-regular or symlinked ~/.pi/agent/settings.json preserved; create a regular file there manually if pi needs global settings."
  fi
}

cmd_pi() {
  info "Installing the pinned pi coding agent (${PI_VERSION})"
  if command -v pi >/dev/null 2>&1; then
    local current
    current="$(pi --version 2>/dev/null || echo 'version unknown')"
    ok "pi already installed: ${current} (left untouched)"
    [[ "$current" == *"$PI_VERSION"* ]] || warn "Reproducible baseline is ${PI_VERSION}; run '$0 agent-upgrade pi' to replace the existing binary with the configured pinned release."
  else
    command -v npm >/dev/null 2>&1 || die "npm not found — run: $0 install"
    # Pi's official npm path needs no lifecycle scripts. Pinning the exact
    # package lets npm validate the registry SRI instead of executing a mutable
    # curl-to-shell installer.
    mkdir -p "$HOME/.local"
    npm install --global --prefix "$HOME/.local" --ignore-scripts \
      "@earendil-works/pi-coding-agent@${PI_VERSION}"
    ok "pi ${PI_VERSION} installed from the pinned npm package (scripts disabled)"
  fi

  ensure_pi_settings

  add_bashrc_line 'export PATH="$HOME/.local/bin:$PATH"'
  set_managed_shell_export LLAMA_BASE_URL \
    'export LLAMA_BASE_URL=http://127.0.0.1:'"${PORT}" \
    ''
  add_api_key_export
  write_agent_launcher

  cat <<EOF

  Connect pi to the local router (open a new shell so the exports load):

     1. cd into a project and run: pi
     2. /llama  -> load qwen3.8-27b, coder, or qwen3.5-122b-a10b
     3. /model  -> select it for the session

  pi is the manual diagnostic fallback; automatic task routing is configured in
  omp. Add models through this script so revisions and SHA-256 remain pinned.

EOF
}

# ------------------------------- oh-my-pi (omp) ------------------------------

legacy_omp_file() {
  local path="$1" kind="$2"
  [[ ! -L "$path" && -f "$path" ]] || return 1
  case "$kind" in
    models)
      grep -q 'id: Qwen3.8-27B' "$path" &&
        grep -q '^  llamacpp:' "$path" &&
        [[ "$(grep -c '^      - id:' "$path" || true)" == 1 ]]
      ;;
    config)
      grep -q 'default: llamacpp/Qwen3.8-27B' "$path" &&
        grep -q '^compaction:' "$path"
      ;;
  esac
}

omp_file_is_custom() {
  local path="$1" kind="$2"
  [[ -e "$path" || -L "$path" ]] || return 1
  [[ ! -L "$path" ]] || return 0
  grep -q '^# Managed by local-ai-setup' "$path" && return 1
  legacy_omp_file "$path" "$kind" && return 1
  return 0
}

omp_managed_routing_present() {
  local path
  for path in "$OMP_AGENT_DIR/models.yml" "$OMP_AGENT_DIR/config.yml"; do
    if [[ ! -L "$path" && -f "$path" ]] && grep -q '^# Managed by local-ai-setup' "$path"; then
      return 0
    fi
  done
  return 1
}

restore_omp_pair_transaction() {
  (( pair_txn_armed == 1 )) || return 0
  local failed=0
  rm -f -- "$models_path" "$config_path" || failed=1
  if (( had_models )); then cp -a -- "$txn/models.yml" "$models_path" || failed=1; fi
  if (( had_config )); then cp -a -- "$txn/config.yml" "$config_path" || failed=1; fi
  if (( failed == 0 )); then
    rm -f -- "$txn/models.yml" "$txn/config.yml"
    rmdir "$txn" 2>/dev/null || true
    pair_txn_armed=0
  else
    warn "OMP routing rollback was incomplete; recovery copies remain in $txn."
  fi
  return "$failed"
}

omp_pair_exit_handler() {
  local rc=$?
  trap - EXIT HUP INT TERM
  restore_omp_pair_transaction || true
  exit "$rc"
}

omp_pair_signal_handler() {
  trap - EXIT HUP INT TERM
  warn "OMP routing update was interrupted; restoring both prior files."
  restore_omp_pair_transaction || true
  exit 130
}

install_omp_pair() {
  local ompdir="$1" models_tmp="$2" config_tmp="$3" force="$4" parent_transaction="${5:-0}"
  local models_path="$ompdir/models.yml" config_path="$ompdir/config.yml"
  local txn had_models=0 had_config=0 failed=0 backup path pair_txn_armed=0

  for path in "$models_path" "$config_path"; do
    [[ ! -e "$path" && ! -L "$path" ]] || [[ -f "$path" || -L "$path" ]] || {
      warn "Refusing to replace non-file OMP configuration path: $path"
      return 1
    }
  done
  txn="$(mktemp -d "$ompdir/.routing-transaction.XXXXXX")" || return 1
  if [[ -e "$models_path" || -L "$models_path" ]]; then
    cp -a -- "$models_path" "$txn/models.yml" || { rmdir "$txn" 2>/dev/null || true; return 1; }
    had_models=1
  fi
  if [[ -e "$config_path" || -L "$config_path" ]]; then
    cp -a -- "$config_path" "$txn/config.yml" || {
      rm -f -- "$txn/models.yml"
      rmdir "$txn" 2>/dev/null || true
      return 1
    }
    had_config=1
  fi

  # Preserve recognizable legacy files and explicitly forced custom files in
  # user-visible backups before either half of the active pair is changed.
  if (( had_models )) && legacy_omp_file "$models_path" models; then
    backup="${models_path}.pre-multimodel"
    [[ -e "$backup" || -L "$backup" ]] || cp -a -- "$models_path" "$backup" || failed=1
  elif (( had_models && force )) && omp_file_is_custom "$models_path" models; then
    backup="${models_path}.bak.$(date +%Y%m%d%H%M%S).$$"
    cp -a -- "$models_path" "$backup" || failed=1
    (( failed )) || warn "Backed up custom $models_path before explicit replacement: $backup"
  fi
  if (( had_config )) && legacy_omp_file "$config_path" config; then
    backup="${config_path}.pre-multimodel"
    [[ -e "$backup" || -L "$backup" ]] || cp -a -- "$config_path" "$backup" || failed=1
  elif (( had_config && force )) && omp_file_is_custom "$config_path" config; then
    backup="${config_path}.bak.$(date +%Y%m%d%H%M%S).$$"
    cp -a -- "$config_path" "$backup" || failed=1
    (( failed )) || warn "Backed up custom $config_path before explicit replacement: $backup"
  fi

  if (( failed )); then
    rm -f -- "$txn/models.yml" "$txn/config.yml"
    rmdir "$txn" 2>/dev/null || true
    return 1
  fi
  pair_txn_armed=1
  if (( parent_transaction == 0 )); then
    trap 'omp_pair_exit_handler' EXIT
    trap 'omp_pair_signal_handler' HUP INT TERM
  fi
  if ! mv -- "$models_tmp" "$models_path"; then
    restore_omp_pair_transaction || true
    (( parent_transaction )) || trap - EXIT HUP INT TERM
    return 1
  fi
  if ! mv -- "$config_tmp" "$config_path"; then
    warn "OMP routing-pair installation failed; restoring both prior files."
    restore_omp_pair_transaction || true
    (( parent_transaction )) || trap - EXIT HUP INT TERM
    return 1
  fi

  pair_txn_armed=0
  (( parent_transaction )) || trap - EXIT HUP INT TERM
  rm -f -- "$txn/models.yml" "$txn/config.yml"
  rmdir "$txn" 2>/dev/null || true
  ok "Installed OMP models.yml + config.yml as one transactional pair"
}

write_omp_launchers() {
  local force="${1:-0}"
  mkdir -p "$LOCAL_BIN_DIR"
  local tier id launcher backup quoted_omp quoted_key launcher_tmp
  printf -v quoted_omp '%q' "$LOCAL_BIN_DIR/omp"
  printf -v quoted_key '%q' "$KEY_FILE"
  for tier in everyday coder senior; do
    id="$(tier_id "$tier")"
    launcher="$LOCAL_BIN_DIR/omp-${tier}"
    if ! tier_available "$tier"; then
      # Remove only wrappers carrying our marker. Do not leave a command that
      # deterministically routes to an uninstalled model and returns a 404.
      if [[ ! -L "$launcher" && -f "$launcher" ]] && grep -q '^# Managed by local-ai-setup:' "$launcher"; then
        rm -f -- "$launcher"
      fi
      continue
    fi
    if [[ -e "$launcher" || -L "$launcher" ]]; then
      if [[ ! -L "$launcher" && -f "$launcher" ]] && grep -q '^# Managed by local-ai-setup:' "$launcher"; then
        : # safe managed replacement
      elif (( force )); then
        backup="${launcher}.bak.$(date +%Y%m%d%H%M%S).$$"
        cp -a -- "$launcher" "$backup" || die "Could not back up user-owned launcher $launcher"
        warn "Backed up user-owned launcher before explicit replacement: $backup"
      else
        warn "User-owned launcher preserved: $launcher (use routing --force to back it up and replace it)"
        continue
      fi
    fi
    launcher_tmp="$(mktemp "$LOCAL_BIN_DIR/.omp-${tier}.XXXXXX")" || die "Could not stage $launcher"
    cat > "$launcher_tmp" <<EOF
#!/usr/bin/env bash
# Managed by local-ai-setup: force the ${tier} router alias.
set -euo pipefail
omp_bin=${quoted_omp}
if [[ ! -x "\$omp_bin" ]]; then omp_bin="\$(command -v omp 2>/dev/null || true)"; fi
[[ -n "\$omp_bin" && -x "\$omp_bin" ]] || { echo "error: omp is not installed; run '$0 agent-upgrade omp'" >&2; exit 1; }
key_file=${quoted_key}
[[ -s "\$key_file" ]] || { echo "error: API key missing; run '$0 service'" >&2; exit 1; }
LLAMA_API_KEY="\$(<"\$key_file")"
[[ "\$LLAMA_API_KEY" =~ ^[A-Za-z0-9._~-]{32,}\$ ]] || { echo "error: invalid local AI API key" >&2; exit 1; }
export LLAMA_API_KEY
export LLAMA_BASE_URL=http://127.0.0.1:${PORT}
export LLAMA_CPP_BASE_URL=http://127.0.0.1:${PORT}
export PI_NO_TITLE=1
exec "\$omp_bin" --model llamacpp/${id} "\$@"
EOF
    chmod 700 "$launcher_tmp" || { rm -f -- "$launcher_tmp"; die "Could not protect staged launcher"; }
    mv -- "$launcher_tmp" "$launcher" || { rm -f -- "$launcher_tmp"; die "Could not atomically install $launcher"; }
  done
}

ROUTING_TXN_DIR=""
ROUTING_TXN_ARMED=0

routing_transaction_snapshot() {
  local path="$1" label="$2"
  if [[ -e "$path" || -L "$path" ]]; then
    cp -a -- "$path" "$ROUTING_TXN_DIR/$label" || return 1
    : > "$ROUTING_TXN_DIR/$label.present" || return 1
  fi
}

routing_transaction_restore_one() {
  local path="$1" label="$2"
  if [[ -d "$path" && ! -L "$path" ]]; then
    warn "Routing rollback preserved unexpected directory at $path; recovery files remain in $ROUTING_TXN_DIR."
    return 1
  fi
  rm -f -- "$path" || return 1
  if [[ -e "$ROUTING_TXN_DIR/$label.present" ]]; then
    cp -a -- "$ROUTING_TXN_DIR/$label" "$path" || return 1
  fi
}

cleanup_routing_transaction() {
  local label
  [[ -n "$ROUTING_TXN_DIR" && "$ROUTING_TXN_DIR" == "$OMP_AGENT_DIR"/.routing-bundle.* ]] || return 1
  for label in models config launcher-everyday launcher-coder launcher-senior; do
    rm -f -- "$ROUTING_TXN_DIR/$label" "$ROUTING_TXN_DIR/$label.present"
  done
  rmdir "$ROUTING_TXN_DIR" 2>/dev/null || true
  ROUTING_TXN_DIR=""
  ROUTING_TXN_ARMED=0
}

begin_routing_transaction() {
  ROUTING_TXN_DIR="$(mktemp -d "$OMP_AGENT_DIR/.routing-bundle.XXXXXX")" || return 1
  routing_transaction_snapshot "$OMP_AGENT_DIR/models.yml" models &&
    routing_transaction_snapshot "$OMP_AGENT_DIR/config.yml" config &&
    routing_transaction_snapshot "$LOCAL_BIN_DIR/omp-everyday" launcher-everyday &&
    routing_transaction_snapshot "$LOCAL_BIN_DIR/omp-coder" launcher-coder &&
    routing_transaction_snapshot "$LOCAL_BIN_DIR/omp-senior" launcher-senior || {
      cleanup_routing_transaction || true
      return 1
    }
  ROUTING_TXN_ARMED=1
}

rollback_routing_transaction() {
  (( ROUTING_TXN_ARMED == 1 )) || return 0
  local failed=0
  routing_transaction_restore_one "$OMP_AGENT_DIR/models.yml" models || failed=1
  routing_transaction_restore_one "$OMP_AGENT_DIR/config.yml" config || failed=1
  routing_transaction_restore_one "$LOCAL_BIN_DIR/omp-everyday" launcher-everyday || failed=1
  routing_transaction_restore_one "$LOCAL_BIN_DIR/omp-coder" launcher-coder || failed=1
  routing_transaction_restore_one "$LOCAL_BIN_DIR/omp-senior" launcher-senior || failed=1
  if (( failed == 0 )); then
    cleanup_routing_transaction
  else
    warn "Routing rollback was incomplete; recovery files remain in $ROUTING_TXN_DIR."
  fi
  return "$failed"
}

routing_transaction_exit_handler() {
  local rc=$?
  trap - EXIT HUP INT TERM
  rollback_routing_transaction || true
  exit "$rc"
}

routing_transaction_signal_handler() {
  trap - EXIT HUP INT TERM
  warn "OMP routing/launcher update was interrupted; restoring the prior bundle."
  rollback_routing_transaction || true
  exit 130
}

commit_routing_transaction() {
  ROUTING_TXN_ARMED=0
  trap - EXIT HUP INT TERM
  cleanup_routing_transaction
}

omp_semver() {
  local_ai_semver_from_text "$1"
}

omp_binary() {
  local found
  if [[ -x "$LOCAL_BIN_DIR/omp" ]]; then
    printf '%s\n' "$LOCAL_BIN_DIR/omp"
  else
    found="$(command -v omp 2>/dev/null || true)"
    [[ -z "$found" ]] || printf '%s\n' "$found"
  fi
}

cmd_routing() {
  [[ $# -le 1 ]] || die "Usage: $0 routing [--force]"
  [[ $# == 0 || "${1:-}" == --force ]] || die "Usage: $0 routing [--force]"
  local ompdir="$OMP_AGENT_DIR"
  mkdir -p "$ompdir"
  local force=0
  [[ "${1:-}" != "--force" ]] || force=1
  local installed_omp_bin
  installed_omp_bin="$(omp_binary)"
  if [[ -n "$installed_omp_bin" ]]; then
    local installed_omp_output installed_omp_version
    installed_omp_output="$("$installed_omp_bin" --version 2>/dev/null || true)"
    installed_omp_version="$(omp_semver "$installed_omp_output")"
    [[ "$installed_omp_version" == "$OMP_VERSION" ]] || \
      die "Installed omp (${installed_omp_output:-unknown}) does not match the supported pinned version ${OMP_VERSION}; update it before writing v18 routing."
  fi
  if ! tier_available everyday && ! tier_available coder && ! tier_available senior; then
    die "No complete model tier is installed — run '$0 model everyday' before writing OMP routing."
  fi

  local models_tmp
  models_tmp="$(mktemp "$ompdir/.models.yml.local-ai.XXXXXX")" || die "Could not stage OMP models.yml"
  cat > "$models_tmp" <<EOF
# Managed by local-ai-setup. Re-run '$0 routing' after changing model tiers.
providers:
  llamacpp:
    baseUrl: http://127.0.0.1:${PORT}/v1
    api: openai-completions
    apiKey: LLAMA_API_KEY
    authHeader: true
    discovery:
      type: llama.cpp
    models:
EOF
  if tier_available everyday; then
    cat >> "$models_tmp" <<EOF
      - id: ${EVERYDAY_ID}
        name: Qwen 3.8 27B — everyday (local)
        reasoning: true
        imageInputDecoder: stb
        thinking:
          mode: effort
          efforts: [low, medium, xhigh]
          defaultLevel: ${REASONING_EFFORT}
          requiresEffort: false
        input: [text, image]
        contextWindow: ${CTX}
        maxTokens: $(tier_output_tokens everyday)
        cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }
        compat:
          supportsStore: false
          supportsDeveloperRole: false
EOF
  fi
  if tier_available coder; then
    cat >> "$models_tmp" <<EOF
      - id: ${CODER_ID}
        name: Qwen3-Coder-Next — specialist (local)
        reasoning: false
        tokenizer: qwen3
        input: [text]
        contextWindow: ${CODER_CTX}
        maxTokens: $(tier_output_tokens coder)
        cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }
        compat: { supportsStore: false, supportsDeveloperRole: false }
EOF
  fi
  if tier_available senior; then
    cat >> "$models_tmp" <<EOF
      - id: ${SENIOR_ID}
        name: Qwen3.5-122B-A10B — senior (local)
        reasoning: true
        # Qwen3.5 exposes a binary thinking switch, not genuine effort levels.
        # A single symbolic level gives OMP an On/Off surface while the compat
        # flag below suppresses an unsupported reasoning_effort payload.
        thinking:
          mode: effort
          efforts: [low]
          defaultLevel: low
          requiresEffort: false
        input: [text]
        contextWindow: ${SENIOR_CTX}
        maxTokens: $(tier_output_tokens senior)
        cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }
        compat:
          supportsStore: false
          supportsDeveloperRole: false
          supportsReasoningEffort: false
EOF
  fi
  # Never route at an optional alias until its complete file set is installed.
  # Re-running `routing` promotes the role automatically. If tiers were
  # installed out of order, use the first complete one as a temporary default.
  local base_selector="llamacpp/${EVERYDAY_ID}"
  if ! tier_available everyday; then
    if tier_available coder; then
      base_selector="llamacpp/${CODER_ID}"
    elif tier_available senior; then
      base_selector="llamacpp/${SENIOR_ID}"
    else
      warn "No complete model tier is installed; roles become usable after '$0 model'."
    fi
  fi
  local specialist_selector="$base_selector" architect_selector="$base_selector"
  local task_selector="$base_selector" review_selector="$base_selector"
  tier_available coder && specialist_selector="llamacpp/${CODER_ID}"
  tier_available senior && architect_selector="llamacpp/${SENIOR_ID}"
  case "$ROUTING_PROFILE" in
    sticky) ;;
    balanced) task_selector="$specialist_selector" ;;
    quality) task_selector="$specialist_selector"; review_selector="$architect_selector" ;;
  esac

  local config_tmp
  config_tmp="$(mktemp "$ompdir/.config.yml.local-ai.XXXXXX")" || {
    rm -f -- "$models_tmp"
    die "Could not stage OMP config.yml"
  }
  cat > "$config_tmp" <<EOF
# Managed by local-ai-setup. Custom files are preserved unless --force is used.
# Routing profile: ${ROUTING_PROFILE}
setupVersion: 1
symbolPreset: nerd
disabledProviders:
  # A custom authenticated provider is declared in models.yml. Disable OMP's
  # implicit keyless llama.cpp duplicate so it cannot generate stray 401s.
  - llama.cpp
modelRoles:
  default: ${base_selector}
  vision: ${base_selector}
  smol: ${base_selector}
  commit: ${base_selector}
  tiny: ${base_selector}
  title: ${base_selector}
  task: ${task_selector}
  slow: ${review_selector}
  plan: ${review_selector}
  advisor: ${review_selector}
  designer: ${review_selector}
task:
  # One llama.cpp model process/slot is resident at a time on this 128 GiB box.
  maxConcurrency: 1
providers:
  # Prevent concurrent requests from fighting a one-model-at-a-time router.
  maxInFlightRequests:
    llamacpp: 1
advisor:
  # Opt in for hard sessions; enabling it reviews every turn with the senior.
  enabled: false
memory:
  backend: "off"
EOF

  # models.yml and config.yml form one routing configuration. If either active
  # file is custom, preserve the pair atomically: installing only the missing
  # half would leave modelRoles pointing at providers that do not exist.
  local preserve_pair=0
  if (( force == 0 )); then
    if omp_file_is_custom "$ompdir/models.yml" models; then preserve_pair=1; fi
    if omp_file_is_custom "$ompdir/config.yml" config; then preserve_pair=1; fi
  fi
  if (( preserve_pair )); then
    mv "$models_tmp" "$ompdir/models.yml.local-ai-setup.example"
    mv "$config_tmp" "$ompdir/config.yml.local-ai-setup.example"
    warn "Custom OMP configuration was preserved as a pair; no routing files or launchers were changed."
    warn "Review both *.local-ai-setup.example files, or run '$0 routing --force' to back up and replace both."
    return 2
  fi

  begin_routing_transaction || die "Could not snapshot the active OMP routing/launcher bundle"
  trap 'routing_transaction_exit_handler' EXIT
  trap 'routing_transaction_signal_handler' HUP INT TERM
  if ! install_omp_pair "$ompdir" "$models_tmp" "$config_tmp" "$force" 1; then
    rollback_routing_transaction || true
    trap - EXIT HUP INT TERM
    die "Could not install the generated OMP routing pair"
  fi
  write_omp_launchers "$force"
  commit_routing_transaction

  ok "Routing (${ROUTING_PROFILE}): base=${base_selector#llamacpp/} task=${task_selector#llamacpp/} slow/plan/advisor=${review_selector#llamacpp/}"
}

cmd_omp() {
  info "Installing pinned oh-my-pi (omp ${OMP_VERSION})"
  local omp_bin current current_version
  omp_bin="$(omp_binary)"

  if [[ -z "$omp_bin" ]]; then
    if ! command -v bun >/dev/null 2>&1; then
      need_arch
      info "Installing Bun from Arch's signed repository package"
      sudo pacman -Syu --needed --noconfirm bun
    fi
    # Avoid mutable remote installers and dependency lifecycle scripts. The
    # exact npm package version is locked; Bun validates registry integrity.
    mkdir -p "$LOCAL_BIN_DIR" "$HOME/.local/share/bun/install/global"
    BUN_INSTALL_BIN="$LOCAL_BIN_DIR" \
    BUN_INSTALL_GLOBAL_DIR="$HOME/.local/share/bun/install/global" \
      bun install --global --ignore-scripts "@oh-my-pi/pi-coding-agent@${OMP_VERSION}"
    omp_bin="$LOCAL_BIN_DIR/omp"
    [[ -x "$omp_bin" ]] || die "Pinned OMP package installed but did not create $omp_bin"
    current="$("$omp_bin" --version 2>/dev/null || true)"
    current_version="$(omp_semver "$current")"
    [[ "$current_version" == "$OMP_VERSION" ]] || die "Installed OMP reports '${current:-unknown}', expected ${OMP_VERSION}"
    ok "omp ${OMP_VERSION} installed from the pinned package (scripts disabled)"
  else
    current="$("$omp_bin" --version 2>/dev/null || echo 'version unknown')"
    current_version="$(omp_semver "$current")"
    ok "omp already installed: ${current} (left untouched)"
    [[ "$current_version" == "$OMP_VERSION" ]] || \
      die "Existing omp does not match the supported pinned version ${OMP_VERSION}; run '$0 agent-upgrade omp' to install the configured pinned release."
  fi

  local routing_result=0
  if tier_available everyday || tier_available coder || tier_available senior; then
    if cmd_routing; then
      routing_result=0
    else
      routing_result=$?
      (( routing_result == 2 )) || return "$routing_result"
    fi
  else
    warn "OMP is installed, but routing needs at least one complete model tier; run '$0 model everyday', then '$0 routing'."
  fi

  add_bashrc_line 'export PATH="$HOME/.local/bin:$PATH"'
  add_api_key_export
  add_bashrc_line 'export PI_NO_TITLE=1'
  remove_legacy_shell_export 'export OMPX_PARSER_ACTIVE=1'
  write_agent_launcher

  cat <<EOF

  oh-my-pi binary and shell integration are ready. In a new shell (so the exports load):

     cd <your-project>
     omp                       # everyday implementer
     omp-coder                # coding specialist, if installed
     omp-senior               # senior architect/reviewer, if installed

  Active routing profile: ${ROUTING_PROFILE}. Sticky keeps all roles on the
  base model; balanced sends task to coder; quality also sends slow, plan,
  advisor, and designer to senior. Missing optional tiers safely fall back to
  the first installed everyday/coder/senior tier until you download and re-run:
     $0 model coder && $0 model senior && $0 service && $0 routing

  Optional but recommended for omp's IDE features:
     ./$(basename "$0") omp-lsp   # install language servers (LSP is wired into edits)

  If omp reports 401/unauthorized, the LLAMA_API_KEY export is missing from your
  shell. If it emits tool calls as text, verify the selected Qwen model ID and
  llama.cpp chat-template support rather than enabling an external parser.

EOF
  if (( routing_result == 2 )); then
    warn "OMP and shell integration are ready, but your custom routing pair remains active; generated examples were left beside it for review."
    return 2
  fi
}

# Append a POSIX-compatible export to bash and, when active, zsh startup files.
add_bashrc_line() {
  local line="$1" rc
  local rc_files=("$HOME/.bashrc")
  [[ "${SHELL:-}" != */zsh ]] || rc_files+=("$HOME/.zshrc")
  for rc in "${rc_files[@]}"; do
    touch "$rc"
    grep -qxF "$line" "$rc" || printf '%s\n' "$line" >> "$rc"
  done
}

set_managed_shell_export() {
  local name="$1" line="$2" legacy_regex="$3" rc target tmp marker mode
  marker="# managed-by-local-ai-setup: ${name}"
  local rc_files=("$HOME/.bashrc")
  [[ "${SHELL:-}" != */zsh ]] || rc_files+=("$HOME/.zshrc")
  for rc in "${rc_files[@]}"; do
    touch "$rc" || die "Could not create or access shell startup file: $rc"
    target="$rc"
    if [[ -L "$rc" ]]; then
      command -v realpath >/dev/null 2>&1 || \
        die "$rc is a symlink and realpath is unavailable; add the ${name} export to its target manually"
      target="$(realpath "$rc" 2>/dev/null || true)"
      [[ -n "$target" && -f "$target" && ! -L "$target" ]] || \
        die "Refusing shell integration through unresolved/non-regular symlink: $rc"
    fi
    [[ -f "$target" ]] || die "Refusing non-regular shell startup path: $target"
    if awk -v name="$name" -v marker="$marker" '
        $0 ~ ("^export " name "=") && index($0, marker) == 0 { found=1 }
        END { exit(found ? 0 : 1) }
      ' "$target"; then
      warn "Preserving unmarked user-authored ${name} export in $target; the managed value is appended last for this setup."
    fi
    mode="$(stat -c '%a' "$target" 2>/dev/null || stat -f '%Lp' "$target" 2>/dev/null || true)"
    [[ "$mode" =~ ^[0-7]{3,4}$ ]] || die "Could not read permissions for shell startup file: $target"
    tmp="$(mktemp "${target}.local-ai.XXXXXX")" || die "Could not stage shell integration for $target"
    if ! awk -v marker="$marker" -v legacy="$legacy_regex" '
      index($0, marker) { next }
      length(legacy) && $0 ~ legacy { next }
      { print }
    ' "$target" > "$tmp"; then
      rm -f -- "$tmp"
      die "Could not migrate managed ${name} export in $target"
    fi
    printf '%s  %s\n' "$line" "$marker" >> "$tmp" || {
      rm -f -- "$tmp"
      die "Could not stage managed ${name} export in $rc"
    }
    chmod "$mode" "$tmp" || { rm -f -- "$tmp"; die "Could not preserve shell startup permissions"; }
    mv -- "$tmp" "$target" || { rm -f -- "$tmp"; die "Could not install shell integration in $target"; }
  done
}

remove_legacy_shell_export() {
  local line="$1" rc removed=0
  for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
    [[ -f "$rc" ]] || continue
    if grep -qxF "$line" "$rc"; then
      # This exact obsolete line was appended by the previous generated setup;
      # current OMP uses native llama.cpp/Qwen chat-template compatibility.
      if sed --follow-symlinks -i '\|^export OMPX_PARSER_ACTIVE=1$|d' "$rc"; then
        removed=1
      else
        warn "Could not remove obsolete OMPX_PARSER_ACTIVE from $rc; remove that exact line manually."
      fi
    fi
  done
  (( removed == 0 )) || ok "Removed obsolete OMPX_PARSER_ACTIVE shell export"
}

add_api_key_export() {
  local quoted_key_file
  printf -v quoted_key_file '%q' "$KEY_FILE"
  set_managed_shell_export LLAMA_API_KEY \
    "export LLAMA_API_KEY=\$(<${quoted_key_file})" \
    ''
}

write_agent_launcher() {
  local launcher="$LOCAL_BIN_DIR/local-ai-agent" quoted_bin quoted_key quoted_local_bin launcher_tmp
  mkdir -p "$LOCAL_BIN_DIR"
  if [[ -e "$launcher" || -L "$launcher" ]]; then
    if [[ -L "$launcher" || ! -f "$launcher" ]] || ! grep -q '^# Managed by local-ai-setup: selected agent launcher' "$launcher"; then
      warn "User-owned $launcher was preserved; invoke ${AGENT} directly or move it before rerunning."
      return 0
    fi
  fi
  printf -v quoted_bin '%q' "$LOCAL_BIN_DIR/$AGENT"
  printf -v quoted_key '%q' "$KEY_FILE"
  printf -v quoted_local_bin '%q' "$LOCAL_BIN_DIR"
  launcher_tmp="$(mktemp "$LOCAL_BIN_DIR/.local-ai-agent.XXXXXX")" || die "Could not stage $launcher"
  cat > "$launcher_tmp" <<EOF
#!/usr/bin/env bash
# Managed by local-ai-setup: selected agent launcher (${AGENT}).
set -euo pipefail
export PATH=${quoted_local_bin}:"\$PATH"
agent_bin=${quoted_bin}
if [[ ! -x "\$agent_bin" ]]; then agent_bin="\$(command -v ${AGENT} 2>/dev/null || true)"; fi
[[ -n "\$agent_bin" && -x "\$agent_bin" ]] || { echo "error: ${AGENT} is not installed; run '$0 agent-upgrade ${AGENT}'" >&2; exit 1; }
key_file=${quoted_key}
[[ -s "\$key_file" ]] || { echo "error: API key missing; run '$0 service'" >&2; exit 1; }
LLAMA_API_KEY="\$(<"\$key_file")"
[[ "\$LLAMA_API_KEY" =~ ^[A-Za-z0-9._~-]{32,}\$ ]] || { echo "error: invalid local AI API key" >&2; exit 1; }
export LLAMA_API_KEY
export LLAMA_BASE_URL=http://127.0.0.1:${PORT}
export LLAMA_CPP_BASE_URL=http://127.0.0.1:${PORT}
export PI_NO_TITLE=1
exec "\$agent_bin" "\$@"
EOF
  chmod 700 "$launcher_tmp" || { rm -f -- "$launcher_tmp"; die "Could not protect staged agent launcher"; }
  mv -- "$launcher_tmp" "$launcher" || { rm -f -- "$launcher_tmp"; die "Could not atomically install $launcher"; }
  ok "Installed same-shell agent launcher: $launcher"
}

cmd_omp_lsp() {
  info "Installing common language servers for omp's LSP integration"
  # These power omp's rename/refactor/diagnostics-on-edit. Install what matches
  # the languages you work in; the rest are harmless to skip.
  if command -v pacman >/dev/null 2>&1; then
    if ! sudo pacman -Syu --needed --noconfirm \
      bash-language-server typescript-language-server \
      python-lsp-server gopls rust-analyzer clang 2>/dev/null \
    ; then
      warn "Some LSP packages weren't found in the repos — install the ones you need by hand."
      return 1
    fi
  fi
  ok "LSP servers installed (omp auto-detects them per language)."
}

# Install whichever agent is selected.
cmd_agent() {
  case "$AGENT" in
    pi)  cmd_pi ;;
    omp) cmd_omp ;;
    *)   die "Unknown AGENT '$AGENT' (expected: pi | omp). Set it with: $0 save-config AGENT=omp" ;;
  esac
}

cmd_agent_upgrade() {
  [[ $# -le 1 ]] || die "Usage: $0 agent-upgrade [pi|omp]"
  local target="${1:-$AGENT}" binary output version routing_result=0
  case "$target" in
    pi)
      command -v npm >/dev/null 2>&1 || die "npm not found — run: $0 install"
      mkdir -p "$HOME/.local"
      npm install --global --prefix "$HOME/.local" --ignore-scripts \
        "@earendil-works/pi-coding-agent@${PI_VERSION}"
      binary="$LOCAL_BIN_DIR/pi"
      [[ -x "$binary" ]] || die "Pinned pi package did not create $binary"
      output="$("$binary" --version 2>/dev/null || true)"
      [[ "$output" == *"$PI_VERSION"* ]] || die "Upgraded pi reports '${output:-unknown}', expected ${PI_VERSION}"
      add_bashrc_line 'export PATH="$HOME/.local/bin:$PATH"'
      set_managed_shell_export LLAMA_BASE_URL \
        'export LLAMA_BASE_URL=http://127.0.0.1:'"${PORT}" \
        ''
      add_api_key_export
      [[ "$AGENT" != pi ]] || write_agent_launcher
      ok "Upgraded pi to pinned version ${PI_VERSION}"
      ;;
    omp)
      if ! command -v bun >/dev/null 2>&1; then
        need_arch
        sudo pacman -Syu --needed --noconfirm bun
      fi
      mkdir -p "$LOCAL_BIN_DIR" "$HOME/.local/share/bun/install/global"
      BUN_INSTALL_BIN="$LOCAL_BIN_DIR" \
      BUN_INSTALL_GLOBAL_DIR="$HOME/.local/share/bun/install/global" \
        bun install --global --ignore-scripts "@oh-my-pi/pi-coding-agent@${OMP_VERSION}"
      binary="$LOCAL_BIN_DIR/omp"
      [[ -x "$binary" ]] || die "Pinned OMP package did not create $binary"
      output="$("$binary" --version 2>/dev/null || true)"
      version="$(omp_semver "$output")"
      [[ "$version" == "$OMP_VERSION" ]] || die "Upgraded OMP reports '${output:-unknown}', expected ${OMP_VERSION}"
      if tier_available everyday || tier_available coder || tier_available senior; then
        if cmd_routing; then routing_result=0; else routing_result=$?; (( routing_result == 2 )) || return "$routing_result"; fi
      else
        warn "OMP was upgraded, but routing needs at least one complete model tier; run '$0 model everyday' first."
      fi
      add_bashrc_line 'export PATH="$HOME/.local/bin:$PATH"'
      add_api_key_export
      add_bashrc_line 'export PI_NO_TITLE=1'
      remove_legacy_shell_export 'export OMPX_PARSER_ACTIVE=1'
      [[ "$AGENT" != omp ]] || write_agent_launcher
      ok "Upgraded OMP to pinned version ${OMP_VERSION}"
      (( routing_result == 0 )) || warn "Custom OMP routing remains active; generated examples were refreshed."
      ;;
    *) die "Usage: $0 agent-upgrade [pi|omp]" ;;
  esac
}

cmd_show_config() {
  info "Effective configuration (environment > $SETUP_ENV > defaults):"
  local k
  for k in $CONFIG_KEYS; do printf '    %-18s= %s\n' "$k" "${!k}"; done
  [[ -f "$SETUP_ENV" ]] || echo "    (no saved file yet — these are defaults/env)"
}

# save-config KEY=VALUE [KEY=VALUE ...]  — persist tunables.
cmd_save_config() {
  (( $# > 0 )) || die "Usage: $0 save-config KEY=VALUE [KEY=VALUE ...]"
  local pair k v
  for pair in "$@"; do
    [[ "$pair" == *=* ]] || die "Expected KEY=VALUE, got: $pair"
    k="${pair%%=*}"; v="${pair#*=}"
    if [[ "$k" == MODELS_MAX && "$v" =~ ^[0-9]+$ ]] && (( v > 1 )); then
      die "MODELS_MAX is fixed at 1 on this 128 GiB target; multi-resident large-model services are not generated."
    fi
    case " $CONFIG_KEYS " in
      *" $k "*) printf -v "$k" '%s' "$v" ;;
      *) die "Unknown config key: $k (allowed: $CONFIG_KEYS)" ;;
    esac
  done
  validate_config
  save_config
  cmd_show_config
}

cmd_plan() {
  [[ $# == 0 ]] || die "Usage: $0 plan"
  local tier artifacts bytes base="" specialist architect task review startup blocked=0 complete=0
  local server_bin preflight_rc installed_omp_bin installed_omp_output installed_omp_version
  echo "Resolved local-AI plan (read-only; no files or services were changed):"
  echo "  agent=${AGENT} routing=${ROUTING_PROFILE} models-max=${MODELS_MAX} KV=${KV_CACHE_PROFILE}"
  echo "  contexts: everyday=${CTX} coder=${CODER_CTX} senior=${SENIOR_CTX}"
  echo "  load modes: everyday=${LOAD_MODE_EVERYDAY} coder=${LOAD_MODE_CODER} senior=${LOAD_MODE_SENIOR}"
  for tier in everyday coder senior; do
    if tier_available "$tier"; then artifacts=installed; complete=$((complete + 1)); elif tier_any_file "$tier"; then artifacts=partial; else artifacts=absent; fi
    bytes="$(tier_required_bytes "$tier")"
    printf '  %-9s artifacts=%-9s required=%s id=%s\n' "$tier" "$artifacts" "$(human_bytes "$bytes")" "$(tier_id "$tier")"
  done
  if tier_available everyday; then base="$EVERYDAY_ID"; elif tier_available coder; then base="$CODER_ID"; elif tier_available senior; then base="$SENIOR_ID"; else base='(blocked: install a complete tier)'; fi
  specialist="$base"; architect="$base"
  tier_available coder && specialist="$CODER_ID"
  tier_available senior && architect="$SENIOR_ID"
  task="$base"; review="$base"
  case "$ROUTING_PROFILE" in balanced) task="$specialist" ;; quality) task="$specialist"; review="$architect" ;; esac
  startup="$(effective_startup_tier)"
  echo "  OMP roles: base=${base} task=${task} slow/plan/advisor/designer=${review} (advisor disabled)"
  echo "  service: startup=${startup} port=${PORT} preset=${PRESET_FILE}"
  if (( complete == 0 )); then blocked=1; fi
  if tier_manifest_any_file everyday && ! tier_available everyday; then
    echo "  gate: selected everyday QUANT=$QUANT is incomplete while managed everyday artifacts exist"
    blocked=1
  fi
  if [[ "$STARTUP_TIER" != none ]] && ! tier_available "$STARTUP_TIER"; then
    echo "  gate: configured STARTUP_TIER=$STARTUP_TIER is not installed"
    blocked=1
  fi
  local refresh_omp=0
  [[ "$AGENT" == omp ]] && refresh_omp=1
  omp_managed_routing_present && refresh_omp=1
  if (( refresh_omp )) && { omp_file_is_custom "$OMP_AGENT_DIR/models.yml" models || omp_file_is_custom "$OMP_AGENT_DIR/config.yml" config; }; then
    echo "  gate: custom OMP routing pair will be preserved; review generated examples or run '$0 routing --force' explicitly"
    blocked=1
  fi
  if ! service_paths_owned_or_absent; then
    echo "  gate: custom/symlinked/mixed service preset, launcher, or unit will be preserved; move the trio explicitly before apply"
    blocked=1
  fi
  if server_bin="$(llama_server_preflight)"; then
    echo "  gate: compatible llama-server found at ${server_bin}"
  else
    preflight_rc=$?
    if (( preflight_rc == 1 )); then
      echo "  gate: llama-server is not installed (run '$0 install')"
    else
      echo "  gate: llama-server lacks required router/MTP/reasoning/cache options (complete the Arch update)"
    fi
    blocked=1
  fi
  if (( refresh_omp )); then
    installed_omp_bin="$(omp_binary)"
    if [[ -z "$installed_omp_bin" ]]; then
      if [[ "$AGENT" == omp ]]; then
        echo "  gate: OMP is not installed (run '$0 agent' or '$0 omp')"
        blocked=1
      else
        echo "  gate: managed OMP routing will be refreshed for consistency (OMP binary is not currently installed)"
      fi
    else
      installed_omp_output="$("$installed_omp_bin" --version 2>/dev/null || true)"
      installed_omp_version="$(omp_semver "$installed_omp_output")"
      if [[ "$installed_omp_version" != "$OMP_VERSION" ]]; then
        echo "  gate: installed OMP is ${installed_omp_output:-unknown}; pinned schema requires ${OMP_VERSION} (run '$0 agent-upgrade omp')"
        blocked=1
      else
        echo "  gate: compatible OMP ${OMP_VERSION} found at ${installed_omp_bin}"
      fi
    fi
  fi
  if system_reboot_required; then
    if [[ "$ALLOW_PENDING_REBOOT" == 1 ]]; then
      echo "  gate: WARNING — reboot/runtime-state check explicitly bypassed for this run (ALLOW_PENDING_REBOOT=1)"
    else
      echo "  gate: reboot required before apply/service"
      blocked=1
    fi
  else
    echo "  gate: runtime kernel/TTM state is ready"
  fi
  echo "  apply will persist setup.env, transactionally restart the router, update selected-agent routing, and refresh managed launchers."
  if (( blocked )); then
    warn "Plan is unresolved; satisfy the gate(s) above before apply."
    return 1
  fi
}

APPLY_TXN_DIR=""
APPLY_SERVICE_PHASE=0
APPLY_SERVICE_WAS_ACTIVE=0
APPLY_SERVICE_WAS_ENABLED=0

apply_snapshot_path() {
  local path="$1" label="$2"
  if [[ -e "$path" || -L "$path" ]]; then
    cp -a -- "$path" "$APPLY_TXN_DIR/$label" || return 1
    : > "$APPLY_TXN_DIR/$label.present" || return 1
  fi
}

apply_restore_path() {
  local path="$1" label="$2"
  if [[ -d "$path" && ! -L "$path" ]]; then
    warn "Rollback preserved unexpected directory at $path; restore $label manually from $APPLY_TXN_DIR."
    return 1
  fi
  rm -f -- "$path" || return 1
  if [[ -f "$APPLY_TXN_DIR/$label.present" ]]; then
    mkdir -p "$(dirname "$path")" || return 1
    cp -a -- "$APPLY_TXN_DIR/$label" "$path" || return 1
  fi
}

cleanup_apply_transaction() {
  [[ -n "$APPLY_TXN_DIR" && "$APPLY_TXN_DIR" == "$LOCAL_AI_CONFIG_DIR"/.apply-transaction.* ]] || return 0
  rm -f -- "$APPLY_TXN_DIR"/* "$APPLY_TXN_DIR"/.*.present 2>/dev/null || true
  rmdir "$APPLY_TXN_DIR" 2>/dev/null || true
  APPLY_TXN_DIR=""
}

rollback_apply_files() {
  [[ -n "$APPLY_TXN_DIR" ]] || return 0
  local failed=0
  apply_restore_path "$SETUP_ENV" setup.env || failed=1
  apply_restore_path "$OMP_AGENT_DIR/models.yml" omp-models.yml || failed=1
  apply_restore_path "$OMP_AGENT_DIR/config.yml" omp-config.yml || failed=1
  apply_restore_path "$LOCAL_BIN_DIR/local-ai-agent" local-ai-agent || failed=1
  apply_restore_path "$LOCAL_BIN_DIR/omp-everyday" omp-everyday || failed=1
  apply_restore_path "$LOCAL_BIN_DIR/omp-coder" omp-coder || failed=1
  apply_restore_path "$LOCAL_BIN_DIR/omp-senior" omp-senior || failed=1
  if (( APPLY_SERVICE_PHASE )); then
    apply_restore_path "$PRESET_FILE" service-preset || failed=1
    apply_restore_path "$LAUNCHER" service-launcher || failed=1
    apply_restore_path "$UNIT_DIR/$UNIT_NAME" service-unit || failed=1
    systemctl --user daemon-reload || failed=1
    if (( APPLY_SERVICE_WAS_ENABLED )); then
      systemctl --user enable "$UNIT_NAME" >/dev/null 2>&1 || failed=1
    else
      systemctl --user disable "$UNIT_NAME" >/dev/null 2>&1 || true
    fi
    if (( APPLY_SERVICE_WAS_ACTIVE )); then
      systemctl --user restart "$UNIT_NAME" || failed=1
    else
      systemctl --user stop "$UNIT_NAME" >/dev/null 2>&1 || true
    fi
  fi
  (( failed == 0 )) || warn "Apply rollback was incomplete; backups remain in $APPLY_TXN_DIR."
  (( failed != 0 )) || cleanup_apply_transaction
  return "$failed"
}

apply_signal_handler() {
  trap - HUP INT TERM
  warn "Apply was interrupted; restoring the prior desired/routing files."
  rollback_apply_files || true
  exit 130
}

cmd_apply() {
  [[ $# == 0 ]] || die "Usage: $0 apply"
  cmd_plan || die "Apply preflight failed; no desired or live configuration was changed."

  mkdir -p "$LOCAL_AI_CONFIG_DIR"
  chmod 700 "$LOCAL_AI_CONFIG_DIR"
  APPLY_TXN_DIR="$(mktemp -d "$LOCAL_AI_CONFIG_DIR/.apply-transaction.XXXXXX")" || \
    die "Could not create apply transaction directory"
  apply_snapshot_path "$SETUP_ENV" setup.env || { cleanup_apply_transaction; die "Could not snapshot setup.env"; }
  apply_snapshot_path "$OMP_AGENT_DIR/models.yml" omp-models.yml || { cleanup_apply_transaction; die "Could not snapshot OMP models.yml"; }
  apply_snapshot_path "$OMP_AGENT_DIR/config.yml" omp-config.yml || { cleanup_apply_transaction; die "Could not snapshot OMP config.yml"; }
  apply_snapshot_path "$LOCAL_BIN_DIR/local-ai-agent" local-ai-agent || { cleanup_apply_transaction; die "Could not snapshot selected-agent launcher"; }
  apply_snapshot_path "$LOCAL_BIN_DIR/omp-everyday" omp-everyday || { cleanup_apply_transaction; die "Could not snapshot everyday launcher"; }
  apply_snapshot_path "$LOCAL_BIN_DIR/omp-coder" omp-coder || { cleanup_apply_transaction; die "Could not snapshot coder launcher"; }
  apply_snapshot_path "$LOCAL_BIN_DIR/omp-senior" omp-senior || { cleanup_apply_transaction; die "Could not snapshot senior launcher"; }
  apply_snapshot_path "$PRESET_FILE" service-preset || { cleanup_apply_transaction; die "Could not snapshot service preset"; }
  apply_snapshot_path "$LAUNCHER" service-launcher || { cleanup_apply_transaction; die "Could not snapshot service launcher"; }
  apply_snapshot_path "$UNIT_DIR/$UNIT_NAME" service-unit || { cleanup_apply_transaction; die "Could not snapshot service unit"; }
  APPLY_SERVICE_WAS_ACTIVE="$(managed_user_service_active_flag)" || {
    cleanup_apply_transaction
    die "$UNIT_NAME is transitioning or unverifiable; wait for it to settle before apply."
  }
  systemctl --user is-enabled --quiet "$UNIT_NAME" 2>/dev/null && APPLY_SERVICE_WAS_ENABLED=1 || true
  trap 'apply_signal_handler' HUP INT TERM

  if ! (save_config); then
    rollback_apply_files || true
    trap - HUP INT TERM
    die "Could not persist the staged desired configuration"
  fi

  if [[ "$AGENT" == omp ]] || omp_managed_routing_present; then
    if ! (cmd_routing); then
      rollback_apply_files || true
      trap - HUP INT TERM
      die "OMP routing failed; prior desired/routing files were restored and the router was not changed."
    fi
  else
    info "AGENT=pi uses manual model selection; no managed OMP routing was present to refresh."
  fi
  if ! (write_agent_launcher); then
    rollback_apply_files || true
    trap - HUP INT TERM
    die "Agent-launcher generation failed; prior desired/routing files were restored and the router was not changed."
  fi
  APPLY_SERVICE_PHASE=1
  if ! (cmd_service); then
    rollback_apply_files || true
    trap - HUP INT TERM
    die "Router apply failed; prior desired/routing files were restored."
  fi
  cleanup_apply_transaction
  trap - HUP INT TERM
  ok "Applied persisted runtime and ${AGENT} routing configuration as one coordinated transaction."
}

KERNEL_TXN_ARMED=0
KERNEL_TXN_FILES_TOUCHED=0
KERNEL_TXN_TARGET=""
KERNEL_TXN_TARGET_BACKUP=""
KERNEL_TXN_HAD_TARGET=0
KERNEL_TXN_LEGACY=""
KERNEL_TXN_LEGACY_BACKUP=""
KERNEL_TXN_HAD_LEGACY=0

reset_kernel_transaction() {
  KERNEL_TXN_ARMED=0
  KERNEL_TXN_FILES_TOUCHED=0
  KERNEL_TXN_TARGET=""
  KERNEL_TXN_TARGET_BACKUP=""
  KERNEL_TXN_HAD_TARGET=0
  KERNEL_TXN_LEGACY=""
  KERNEL_TXN_LEGACY_BACKUP=""
  KERNEL_TXN_HAD_LEGACY=0
}

rollback_kernel_transaction() {
  (( KERNEL_TXN_ARMED == 1 )) || return 0
  local failed=0
  if (( KERNEL_TXN_FILES_TOUCHED )); then
    if (( KERNEL_TXN_HAD_TARGET )); then
      sudo cp -p "$KERNEL_TXN_TARGET_BACKUP" "$KERNEL_TXN_TARGET" || failed=1
    else
      sudo rm -f "$KERNEL_TXN_TARGET" || failed=1
    fi
    if (( KERNEL_TXN_HAD_LEGACY )); then
      sudo cp -p "$KERNEL_TXN_LEGACY_BACKUP" "$KERNEL_TXN_LEGACY" || failed=1
    else
      sudo rm -f "$KERNEL_TXN_LEGACY" || failed=1
    fi
    # amd-ttm may have rebuilt initramfs before failing or receiving a signal.
    # Rebuild from the restored files so the next boot cannot use a partially
    # applied TTM policy.
    sudo mkinitcpio -P || failed=1
  fi
  if (( failed == 0 )); then
    reset_kernel_transaction
  else
    warn "Kernel-tweak rollback was incomplete. Recovery copies remain at ${KERNEL_TXN_TARGET_BACKUP:-none} and ${KERNEL_TXN_LEGACY_BACKUP:-none}."
  fi
  return "$failed"
}

kernel_transaction_exit_handler() {
  local rc=$?
  trap - EXIT HUP INT TERM
  rollback_kernel_transaction || true
  exit "$rc"
}

kernel_transaction_signal_handler() {
  trap - EXIT HUP INT TERM
  warn "Kernel tweak was interrupted; restoring the prior TTM files and initramfs."
  rollback_kernel_transaction || true
  exit 130
}

commit_kernel_transaction() {
  KERNEL_TXN_ARMED=0
  trap - EXIT HUP INT TERM
  reset_kernel_transaction
}

cmd_kernel_tweaks() {
  need_arch
  info "OPTIONAL: raise GPU-addressable unified memory to ~${GTT_GIB} GiB"
  echo
  echo "  Not needed for the everyday model; keep the stock allocation for baseline tests."
  echo "  Consider this only for the senior model, Q8 plus very large context, or"
  echo "  another model that cannot fully offload with the stock allocation."
  echo
  echo "  This uses AMD's amd-ttm helper to persist only TTM pages_limit. It may"
  echo "  rebuild initramfs and request a reboot; deprecated amdgpu.gttsize and"
  echo "  page_pool_size settings are intentionally not written."
  echo
  local reply=""
  read -r -p "Proceed? [y/N] " reply || true
  [[ "$reply" =~ ^[Yy]$ ]] || { warn "Skipped."; return 0; }

  info "Ensuring AMD's recommended Arch amd-debug-tools package is current"
  sudo pacman -Syu --needed --noconfirm amd-debug-tools || die "Could not install/update amd-debug-tools"
  command -v amd-ttm >/dev/null 2>&1 || die "amd-ttm was not installed by amd-debug-tools"
  local target backup="" had_previous=0 legacy legacy_backup="" conflicts file
  target=/etc/modprobe.d/ttm.conf
  legacy=/etc/modprobe.d/99-strix-halo-llm.conf

  # First perform every read-only conflict/customization check. No active file
  # is moved until we know the complete migration can proceed.
  sudo test -L "$target" && die "Symlinked TTM policy was preserved at $target; replace or merge it explicitly before using amd-ttm."
  sudo test -L "$legacy" && die "Symlinked legacy GTT policy was preserved at $legacy; replace or merge it explicitly before using amd-ttm."
  if sudo test -e "$target" && ! sudo test -f "$target"; then
    die "Non-regular TTM policy was preserved at $target; replace or merge it explicitly before using amd-ttm."
  fi
  if sudo test -e "$legacy" && ! sudo test -f "$legacy"; then
    die "Non-regular legacy GTT policy was preserved at $legacy; replace or merge it explicitly before using amd-ttm."
  fi
  conflicts="$(sudo grep -ERl --include='*.conf' \
    'options[[:space:]]+amdgpu.*gttsize|options[[:space:]]+ttm.*(pages_limit|page_pool_size)' \
    /etc/modprobe.d 2>/dev/null || true)"
  while IFS= read -r file; do
    [[ -z "$file" || "$file" == "$target" || "$file" == "$legacy" ]] || \
      die "Conflicting GTT/TTM settings remain in $file; merge/remove them explicitly before using amd-ttm."
  done <<< "$conflicts"

  if sudo test -f "$legacy"; then
    if ! sudo grep -q '^# Generated by setup-qwen38-pi.sh' "$legacy" || \
       ! sudo awk '
         NF && !/^#/ {
           n++
           if ($0 ~ /^options amdgpu gttsize=[0-9]+$/) a++
           else if ($0 ~ /^options ttm pages_limit=[0-9]+ page_pool_size=[0-9]+$/) t++
           else bad=1
         }
         END { exit !(n == 2 && a == 1 && t == 1 && !bad) }
       ' "$legacy"; then
      die "A custom legacy GTT file exists at $legacy. Remove deprecated gttsize/page_pool_size settings manually before using amd-ttm."
    fi
  fi
  if sudo test -f "$target" && \
     ! sudo awk 'NF && !/^#/ && $0 !~ /^options ttm pages_limit=[0-9]+$/ { bad=1 } END { exit bad }' "$target" && \
     [[ "${KERNEL_TWEAKS_FORCE:-0}" != 1 ]]; then
    die "Existing custom $target was preserved. Merge it manually or rerun with KERNEL_TWEAKS_FORCE=1 to back it up before amd-ttm replaces it."
  fi

  if sudo test -f "$target"; then
    # amd-ttm itself writes a single pages_limit line. Preserve/refuse any richer
    # hand-maintained TTM policy unless the user explicitly opts into a backup.
    backup="$(sudo mktemp "${target}.bak.XXXXXX")" || die "Could not create a backup for $target"
    sudo cp -p "$target" "$backup" || die "Could not back up $target"
    had_previous=1
  fi

  # Back up every active file before removing either one. This keeps a failure
  # while preparing ttm.conf from leaving the old generated policy inactive.
  if sudo test -f "$legacy"; then
    legacy_backup="$(sudo mktemp "${legacy}.pre-amd-ttm.XXXXXX")" || die "Could not back up $legacy"
    sudo cp -p "$legacy" "$legacy_backup" || die "Could not back up $legacy"
  fi

  reset_kernel_transaction
  KERNEL_TXN_TARGET="$target"
  KERNEL_TXN_TARGET_BACKUP="$backup"
  KERNEL_TXN_HAD_TARGET="$had_previous"
  KERNEL_TXN_LEGACY="$legacy"
  KERNEL_TXN_LEGACY_BACKUP="$legacy_backup"
  [[ -z "$legacy_backup" ]] || KERNEL_TXN_HAD_LEGACY=1
  KERNEL_TXN_ARMED=1
  trap 'kernel_transaction_exit_handler' EXIT
  trap 'kernel_transaction_signal_handler' HUP INT TERM

  if (( KERNEL_TXN_HAD_LEGACY )); then
    # Conservatively arm rollback before the first unlink. A signal between
    # this removal and amd-ttm must restore both policy files.
    KERNEL_TXN_FILES_TOUCHED=1
    sudo rm -f "$legacy" || die "Could not remove the deprecated generated file $legacy"
    ok "Migrated deprecated generated GTT config (backup: $legacy_backup)"
  fi
  KERNEL_TXN_FILES_TOUCHED=1
  if ! sudo amd-ttm --set "$GTT_GIB"; then
    warn "amd-ttm failed; restoring the prior TTM configuration."
    trap - EXIT HUP INT TERM
    rollback_kernel_transaction || true
    die "GTT tweak was not applied"
  fi
  commit_kernel_transaction

  ok "amd-ttm configured a ${GTT_GIB} GiB TTM pages limit; follow its reboot guidance."
  [[ -z "$backup" ]] || ok "Previous modprobe configuration backup: $backup"
  [[ -z "$legacy_backup" ]] || ok "Deprecated configuration backup retained: $legacy_backup"
  echo
  echo "  IOMMU remains enabled. This script never disables that security,"
  echo "  virtualization, and device-isolation feature. Benchmark the stock system"
  echo "  first; only A/B test IOMMU changes later if you understand the tradeoff."
  echo
  echo "  BIOS reminder (Framework Desktop): leave iGPU Memory Allocation at the"
  echo "  small/default (512MB) setting — on Linux, models live in GTT, not the"
  echo "  dedicated carveout."
}

cmd_bench_raw() {
  local tier="$1" file bench_help
  local -a bench_args
  tier_available "$tier" || die "$tier model is incomplete — run: $0 model $tier"
  file="$(tier_file "$tier" main)"
  command -v llama-bench >/dev/null 2>&1 || die "llama-bench not found — run: $0 install"
  bench_help="$(llama-bench --help 2>&1 || true)"
  help_has_option "$bench_help" --load-mode || die "llama-bench is too old (missing --load-mode); update llama.cpp first"
  require_router_fully_stopped "running llama-bench so no mapped model skews fitting"
  command -v sha256sum >/dev/null 2>&1 || die "sha256sum is required (install coreutils)"
  info "Verifying locked $tier artifacts before benchmarking"
  verify_tier_integrity "$tier" 0 cached || die "$tier files do not match models.lock; refusing to load them"

  info "Benchmarking $(tier_label "$tier") (pp512 prompt processing; tg128 generation)"
  bench_args=(--model "$file" --flash-attn on --load-mode "$(tier_load_mode "$tier")" --n-prompt 512 --n-gen 128)
  if [[ "$tier" == senior ]]; then
    help_has_option "$bench_help" --fit-target || \
      die "llama-bench is too old (missing --fit-target); update llama.cpp first"
    # This is a free-device-memory margin, not an allocation cap. Let the
    # fitter choose a mixed GPU/CPU placement while leaving a conservative
    # 4 GiB of addressable memory free. Verbose mode exposes its tensor/layer
    # placement instead of reducing the result to an ambiguous ngl count.
    bench_args+=(--fit-target 4096 --verbose)
  else
    # Current llama-bench spells full offload as -1; unlike llama-server it
    # does not accept the word "all" for this integer option.
    bench_args+=(--n-gpu-layers -1)
  fi
  llama-bench "${bench_args[@]}"
  echo
  echo "  This is a raw single-model benchmark. The everyday router preset also uses"
  echo "  MTP speculative decoding, which llama-bench above does not exercise."
  if [[ "$tier" == senior ]]; then
    echo "  Senior used llama.cpp auto-fit with a 4 GiB free-device-memory margin;"
    echo "  layer placement is reported in the benchmark output."
  fi
}

BENCH_TXN_ARMED=0
BENCH_TXN_WAS_ACTIVE=0

restore_bench_service_transaction() {
  (( BENCH_TXN_ARMED )) || return 0
  local failed=0
  if (( BENCH_TXN_WAS_ACTIVE )); then
    systemctl --user start "$UNIT_NAME" || failed=1
    (( failed )) || wait_for_managed_router_control_plane 30 || failed=1
  fi
  BENCH_TXN_ARMED=0
  return "$failed"
}

bench_service_exit_handler() {
  local rc=$?
  trap - EXIT HUP INT TERM
  restore_bench_service_transaction || true
  exit "$rc"
}

bench_service_signal_handler() {
  trap - EXIT HUP INT TERM
  warn "Raw benchmark was interrupted; restoring the prior router service state."
  restore_bench_service_transaction || true
  exit 130
}

cmd_bench() {
  [[ $# -le 2 ]] || die "Usage: $0 bench [everyday|coder|senior] [--manage-service]"
  local tier="${1:-everyday}" manage_service=0 was_active restore_failed=0
  if [[ "$tier" == --manage-service ]]; then tier=everyday; manage_service=1; fi
  if (( $# == 2 )); then
    [[ "$2" == --manage-service ]] || die "Usage: $0 bench [everyday|coder|senior] [--manage-service]"
    manage_service=1
  fi
  case "$tier" in everyday|coder|senior) ;; *) die "Usage: $0 bench [everyday|coder|senior] [--manage-service]" ;; esac
  if (( manage_service == 0 )); then
    cmd_bench_raw "$tier"
    return
  fi

  was_active="$(managed_user_service_active_flag)" || \
    die "The router service is transitioning or unverifiable; wait for it to settle before benchmarking."
  BENCH_TXN_WAS_ACTIVE="$was_active"
  BENCH_TXN_ARMED=1
  trap 'bench_service_exit_handler' EXIT
  trap 'bench_service_signal_handler' HUP INT TERM
  if (( was_active )); then
    systemctl --user stop "$UNIT_NAME" || die "Could not stop $UNIT_NAME; raw benchmark was not started."
  fi
  require_router_fully_stopped "running llama-bench so no mapped model skews fitting"
  cmd_bench_raw "$tier"
  restore_bench_service_transaction || restore_failed=1
  trap - EXIT HUP INT TERM
  (( restore_failed == 0 )) || die "Benchmark finished, but the prior router service could not be restored."
}

api_curl() {
  local_ai_api_key_from_file "$KEY_FILE" >/dev/null 2>&1 || {
    warn "API key is missing, unsafe, or symlinked: $KEY_FILE (run '$0 service')"
    return 1
  }
  local_ai_curl_authenticated "$KEY_FILE" --silent --show-error --fail-with-body "$@"
}

system_reboot_required() {
  [[ -e /run/reboot-required ]] && return 0
  if command -v pacman >/dev/null 2>&1; then
    local running_kernel
    running_kernel="$(uname -r)"
    if [[ "$(printf '%s\n' '6.18.4' "${running_kernel%%-*}" | sort -V | head -1)" != '6.18.4' ]]; then
      return 0
    fi
    [[ -d "/usr/lib/modules/$running_kernel" ]] || return 0
  fi
  if [[ -r /etc/modprobe.d/ttm.conf && -r /sys/module/ttm/parameters/pages_limit ]]; then
    local configured running
    configured="$(sed -nE 's/.*pages_limit=([0-9]+).*/\1/p' /etc/modprobe.d/ttm.conf 2>/dev/null | head -1)"
    running="$(</sys/module/ttm/parameters/pages_limit)"
    [[ -z "$configured" || "$configured" == "$running" ]] || return 0
  fi
  return 1
}

tier_artifact_progress() {
  local tier="$1" done=0 total=0 remote bytes file have
  local _t _v _id _dir _repo _rev _sha _kind
  while IFS='|' read -r _t _v _id _dir _repo _rev remote bytes _sha _kind; do
    total=$((total + bytes))
    file="$(tier_dir "$tier")/${remote##*/}"
    have=0
    if [[ -f "$file" && ! -L "$file" ]]; then
      have="$(file_size "$file")"
    elif [[ -f "${file}.part" && ! -L "${file}.part" ]]; then
      have="$(file_size "${file}.part")"
    fi
    (( have > bytes )) && have="$bytes"
    done=$((done + have))
  done < <(model_rows "$tier")
  printf '%s %s\n' "$done" "$total"
}

authenticated_catalog_capture() {
  local_ai_curl_authenticated "$KEY_FILE" --silent --show-error --max-time 2 \
    --write-out $'\n%{http_code}' "http://127.0.0.1:${PORT}/v1/models?autoload=0" || return 2
}

authenticated_protected_probe_code() {
  local_ai_curl_authenticated "$KEY_FILE" --silent --output /dev/null \
    --write-out '%{http_code}' --max-time 1 -H 'Content-Type: application/json' \
    -d '{"model":"__local_ai_auth_probe__","messages":[]}' \
    "http://127.0.0.1:${PORT}/v1/chat/completions" || return 2
}

require_authenticated_api_wall() {
  local unauth_code keyed_code
  unauth_code="$(curl --silent --output /dev/null --write-out '%{http_code}' --max-time 1 \
    -H 'Content-Type: application/json' \
    -d '{"model":"__local_ai_auth_probe__","messages":[]}' \
    "http://127.0.0.1:${PORT}/v1/chat/completions" 2>/dev/null || true)"
  case "$unauth_code" in 401|403) ;; *) warn "Protected chat did not reject an unauthenticated request (HTTP ${unauth_code:-unreachable})."; return 1 ;; esac
  keyed_code="$(authenticated_protected_probe_code 2>/dev/null || true)"
  case "$keyed_code" in
    200|400|404|405|409|422) return 0 ;;
    401|403|'') warn "The configured API key was rejected by protected chat." ;;
    000) warn "The protected API is unreachable." ;;
    *) warn "Protected keyed auth probe returned unexpected HTTP ${keyed_code}." ;;
  esac
  return 1
}

router_catalog_has_expected_schema() {
  jq -e 'type == "object" and (.data | type == "array") and
    all(.data[]?; (.id | type == "string") and (.status | type == "object"))' \
    >/dev/null 2>&1 <<< "$1"
}

router_catalog_matches_installed_tiers() {
  local catalog="$1" tier id
  router_catalog_has_expected_schema "$catalog" || return 1
  for tier in everyday coder senior; do
    tier_available "$tier" || continue
    id="$(tier_id "$tier")"
    jq -e --arg id "$id" 'any(.data[]?; .id == $id)' >/dev/null 2>&1 <<< "$catalog" || return 1
  done
}

wait_for_managed_router_control_plane() {
  local timeout="${1:-30}" deadline remaining probe_timeout catalog
  deadline=$((SECONDS + timeout))
  while (( SECONDS < deadline )); do
    remaining=$((deadline - SECONDS))
    probe_timeout=2
    (( remaining >= probe_timeout )) || probe_timeout="$remaining"
    (( probe_timeout > 0 )) || break
    if managed_router_unit_owns_listener &&
       require_authenticated_api_wall >/dev/null 2>&1; then
      catalog="$(api_curl --max-time "$probe_timeout" \
        "http://127.0.0.1:${PORT}/v1/models?autoload=0" 2>/dev/null || true)"
      router_catalog_matches_installed_tiers "$catalog" && return 0
    fi
    (( SECONDS < deadline )) && sleep 1
  done
  warn "The managed router did not regain a stable authenticated control plane within ${timeout}s."
  return 1
}

build_status_json() {
  command -v jq >/dev/null 2>&1 || die "jq is required for status output (run: $0 install)"
  local service_state unauth_code keyed_code api_state=down auth_enforced=false catalog_json="" captured code body
  service_state="$(systemctl --user is-active "$UNIT_NAME" 2>/dev/null || true)"
  case "$service_state" in active|inactive|failed|activating|deactivating) ;; *) service_state=unknown ;; esac
  # Service state and port ownership are independent. Always probe loopback so
  # an inactive/failed managed unit cannot hide a conflicting insecure listener.
  unauth_code="$(curl --silent --output /dev/null --write-out '%{http_code}' --max-time 1 \
    -H 'Content-Type: application/json' \
    -d '{"model":"__local_ai_auth_probe__","messages":[]}' \
    "http://127.0.0.1:${PORT}/v1/chat/completions" 2>/dev/null || true)"
  case "$unauth_code" in
    401|403)
      auth_enforced=true
      keyed_code="$(authenticated_protected_probe_code 2>/dev/null || true)"
      case "$keyed_code" in
        200|400|404|405|409|422)
          if captured="$(authenticated_catalog_capture 2>/dev/null)"; then
            code="${captured##*$'\n'}"; body="${captured%$'\n'*}"
            case "$code" in
              200) if router_catalog_has_expected_schema "$body"; then api_state=authenticated; catalog_json="$body"; else api_state=error; fi ;;
              401|403) api_state=unauthorized ;;
              *) api_state=error ;;
            esac
          else
            api_state=error
          fi
          ;;
        401|403|'') api_state=unauthorized ;;
        000) api_state=down ;;
        *) api_state=error ;;
      esac
      ;;
    000|'') api_state=down ;;
    200|400|404|405|409|422)
      api_state=insecure
      catalog_json="$(curl --silent --max-time 2 "http://127.0.0.1:${PORT}/v1/models?autoload=0" 2>/dev/null || true)"
      router_catalog_has_expected_schema "$catalog_json" || catalog_json=""
      ;;
    *) api_state=error ;;
  esac

  local models_json='[]' tier id label artifacts runtime progress router_progress entry artifact_done artifact_total
  for tier in everyday coder senior; do
    id="$(tier_id "$tier")"
    label="$(tier_label "$tier")"
    if tier_available "$tier"; then artifacts=installed; elif tier_any_file "$tier"; then artifacts=partial; else artifacts=absent; fi
    read -r artifact_done artifact_total < <(tier_artifact_progress "$tier")
    runtime=unknown
    progress=null
    router_progress=null
    if [[ -n "$catalog_json" ]]; then
      entry="$(jq -c --arg id "$id" '.data[]? | select(.id == $id)' <<< "$catalog_json" | head -1)"
      if [[ -n "$entry" ]]; then
        runtime="$(jq -r 'if (.status.failed // false) then "failed" else (.status.value // "unknown") end' <<< "$entry")"
        case "$runtime" in loaded|loading|unloaded|sleeping|failed) ;; downloading) runtime=loading ;; *) runtime=unknown ;; esac
        router_progress="$(jq -c '.status.progress // null' <<< "$entry")"
        progress="$(jq -c 'if (.status.progress | type) == "number" then .status.progress else null end' <<< "$entry")"
      elif [[ "$api_state" == authenticated || "$api_state" == insecure ]]; then
        runtime=unloaded
      fi
    fi
    models_json="$(jq -cn \
      --argjson models "$models_json" --arg tier "$tier" --arg id "$id" --arg label "$label" \
      --arg artifacts "$artifacts" --arg runtime "$runtime" --argjson progress "$progress" \
      --argjson routerProgress "$router_progress" \
      --argjson bytes "$artifact_total" --argjson done "$artifact_done" \
      '$models + [{tier:$tier,id:$id,label:$label,bytes:$bytes,artifacts:$artifacts,runtime:$runtime,progress:$progress,routerProgress:$routerProgress,artifactProgress:{doneBytes:$done,totalBytes:$bytes}}]')"
  done
  local loaded_model reboot_required=false
  loaded_model="$(jq -r '[.[] | select(.runtime == "loaded")][0].id // empty' <<< "$models_json")"
  system_reboot_required && reboot_required=true
  jq -cn \
    --arg state "$service_state" --arg api "$api_state" --argjson port "$PORT" \
    --argjson auth "$auth_enforced" --arg loaded "$loaded_model" --argjson models "$models_json" \
    --arg agent "$AGENT" --arg routing "$ROUTING_PROFILE" --arg startup "$STARTUP_TIER" \
    --argjson modelsMax "$MODELS_MAX" --argjson everydayCtx "$CTX" --argjson coderCtx "$CODER_CTX" \
    --argjson seniorCtx "$SENIOR_CTX" --arg kv "$KV_CACHE_PROFILE" \
    --arg everydayLoad "$LOAD_MODE_EVERYDAY" --arg coderLoad "$LOAD_MODE_CODER" --arg seniorLoad "$LOAD_MODE_SENIOR" \
    --argjson reboot "$reboot_required" \
    '{schemaVersion:1,service:{state:$state,api:$api,port:$port,authEnforced:$auth},loadedModel:(if $loaded=="" then null else $loaded end),models:$models,config:{agent:$agent,routingProfile:$routing,startupTier:$startup,modelsMax:$modelsMax,contexts:{everyday:$everydayCtx,coder:$coderCtx,senior:$seniorCtx},kvCacheProfile:$kv,loadModes:{everyday:$everydayLoad,coder:$coderLoad,senior:$seniorLoad}},system:{rebootRequired:$reboot}}'
}

cmd_status() {
  [[ $# -le 1 ]] || die "Usage: $0 status [--json]"
  local mode="${1:-human}" json
  [[ "$mode" == human || "$mode" == --json ]] || die "Usage: $0 status [--json]"
  json="$(build_status_json)"
  if [[ "$mode" == --json ]]; then
    printf '%s\n' "$json"
    return 0
  fi
  jq -r '
    "Service: \(.service.state) · API: \(.service.api) · port \(.service.port) · auth enforced: \(.service.authEnforced)",
    "Loaded model: \(.loadedModel // "none")", "Routing: \(.config.routingProfile) · startup: \(.config.startupTier) · max resident: \(.config.modelsMax)",
    (.models[] | "  \(.tier): artifacts=\(.artifacts) runtime=\(.runtime) bytes=\(.artifactProgress.doneBytes)/\(.artifactProgress.totalBytes)"),
    "Reboot required: \(.system.rebootRequired)"
  ' <<< "$json"
}

cmd_smoke() {
  [[ $# -le 1 ]] || die "Usage: $0 smoke [everyday|coder|senior]"
  local tier="${1:-}" abin model_id models_json payload response unauth_code
  if [[ -z "$tier" ]]; then
    for tier in everyday coder senior; do tier_available "$tier" && break; done
  fi
  case "$tier" in everyday|coder|senior) ;; *) die "Usage: $0 smoke [everyday|coder|senior]" ;; esac
  tier_available "$tier" || die "$tier model is incomplete — run: $0 model $tier"
  model_id="$(tier_id "$tier")"

  info "Configuration: agent=${AGENT}  smoke-model=${model_id}  models-max=${MODELS_MAX}"
  abin=$(command -v "$AGENT" 2>/dev/null || echo "NOT INSTALLED — run: $0 agent")
  echo "    ${AGENT} binary: ${abin}"
  echo
  info "Service:"
  systemctl --user --no-pager status "$UNIT_NAME" || true
  echo
  info "API check (http://127.0.0.1:${PORT}):"
  # Probe a protected POST (rather than a release-dependent health/catalog
  # allowlist) with an invalid model ID, so a missing auth wall fails fast.
  unauth_code="$(curl --silent --output /dev/null --write-out '%{http_code}' \
    --max-time 10 -H 'Content-Type: application/json' \
    -d '{"model":"__local_ai_auth_probe__","messages":[]}' \
    "http://127.0.0.1:${PORT}/v1/chat/completions" 2>/dev/null || true)"
  case "$unauth_code" in
    401|403) ok "Unauthenticated requests are rejected (${unauth_code})" ;;
    000|'') warn "Server is not reachable on port ${PORT}"; return 1 ;;
    *) warn "API authentication is not enforced (protected chat returned ${unauth_code} without a key)"; return 1 ;;
  esac
  if ! models_json="$(api_curl --max-time 10 "http://127.0.0.1:${PORT}/v1/models")"; then
    warn "Authenticated /v1/models failed. Logs: journalctl --user -fu ${UNIT_NAME}"
    return 1
  fi
  if ! jq -e . <<< "$models_json"; then
    warn "Server returned invalid JSON from /v1/models"
    return 1
  fi
  echo
  info "Chat smoke test for '${model_id}' (a model swap can take several minutes):"
  payload="$(jq -cn --arg model "$model_id" '{model:$model,messages:[{role:"user",content:"Reply with exactly: READY"}],max_tokens:256,stream:false}')"
  if ! response="$(api_curl --max-time 600 \
      -H 'Content-Type: application/json' \
      -d "$payload" \
      "http://127.0.0.1:${PORT}/v1/chat/completions")"; then
    warn "Authenticated chat request failed — check the service logs."
    return 1
  fi
  if ! jq -e '[.choices[0].message.content, .choices[0].message.reasoning_content] | any(type == "string" and length > 0)' <<< "$response" >/dev/null; then
    warn "Chat response had no assistant content or reasoning content. Full response:"
    jq . <<< "$response" 2>/dev/null || printf '%s\n' "$response"
    return 1
  fi
  ok "Authenticated chat returned assistant output for ${model_id}"
}

# ---------------------- production API performance check --------------------

PERF_HISTORY_FILE="${PERF_HISTORY_FILE:-$LOCAL_AI_CONFIG_DIR/perf-history.jsonl}"
PERF_RESTORE_IDS=""
PERF_TARGET_ID=""
PERF_KEEP_TARGET=0
PERF_COMPLETED=0
PERF_CLEANUP_ACTIVE=0
PERF_TMP_DIR=""
PERF_REQUEST_JSON=""

router_catalog_json() {
  local timeout="${1:-5}"
  api_curl --max-time "$timeout" "http://127.0.0.1:${PORT}/v1/models?autoload=0"
}

router_model_state() {
  local model_id="$1" timeout="${2:-5}" catalog state
  catalog="$(router_catalog_json "$timeout" 2>/dev/null)" || return 1
  state="$(jq -r --arg id "$model_id" '
    [.data[]? | select(.id == $id)][0] |
    if . == null then "absent"
    elif (.status.failed // false) then "failed"
    else (.status.value // "unknown") end
  ' <<< "$catalog" 2>/dev/null)" || return 1
  printf '%s\n' "$state"
}

router_post_model_action() {
  local action="$1" model_id="$2" timeout="${3:-30}" payload
  payload="$(jq -cn --arg model "$model_id" '{model:$model}')" || return 1
  api_curl --max-time "$timeout" --output /dev/null -H 'Content-Type: application/json' \
    -d "$payload" "http://127.0.0.1:${PORT}/models/${action}"
}

router_wait_model_state() {
  local model_id="$1" wanted="$2" timeout="${3:-$SERVICE_READY_TIMEOUT}" state
  local deadline=$((SECONDS + timeout)) remaining probe_timeout
  while (( SECONDS < deadline )); do
    remaining=$((deadline - SECONDS))
    probe_timeout=5; (( remaining >= probe_timeout )) || probe_timeout="$remaining"
    (( probe_timeout > 0 )) || break
    state="$(router_model_state "$model_id" "$probe_timeout" 2>/dev/null || true)"
    case "$wanted:$state" in
      loaded:loaded|unloaded:unloaded|unloaded:absent) return 0 ;;
      *:failed) return 1 ;;
    esac
    (( SECONDS < deadline )) && sleep 1
  done
  return 1
}

router_load_model() {
  local model_id="$1" timeout="${2:-$SERVICE_READY_TIMEOUT}" state remaining action_timeout
  local deadline=$((SECONDS + timeout))
  state="$(router_model_state "$model_id" 5 2>/dev/null || true)"
  [[ "$state" != loaded ]] || return 0
  remaining=$((deadline - SECONDS)); (( remaining > 0 )) || return 1
  action_timeout=30; (( remaining >= action_timeout )) || action_timeout="$remaining"
  router_post_model_action load "$model_id" "$action_timeout" || return 1
  remaining=$((deadline - SECONDS)); (( remaining > 0 )) || return 1
  router_wait_model_state "$model_id" loaded "$remaining"
}

router_unload_model() {
  local model_id="$1" timeout="${2:-$SERVICE_READY_TIMEOUT}" state remaining action_timeout
  local deadline=$((SECONDS + timeout))
  state="$(router_model_state "$model_id" 5 2>/dev/null || true)"
  case "$state" in
    unloaded|absent) return 0 ;;
    ''|unknown) return 1 ;;
  esac
  remaining=$((deadline - SECONDS)); (( remaining > 0 )) || return 1
  action_timeout=30; (( remaining >= action_timeout )) || action_timeout="$remaining"
  router_post_model_action unload "$model_id" "$action_timeout" || return 1
  remaining=$((deadline - SECONDS)); (( remaining > 0 )) || return 1
  router_wait_model_state "$model_id" unloaded "$remaining"
}

perf_id_was_prior() {
  local needle="$1" prior
  while IFS= read -r prior; do
    [[ -n "$prior" && "$prior" == "$needle" ]] && return 0
  done <<< "$PERF_RESTORE_IDS"
  return 1
}

perf_cleanup_tmp() {
  [[ -n "$PERF_TMP_DIR" ]] || return 0
  rm -f -- \
    "$PERF_TMP_DIR/cold.sse" "$PERF_TMP_DIR/cold.sse.timing" "$PERF_TMP_DIR/cold.sse.first-event" \
    "$PERF_TMP_DIR/warm.sse" "$PERF_TMP_DIR/warm.sse.timing" "$PERF_TMP_DIR/warm.sse.first-event"
  if rmdir "$PERF_TMP_DIR" 2>/dev/null; then
    PERF_TMP_DIR=""
  else
    warn "Performance scratch directory could not be removed and remains for inspection: $PERF_TMP_DIR"
    return 1
  fi
}

perf_restore_residency() {
  (( PERF_CLEANUP_ACTIVE == 1 )) || { perf_cleanup_tmp; return 0; }
  # Restoration is the recovery critical section. Ignore a second terminal
  # signal until all prior residency is back; otherwise a re-entered handler
  # can observe cleanup inactive and strand a partially restored router.
  trap '' HUP INT TERM
  local failed=0 catalog current prior state
  if (( PERF_KEEP_TARGET == 1 && PERF_COMPLETED == 1 )); then
    perf_cleanup_tmp || failed=1
  else
    info "Restoring the model residency that existed before perf"
    if ! catalog="$(router_catalog_json 2>/dev/null)"; then
      warn "Could not read the router catalog while restoring prior residency."
      failed=1
    else
      while IFS= read -r current; do
        [[ -n "$current" ]] || continue
        if ! perf_id_was_prior "$current"; then
          router_unload_model "$current" || { warn "Could not unload perf model $current during restore."; failed=1; }
        fi
      done < <(jq -r '.data[]? | select((.status.value == "loaded") or (.status.value == "loading") or (.status.value == "sleeping")) | .id' <<< "$catalog")
      while IFS= read -r prior; do
        [[ -n "$prior" ]] || continue
        state="$(router_model_state "$prior" 2>/dev/null || true)"
        if [[ "$state" != loaded ]]; then
          router_load_model "$prior" || { warn "Could not reload prior model $prior."; failed=1; }
        fi
      done <<< "$PERF_RESTORE_IDS"
    fi
    perf_cleanup_tmp || failed=1
  fi
  PERF_CLEANUP_ACTIVE=0
  trap - HUP INT TERM
  (( failed == 0 ))
}

perf_exit_handler() {
  local rc=$?
  trap - EXIT HUP INT TERM
  perf_restore_residency || true
  exit "$rc"
}

perf_signal_handler() {
  trap - EXIT HUP INT TERM
  perf_restore_residency || true
  exit 130
}

now_millis() {
  local value
  value="$(date +%s%3N 2>/dev/null || true)"
  if [[ ! "$value" =~ ^[0-9]{13}$ ]]; then
    if command -v python3 >/dev/null 2>&1; then
      value="$(python3 -c 'import time; print(time.time_ns() // 1_000_000)')"
    else
      value="$(date +%s)000"
    fi
  fi
  printf '%s\n' "$value"
}

perf_line_has_token_event() {
  local line="$1" json
  case "$line" in
    data:\ *) json="${line#data: }" ;;
    \{*) json="$line" ;;
    *) return 1 ;;
  esac
  [[ "$json" != '[DONE]' ]] || return 1
  jq -e '
    [
      .choices[]? |
      .delta.content?, .delta.reasoning_content?,
      .message.content?, .message.reasoning_content?, .text?
    ] | any(.[]; type == "string" and length > 0)
  ' >/dev/null 2>&1 <<< "$json"
}

perf_api_request() {
  local label="$1" payload="$2" response_file="$3"
  local curl_timing http_code response_start total events usage timings
  local timing_file="${response_file}.timing" first_event_file="${response_file}.first-event" line
  local request_start_ms first_event_ms ttft_ms
  rm -f -- "$timing_file" "$first_event_file"
  request_start_ms="$(now_millis)"
  # Stream through a line recorder instead of relying on curl's
  # time_starttransfer (which can be only the response headers). --no-buffer
  # lets us timestamp the first generated content/reasoning token as it
  # arrives. Role-only and empty-delta SSE events are intentionally ignored.
  if ! api_curl --max-time 1800 --no-buffer --output - \
      --write-out $'\n__LOCAL_AI_TIMING__%{http_code}|%{time_starttransfer}|%{time_total}\n' \
      -H 'Content-Type: application/json' -d "$payload" \
      "http://127.0.0.1:${PORT}/v1/chat/completions" |
      while IFS= read -r line || [[ -n "$line" ]]; do
        case "$line" in
          __LOCAL_AI_TIMING__*) printf '%s\n' "${line#__LOCAL_AI_TIMING__}" > "$timing_file" ;;
          *)
            printf '%s\n' "$line" >> "$response_file"
            if [[ ! -s "$first_event_file" ]] && perf_line_has_token_event "$line"; then
              now_millis > "$first_event_file"
            fi
            ;;
        esac
      done
  then
    rm -f -- "$timing_file" "$first_event_file"
    return 1
  fi
  [[ -s "$timing_file" ]] || { rm -f -- "$first_event_file"; return 1; }
  curl_timing="$(<"$timing_file")"
  IFS='|' read -r http_code response_start total <<< "$curl_timing"
  [[ "$http_code" == 200 ]] || {
    rm -f -- "$timing_file" "$first_event_file"
    warn "$label request returned HTTP ${http_code:-unknown}"
    return 1
  }
  [[ -s "$first_event_file" ]] || {
    rm -f -- "$timing_file" "$first_event_file"
    warn "$label response contained no data event"
    return 1
  }
  first_event_ms="$(<"$first_event_file")"
  ttft_ms=$((first_event_ms - request_start_ms))
  (( ttft_ms >= 0 )) || ttft_ms=0
  rm -f -- "$timing_file" "$first_event_file"

  events="$(awk 'substr($0,1,7)=="data: {" { sub(/^data: /, ""); sub(/\r$/, ""); print }' "$response_file" | jq -sc '.')" || return 1
  if [[ "$(jq 'length' <<< "$events")" == 0 ]] && jq -e . "$response_file" >/dev/null 2>&1; then
    events="$(jq -sc '.' "$response_file")" || return 1
  fi
  usage="$(jq -c '[.[] | .usage? | select(. != null)] | last // {}' <<< "$events")" || return 1
  timings="$(jq -c '[.[] | .timings? | select(. != null)] | last // {}' <<< "$events")" || return 1
  PERF_REQUEST_JSON="$(jq -cn \
    --arg label "$label" --arg http "$http_code" --arg responseStart "$response_start" --arg total "$total" \
    --argjson ttftMs "$ttft_ms" \
    --argjson usage "$usage" --argjson timings "$timings" \
    '{label:$label,httpCode:($http|tonumber),responseStartSeconds:($responseStart|tonumber),ttftSeconds:($ttftMs/1000),totalSeconds:($total|tonumber),promptTokens:($usage.prompt_tokens // $timings.prompt_n // null),completionTokens:($usage.completion_tokens // $timings.predicted_n // null),tokensPerSecond:($timings.predicted_per_second // null),draftTokens:($timings.draft_n // 0),draftAccepted:($timings.draft_n_accepted // 0),draftAcceptanceRate:(if ($timings.draft_n // 0)>0 then (($timings.draft_n_accepted // 0)/$timings.draft_n) else null end),serverTimings:$timings}')" || return 1
}

runtime_memory_snapshot_json() {
  local service_bytes=null gtt_bytes=null candidate value
  value="$(systemctl --user show "$UNIT_NAME" -p MemoryCurrent --value 2>/dev/null || true)"
  [[ "$value" =~ ^[0-9]+$ ]] && service_bytes="$value"
  for candidate in /sys/class/drm/card*/device/mem_info_gtt_used; do
    [[ -r "$candidate" ]] || continue
    value="$(<"$candidate")"
    if [[ "$value" =~ ^[0-9]+$ ]]; then gtt_bytes="$value"; break; fi
  done
  jq -cn --argjson service "$service_bytes" --argjson gtt "$gtt_bytes" \
    '{serviceMemoryBytes:$service,gttUsedBytes:$gtt}'
}

perf_runtime_identity_json() {
  local server_bin server_version kernel gtt_pages=unknown
  server_bin="$(command -v llama-server 2>/dev/null || true)"
  if [[ -n "$server_bin" ]]; then
    server_version="$("$server_bin" --version 2>&1 | head -1 || true)"
  else
    server_version=unknown
  fi
  [[ -n "$server_version" ]] || server_version=unknown
  kernel="$(uname -r 2>/dev/null || printf '%s' unknown)"
  if [[ -r /sys/module/ttm/parameters/pages_limit ]]; then
    gtt_pages="$(</sys/module/ttm/parameters/pages_limit)"
    [[ "$gtt_pages" =~ ^[0-9]+$ ]] || gtt_pages=unknown
  fi
  jq -cn --arg llama "$server_version" --arg kernel "$kernel" --arg gtt "$gtt_pages" \
    '{llamaServerVersion:$llama,kernelRelease:$kernel,gttPagesLimit:$gtt}'
}

perf_last_comparable() {
  local tier="$1" model_id="$2" context="$3" mtp="$4" variant="$5" artifact_digest="$6"
  local prompt_words="$7" reasoning_effort="$8" identity server_version kernel_release gtt_pages
  identity="$(perf_runtime_identity_json)"
  server_version="$(jq -r '.llamaServerVersion' <<< "$identity")"
  kernel_release="$(jq -r '.kernelRelease' <<< "$identity")"
  gtt_pages="$(jq -r '.gttPagesLimit' <<< "$identity")"
  [[ -f "$PERF_HISTORY_FILE" && ! -L "$PERF_HISTORY_FILE" ]] || { printf '%s\n' null; return 0; }
  jq -sc --arg tier "$tier" --arg id "$model_id" --arg routing "$ROUTING_PROFILE" \
    --arg load "$(tier_load_mode "$tier")" --arg kv "$KV_CACHE_PROFILE" \
    --arg variant "$variant" --arg artifact "$artifact_digest" --arg reasoning "$reasoning_effort" \
    --arg server "$server_version" --arg kernel "$kernel_release" --arg gtt "$gtt_pages" \
    --argjson context "$context" --argjson mtp "$mtp" --argjson promptWords "$prompt_words" '
      [.[] | select(.tier==$tier and .id==$id and .routingProfile==$routing and
        .loadMode==$load and .kvCacheProfile==$kv and .context==$context and
        .mtpDraftTokens==$mtp and .variant==$variant and .artifactSetDigest==$artifact and
        .promptWords==$promptWords and .reasoningEffort==$reasoning and
        .runtimeIdentity.llamaServerVersion==$server and
        .runtimeIdentity.kernelRelease==$kernel and .runtimeIdentity.gttPagesLimit==$gtt)] | last // null
    ' "$PERF_HISTORY_FILE" 2>/dev/null || printf '%s\n' null
}

tier_artifact_set_digest() {
  model_rows "$1" | awk -F'|' '{print $7 "|" $8 "|" $9}' | sha256sum | awk '{print $1}'
}

active_preset_matches_desired() {
  [[ -f "$PRESET_FILE" && ! -L "$PRESET_FILE" ]] || return 1
  local candidate
  candidate="$(mktemp "${TMPDIR:-/tmp}/local-ai-models.ini.XXXXXX")" || return 1
  if ! write_model_preset "$candidate"; then
    rm -f -- "$candidate"
    return 1
  fi
  if cmp -s -- "$candidate" "$PRESET_FILE"; then
    rm -f -- "$candidate"
    return 0
  fi
  rm -f -- "$candidate"
  return 1
}

perf_append_history() {
  local record="$1"
  [[ ! -e "$PERF_HISTORY_FILE" || ( -f "$PERF_HISTORY_FILE" && ! -L "$PERF_HISTORY_FILE" ) ]] || \
    die "Refusing non-regular or symlinked performance history: $PERF_HISTORY_FILE"
  mkdir -p "$LOCAL_AI_CONFIG_DIR"
  chmod 700 "$LOCAL_AI_CONFIG_DIR"
  printf '%s\n' "$record" >> "$PERF_HISTORY_FILE"
  chmod 600 "$PERF_HISTORY_FILE"
}

perf_prompt_budget_valid() {
  local context="$1" words="$2"
  # Whitespace words are not tokenizer tokens: identifiers and punctuation can
  # split. Reserve a conservative 2 tokens/word plus 1024 tokens for the
  # instruction envelope, 256-token response, and chat-template overhead.
  (( words * 2 + 1024 <= context ))
}

cmd_perf() {
  local tier=everyday keep=0 arg tier_seen=0
  [[ $# -le 2 ]] || die "Usage: $0 perf [everyday|coder|senior] [--keep]"
  for arg in "$@"; do
    case "$arg" in
      --keep) (( keep == 0 )) || die "Usage: $0 perf [everyday|coder|senior] [--keep]"; keep=1 ;;
      everyday|coder|senior) (( tier_seen == 0 )) || die "Usage: $0 perf [everyday|coder|senior] [--keep]"; tier="$arg"; tier_seen=1 ;;
      *) die "Usage: $0 perf [everyday|coder|senior] [--keep]" ;;
    esac
  done
  command -v jq >/dev/null 2>&1 || die "jq is required (run: $0 install)"
  command -v curl >/dev/null 2>&1 || die "curl is required (run: $0 install)"
  tier_available "$tier" || die "$tier model is incomplete — run: $0 model $tier"
  command -v sha256sum >/dev/null 2>&1 || die "sha256sum is required (install coreutils)"
  active_preset_matches_desired || \
    die "The active preset does not match desired QUANT/context/load/KV/startup settings. Run '$0 plan' and '$0 apply' before recording performance."
  info "Checking cached models.lock verification receipt for $tier"
  verify_tier_integrity "$tier" 0 cached || die "$tier files do not match models.lock; refusing to benchmark them"
  require_authenticated_api_wall || die "Refusing a mutating performance check without verified API authentication."
  local model_id context mtp variant artifact_digest catalog active_ids prompt payload cold_json warm_json
  local start_ms end_ms load_ms runtime timestamp previous record resources runtime_identity restore_rc=0
  model_id="$(tier_id "$tier")"
  context="$(tier_context "$tier")"
  perf_prompt_budget_valid "$context" "$PERF_PROMPT_WORDS" || \
    die "PERF_PROMPT_WORDS=$PERF_PROMPT_WORDS is too large for $tier context=$context after conservative token/output headroom. Reduce PERF_PROMPT_WORDS or apply a larger tier context."
  variant="$(tier_variant "$tier")"
  artifact_digest="$(tier_artifact_set_digest "$tier")"
  mtp=0; [[ "$tier" != everyday ]] || mtp="$DRAFT_N"
  catalog="$(router_catalog_json)" || die "Authenticated router catalog is unavailable; run '$0 service' first."
  jq -e . >/dev/null 2>&1 <<< "$catalog" || die "Router returned an invalid model catalog."
  if jq -e '.data[]? | select(.status.value == "loading")' >/dev/null <<< "$catalog"; then
    die "A model is already loading; wait for it to settle before running perf."
  fi
  if jq -e '.data[]? | select(.status.value == "sleeping")' >/dev/null <<< "$catalog"; then
    die "A model is sleeping. llama.cpp exposes no sleep action for exact restoration; wake or unload it explicitly before running perf."
  fi
  PERF_RESTORE_IDS="$(jq -r '.data[]? | select(.status.value == "loaded") | .id' <<< "$catalog")"
  PERF_TARGET_ID="$model_id"
  PERF_KEEP_TARGET="$keep"
  PERF_COMPLETED=0
  PERF_CLEANUP_ACTIVE=1
  PERF_TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/local-ai-perf.XXXXXX")" || die "Could not create performance scratch directory"
  trap 'perf_exit_handler' EXIT
  trap 'perf_signal_handler' HUP INT TERM

  # Remove every active process first: this makes load timing genuinely
  # cold and avoids relying on LRU eviction behavior for MODELS_MAX=1.
  active_ids="$(jq -r '.data[]? | select(.status.value == "loaded") | .id' <<< "$catalog")"
  while IFS= read -r arg; do
    [[ -n "$arg" ]] || continue
    router_unload_model "$arg" || die "Could not unload $arg before the cold-load measurement."
  done <<< "$active_ids"

  info "Cold-loading $(tier_label "$tier") with load-mode=$(tier_load_mode "$tier"), context=${context}, KV=${KV_CACHE_PROFILE}"
  start_ms="$(now_millis)"
  router_load_model "$model_id" || die "Router failed to load $model_id within ${SERVICE_READY_TIMEOUT}s."
  end_ms="$(now_millis)"
  load_ms=$((end_ms - start_ms))

  prompt="$(awk -v count="$PERF_PROMPT_WORDS" 'BEGIN {
    split("Review a production code change for correctness concurrency hazards security and maintainability Return a concise prioritized review Context follows module validates inputs before state changes and preserves rollback invariants", words, " ")
    width = 31
    for (i = 1; i <= count; i++) {
      printf "%s%s", (i == 1 ? "" : " "), words[((i - 1) % width) + 1]
    }
  }')"
  payload="$(jq -cn --arg model "$model_id" --arg prompt "$prompt" \
    '{model:$model,messages:[{role:"user",content:$prompt}],max_tokens:256,stream:true,stream_options:{include_usage:true}}')" || die "Could not construct perf request."

  info "Running cold-prompt API request (${PERF_PROMPT_WORDS} approximate prompt words)"
  perf_api_request cold "$payload" "$PERF_TMP_DIR/cold.sse" || die "Cold API request failed."
  cold_json="$PERF_REQUEST_JSON"
  info "Running identical warm request to exercise prompt-cache reuse"
  perf_api_request warm "$payload" "$PERF_TMP_DIR/warm.sse" || die "Warm API request failed."
  warm_json="$PERF_REQUEST_JSON"
  runtime="$(router_model_state "$model_id" 2>/dev/null || printf '%s' unknown)"
  resources="$(runtime_memory_snapshot_json)"
  runtime_identity="$(perf_runtime_identity_json)"
  timestamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  previous="$(perf_last_comparable "$tier" "$model_id" "$context" "$mtp" "$variant" "$artifact_digest" "$PERF_PROMPT_WORDS" "$REASONING_EFFORT")"
  record="$(jq -cn --arg timestamp "$timestamp" --arg tier "$tier" --arg id "$model_id" \
    --arg routing "$ROUTING_PROFILE" --arg load "$(tier_load_mode "$tier")" --arg kv "$KV_CACHE_PROFILE" \
    --arg runtime "$runtime" --arg variant "$variant" --arg artifact "$artifact_digest" \
    --arg reasoning "$REASONING_EFFORT" --argjson promptWords "$PERF_PROMPT_WORDS" \
    --argjson context "$context" --argjson mtp "$mtp" \
    --argjson loadMs "$load_ms" --argjson cold "$cold_json" --argjson warm "$warm_json" \
    --argjson resources "$resources" --argjson identity "$runtime_identity" \
    '{schemaVersion:3,timestamp:$timestamp,tier:$tier,id:$id,variant:$variant,artifactSetDigest:$artifact,routingProfile:$routing,loadMode:$load,kvCacheProfile:$kv,context:$context,mtpDraftTokens:$mtp,promptWords:$promptWords,promptTokens:$cold.promptTokens,reasoningEffort:$reasoning,loadSeconds:($loadMs/1000),cold:$cold,warm:$warm,runtime:$runtime,resources:$resources,runtimeIdentity:$identity}')" || die "Could not encode performance result."
  perf_append_history "$record"

  jq -r '
    "Performance result: \(.tier) / \(.id)",
    "  cold load: \(.loadSeconds)s · runtime: \(.runtime)",
    "  cold request: TTFT \(.cold.ttftSeconds)s · total \(.cold.totalSeconds)s · prompt \(.cold.promptTokens // "?") · generated \(.cold.completionTokens // "?") · \(.cold.tokensPerSecond // "?") tok/s · draft \(.cold.draftAccepted)/\(.cold.draftTokens)",
    "  warm request: TTFT \(.warm.ttftSeconds)s · total \(.warm.totalSeconds)s · prompt \(.warm.promptTokens // "?") · generated \(.warm.completionTokens // "?") · \(.warm.tokensPerSecond // "?") tok/s · draft \(.warm.draftAccepted)/\(.warm.draftTokens)",
    "  resources after warm request: service RAM \(.resources.serviceMemoryBytes // "?") bytes · GTT \(.resources.gttUsedBytes // "?") bytes"
  ' <<< "$record"
  if [[ "$previous" != null ]]; then
    jq -nr --argjson old "$previous" --argjson new "$record" '
      def delta(a;b): if (a|type)=="number" and (b|type)=="number" and a != 0 then ((b-a)/a*100) else null end;
      "  versus prior comparable run (\($old.timestamp)): load \(delta($old.loadSeconds;$new.loadSeconds) // "?")%, warm total \(delta($old.warm.totalSeconds;$new.warm.totalSeconds) // "?")%, generation rate \(delta($old.warm.tokensPerSecond;$new.warm.tokensPerSecond) // "?")%"
    '
  else
    echo "  no prior comparable run (same artifact/runtime-build/kernel/GTT/routing/load/KV/context/MTP/prompt/reasoning profile)"
  fi
  echo "  history: $PERF_HISTORY_FILE"

  PERF_COMPLETED=1
  perf_restore_residency || restore_rc=1
  trap - EXIT HUP INT TERM
  (( restore_rc == 0 )) || die "Performance run completed, but prior model residency could not be fully restored."
  (( keep == 0 )) || ok "--keep selected; ${model_id} remains resident."
}

cmd_perf_history() {
  [[ $# -le 1 ]] || die "Usage: $0 perf-history [all|everyday|coder|senior]"
  local tier="${1:-all}"
  case "$tier" in all|everyday|coder|senior) ;; *) die "Usage: $0 perf-history [all|everyday|coder|senior]" ;; esac
  [[ -f "$PERF_HISTORY_FILE" && ! -L "$PERF_HISTORY_FILE" ]] || { echo "No performance history at $PERF_HISTORY_FILE"; return 0; }
  jq -sr --arg tier "$tier" '
    [.[] | select($tier=="all" or .tier==$tier)] | reverse | .[:20][] |
    "\(.timestamp // "?")  \(.tier // "?")  id=\(.id // "?")  variant=\(.variant // "?")  artifact=\(((.artifactSetDigest // "?") | tostring)[0:12])  load=\(.loadSeconds // "?")s  cold=\(.cold.totalSeconds // "?")s  warm=\(.warm.totalSeconds // "?")s  warm-gen=\(.warm.tokensPerSecond // "?") tok/s  profile=\(.routingProfile // "?")/\(.loadMode // "?")/\(.kvCacheProfile // "?")/ctx\(.context // "?")/mtp\(.mtpDraftTokens // "?")/words\(.promptWords // "?")/reasoning-\(.reasoningEffort // "?")  runtime=\(.runtimeIdentity.llamaServerVersion // .runtime // "?")  kernel=\(.runtimeIdentity.kernelRelease // "?")  gtt-pages=\(.runtimeIdentity.gttPagesLimit // "?")"
  ' "$PERF_HISTORY_FILE" || die "Performance history is not valid JSONL: $PERF_HISTORY_FILE"
}

# ------------------------- remote access (LAN-only) --------------------------

SSHD_DROPIN="${SSHD_DROPIN:-/etc/ssh/sshd_config.d/20-local-ai-lan.conf}"

SSHD_TXN_ARMED=0
SSHD_TXN_FILE_TOUCHED=0
SSHD_TXN_DAEMON_TOUCHED=0
SSHD_TXN_BACKUP=""
SSHD_TXN_CANDIDATE=""
SSHD_TXN_HAD_PREVIOUS=0
SSHD_TXN_WAS_ACTIVE=0
SSHD_HOST_KEYS_READY=0
SSHD_LAST_WAS_ACTIVE=0

reset_sshd_transaction() {
  SSHD_TXN_ARMED=0
  SSHD_TXN_FILE_TOUCHED=0
  SSHD_TXN_DAEMON_TOUCHED=0
  SSHD_TXN_BACKUP=""
  SSHD_TXN_CANDIDATE=""
  SSHD_TXN_HAD_PREVIOUS=0
  SSHD_TXN_WAS_ACTIVE=0
}

sshd_effective_config() {
  local me host addr
  me="$(id -un)"
  host="$(hostname)"
  addr="${SSHD_TEST_ADDR:-${SSH_CLIENT:-}}"
  addr="${addr%% *}"
  if [[ -z "$addr" ]] && command -v ip >/dev/null 2>&1; then
    addr="$(ip -4 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="via"){print $(i+1); exit}}')"
  fi
  [[ "$addr" =~ ^[0-9A-Fa-f:.]+$ ]] || addr=127.0.0.1
  sudo sshd -T -C "user=${me},host=${host},addr=${addr}" 2>/dev/null
}

ensure_sshd_host_keys() {
  local load_state
  (( SSHD_HOST_KEYS_READY == 0 )) || return 0
  load_state="$(sudo systemctl show sshdgenkeys.service --property=LoadState --value 2>/dev/null || true)"
  if [[ "$load_state" == loaded ]]; then
    if sudo systemctl start sshdgenkeys.service 2>/dev/null; then
      SSHD_HOST_KEYS_READY=1
      return 0
    fi
    warn "sshdgenkeys.service could not run; falling back to ssh-keygen -A."
  fi
  sudo ssh-keygen -A >/dev/null 2>&1 || return 1
  SSHD_HOST_KEYS_READY=1
}

sshd_stable_active_flag() {
  local state
  state="$(sudo systemctl show sshd --property=ActiveState --value 2>/dev/null || true)"
  case "$state" in
    active) printf '1\n' ;;
    inactive|failed) printf '0\n' ;;
    *)
      warn "sshd is in an unstable or unverifiable state (${state:-unknown}); wait for the systemd job to settle before changing authentication policy."
      return 1
      ;;
  esac
}

sshd_effective_authorized_keys_includes_checked_file() {
  local effective="$1" checked_home account_home user uid token expanded sentinel='__LOCAL_AI_LITERAL_PERCENT__'
  checked_home="${HOME%/}"
  user="$(id -un)"
  uid="$(id -u)"
  account_home="$(getent passwd "$user" 2>/dev/null | awk -F: 'NR==1 { print $6 }' || true)"
  [[ "$account_home" == /* ]] || account_home="$checked_home"
  account_home="${account_home%/}"
  while IFS= read -r token; do
    [[ -n "$token" && "$token" != none ]] || continue
    expanded="${token//%%/$sentinel}"
    expanded="${expanded//%h/$account_home}"
    expanded="${expanded//%u/$user}"
    expanded="${expanded//%U/$uid}"
    expanded="${expanded//$sentinel/%}"
    [[ "$expanded" == /* ]] || expanded="$account_home/$expanded"
    [[ "$expanded" != "$account_home/./"* ]] || expanded="$account_home/${expanded#"$account_home/./"}"
    [[ "$expanded" == "$checked_home/.ssh/authorized_keys" ]] && return 0
  done < <(awk '$1=="authorizedkeysfile" { for (i=2; i<=NF; i++) print $i; exit }' <<< "$effective")
  return 1
}

restore_sshd_dropin() {
  local backup="$1" had_previous="$2" was_active="${3:-0}" daemon_touched="${4:-1}" failed=0
  if (( had_previous )); then
    sudo cp -p "$backup" "$SSHD_DROPIN" || {
      warn "Could not restore the prior SSH drop-in from $backup"
      failed=1
    }
  else
    sudo rm -f "$SSHD_DROPIN" || {
      warn "Could not remove the rejected SSH drop-in: $SSHD_DROPIN"
      failed=1
    }
  fi
  if (( failed == 0 && was_active && daemon_touched )); then
    if ! sudo sshd -t; then
      warn "Prior SSH config was restored on disk but no longer validates"
      failed=1
    elif ! sudo systemctl reload sshd 2>/dev/null && ! sudo systemctl restart sshd 2>/dev/null; then
      warn "Prior SSH config was restored on disk, but sshd could not be reloaded"
      failed=1
    fi
  fi
  if (( failed == 0 )); then
    sudo rm -f "$backup" || warn "Could not remove temporary SSH backup: $backup"
  else
    warn "SSH rollback was incomplete; recovery copy remains at $backup."
  fi
  return "$failed"
}

rollback_sshd_transaction() {
  (( SSHD_TXN_ARMED == 1 )) || return 0
  local failed=0
  if (( SSHD_TXN_FILE_TOUCHED )); then
    restore_sshd_dropin "$SSHD_TXN_BACKUP" "$SSHD_TXN_HAD_PREVIOUS" \
      "$SSHD_TXN_WAS_ACTIVE" "$SSHD_TXN_DAEMON_TOUCHED" || failed=1
  else
    sudo rm -f "$SSHD_TXN_BACKUP" || failed=1
  fi
  if [[ -n "$SSHD_TXN_CANDIDATE" ]]; then
    rm -f -- "$SSHD_TXN_CANDIDATE" || failed=1
  fi
  if (( failed == 0 )); then
    reset_sshd_transaction
  else
    warn "SSH policy rollback was incomplete; inspect ${SSHD_TXN_BACKUP:-the retained recovery copy}."
  fi
  return "$failed"
}

abort_sshd_transaction() {
  trap - EXIT HUP INT TERM
  rollback_sshd_transaction
}

sshd_transaction_exit_handler() {
  local rc=$?
  trap - EXIT HUP INT TERM
  rollback_sshd_transaction || true
  exit "$rc"
}

sshd_transaction_signal_handler() {
  trap - EXIT HUP INT TERM
  warn "SSH policy update was interrupted; restoring the prior file and daemon state."
  rollback_sshd_transaction || true
  exit 130
}

commit_sshd_transaction() {
  local backup="$SSHD_TXN_BACKUP" candidate="$SSHD_TXN_CANDIDATE"
  SSHD_TXN_ARMED=0
  trap - EXIT HUP INT TERM
  [[ -z "$candidate" ]] || rm -f -- "$candidate" || warn "Could not remove temporary SSH candidate: $candidate"
  sudo rm -f "$backup" || warn "Could not remove temporary SSH backup: $backup"
  reset_sshd_transaction
}

write_sshd_dropin() {
  local pw="$1" kbd="${2:-$1}" me backup candidate was_active=0
  me="$(id -un)"
  SSHD_LAST_WAS_ACTIVE=0
  if ! managed_root_file_or_absent "$SSHD_DROPIN" '# Generated by setup-qwen38-pi.sh (remote / ssh-harden).'; then
    warn "Custom or symlinked SSH policy was preserved at $SSHD_DROPIN."
    warn "Move it explicitly or merge the generated LAN-only settings by hand before retrying."
    return 1
  fi
  if ! ensure_sshd_host_keys; then
    warn "Could not generate or verify the SSH host-key prerequisites without starting sshd."
    return 1
  fi
  was_active="$(sshd_stable_active_flag)" || return 1
  SSHD_LAST_WAS_ACTIVE="$was_active"
  backup="$(sudo mktemp "${SSHD_DROPIN%/*}/.local-ai-backup.XXXXXX")" || {
    warn "Could not create an SSH configuration backup"
    return 1
  }
  reset_sshd_transaction
  SSHD_TXN_BACKUP="$backup"
  SSHD_TXN_WAS_ACTIVE="$was_active"
  SSHD_TXN_ARMED=1
  trap 'sshd_transaction_exit_handler' EXIT
  trap 'sshd_transaction_signal_handler' HUP INT TERM
  candidate="$(mktemp)" || {
    abort_sshd_transaction || true
    warn "Could not create a temporary SSH configuration"
    return 1
  }
  SSHD_TXN_CANDIDATE="$candidate"
  if sudo test -f "$SSHD_DROPIN"; then
    if ! sudo cp -p "$SSHD_DROPIN" "$backup"; then
      abort_sshd_transaction || true
      warn "Could not back up the existing SSH drop-in"
      return 1
    fi
    SSHD_TXN_HAD_PREVIOUS=1
  fi
  if ! cat > "$candidate" <<EOF
# Generated by setup-qwen38-pi.sh (remote / ssh-harden). LAN-only SSH policy.
# Re-run 'setup-qwen38-pi.sh ssh-harden' after installing keys on every device.
PermitRootLogin no
AllowUsers ${me}
PubkeyAuthentication yes
PasswordAuthentication ${pw}
KbdInteractiveAuthentication ${kbd}
MaxAuthTries 3
X11Forwarding no
AllowAgentForwarding no
ClientAliveInterval 60
ClientAliveCountMax 10
EOF
  then
    abort_sshd_transaction || true
    warn "Could not write the temporary SSH policy"
    return 1
  fi

  SSHD_TXN_FILE_TOUCHED=1
  if ! sudo install -o root -g root -m 0644 "$candidate" "$SSHD_DROPIN"; then
    abort_sshd_transaction || true
    warn "Could not install the SSH policy drop-in"
    return 1
  fi
  if ! rm -f "$candidate"; then
    abort_sshd_transaction || true
    warn "Could not remove the staged SSH candidate after installation"
    return 1
  fi
  SSHD_TXN_CANDIDATE=""

  # Validate the WHOLE config before touching the running daemon — a syntax
  # error here could otherwise lock you out on the next restart.
  if ! sudo sshd -t; then
    warn "sshd config failed validation; restoring the prior drop-in."
    abort_sshd_transaction || true
    return 1
  fi

  # Verify the RESOLVED setting actually took effect. Because sshd uses
  # first-match-wins, an authentication line earlier in the main config could
  # silently override this drop-in. Check Match-aware values before reload.
  local effective_config effective_pw effective_kbd effective_pubkey effective_methods method methods_ok=0
  local effective_root effective_users effective_x11 effective_agent effective_tries
  effective_config="$(sshd_effective_config || true)"
  effective_pw="$(awk '$1=="passwordauthentication"{print $2; exit}' <<< "$effective_config")"
  effective_kbd="$(awk '$1=="kbdinteractiveauthentication"{print $2; exit}' <<< "$effective_config")"
  effective_pubkey="$(awk '$1=="pubkeyauthentication"{print $2; exit}' <<< "$effective_config")"
  effective_methods="$(awk '$1=="authenticationmethods"{$1=""; sub(/^[[:space:]]+/, ""); print; exit}' <<< "$effective_config")"
  effective_root="$(awk '$1=="permitrootlogin"{print $2; exit}' <<< "$effective_config")"
  effective_users="$(awk '$1=="allowusers"{$1=""; sub(/^[[:space:]]+/, ""); print; exit}' <<< "$effective_config")"
  effective_x11="$(awk '$1=="x11forwarding"{print $2; exit}' <<< "$effective_config")"
  effective_agent="$(awk '$1=="allowagentforwarding"{print $2; exit}' <<< "$effective_config")"
  effective_tries="$(awk '$1=="maxauthtries"{print $2; exit}' <<< "$effective_config")"
  for method in $effective_methods; do
    [[ "$method" != any && "$method" != publickey ]] || methods_ok=1
  done
  if [[ "$effective_pw" != "$pw" || "$effective_kbd" != "$kbd" || "$effective_pubkey" != yes || \
        "$effective_root" != no || "$effective_users" != "$me" || "$effective_x11" != no || \
        "$effective_agent" != no || "$effective_tries" != 3 ]] || \
     { [[ "$pw" == no && "$kbd" == no ]] && (( methods_ok == 0 )); }; then
    warn "sshd resolved password/kbd/pubkey=${effective_pw:-unknown}/${effective_kbd:-unknown}/${effective_pubkey:-unknown}; expected ${pw}/${kbd}/yes."
    warn "sshd resolved root/allowusers/x11/agent/maxtries=${effective_root:-unknown}/${effective_users:-unknown}/${effective_x11:-unknown}/${effective_agent:-unknown}/${effective_tries:-unknown}; expected no/${me}/no/no/3."
    [[ "$pw" != no || "$kbd" != no || "$methods_ok" == 1 ]] || \
      warn "AuthenticationMethods=${effective_methods:-unknown} does not permit publickey by itself."
    warn "Something earlier in /etc/ssh/sshd_config wins (first-match). Check the Include"
    warn "line is near the TOP of /etc/ssh/sshd_config, above authentication settings."
    abort_sshd_transaction || true
    return 1
  fi

  if (( was_active )); then
    SSHD_TXN_DAEMON_TOUCHED=1
    if ! sudo systemctl reload sshd 2>/dev/null && ! sudo systemctl restart sshd 2>/dev/null; then
      warn "sshd could not reload the new policy; restoring the prior drop-in."
      abort_sshd_transaction || true
      return 1
    fi
  fi
  commit_sshd_transaction
  return 0
}

detect_lan_cidr() {
  if [[ -n "${LAN_CIDR:-}" ]]; then echo "$LAN_CIDR"; return 0; fi
  local dev cidr
  dev=$(ip -4 route show default 2>/dev/null | awk '{for(i=1;i<NF;i++) if($i=="dev"){print $(i+1); exit}}')
  [[ -n "$dev" ]] || return 1
  cidr=$(ip -4 -o addr show dev "$dev" scope global 2>/dev/null | awk '{print $4; exit}')
  [[ -n "$cidr" ]] || return 1
  echo "$cidr"
}

private_lan_cidr() {
  local cidr="$1" a b c d prefix
  [[ "$cidr" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})/([0-9]{1,2})$ ]] || return 1
  a=$((10#${BASH_REMATCH[1]})); b=$((10#${BASH_REMATCH[2]}))
  c=$((10#${BASH_REMATCH[3]})); d=$((10#${BASH_REMATCH[4]}))
  prefix=$((10#${BASH_REMATCH[5]}))
  (( a <= 255 && b <= 255 && c <= 255 && d <= 255 && prefix <= 32 )) || return 1
  (( a == 10 && prefix >= 8 )) && return 0
  (( a == 172 && b >= 16 && b <= 31 && prefix >= 12 )) && return 0
  (( a == 192 && b == 168 && prefix >= 16 )) && return 0
  (( a == 169 && b == 254 && prefix >= 16 )) && return 0
  return 1
}

canonical_ipv4_cidr() {
  local cidr="$1" a b c d prefix ip mask network
  [[ "$cidr" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})/([0-9]{1,2})$ ]] || return 1
  a=$((10#${BASH_REMATCH[1]})); b=$((10#${BASH_REMATCH[2]}))
  c=$((10#${BASH_REMATCH[3]})); d=$((10#${BASH_REMATCH[4]}))
  prefix=$((10#${BASH_REMATCH[5]}))
  (( a <= 255 && b <= 255 && c <= 255 && d <= 255 && prefix <= 32 )) || return 1
  ip=$(( (a << 24) | (b << 16) | (c << 8) | d ))
  if (( prefix == 0 )); then mask=0; else mask=$(( (0xffffffff << (32 - prefix)) & 0xffffffff )); fi
  network=$((ip & mask))
  printf '%d.%d.%d.%d/%d\n' \
    $(( (network >> 24) & 255 )) $(( (network >> 16) & 255 )) \
    $(( (network >> 8) & 255 )) $(( network & 255 )) "$prefix"
}

broad_ufw_inbound_rules() {
  local allowed_source="${1:-}"
  LC_ALL=C awk -v allowed="$allowed_source" '
    BEGIN {
      allowed_alt = allowed
      sub(/\/32$/, "", allowed_alt)
    }
    {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      n = split(line, col, /[[:space:]][[:space:]]+/)
      if (n < 3 || col[2] !~ /^(ALLOW|LIMIT) IN$/) next
      source = col[3]
      sub(/[[:space:]]+#[[:space:]].*$/, "", source)
      # With no argument retain the narrow legacy helper behavior used by
      # older callers. The remote workflow passes its selected LAN CIDR and
      # rejects every other inbound source, not just the literal Anywhere.
      if (allowed == "") {
        if (source ~ /^Anywhere([[:space:]]+\(v6\))?$/) print $0
      } else {
        source_ok = (source == allowed || source == allowed_alt)
        tuple_ok = ((col[1] == "22/tcp" && col[2] == "LIMIT IN") ||
                    (col[1] == "60000:61000/udp" && col[2] == "ALLOW IN") ||
                    (col[1] == "5353/udp" && col[2] == "ALLOW IN"))
        if (!source_ok || !tuple_ok) print $0
      }
    }
  '
}

managed_root_file_or_absent() {
  local path="$1" marker="$2"
  sudo test -L "$path" && return 1
  sudo test -e "$path" || return 0
  sudo test -f "$path" && sudo grep -qF "$marker" "$path"
}

fail2ban_sshd_ready() {
  local attempt
  for attempt in {1..5}; do
    sudo fail2ban-client status sshd >/dev/null 2>&1 && return 0
    sleep 1
  done
  return 1
}

legacy_session_helper() {
  local path="$1"
  [[ ! -L "$path" && -f "$path" ]] || return 1
  grep -q '^# ai-session — attach-or-create a persistent coding-agent session' "$path" || return 1
  # Recognize both the immediately preceding credential-loading template and
  # the exact helper emitted by the committed single-model setup.
  grep -q 'local router credentials' "$path" && return 0
  grep -q '^# Pick the agent: explicit env > saved setup.env > pi\.$' "$path" &&
    grep -qF 'tmux send-keys -t "=$name" "$AGENT" C-m' "$path"
}

write_session_helper() {
  local output="$1"
  cat > "$output" <<'EOF'
#!/usr/bin/env bash
# Managed by local-ai-setup: LAN tmux coding-agent session helper.
# ai-session — attach-or-create a persistent coding-agent session (tmux).
# Launches whichever agent you selected (pi or omp). Survives SSH drops and
# device switches; several devices can attach at once and mirror one screen.
#
#   ai-session <project-dir>   attach (or start) the agent session for that dir
#   ai-session                 list running agent sessions
#   AGENT=omp ai-session <dir> override the agent for this session
#
# Detach with Ctrl-b then d — the agent keeps running on the machine.
set -euo pipefail
export PATH="$HOME/.local/bin:$HOME/.bun/bin:$PATH"
export PI_NO_TITLE=1

# Pick the agent: explicit env > saved setup.env > omp.
env_file="$HOME/.config/local-ai/setup.env"
if [[ -z "${AGENT:-}" && -f "$env_file" ]]; then
  AGENT=$(awk -F= '$1=="AGENT"{print $2}' "$env_file" | tail -1)
fi
AGENT="${AGENT:-omp}"
case "$AGENT" in pi|omp) ;; *) echo "invalid AGENT in ${env_file}: $AGENT" >&2; exit 1 ;; esac

# Non-interactive SSH commands do not reliably source .bashrc/.zshrc. Load the
# local router credentials and port directly before creating the tmux session.
router_port=8080
if [[ -f "$env_file" ]]; then
  saved_port=$(awk -F= '$1=="PORT"{print $2}' "$env_file" | tail -1)
  [[ "$saved_port" =~ ^[0-9]+$ ]] && router_port="$saved_port"
fi
key_file="$HOME/.config/local-ai/llama.key"
[[ -s "$key_file" ]] || { echo "missing local router key: $key_file" >&2; exit 1; }
export LLAMA_API_KEY="$(<"$key_file")"
export LLAMA_BASE_URL="http://127.0.0.1:${router_port}"
export LLAMA_CPP_BASE_URL="http://127.0.0.1:${router_port}"

if [[ $# -eq 0 ]]; then
  echo "agent sessions:"
  tmux ls 2>/dev/null | grep '^ai-' || echo "  (none)"
  echo "usage: ai-session <project-dir>   (agent: $AGENT)"
  exit 0
fi

dir=$(cd -- "$1" 2>/dev/null && pwd -P) || { echo "no such directory: $1" >&2; exit 1; }

base=$(basename "$dir")
# The basename remains recognizable, while a canonical-path digest prevents
# two repositories with the same leaf directory from sharing the wrong pane.
path_digest=$(printf '%s' "$dir" | sha256sum)
path_digest="${path_digest%% *}"
name="ai-${base//[^A-Za-z0-9_-]/-}-${path_digest:0:12}"

if ! tmux has-session -t "=$name" 2>/dev/null; then
  tmux new-session -d -s "$name" -c "$dir"
  # tmux servers may predate these environment variables. Have the new pane
  # read the 0600 key itself; the secret is never passed in a tmux argv.
  launch_cmd='export LLAMA_API_KEY="$(<"$HOME/.config/local-ai/llama.key")"; '
  launch_cmd+="export LLAMA_BASE_URL=\"http://127.0.0.1:${router_port}\"; "
  launch_cmd+="export LLAMA_CPP_BASE_URL=\"http://127.0.0.1:${router_port}\"; "
  launch_cmd+="export PI_NO_TITLE=1; exec ${AGENT}"
  tmux send-keys -t "=$name" "$launch_cmd" C-m
fi
exec tmux attach-session -t "=$name"
EOF
}

install_session_helper() {
  info "Installing the ai-session helper to /usr/local/bin"
  local tmp target alias_target alias_value="" alias_ready=0 legacy_target=0 legacy_backup
  tmp=$(mktemp)
  write_session_helper "$tmp"
  target=/usr/local/bin/ai-session
  alias_target=/usr/local/bin/pi-session
  if sudo test -e "$target" || sudo test -L "$target"; then
    if sudo test ! -L "$target" && sudo grep -q '^# Managed by local-ai-setup:' "$target"; then
      : # safe managed replacement
    elif legacy_session_helper "$target"; then
      warn "Migrating a recognized prior generated ai-session helper"
      legacy_target=1
    else
      rm -f "$tmp"
      die "User-owned $target was preserved. Move it explicitly before rerunning remote."
    fi
  fi
  if (( legacy_target )); then
    legacy_backup="${target}.pre-multimodel"
    if ! sudo test -e "$legacy_backup" && ! sudo test -L "$legacy_backup"; then
      sudo cp -p "$target" "$legacy_backup" || {
        rm -f "$tmp"
        die "Could not back up legacy helper to $legacy_backup"
      }
    fi
  fi
  sudo install -o root -g root -m 0755 "$tmp" "$target" || {
    rm -f "$tmp"
    die "Could not install $target"
  }

  # Keep pi-session as a compatibility alias, but never force-replace a
  # generic user-owned command at that name.
  if sudo test -L "$alias_target"; then
    alias_value="$(sudo readlink "$alias_target" 2>/dev/null || true)"
  fi
  if ! sudo test -e "$alias_target" && ! sudo test -L "$alias_target"; then
    if sudo ln -s "$target" "$alias_target"; then alias_ready=1; else warn "Could not create compatibility alias $alias_target"; fi
  elif [[ "$alias_value" == "$target" ]]; then
    alias_ready=1
  else
    warn "User-owned $alias_target was preserved; use ai-session directly."
  fi
  rm -f "$tmp"
  if (( alias_ready )); then
    ok "ai-session installed (pi-session kept as an alias)"
  else
    ok "ai-session installed; existing pi-session was left untouched"
  fi
}

configure_firewall() {
  if systemctl is-active --quiet firewalld 2>/dev/null; then
    warn "firewalld is active, and this setup cannot prove an equivalent default-deny, rate-limited SSH/mosh/mDNS policy there."
    warn "For safety it will not open or bootstrap SSH. Audit firewalld yourself, or disable it explicitly and rerun so the managed UFW policy can be verified."
    return 1
  fi

  local cidr
  if ! cidr=$(detect_lan_cidr); then
    warn "Could not auto-detect your LAN subnet."
    warn "Re-run as:  LAN_CIDR=192.168.1.0/24 $0 remote"
    return 1
  fi
  if ! private_lan_cidr "$cidr"; then
    warn "Refusing non-private or overbroad LAN_CIDR: $cidr"
    warn "Use an RFC1918/link-local IPv4 prefix (10/8, 172.16/12, 192.168/16, or 169.254/16), narrowed as appropriate."
    return 1
  fi
  cidr="$(canonical_ipv4_cidr "$cidr")" || {
    warn "Could not normalize LAN_CIDR: $cidr"
    return 1
  }

  info "Firewall: restrict SSH/mosh/mDNS to your home subnet (${cidr})"
  echo "  (address/prefix form is fine — the firewall masks it to the subnet)"
  local reply=""
  read -r -p "Apply ufw rules and enable the firewall now? [Y/n] " reply || true
  if [[ "$reply" =~ ^[Nn]$ ]]; then warn "Skipped firewall setup."; return 1; fi

  # Ensure ufw also manages ip6tables. If IPV6=no, IPv6 inbound is left to the
  # kernel default (often ACCEPT) — and many home ISPs hand out a globally
  # routable IPv6 address via SLAAC, which would expose sshd to the internet.
  if [[ -f /etc/default/ufw ]] && ! grep -qE '^IPV6=yes' /etc/default/ufw; then
    if grep -qE '^IPV6=' /etc/default/ufw; then
      sudo sed -i 's/^IPV6=.*/IPV6=yes/' /etc/default/ufw || {
        warn "Could not enable IPv6 filtering in /etc/default/ufw"
        return 1
      }
    elif ! printf '%s\n' 'IPV6=yes' | sudo tee -a /etc/default/ufw >/dev/null; then
      warn "Could not enable IPv6 filtering in /etc/default/ufw"
      return 1
    fi
    ok "Set IPV6=yes in /etc/default/ufw (IPv6 now default-denied too)"
  fi

  sudo ufw default deny incoming || { warn "Could not set ufw inbound default"; return 1; }
  sudo ufw default deny routed || { warn "Could not set ufw routed default"; return 1; }
  # Preserve the user's outbound default. Remote access only needs the
  # explicitly scoped inbound rules below; broadening an existing restricted
  # egress policy would be an unrelated and surprising security change.
  # 'limit' rate-limits new SSH connections (>=6 in 30s from one source get
  # dropped) — cheap brute-force resistance for the LAN-facing port.
  sudo ufw limit from "$cidr" to any port 22 proto tcp comment 'ssh (LAN only, rate-limited)' || { warn "Could not add the LAN-only SSH rule"; return 1; }
  sudo ufw allow from "$cidr" to any port 60000:61000 proto udp comment 'mosh (LAN only)' || { warn "Could not add the LAN-only mosh rule"; return 1; }
  sudo ufw allow from "$cidr" to any port 5353 proto udp comment 'mDNS (LAN only)' || { warn "Could not add the LAN-only mDNS rule"; return 1; }
  sudo ufw --force enable || { warn "Could not enable ufw"; return 1; }
  sudo systemctl enable --now ufw >/dev/null 2>&1 || { warn "Could not enable the ufw service"; return 1; }
  local ufw_status broad_rules
  ufw_status="$(sudo env LC_ALL=C ufw status verbose)" || {
    warn "Could not verify the active ufw policy."
    return 1
  }
  printf '%s\n' "$ufw_status"
  grep -q '^Status: active' <<< "$ufw_status" || {
    warn "ufw did not report an active firewall after enable."
    return 1
  }

  # Adding narrow rules does not supersede existing rules. Accept only the
  # exact advertised tuples: rate-limited SSH, mosh, and mDNS from this LAN.
  # This catches an ALLOW (rather than LIMIT) on 22 and a same-LAN catch-all,
  # either of which would invalidate the final policy claim.
  broad_rules="$(broad_ufw_inbound_rules "$cidr" <<< "$ufw_status")"
  if [[ -n "$broad_rules" ]]; then
    warn "Pre-existing inbound rules outside the exact LAN SSH/mosh/mDNS policy were preserved and prevent completion:"
    printf '%s\n' "$broad_rules" | sed 's/^/    /'
    warn "Delete those rules explicitly with 'sudo ufw status numbered' and 'sudo ufw delete <number>', then re-run remote."
    return 1
  fi

  # Defense in depth against password brute force during the bootstrap window.
  if sudo pacman -S --needed --noconfirm fail2ban >/dev/null 2>&1; then
    local jail_tmp jail_target jail_writable=1 jail_backup="" jail_had=0 jail_ok=0
    local fail2ban_was_active=0 fail2ban_was_enabled=0
    jail_target=/etc/fail2ban/jail.d/local-ai-sshd.local
    jail_tmp="$(mktemp)" || jail_tmp=""
    if [[ -n "$jail_tmp" ]]; then
      cat > "$jail_tmp" <<'EOF'
# Generated by setup-qwen38-pi.sh — ban hosts that fail SSH auth repeatedly.
[sshd]
enabled = true
backend = systemd
maxretry = 4
findtime = 10m
bantime = 1h
EOF
    fi
    if ! managed_root_file_or_absent "$jail_target" '# Generated by setup-qwen38-pi.sh'; then
      warn "User-owned fail2ban policy preserved: $jail_target"
      jail_writable=0
    fi
    systemctl is-active --quiet fail2ban 2>/dev/null && fail2ban_was_active=1 || true
    systemctl is-enabled --quiet fail2ban 2>/dev/null && fail2ban_was_enabled=1 || true
    if [[ -n "$jail_tmp" ]] && (( jail_writable )) && sudo mkdir -p /etc/fail2ban/jail.d; then
      if sudo test -e "$jail_target"; then
        jail_backup="$(sudo mktemp /etc/fail2ban/jail.d/.local-ai-sshd-backup.XXXXXX)" || jail_writable=0
        if (( jail_writable )); then
          sudo cp -p "$jail_target" "$jail_backup" || jail_writable=0
          (( jail_writable )) && jail_had=1
        fi
      fi
      if (( jail_writable )); then
        if sudo install -o root -g root -m 0644 "$jail_tmp" "$jail_target" && \
           sudo fail2ban-client -t >/dev/null 2>&1 && \
           sudo systemctl enable fail2ban >/dev/null 2>&1 && \
           sudo systemctl restart fail2ban >/dev/null 2>&1 && \
           fail2ban_sshd_ready; then
          jail_ok=1
        else
          # Restore both file and daemon state if validation/activation failed.
          if (( jail_had )); then sudo cp -p "$jail_backup" "$jail_target" || true; else sudo rm -f "$jail_target" || true; fi
          sudo fail2ban-client -t >/dev/null 2>&1 || true
          if (( fail2ban_was_active )); then
            sudo systemctl restart fail2ban >/dev/null 2>&1 || true
          else
            sudo systemctl stop fail2ban >/dev/null 2>&1 || true
          fi
          (( fail2ban_was_enabled )) || sudo systemctl disable fail2ban >/dev/null 2>&1 || true
        fi
      fi
    fi
    [[ -z "$jail_backup" ]] || sudo rm -f "$jail_backup" || true
    if (( jail_ok )); then
      ok "fail2ban enabled (bans a source after 4 failed SSH logins in 10 min)"
    else
      warn "fail2ban installed but the generated jail was not validated/activated; ufw rate-limiting remains active."
    fi
    [[ -z "$jail_tmp" ]] || rm -f "$jail_tmp"
  else
    warn "Could not install fail2ban — brute-force protection relies on ufw rate-limiting only."
  fi

  ok "Inbound traffic is blocked except SSH/mosh/mDNS from ${cidr}."
  ok "Do NOT port-forward 22 on your router — nothing here should be internet-facing."
}

ensure_tmux_config() {
  local tmux_config="$HOME/.tmux.conf" tmux_tmp
  if [[ ! -e "$tmux_config" && ! -L "$tmux_config" ]]; then
    tmux_tmp="$(mktemp "$HOME/.tmux.conf.local-ai.XXXXXX")" || die "Could not stage ~/.tmux.conf"
    cat > "$tmux_tmp" <<'EOF'
# Defaults for phone-friendly coding-agent sessions (generated; edit freely).
set -g mouse on                       # touch scrolling on iPhone/iPad
set -g history-limit 50000
set -s escape-time 10
setw -g mode-keys vi

# The agents need extended keys so Shift+Enter / Ctrl+Enter aren't plain Enter.
# The csi-u form needs tmux >= 3.5, so guard it below.
set -g extended-keys on
%if "#{>=:#{version},3.5}"
set -g extended-keys-format csi-u
%endif

# Truecolor + focus events so the TUI renders correctly over SSH.
set -g default-terminal "tmux-256color"
set -ga terminal-features ",*:RGB"
set -g focus-events on
EOF
    chmod 600 "$tmux_tmp" || { rm -f -- "$tmux_tmp"; die "Could not protect staged ~/.tmux.conf"; }
    mv -- "$tmux_tmp" "$tmux_config" || { rm -f -- "$tmux_tmp"; die "Could not atomically install ~/.tmux.conf"; }
    ok "wrote ~/.tmux.conf (mouse + extended keys tuned for coding agents)"
  elif [[ ! -L "$tmux_config" && -f "$tmux_config" ]]; then
    ok "existing ~/.tmux.conf found — leaving it alone"
  else
    warn "Non-regular or symlinked ~/.tmux.conf preserved; configure tmux manually."
  fi
}

cmd_remote() {
  need_arch
  info "Setting up LAN-only remote access (SSH + mosh + tmux + mDNS)"
  sudo pacman -Syu --needed --noconfirm openssh mosh tmux avahi ufw

  # Make sure key-based logins have somewhere to land.
  mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
  touch "$HOME/.ssh/authorized_keys" && chmod 600 "$HOME/.ssh/authorized_keys"

  # Fresh Arch installs generate host keys through sshdgenkeys.service. Do
  # that before policy inspection or firewall mutation, without starting the
  # listening daemon, so first-run `sshd -T` can validate safely.
  ensure_sshd_host_keys || \
    die "Could not generate SSH host keys without opening the port; remote setup made no firewall or sshd-policy change."

  # Establish the LAN-only perimeter before opening sshd or enabling any
  # password bootstrap path. A declined/unknown firewall state is a hard stop.
  configure_firewall || die "Firewall was not confirmed; SSH/password bootstrap was not enabled."

  local effective_config password_mode kbd_mode
  # Snapshot the effective policy, including settings from drop-ins this script
  # does not own. Re-running `remote` must never weaken an existing key-only
  # configuration just because our own drop-in is absent.
  effective_config="$(sshd_effective_config)" || die "Could not resolve the current sshd authentication policy."
  password_mode="$(awk '$1=="passwordauthentication"{print $2; exit}' <<< "$effective_config")"
  kbd_mode="$(awk '$1=="kbdinteractiveauthentication"{print $2; exit}' <<< "$effective_config")"
  case "$password_mode" in yes|no) ;; *) die "sshd did not report PasswordAuthentication" ;; esac
  case "$kbd_mode" in yes|no) ;; *) die "sshd did not report KbdInteractiveAuthentication" ;; esac
  if ! write_sshd_dropin "$password_mode" "$kbd_mode"; then
    die "SSH policy drop-in did not fully apply; the prior configuration was restored."
  fi
  # The validated drop-in is now on disk. Starting an inactive daemon only at
  # this point avoids a window where it listens under a preexisting policy.
  sudo systemctl enable --now sshd || die "Could not enable sshd with the validated policy"
  if [[ "$password_mode" == no && "$kbd_mode" == no ]]; then
    ok "sshd enabled; existing key-only authentication policy preserved"
  else
    ok "sshd enabled (password/keyboard bootstrap modes: ${password_mode}/${kbd_mode})"
    warn "Run '$0 ssh-harden' once keys are installed on every device."
  fi

  sudo systemctl enable --now avahi-daemon || die "Could not enable avahi-daemon"
  ok "mDNS enabled — this machine is reachable as $(hostname).local on your LAN"

  ensure_tmux_config

  install_session_helper

  local me host
  me="${USER:-$(id -un)}"
  host="$(hostname)"

  # Print host-key fingerprints so you can verify them out-of-band on first
  # connect. mDNS names (${host}.local) are unauthenticated and spoofable, so a
  # hostile LAN device could impersonate this box and harvest your password on
  # the very first connection. Compare what your SSH client shows against this:
  echo
  info "This machine's SSH host-key fingerprints — verify these on first connect:"
  local hk
  for hk in /etc/ssh/ssh_host_ed25519_key.pub /etc/ssh/ssh_host_ecdsa_key.pub; do
    [[ -f "$hk" ]] && ssh-keygen -lf "$hk" 2>/dev/null | sed 's/^/    /'
  done
  cat <<EOF

  ── Connect from your devices (same wifi) ────────────────────────────────

  Preserved password/keyboard-interactive modes: ${password_mode}/${kbd_mode}
  ssh-copy-id or a password-first connection works only when one of those
  modes (or another existing login method) permits it. Under an existing
  key-only policy, add the new public key locally or from a trusted session.

  Laptop (macOS / Linux):
     ssh-copy-id ${me}@${host}.local                      # once per laptop
     ssh -t ${me}@${host}.local ai-session ~/some-project
     mosh ${me}@${host}.local -- ai-session ~/some-project    # survives sleep/roaming

  iPhone / iPad — Blink Shell (best mosh support) or Termius:
     1. Generate a key in the app and copy the public key
     2. If password bootstrap is permitted, connect once and run:
          echo '<pasted public key>' >> ~/.ssh/authorized_keys
     3. From then on:  ai-session <project-dir>
     Prefer mosh in Blink — it stays alive when iOS suspends the app.

  ai-session launches your selected agent (${AGENT}); all devices on the same
  session mirror one screen. Detach: Ctrl-b then d · list sessions: ai-session

  When every device has a key installed, lock out passwords:
     $0 ssh-harden

EOF
}

cmd_ssh_harden() {
  need_arch
  local keys=0 effective_config effective_authorized_keys
  command -v ssh-keygen >/dev/null 2>&1 || die "ssh-keygen not found — install openssh first"
  ensure_sshd_host_keys || \
    die "Could not generate SSH host keys without opening the port; hardening was not attempted."
  effective_config="$(sshd_effective_config)" || \
    die "Could not resolve sshd's effective AuthorizedKeysFile policy; hardening was not attempted."
  effective_authorized_keys="$(awk '$1=="authorizedkeysfile" {$1=""; sub(/^[[:space:]]+/, ""); print; exit}' <<< "$effective_config")"
  sshd_effective_authorized_keys_includes_checked_file "$effective_config" || \
    die "Effective AuthorizedKeysFile (${effective_authorized_keys:-none}) does not include $HOME/.ssh/authorized_keys; refusing to disable passwords based on a key file sshd ignores."
  if [[ -f "$HOME/.ssh/authorized_keys" ]]; then
    keys=$(ssh-keygen -lf "$HOME/.ssh/authorized_keys" 2>/dev/null | wc -l | tr -d ' ' || true)
    keys="${keys:-0}"
  fi
  (( keys > 0 )) || die "No valid keys in ~/.ssh/authorized_keys — add a valid public key first, or you'll lock yourself out."
  if write_sshd_dropin no no; then
    if (( SSHD_LAST_WAS_ACTIVE )); then
      ok "Password auth disabled — SSH is now key-only (${keys} authorized key(s))."
      ok "Confirm from a SECOND session before closing this one:  ssh ${USER:-$(id -un)}@localhost true"
    else
      ok "Key-only policy staged (${keys} authorized key(s)); sshd remains inactive."
    fi
  else
    die "Hardening did NOT take effect (see warnings). Password auth may still be ON — do not assume you're locked down."
  fi
}

cmd_all() {
  save_config          # persist the agent/tunables this run used
  cmd_check
  cmd_install
  if system_reboot_required && [[ "$ALLOW_PENDING_REBOOT" != 1 ]]; then
    die "System packages/TTM changed and a reboot is required. No model download or GPU load was attempted; reboot and run '$0 all' again."
  fi
  cmd_model everyday
  cmd_service
  cmd_agent
  echo
  ok "Everyday baseline ready (agent: ${AGENT}). Try: $0 status; then cd <project> && $LOCAL_BIN_DIR/local-ai-agent"
  echo "   Optional model team: $0 model coder   and   $0 model senior"
  echo "   Optional: $0 remote   — SSH/mosh access from your phones and laptops (LAN-only)"
}

# --------------------------------- main --------------------------------------

cmd_help() {
  cat <<EOF
Usage: $0 <command> [arguments]

Baseline:       all | check | install | model [tier|all] [--yes] | service | agent
Model team:     model-catalog | model-verify [tier|all] | model-remove <tier> [--yes] | model-prune [--yes]
Lifecycle:      model-maintain remove <tier> [--yes] | model-maintain prune [--yes]
Configuration:  plan | apply | show-config | save-config KEY=VALUE ... | routing [--force]
Operations:     status [--json] | smoke [tier] | bench [tier] [--manage-service] | perf [tier] [--keep] | perf-history [tier|all]
Agents:         pi | omp | agent-upgrade [pi|omp] | omp-lsp
System:         kernel-tweaks | remote | ssh-harden

Model download/verification/history also accept all; runtime load/bench/perf tiers are everyday, coder, or senior.
Run '$0 plan' for the resolved read-only plan.
EOF
}

require_no_args() {
  local command_name="$1"
  shift
  (( $# == 0 )) || die "Usage: $0 ${command_name}"
}

OPERATION_LOCK_DIR=""
OPERATION_LOCK_HELD=0
LOCKED_CHILD_PID=0
LOCKED_CHILD_PGID=0
LOCKED_DESCENDANT_PIDS=""

release_operation_lock() {
  (( OPERATION_LOCK_HELD )) || return 0
  [[ -n "$OPERATION_LOCK_DIR" && "$OPERATION_LOCK_DIR" == */local-ai-setup-*.lock ]] || return 1
  rm -f -- "$OPERATION_LOCK_DIR/pid" 2>/dev/null || true
  rmdir "$OPERATION_LOCK_DIR" 2>/dev/null || true
  OPERATION_LOCK_HELD=0
}

operation_runtime_dir_safe() {
  local path="$1" uid mode mode_value
  [[ -d "$path" && ! -L "$path" ]] || return 1
  uid="$(local_ai_file_uid "$path" 2>/dev/null || true)"
  mode="$(local_ai_file_mode "$path" 2>/dev/null || true)"
  [[ "$uid" == "$(id -u)" && "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
  mode_value=$((8#$mode))
  (( (mode_value & 0022) == 0 ))
}

operation_runtime_root() {
  local candidate fallback
  if [[ -n "${XDG_RUNTIME_DIR:-}" ]]; then
    candidate="$XDG_RUNTIME_DIR"
    operation_runtime_dir_safe "$candidate" || \
      die "XDG_RUNTIME_DIR is not a private directory owned by this user: $candidate"
    printf '%s\n' "$candidate"
    return 0
  fi
  candidate="${TMPDIR:-/tmp}"
  if operation_runtime_dir_safe "$candidate"; then
    printf '%s\n' "$candidate"
    return 0
  fi
  # /tmp itself is intentionally shared. Keep the stable cross-process lock
  # under the private application config tree rather than using a predictable
  # shared sticky-directory child another user can pre-create.
  fallback="$LOCAL_AI_CONFIG_DIR/runtime"
  [[ ! -L "$LOCAL_AI_CONFIG_DIR" && ! -L "$fallback" ]] || \
    die "Refusing symlinked local-AI runtime directory: $fallback"
  mkdir -p "$fallback" || die "Could not create private runtime directory: $fallback"
  chmod 700 "$LOCAL_AI_CONFIG_DIR" "$fallback" || \
    die "Could not protect private runtime directory: $fallback"
  operation_runtime_dir_safe "$fallback" || \
    die "Local-AI runtime directory is not private and user-owned: $fallback"
  printf '%s\n' "$fallback"
}

process_start_cookie() {
  local pid="$1"
  LC_ALL=C ps -o lstart= -p "$pid" 2>/dev/null | awk '{$1=$1; print; exit}'
}

acquire_operation_lock() {
  local runtime_root owner_pid owner_cookie live_cookie attempt stale_claim
  runtime_root="$(operation_runtime_root)"
  # One lock per user deliberately covers every mutable root. MODELS_DIR is
  # itself configurable, while setup.env, OMP launchers, the user service, and
  # SSH/firewall operations remain shared; deriving the lock from a mutable
  # path would let two lifecycle commands race those common resources.
  OPERATION_LOCK_DIR="${runtime_root%/}/local-ai-setup-$(id -u).lock"
  for attempt in 1 2 3 4; do
    if mkdir "$OPERATION_LOCK_DIR" 2>/dev/null; then
      chmod 700 "$OPERATION_LOCK_DIR" 2>/dev/null || true
      printf '%s\n%s\n' "$$" "$(process_start_cookie "$$")" > "$OPERATION_LOCK_DIR/pid" || {
        rmdir "$OPERATION_LOCK_DIR" 2>/dev/null || true
        die "Could not record operation lock owner"
      }
      OPERATION_LOCK_HELD=1
      return 0
    fi
    [[ -d "$OPERATION_LOCK_DIR" && ! -L "$OPERATION_LOCK_DIR" ]] || \
      die "Unsafe local-AI operation lock path: $OPERATION_LOCK_DIR"
    operation_runtime_dir_safe "$OPERATION_LOCK_DIR" || \
      die "Local-AI operation lock is not private and user-owned: $OPERATION_LOCK_DIR"
    owner_pid="$(sed -n '1p' "$OPERATION_LOCK_DIR/pid" 2>/dev/null || true)"
    owner_cookie="$(sed -n '2p' "$OPERATION_LOCK_DIR/pid" 2>/dev/null || true)"
    if [[ "$owner_pid" =~ ^[0-9]+$ ]] && kill -0 "$owner_pid" 2>/dev/null; then
      live_cookie="$(process_start_cookie "$owner_pid" || true)"
      if [[ -z "$owner_cookie" || -z "$live_cookie" || "$live_cookie" == "$owner_cookie" ]]; then
        die "Another local-AI mutation is already running (PID $owner_pid). Wait for it to finish before retrying."
      fi
      warn "Operation-lock PID $owner_pid was reused; reclaiming the stale identity."
    fi
    # Claim the stale directory with one atomic rename. Competing reclaimers
    # can no longer delete a fresh live lock using a cached dead PID.
    stale_claim="${OPERATION_LOCK_DIR}.stale.$$.$attempt"
    [[ ! -e "$stale_claim" && ! -L "$stale_claim" ]] || continue
    if mv -- "$OPERATION_LOCK_DIR" "$stale_claim" 2>/dev/null; then
      warn "Recovering stale local-AI operation lock${owner_pid:+ from PID $owner_pid}."
      rm -f -- "$stale_claim/pid" 2>/dev/null || die "Could not clear claimed stale operation lock"
      rmdir "$stale_claim" 2>/dev/null || \
        die "Claimed stale lock contained unexpected files; inspect $stale_claim"
    fi
  done
  die "Could not acquire the local-AI operation lock"
}

child_pids_of() {
  local parent="$1"
  if command -v pgrep >/dev/null 2>&1; then
    pgrep -P "$parent" 2>/dev/null || true
  else
    ps -eo pid=,ppid= 2>/dev/null | awk -v parent="$parent" '$2 == parent { print $1 }'
  fi
}

stop_locked_descendants() {
  local parent="$1" child
  while IFS= read -r child; do
    [[ "$child" =~ ^[0-9]+$ ]] || continue
    kill -STOP "$child" 2>/dev/null || continue
    LOCKED_DESCENDANT_PIDS="${LOCKED_DESCENDANT_PIDS}${child}"$'\n'
    stop_locked_descendants "$child"
  done < <(child_pids_of "$parent")
}

signal_locked_descendants() {
  local signal="$1" child
  while IFS= read -r child; do
    [[ "$child" =~ ^[0-9]+$ ]] || continue
    kill -"$signal" "$child" 2>/dev/null || true
  done <<< "$LOCKED_DESCENDANT_PIDS"
}

locked_descendants_exist() {
  local child state
  while IFS= read -r child; do
    [[ "$child" =~ ^[0-9]+$ ]] || continue
    kill -0 "$child" 2>/dev/null || continue
    # A grandchild killed after its immediate shell exits can briefly be an
    # orphan zombie. It cannot write a .part file or contend with a retry, and
    # this process is not its parent so wait(2) cannot reap it. Do not hold the
    # lifecycle lock waiting for the OS reaper; keep failing closed if process
    # state cannot be inspected.
    state="$(ps -o stat= -p "$child" 2>/dev/null | awk '{print $1; exit}')"
    [[ "$state" == Z* ]] || return 0
  done <<< "$LOCKED_DESCENDANT_PIDS"
  return 1
}

locked_command_signal_handler() {
  trap - HUP INT TERM
  if [[ "$LOCKED_CHILD_PID" =~ ^[0-9]+$ ]] && (( LOCKED_CHILD_PID > 0 )); then
    if [[ "$LOCKED_CHILD_PGID" =~ ^[0-9]+$ ]] && (( LOCKED_CHILD_PGID > 0 )) &&
       kill -TERM "-$LOCKED_CHILD_PGID" 2>/dev/null; then
      # locked_command gives the entire mutation its own process group. TERM
      # stops writers while still allowing command-root transaction traps to
      # restore service/config state; after the root exits, KILL any orphaned
      # group members before releasing the lifecycle lock.
      wait "$LOCKED_CHILD_PID" 2>/dev/null || true
      kill -KILL "-$LOCKED_CHILD_PGID" 2>/dev/null || true
    else
      # Conservative fallback for a shell that cannot create a background
      # process group. Freeze each parent before enumerating descendants so
      # no worker can fork past the snapshot.
      kill -STOP "$LOCKED_CHILD_PID" 2>/dev/null || true
      LOCKED_DESCENDANT_PIDS=""
      stop_locked_descendants "$LOCKED_CHILD_PID"
      signal_locked_descendants KILL
      kill -CONT "$LOCKED_CHILD_PID" 2>/dev/null || true
      kill -TERM "$LOCKED_CHILD_PID" 2>/dev/null || true
      wait "$LOCKED_CHILD_PID" 2>/dev/null || true
    fi
  fi
  release_operation_lock
  exit 130
}

locked_command() {
  local rc=0
  acquire_operation_lock
  reload_persisted_config_under_lock
  trap 'locked_command_signal_handler' HUP INT TERM
  set +e
  # Non-interactive Bash normally puts background jobs in the parent's process
  # group. Briefly enable job control so this mutation and every worker it
  # spawns can be terminated as one group without process-table inspection.
  set -m
  ( set -e; "$@" ) &
  LOCKED_CHILD_PID=$!
  LOCKED_CHILD_PGID=$LOCKED_CHILD_PID
  if [[ -t 0 || -t 1 || -t 2 ]]; then
    # A background process group is stopped by the kernel when it reads the
    # controlling terminal. Put the mutation job in the foreground so model,
    # sudo, firewall, and kernel confirmation prompts remain usable while the
    # parent still owns the lifecycle lock and can terminate the whole group.
    # The mutation can finish between `$!` and `fg`; in that case Bash drops
    # the job-table entry and `fg %%` reports failure even though the command
    # succeeded. Use fg only to transfer terminal ownership, then always wait
    # by PID, whose saved exit status remains available in both cases.
    if kill -0 "$LOCKED_CHILD_PID" 2>/dev/null; then
      # Bash uses fg's stderr as its controlling terminal on older releases;
      # redirecting it can leave a prompt-reading child stopped indefinitely.
      fg %% >/dev/null
    fi
    wait "$LOCKED_CHILD_PID"
    rc=$?
  else
    set +m
    wait "$LOCKED_CHILD_PID"
    rc=$?
  fi
  set +m
  LOCKED_CHILD_PID=0
  LOCKED_CHILD_PGID=0
  set -e
  trap - HUP INT TERM
  release_operation_lock
  return "$rc"
}

if [[ "${LOCAL_AI_SETUP_LIB_ONLY:-0}" != 1 ]]; then
command_name="${1:-help}"
(( $# == 0 )) || shift
case "$command_name" in
  help|-h|--help) require_no_args help "$@"; cmd_help ;;
  all)            require_no_args all "$@"; locked_command cmd_all ;;
  check)          require_no_args check "$@"; cmd_check ;;
  install)        require_no_args install "$@"; locked_command cmd_install ;;
  model)          locked_command cmd_model "$@" ;;
  model-catalog)  require_no_args model-catalog "$@"; cmd_model_catalog ;;
  model-verify)   locked_command cmd_model_verify "$@" ;;
  model-remove)   locked_command cmd_model_remove "$@" ;;
  model-prune)    locked_command cmd_model_prune "$@" ;;
  model-maintain) locked_command cmd_model_maintain "$@" ;;
  service)        require_no_args service "$@"; locked_command cmd_service ;;
  agent)          require_no_args agent "$@"; locked_command cmd_agent ;;
  agent-upgrade)  locked_command cmd_agent_upgrade "$@" ;;
  pi)             require_no_args pi "$@"; locked_command cmd_pi ;;
  omp)            require_no_args omp "$@"; locked_command cmd_omp ;;
  omp-lsp)        require_no_args omp-lsp "$@"; locked_command cmd_omp_lsp ;;
  routing)        locked_command cmd_routing "$@" ;;
  plan)           cmd_plan "$@" ;;
  apply)          locked_command cmd_apply "$@" ;;
  kernel-tweaks)  require_no_args kernel-tweaks "$@"; locked_command cmd_kernel_tweaks ;;
  remote)         require_no_args remote "$@"; locked_command cmd_remote ;;
  ssh-harden)     require_no_args ssh-harden "$@"; locked_command cmd_ssh_harden ;;
  bench)          locked_command cmd_bench "$@" ;;
  perf)           locked_command cmd_perf "$@" ;;
  perf-history)   cmd_perf_history "$@" ;;
  status)         cmd_status "$@" ;;
  smoke)          locked_command cmd_smoke "$@" ;;
  show-config)    require_no_args show-config "$@"; cmd_show_config ;;
  save-config)    locked_command cmd_save_config "$@" ;;
  *) die "Unknown subcommand: $command_name (run '$0 help')" ;;
esac
fi
