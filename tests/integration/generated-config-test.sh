#!/usr/bin/env bash
# Fast, offline tests for manifest parsing and generated configuration.
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
ENGINE="$ROOT/setup-qwen38-pi.sh"
MANAGER="$ROOT/manage.sh"
REAL_LOCK="$ROOT/models.lock"
TEST_TMP="$(mktemp -d "${TMPDIR:-/tmp}/local-ai-setup-test.XXXXXX")"
LOCK="$TEST_TMP/models.lock"

cleanup() {
  [[ "$TEST_TMP" == */local-ai-setup-test.* ]] || return 1
  rm -rf -- "$TEST_TMP"
}
trap cleanup EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$*"; }

command -v jq >/dev/null 2>&1 || fail "jq is required for the test suite"
command -v sha256sum >/dev/null 2>&1 || fail "sha256sum is required for the test suite"
bash -n "$ENGINE" "$MANAGER" "$0"
pass "shell syntax"

rows="$(awk -F'|' '!/^#/ && NF { n++ } END { print n + 0 }' "$REAL_LOCK")"
[[ "$rows" == 11 ]] || fail "expected 11 locked artifacts, found $rows"
awk -F'|' '
  !/^#/ && NF {
    if (NF != 10 || $6 !~ /^[0-9a-f]{40}$/ || $8 !~ /^[0-9]+$/ ||
        $9 !~ /^[0-9a-f]{64}$/ || $7 == "" || $7 ~ /(^|\/)\.\.($|\/)/) exit 1
  }
' "$REAL_LOCK" || fail "malformed artifact lock row"
awk -F'|' '
  $1 == "everyday" && $3 != "qwen3.8-27b" { exit 1 }
  $1 == "coder" && $3 != "coder" { exit 1 }
  $1 == "senior" && $3 != "qwen3.5-122b-a10b" { exit 1 }
' "$REAL_LOCK" || fail "model IDs do not match their OMP compatibility strategy"
pass "artifact lock schema"

# Build a tiny content-addressed lock with the same shape as the production
# manifest. This exercises real byte/SHA validation without allocating 133-144 GiB.
fixture_source="$TEST_TMP/fixture-source"
: > "$LOCK"
while IFS='|' read -r tier variant id model_dir repo revision remote _bytes _sha kind; do
  [[ -z "$tier" || "$tier" == \#* ]] && continue
  printf 'fixture|%s|%s|%s' "$tier" "$variant" "$remote" > "$fixture_source"
  fixture_bytes="$(wc -c < "$fixture_source" | tr -d ' ')"
  fixture_sha="$(sha256sum "$fixture_source" | awk '{print $1}')"
  printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
    "$tier" "$variant" "$id" "$model_dir" "$repo" "$revision" "$remote" \
    "$fixture_bytes" "$fixture_sha" "$kind" >> "$LOCK"
done < "$REAL_LOCK"

catalog="$TEST_TMP/catalog.txt"
MODEL_LOCK="$LOCK" \
LOCAL_AI_CONFIG_DIR="$TEST_TMP/catalog-config" \
MODELS_DIR="$TEST_TMP/catalog-models" \
  "$ENGINE" model-catalog > "$catalog"
grep -q 'everyday.*not installed' "$catalog" || fail "catalog omitted everyday tier"
grep -q 'coder.*not installed' "$catalog" || fail "catalog omitted coder tier"
grep -q 'senior.*not installed' "$catalog" || fail "catalog omitted senior tier"
pass "offline catalog parsing"

partial_catalog_models="$TEST_TMP/partial-catalog-models"
partial_catalog="$TEST_TMP/partial-catalog.txt"
IFS='|' read -r _tier _variant _id partial_model_dir _repo _revision \
  partial_remote _bytes _sha _kind < <(
    awk -F'|' '$1=="everyday" && $2=="UD-Q4_K_XL" {print; exit}' "$LOCK"
  )
mkdir -p "$partial_catalog_models/$partial_model_dir"
printf 'x' > "$partial_catalog_models/$partial_model_dir/${partial_remote##*/}.part"
MODEL_LOCK="$LOCK" LOCAL_AI_CONFIG_DIR="$TEST_TMP/partial-catalog-config" \
MODELS_DIR="$partial_catalog_models" \
  "$ENGINE" model-catalog > "$partial_catalog"
grep -Eq 'everyday.*partial.*[0-9]+\.[0-9]+%' "$partial_catalog" || \
  fail "catalog omitted partial artifact state or byte progress"
pass "partial artifact catalog progress"

# Routing must not emit a nullable/empty models list and dangling selectors.
no_models_omp="$TEST_TMP/no-models-omp"
if MODEL_LOCK="$LOCK" LOCAL_AI_CONFIG_DIR="$TEST_TMP/no-models-config" \
    MODELS_DIR="$TEST_TMP/catalog-models" OMP_AGENT_DIR="$no_models_omp" \
    "$ENGINE" routing >/dev/null 2>&1; then
  fail "routing succeeded without any complete model tier"
fi
[[ ! -e "$no_models_omp/models.yml" && ! -e "$no_models_omp/config.yml" ]] || \
  fail "routing wrote active files without an installed model"
pass "zero-tier routing rejection"

no_model_home="$TEST_TMP/no-model-agent-home"
no_model_bin="$TEST_TMP/no-model-agent-bin"
mkdir -p "$no_model_home" "$no_model_bin"
cat > "$no_model_bin/omp" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == --version ]] && { printf 'omp 18.0.10\n'; exit 0; }
exit 0
EOF
chmod 755 "$no_model_bin/omp"
HOME="$no_model_home" PATH="$no_model_bin:$PATH" MODEL_LOCK="$LOCK" \
  LOCAL_AI_CONFIG_DIR="$TEST_TMP/no-model-agent-config" MODELS_DIR="$TEST_TMP/no-model-agent-models" \
  LOCAL_BIN_DIR="$TEST_TMP/no-model-agent-local-bin" OMP_AGENT_DIR="$TEST_TMP/no-model-agent-omp" \
  "$ENGINE" omp >/dev/null
[[ -x "$TEST_TMP/no-model-agent-local-bin/local-ai-agent" ]] || \
  fail "direct OMP install without a model omitted same-shell launcher integration"
grep -q 'managed-by-local-ai-setup: LLAMA_API_KEY' "$no_model_home/.bashrc" || \
  fail "direct OMP install without a model omitted shell integration"
pass "OMP installation remains usable before model download"

# A crash after the last download byte but before rename must recover a valid
# .part locally instead of retrying from EOF and getting HTTP 416 forever.
part_dir="$TEST_TMP/part-recovery"
part_dest="$part_dir/artifact.gguf"
mkdir -p "$part_dir"
printf 'complete-part-fixture' > "${part_dest}.part"
part_bytes="$(wc -c < "${part_dest}.part" | tr -d ' ')"
part_sha="$(sha256sum "${part_dest}.part" | awk '{print $1}')"
MODEL_LOCK="$LOCK" LOCAL_AI_CONFIG_DIR="$TEST_TMP/part-config" \
MODELS_DIR="$TEST_TMP/part-models" LOCAL_AI_SETUP_LIB_ONLY=1 \
  bash -c 'source "$1"; download_artifact "https://example.invalid/artifact" "$2" "$3" "$4" everyday' \
    _ "$ENGINE" "$part_dest" "$part_bytes" "$part_sha" >/dev/null
[[ -f "$part_dest" && ! -e "${part_dest}.part" ]] || fail "verified complete .part was not promoted"
pass "complete partial-download recovery"

resume_dest="$TEST_TMP/short-resume/artifact.gguf"
resume_expected="$TEST_TMP/short-resume/expected.gguf"
resume_marker="$TEST_TMP/short-resume/curl-resumed"
mkdir -p "$(dirname "$resume_dest")"
printf 'prefix' > "${resume_dest}.part"
printf 'prefixsuffix' > "$resume_expected"
resume_bytes="$(wc -c < "$resume_expected" | tr -d ' ')"
resume_sha="$(sha256sum "$resume_expected" | awk '{print $1}')"
CURL_RESUMED="$resume_marker" MODEL_LOCK="$LOCK" \
LOCAL_AI_CONFIG_DIR="$TEST_TMP/short-resume-config" \
MODELS_DIR="$TEST_TMP/short-resume-models" LOCAL_AI_SETUP_LIB_ONLY=1 \
  bash -c '
    source "$1"
    curl() {
      local output="" resume=0
      while (( $# )); do
        case "$1" in
          -C) [[ "${2:-}" == - ]] || return 98; resume=1; shift 2 ;;
          -o) output="${2:-}"; shift 2 ;;
          *) shift ;;
        esac
      done
      (( resume == 1 )) || return 97
      printf suffix >> "$output"
      : > "$CURL_RESUMED"
    }
    download_artifact "https://example.invalid/artifact" "$2" "$3" "$4" everyday
  ' _ "$ENGINE" "$resume_dest" "$resume_bytes" "$resume_sha" >/dev/null
[[ -e "$resume_marker" && -f "$resume_dest" && ! -e "${resume_dest}.part" ]] || \
  fail "short partial download did not use curl resume and promote the result"
[[ "$(sha256sum "$resume_dest" | awk '{print $1}')" == "$resume_sha" ]] || \
  fail "resumed partial download produced the wrong artifact"
pass "short partial-download resume"

# A complete-but-corrupt or oversized resume file is evidence to preserve, not
# something curl should append to or the downloader should silently replace.
for invalid_part_case in corrupt oversized; do
  invalid_dest="$TEST_TMP/${invalid_part_case}-part/artifact.gguf"
  invalid_marker="$TEST_TMP/${invalid_part_case}-part-curl.called"
  mkdir -p "$(dirname "$invalid_dest")"
  case "$invalid_part_case" in
    corrupt)
      printf 'wrong' > "${invalid_dest}.part"
      invalid_bytes=5
      invalid_sha="$(printf 'right' | sha256sum | awk '{print $1}')"
      ;;
    oversized)
      printf 'too-large' > "${invalid_dest}.part"
      invalid_bytes=1
      invalid_sha="$(printf 'x' | sha256sum | awk '{print $1}')"
      ;;
  esac
  invalid_before="$(sha256sum "${invalid_dest}.part" | awk '{print $1}')"
  if CURL_CALLED="$invalid_marker" MODEL_LOCK="$LOCK" \
      LOCAL_AI_CONFIG_DIR="$TEST_TMP/${invalid_part_case}-part-config" \
      MODELS_DIR="$TEST_TMP/${invalid_part_case}-part-models" \
      LOCAL_AI_SETUP_LIB_ONLY=1 \
      bash -c 'source "$1"; curl(){ : > "$CURL_CALLED"; return 99; }; download_artifact "https://example.invalid/artifact" "$2" "$3" "$4" everyday' \
        _ "$ENGINE" "$invalid_dest" "$invalid_bytes" "$invalid_sha" \
        >/dev/null 2>&1; then
    fail "downloader accepted a complete invalid $invalid_part_case .part file"
  fi
  [[ ! -e "$invalid_marker" ]] || fail "downloader attempted network recovery for an invalid $invalid_part_case .part file"
  [[ "$invalid_before" == "$(sha256sum "${invalid_dest}.part" | awk '{print $1}')" ]] || \
    fail "downloader changed the retained $invalid_part_case .part file"
done
pass "corrupt and oversized partial-download retention"

# Never follow a planted resume symlink, including a dangling one that `-e`
# alone would miss. A shared/custom model directory must not enable writes to
# an unrelated path through curl's output handling.
symlink_dest="$TEST_TMP/symlink-download/artifact.gguf"
symlink_target="$TEST_TMP/unrelated-download-target"
mkdir -p "$(dirname "$symlink_dest")"
ln -s "$symlink_target" "${symlink_dest}.part"
if MODEL_LOCK="$LOCK" LOCAL_AI_CONFIG_DIR="$TEST_TMP/symlink-config" \
    MODELS_DIR="$TEST_TMP/symlink-models" LOCAL_AI_SETUP_LIB_ONLY=1 \
    bash -c 'source "$1"; download_artifact "https://example.invalid/artifact" "$2" 1 "$3" everyday' \
      _ "$ENGINE" "$symlink_dest" "$(printf x | sha256sum | awk '{print $1}')" \
      >/dev/null 2>&1; then
  fail "downloader accepted a symlinked .part path"
fi
[[ -L "${symlink_dest}.part" && ! -e "$symlink_target" ]] || \
  fail "downloader followed or replaced a symlinked .part path"
pass "download path symlink rejection"

MODEL_LOCK="$LOCK" LOCAL_AI_CONFIG_DIR="$TEST_TMP/cidr-config" \
MODELS_DIR="$TEST_TMP/cidr-models" LOCAL_AI_SETUP_LIB_ONLY=1 \
  bash -c 'source "$1"; private_lan_cidr 192.168.1.7/24 && private_lan_cidr 10.2.3.4/8 && [[ "$(canonical_ipv4_cidr 192.168.1.7/24)" == 192.168.1.0/24 ]] && ! private_lan_cidr 0.0.0.0/0 && ! private_lan_cidr 8.8.8.0/24 && ! private_lan_cidr 192.168.1.0/8' \
    _ "$ENGINE" || fail "LAN CIDR validation accepted an unsafe scope or rejected a private one"
pass "private LAN CIDR validation"

ufw_sample="$TEST_TMP/ufw-status.txt"
cat > "$ufw_sample" <<'EOF'
To                         Action      From
--                         ------      ----
Anywhere                   ALLOW IN    Anywhere
22/tcp                     ALLOW IN    Anywhere
2222/tcp                   LIMIT IN    Anywhere
22/tcp                     ALLOW IN    192.168.1.0/24
Anywhere                   ALLOW IN    192.168.1.0/24
22/tcp                     ALLOW IN    203.0.113.4
22/tcp (v6)                ALLOW IN    Anywhere (v6)
22/tcp                     LIMIT IN    192.168.1.0/24
60000:61000/udp            ALLOW IN    192.168.1.0/24
5353/udp                   ALLOW IN    192.168.1.0/24
EOF
broad_ufw="$(MODEL_LOCK="$LOCK" LOCAL_AI_CONFIG_DIR="$TEST_TMP/ufw-config" \
  MODELS_DIR="$TEST_TMP/ufw-models" LOCAL_AI_SETUP_LIB_ONLY=1 \
  bash -c 'source "$1"; broad_ufw_inbound_rules < "$2"' _ "$ENGINE" "$ufw_sample")"
[[ "$(wc -l <<< "$broad_ufw" | tr -d ' ')" == 4 ]] || fail "UFW audit missed catch-all/limited/IPv6 rules or rejected LAN-sourced rules"
non_lan_ufw="$(MODEL_LOCK="$LOCK" LOCAL_AI_CONFIG_DIR="$TEST_TMP/ufw-config" \
  MODELS_DIR="$TEST_TMP/ufw-models" LOCAL_AI_SETUP_LIB_ONLY=1 \
  bash -c 'source "$1"; broad_ufw_inbound_rules 192.168.1.0/24 < "$2"' _ "$ENGINE" "$ufw_sample")"
[[ "$(wc -l <<< "$non_lan_ufw" | tr -d ' ')" == 7 ]] || \
  fail "UFW audit missed a non-LAN/catch-all/wrong-action rule or rejected an exact managed tuple"
pass "exact LAN-only UFW tuple audit"

unsafe_runtime="$TEST_TMP/shared-runtime"
private_runtime_config="$TEST_TMP/private-runtime-config"
mkdir -p "$unsafe_runtime"
chmod 777 "$unsafe_runtime"
resolved_runtime="$(TMPDIR="$unsafe_runtime" MODEL_LOCK="$LOCK" \
  LOCAL_AI_CONFIG_DIR="$private_runtime_config" MODELS_DIR="$TEST_TMP/runtime-models" \
  LOCAL_AI_SETUP_LIB_ONLY=1 bash -c 'source "$1"; operation_runtime_root' _ "$ENGINE")"
[[ "$resolved_runtime" == "$private_runtime_config/runtime" ]] || \
  fail "operation lock used a shared writable runtime directory"
runtime_mode="$(stat -c%a "$resolved_runtime" 2>/dev/null || stat -f%Lp "$resolved_runtime")"
[[ "$runtime_mode" == 700 ]] || fail "fallback operation runtime directory is not mode 0700"
pass "operation lock selects a private user-owned runtime root"

old_helper="$TEST_TMP/old-ai-session"
cat > "$old_helper" <<'EOF'
#!/usr/bin/env bash
# ai-session — attach-or-create a persistent coding-agent session (tmux).
# Pick the agent: explicit env > saved setup.env > pi.
tmux send-keys -t "=$name" "$AGENT" C-m
EOF
custom_helper="$TEST_TMP/custom-ai-session"
printf '# ai-session — attach-or-create a persistent coding-agent session (tmux).\necho custom\n' > "$custom_helper"
MODEL_LOCK="$LOCK" LOCAL_AI_CONFIG_DIR="$TEST_TMP/helper-config" \
MODELS_DIR="$TEST_TMP/helper-models" LOCAL_AI_SETUP_LIB_ONLY=1 \
  bash -c 'source "$1"; legacy_session_helper "$2" && ! legacy_session_helper "$3"' \
    _ "$ENGINE" "$old_helper" "$custom_helper" || fail "session-helper migration fingerprint is too weak or rejects the real old template"
pass "legacy session-helper fingerprint"

# Session names include a digest of the canonical project path. Repositories
# with the same leaf directory must never attach to each other's tmux pane.
session_helper="$TEST_TMP/generated-ai-session"
MODEL_LOCK="$LOCK" LOCAL_AI_CONFIG_DIR="$TEST_TMP/session-helper-config" \
MODELS_DIR="$TEST_TMP/session-helper-models" LOCAL_AI_SETUP_LIB_ONLY=1 \
  bash -c 'source "$1"; write_session_helper "$2"' _ "$ENGINE" "$session_helper"
chmod 755 "$session_helper"
grep -q '^export PI_NO_TITLE=1$' "$session_helper" || \
  fail "noninteractive session helper omitted the title-request guard"
grep -q 'export PI_NO_TITLE=1; exec' "$session_helper" || \
  fail "tmux launch command omitted the title-request guard"
session_home="$TEST_TMP/session-home"
session_bin="$TEST_TMP/session-bin"
session_log="$TEST_TMP/session-tmux.log"
mkdir -p "$session_home/.config/local-ai" "$session_bin" \
  "$TEST_TMP/work-a/project" "$TEST_TMP/work-b/project"
printf '%064d\n' 0 > "$session_home/.config/local-ai/llama.key"
cat > "$session_bin/tmux" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == has-session ]]; then exit 1; fi
printf '%s\n' "$*" >> "${SESSION_TMUX_LOG:?}"
EOF
chmod 755 "$session_bin/tmux"
HOME="$session_home" PATH="$session_bin:$PATH" SESSION_TMUX_LOG="$session_log" AGENT=omp \
  "$session_helper" "$TEST_TMP/work-a/project" >/dev/null
HOME="$session_home" PATH="$session_bin:$PATH" SESSION_TMUX_LOG="$session_log" AGENT=omp \
  "$session_helper" "$TEST_TMP/work-b/project" >/dev/null
session_names="$(awk '$1=="new-session" { print $4 }' "$session_log")"
[[ "$(wc -l <<< "$session_names" | tr -d ' ')" == 2 && \
   "$(sort -u <<< "$session_names" | wc -l | tr -d ' ')" == 2 ]] || \
  fail "same-basename project paths reused one tmux session"
pass "canonical-path session disambiguation"

invalid_config="$TEST_TMP/invalid-config"
if MODEL_LOCK="$LOCK" LOCAL_AI_CONFIG_DIR="$invalid_config" \
    "$ENGINE" save-config MODELS_MAX=0 >/dev/null 2>&1; then
  fail "invalid MODELS_MAX was accepted"
fi
[[ ! -e "$invalid_config/setup.env" ]] || fail "invalid config was persisted"
pass "config validation precedes persistence"

nonregular_config="$TEST_TMP/nonregular-config"
mkdir -p "$nonregular_config/setup.env"
if MODEL_LOCK="$LOCK" LOCAL_AI_CONFIG_DIR="$nonregular_config" \
    SETUP_ENV="$nonregular_config/setup.env" MODELS_DIR="$TEST_TMP/nonregular-models" \
    "$ENGINE" save-config AGENT=pi >/dev/null 2>&1; then
  fail "directory-valued setup.env was accepted"
fi
[[ -d "$nonregular_config/setup.env" ]] || fail "non-regular setup.env ownership was changed"
if find "$nonregular_config/setup.env" -mindepth 1 -print -quit | grep -q .; then
  fail "save-config wrote staged data inside a non-regular setup.env"
fi
pass "non-regular persisted config paths are preserved"

legacy_config="$TEST_TMP/legacy-config"
mkdir -p "$legacy_config"
printf 'AGENT=omp\nREASONING_EFFORT=none\n' > "$legacy_config/setup.env"
legacy_output="$(MODEL_LOCK="$LOCK" LOCAL_AI_CONFIG_DIR="$legacy_config" \
  SETUP_ENV="$legacy_config/setup.env" MODELS_DIR="$TEST_TMP/legacy-models" \
  "$ENGINE" show-config)"
grep -q 'REASONING_EFFORT.*medium' <<< "$legacy_output" || fail "legacy saved reasoning=none blocked or escaped migration"
MODEL_LOCK="$LOCK" LOCAL_AI_CONFIG_DIR="$legacy_config" SETUP_ENV="$legacy_config/setup.env" \
MODELS_DIR="$TEST_TMP/legacy-models" "$ENGINE" save-config REASONING_EFFORT=medium >/dev/null
grep -q '^REASONING_EFFORT=medium$' "$legacy_config/setup.env" || fail "legacy reasoning migration could not be persisted"
if REASONING_EFFORT=none MODEL_LOCK="$LOCK" LOCAL_AI_CONFIG_DIR="$legacy_config" \
    SETUP_ENV="$legacy_config/setup.env" MODELS_DIR="$TEST_TMP/legacy-models" \
    "$ENGINE" show-config >/dev/null 2>&1; then
  fail "explicit current REASONING_EFFORT=none was silently accepted"
fi
pass "legacy reasoning-effort migration"

# Regression: an old setup.env lacking new keys must still return their defaults.
manager_config="$TEST_TMP/manager-config"
mkdir -p "$manager_config"
printf 'AGENT=pi\n' > "$manager_config/setup.env"
port="$(LOCAL_AI_MANAGE_LIB_ONLY=1 LOCAL_AI_CONFIG_DIR="$manager_config" \
  SETUP_ENV="$manager_config/setup.env" bash -c 'source "$1"; cfg PORT 8080' _ "$MANAGER")"
[[ "$port" == 8080 ]] || fail "manage.sh suppressed a missing-key fallback"
pass "control-panel config migration fallback"

# Dynamic shell exports are managed by identity, not exact-line deduplication.
# Cycling 8080 -> 9090 -> 8080 (and key paths A -> B -> A) must leave exactly
# the final values rather than an obsolete later line that wins in the shell.
shell_home="$TEST_TMP/shell-home"
mkdir -p "$shell_home"
cat > "$shell_home/.bashrc" <<'EOF'
export USER_OWNED_SETTING=keep
export LLAMA_BASE_URL=http://127.0.0.1:7777
export LLAMA_API_KEY=$(<"$HOME/custom/llama.key")
EOF
HOME="$shell_home" SHELL=/bin/bash MODEL_LOCK="$LOCK" \
LOCAL_AI_CONFIG_DIR="$TEST_TMP/shell-config" MODELS_DIR="$TEST_TMP/shell-models" \
LOCAL_AI_SETUP_LIB_ONLY=1 bash -c '
  source "$1"
  PORT=8080; KEY_FILE="$HOME/key-a"
  set_managed_shell_export LLAMA_BASE_URL "export LLAMA_BASE_URL=http://127.0.0.1:${PORT}" \
    ""
  add_api_key_export
  PORT=9090; KEY_FILE="$HOME/key-b"
  set_managed_shell_export LLAMA_BASE_URL "export LLAMA_BASE_URL=http://127.0.0.1:${PORT}" \
    ""
  add_api_key_export
  PORT=8080; KEY_FILE="$HOME/key-a"
  set_managed_shell_export LLAMA_BASE_URL "export LLAMA_BASE_URL=http://127.0.0.1:${PORT}" \
    ""
  add_api_key_export
' _ "$ENGINE"
[[ "$(grep -c 'managed-by-local-ai-setup: LLAMA_BASE_URL' "$shell_home/.bashrc")" == 1 ]] || \
  fail "managed base URL accumulated duplicate exports"
[[ "$(grep -c 'managed-by-local-ai-setup: LLAMA_API_KEY' "$shell_home/.bashrc")" == 1 ]] || \
  fail "managed API key accumulated duplicate exports"
grep -q '^export LLAMA_BASE_URL=http://127.0.0.1:8080  # managed-by-local-ai-setup: LLAMA_BASE_URL$' \
  "$shell_home/.bashrc" || fail "cycled base URL left a stale effective port"
grep -q 'export LLAMA_API_KEY=$(<.*/key-a).*managed-by-local-ai-setup: LLAMA_API_KEY$' \
  "$shell_home/.bashrc" || fail "cycled key path left a stale effective path"
grep -q '^export USER_OWNED_SETTING=keep$' "$shell_home/.bashrc" || \
  fail "managed export replacement changed an unrelated shell setting"
grep -q '^export LLAMA_BASE_URL=http://127.0.0.1:7777$' "$shell_home/.bashrc" || \
  fail "managed export migration deleted a user-authored base URL"
grep -q '^export LLAMA_API_KEY=$(<"$HOME/custom/llama.key")$' "$shell_home/.bashrc" || \
  fail "managed export migration deleted a user-authored key loader"
pass "managed shell exports survive value cycles without stale precedence"

dotfiles_dir="$TEST_TMP/dotfiles"
mkdir -p "$dotfiles_dir"
printf 'export DOTFILES_TARGET=keep\n' > "$dotfiles_dir/zshrc"
ln -s "$dotfiles_dir/zshrc" "$shell_home/.zshrc"
HOME="$shell_home" SHELL=/bin/zsh MODEL_LOCK="$LOCK" \
LOCAL_AI_CONFIG_DIR="$TEST_TMP/shell-config" MODELS_DIR="$TEST_TMP/shell-models" \
LOCAL_AI_SETUP_LIB_ONLY=1 bash -c '
  source "$1"
  PORT=8181
  set_managed_shell_export LLAMA_BASE_URL "export LLAMA_BASE_URL=http://127.0.0.1:${PORT}" \
    ""
' _ "$ENGINE"
[[ -L "$shell_home/.zshrc" ]] || fail "shell integration replaced a dotfiles symlink"
grep -q '^export DOTFILES_TARGET=keep$' "$dotfiles_dir/zshrc" || \
  fail "shell integration lost the symlink target's user content"
grep -q 'LLAMA_BASE_URL=http://127.0.0.1:8181.*managed-by-local-ai-setup' "$dotfiles_dir/zshrc" || \
  fail "shell integration did not update the resolved symlink target"
pass "managed shell exports preserve dotfile symlinks and target modes"

# Materialize the selected fixture artifacts with their exact locked content.
models="$TEST_TMP/models"
while IFS='|' read -r tier variant _id model_dir _repo _revision remote _bytes _sha _kind; do
  [[ -z "$tier" || "$tier" == \#* ]] && continue
  wanted=""
  case "$tier" in
    everyday) wanted=UD-Q4_K_XL ;;
    coder) wanted=Q4_K_M ;;
    senior) wanted=MXFP4_MOE ;;
  esac
  [[ "$variant" == ALL || "$variant" == "$wanted" ]] || continue
  mkdir -p "$models/$model_dir"
  printf 'fixture|%s|%s|%s' "$tier" "$variant" "$remote" > \
    "$models/$model_dir/${remote##*/}"
done < "$LOCK"

symlink_row="$(awk -F'|' '$1=="everyday" && $2=="UD-Q4_K_XL" {print; exit}' "$LOCK")"
IFS='|' read -r _t _v _id symlink_dir _repo _rev symlink_remote _bytes _sha _kind <<< "$symlink_row"
symlink_model="$models/$symlink_dir/${symlink_remote##*/}"
mv -- "$symlink_model" "$symlink_model.saved"
ln -s "$symlink_model.saved" "$symlink_model"
MODEL_LOCK="$LOCK" LOCAL_AI_CONFIG_DIR="$TEST_TMP/symlink-catalog-config" MODELS_DIR="$models" \
  "$ENGINE" model-catalog > "$TEST_TMP/symlink-catalog.txt"
grep -q 'everyday.*partial' "$TEST_TMP/symlink-catalog.txt" || \
  fail "catalog reported a same-size symlinked artifact as installed or absent"
rm -f -- "$symlink_model"
mv -- "$symlink_model.saved" "$symlink_model"
pass "catalog treats symlinked managed artifacts as partial"

mock_bin="$TEST_TMP/bin"
mkdir -p "$mock_bin"
cat > "$mock_bin/llama-server" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == --help ]]; then
  if [[ "${MOCK_MISSING_REASONING:-0}" == 1 ]]; then
    echo '--models-preset --models-max --models-autoload --api-key-file --load-mode --flash-attn --cache-reuse --stop-timeout --spec-type --spec-draft-model --spec-draft-n-max --reasoning-effort --reasoning-preserve --no-context-shift --cache-type-k --cache-type-v --spec-draft-type-k --spec-draft-type-v'
  else
    echo '--models-preset --models-max --models-autoload --api-key-file --load-mode --flash-attn --cache-reuse --stop-timeout --spec-type --spec-draft-model --spec-draft-n-max --reasoning --reasoning-effort --reasoning-preserve --no-context-shift --cache-type-k --cache-type-v --spec-draft-type-k --spec-draft-type-v'
  fi
else
  echo 'mock llama-server'
fi
EOF
cat > "$mock_bin/systemctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${SYSTEMCTL_LOG:?}"
if [[ "${FAIL_RESTART:-0}" == 1 && "$*" == '--user restart llama-server.service' ]]; then
  exit 1
fi
if [[ "${MOCK_SERVICE_INACTIVE:-0}" == 1 && "$*" == '--user is-active --quiet llama-server.service' ]]; then
  exit 3
fi
if [[ "${MOCK_SERVICE_INACTIVE:-0}" == 1 && "$*" == '--user is-active llama-server.service' ]]; then
  printf 'inactive\n'; exit 3
fi
if [[ "$*" == '--user is-active llama-server.service' ]]; then
  printf 'active\n'; exit 0
fi
if [[ "$*" == '--user show llama-server.service --property=LoadState --value' ]]; then
  printf 'loaded\n'; exit 0
fi
if [[ "$*" == '--user show llama-server.service --property=MainPID --value' ]]; then
  if [[ "${MOCK_SERVICE_INACTIVE:-0}" == 1 ]]; then
    printf '0\n'
  else
    printf '999999\n'
  fi
  exit 0
fi
if [[ "${MOCK_SSH_INACTIVE:-0}" == 1 && "$*" == 'is-active --quiet sshd' ]]; then
  exit 3
fi
if [[ "$*" == 'show sshd --property=ActiveState --value' ]]; then
  if [[ -n "${MOCK_SSH_STATE:-}" ]]; then
    printf '%s\n' "$MOCK_SSH_STATE"
  elif [[ "${MOCK_SSH_INACTIVE:-0}" == 1 ]]; then
    printf 'inactive\n'
  else
    printf 'active\n'
  fi
  exit 0
fi
if [[ "$*" == 'show sshdgenkeys.service --property=LoadState --value' ]]; then
  printf 'loaded\n'; exit 0
fi
if [[ "${FAIL_SSH_RELOAD:-0}" == 1 && ( "$*" == 'reload sshd' || "$*" == 'restart sshd' ) ]]; then
  exit 1
fi
EOF
cat > "$mock_bin/llama-bench" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == --help ]]; then
  if [[ "${MOCK_BENCH_SUFFIX_ONLY:-0}" == 1 ]]; then
    echo '--model --flash-attn --load-mode-extra --n-prompt --n-gen --n-gpu-layers --fit-target-extra --verbose'
  else
    echo '--model --flash-attn --load-mode --n-prompt --n-gen --n-gpu-layers --fit-target --verbose'
  fi
else
  printf '%s\n' "$*" >> "${LLAMA_BENCH_LOG:?}"
fi
EOF
cat > "$mock_bin/systemd-analyze" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$mock_bin/loginctl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$mock_bin/sshd" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  -t) exit "${MOCK_SSHD_INVALID:-0}" ;;
  -T)
    printf 'passwordauthentication %s\n' "${MOCK_SSH_PW:-no}"
    printf 'kbdinteractiveauthentication %s\n' "${MOCK_SSH_KBD:-no}"
    printf 'pubkeyauthentication %s\n' "${MOCK_SSH_PUBKEY:-yes}"
    printf 'authenticationmethods %s\n' "${MOCK_SSH_METHODS:-any}"
    printf 'permitrootlogin %s\n' "${MOCK_SSH_ROOT:-no}"
    printf 'allowusers %s\n' "${MOCK_SSH_USERS:-$(id -un)}"
    printf 'x11forwarding %s\n' "${MOCK_SSH_X11:-no}"
    printf 'allowagentforwarding %s\n' "${MOCK_SSH_AGENT:-no}"
    printf 'maxauthtries %s\n' "${MOCK_SSH_TRIES:-3}"
    printf 'authorizedkeysfile %s\n' "${MOCK_SSH_AUTH_KEYS:-.ssh/authorized_keys}"
    ;;
esac
EOF
cat > "$mock_bin/sudo" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == install ]]; then
  shift
  args=()
  while (( $# )); do
    case "$1" in
      -o|-g) shift 2 ;;
      *) args+=("$1"); shift ;;
    esac
  done
  exec /usr/bin/install "${args[@]}"
fi
exec "$@"
EOF
chmod 755 "$mock_bin/llama-server" "$mock_bin/llama-bench" "$mock_bin/systemctl" "$mock_bin/systemd-analyze" \
  "$mock_bin/loginctl" "$mock_bin/sshd" "$mock_bin/sudo"

jail_probe="$TEST_TMP/local-ai-sshd.local"
ln -s "$TEST_TMP/missing-jail-target" "$jail_probe"
if SYSTEMCTL_LOG="$TEST_TMP/root-file-systemctl.log" PATH="$mock_bin:$PATH" \
    MODEL_LOCK="$LOCK" LOCAL_AI_CONFIG_DIR="$TEST_TMP/root-file-config" \
    MODELS_DIR="$TEST_TMP/root-file-models" LOCAL_AI_SETUP_LIB_ONLY=1 \
    bash -c 'source "$1"; managed_root_file_or_absent "$2" "# Generated by setup-qwen38-pi.sh"' \
      _ "$ENGINE" "$jail_probe"; then
  fail "dangling fail2ban-policy symlink was treated as managed/replaceable"
fi
pass "root policy symlink preservation"

config="$TEST_TMP/config"
units="$TEST_TMP/units"
systemctl_log="$TEST_TMP/systemctl.log"
SERVICE_HEALTHCHECK=0 SYSTEMCTL_LOG="$systemctl_log" PATH="$mock_bin:$PATH" MODEL_LOCK="$LOCK" \
LOCAL_AI_CONFIG_DIR="$config" MODELS_DIR="$models" LOCAL_BIN_DIR="$mock_bin" \
OMP_AGENT_DIR="$TEST_TMP/omp" UNIT_DIR="$units" \
  "$ENGINE" service >/dev/null

preset="$config/models.ini"
launcher="$mock_bin/llama-qwen38-server"
unit="$units/llama-server.service"
grep -q '^\[qwen3.8-27b\]$' "$preset" || fail "everyday preset missing"
grep -q '^\[coder\]$' "$preset" || fail "coder preset missing"
grep -q '^\[qwen3.5-122b-a10b\]$' "$preset" || fail "senior preset missing"
[[ "$(grep -c '^spec-type = draft-mtp$' "$preset")" == 1 ]] || fail "MTP must apply only to everyday"
[[ "$(grep -c '^spec-type = none$' "$preset")" == 2 ]] || fail "optional models must disable MTP"
grep -q '^load-mode = none$' "$preset" || fail "deprecated mmap behavior was not migrated"
awk '/^\[qwen3.8-27b\]/{s=1;next} /^\[/{s=0} s && /^load-mode = none$/{found=1} END{exit !found}' "$preset" || fail "everyday load mode missing"
awk '/^\[coder\]/{s=1;next} /^\[/{s=0} s && /^load-mode = mmap$/{found=1} END{exit !found}' "$preset" || fail "coder load mode missing"
awk '/^\[qwen3.5-122b-a10b\]/{s=1;next} /^\[/{s=0} s && /^load-mode = mmap$/{found=1} END{exit !found}' "$preset" || fail "senior load mode missing"
[[ "$(grep -c '^load-on-startup = true$' "$preset")" == 1 ]] || fail "startup policy loaded more than one tier"
awk '/^\[qwen3.8-27b\]/{s=1;next} /^\[/{s=0} s && /^load-on-startup = true$/{found=1} END{exit !found}' "$preset" || fail "everyday startup tier missing"
[[ "$(grep -c '^cache-type-[kv] = f16$' "$preset")" == 2 ]] || fail "f16 KV cache profile missing"
[[ "$(grep -c '^spec-draft-type-[kv] = f16$' "$preset")" == 2 ]] || fail "draft KV cache profile missing"
[[ "$(grep -c '^n-gpu-layers = all$' "$preset")" == 2 ]] || fail "full offload must be limited to the smaller tiers"
if awk '/^\[qwen3.5-122b-a10b\]/{s=1;next} /^\[/{s=0} s && /^n-gpu-layers/{exit 1}' "$preset"; then :; else fail "senior preset prevents auto-fit"; fi
grep -q -- '--models-max 1' "$launcher" || fail "safe residency limit missing"
if grep -qE -- '--(spec|ctx|reasoning)|-ngl' "$launcher"; then fail "model-specific flag leaked into router launcher"; fi
grep -q ' restart llama-server.service$' "$systemctl_log" || fail "service was enabled but not restarted"
if grep -q '^SupplementaryGroups=' "$unit"; then fail "user unit tries to change supplementary groups"; fi
if grep -q '^ReadWritePaths=' "$unit"; then fail "server can mutate the pinned model tree"; fi
grep -q '^ReadOnlyPaths=' "$unit" || fail "model tree was not explicitly read-only"
pass "per-model preset and service generation"

# Managed service paths are ownership boundaries. A dotfiles-style symlink (or
# a custom regular file) must never be dereferenced/replaced by the transaction.
preset_link_target="$TEST_TMP/user-preset-target"
mv -- "$preset" "$preset_link_target"
ln -s "$preset_link_target" "$preset"
if SERVICE_HEALTHCHECK=0 SYSTEMCTL_LOG="$systemctl_log" PATH="$mock_bin:$PATH" \
    MODEL_LOCK="$LOCK" LOCAL_AI_CONFIG_DIR="$config" MODELS_DIR="$models" \
    LOCAL_BIN_DIR="$mock_bin" OMP_AGENT_DIR="$TEST_TMP/omp" UNIT_DIR="$units" \
    "$ENGINE" service >/dev/null 2>&1; then
  fail "service transaction accepted a symlinked managed preset"
fi
[[ -L "$preset" ]] || fail "service transaction replaced the preset symlink"
grep -q '^\[qwen3.8-27b\]$' "$preset_link_target" || fail "service transaction changed the symlink target"
rm -f "$preset"
mv -- "$preset_link_target" "$preset"
unit_saved="$TEST_TMP/managed-unit.saved"
cp -p "$unit" "$unit_saved"
printf '[Unit]\nDescription=user-owned\n' > "$unit"
if SERVICE_HEALTHCHECK=0 SYSTEMCTL_LOG="$systemctl_log" PATH="$mock_bin:$PATH" \
    MODEL_LOCK="$LOCK" LOCAL_AI_CONFIG_DIR="$config" MODELS_DIR="$models" \
    LOCAL_BIN_DIR="$mock_bin" OMP_AGENT_DIR="$TEST_TMP/omp" UNIT_DIR="$units" \
    "$ENGINE" service >/dev/null 2>&1; then
  fail "service transaction overwrote a custom unit"
fi
grep -q '^Description=user-owned$' "$unit" || fail "custom service unit was changed"
mv -- "$unit_saved" "$unit"
pass "service transaction preserves custom and symlinked ownership boundaries"

key_path="$config/llama.key"
mv -- "$key_path" "$TEST_TMP/llama.key.saved"
mkdir "$key_path"
if SERVICE_HEALTHCHECK=0 SYSTEMCTL_LOG="$systemctl_log" PATH="$mock_bin:$PATH" \
    MODEL_LOCK="$LOCK" LOCAL_AI_CONFIG_DIR="$config" MODELS_DIR="$models" \
    LOCAL_BIN_DIR="$mock_bin" OMP_AGENT_DIR="$TEST_TMP/omp" UNIT_DIR="$units" \
    "$ENGINE" service >/dev/null 2>&1; then
  fail "service accepted a non-regular API key path"
fi
[[ -d "$key_path" && ! -L "$key_path" ]] || fail "service replaced or chmodded the non-regular API key path"
rmdir "$key_path"
mv -- "$TEST_TMP/llama.key.saved" "$key_path"
pass "service preserves non-regular API key paths"

alternate_preset="$TEST_TMP/models-none-q8.ini"
MODEL_LOCK="$LOCK" LOCAL_AI_CONFIG_DIR="$TEST_TMP/alternate-config" \
MODELS_DIR="$models" STARTUP_TIER=none KV_CACHE_PROFILE=q8 \
LOCAL_AI_SETUP_LIB_ONLY=1 \
  bash -c 'source "$1"; write_model_preset "$2"' _ "$ENGINE" "$alternate_preset"
if grep -q '^load-on-startup = true$' "$alternate_preset"; then fail "STARTUP_TIER=none eagerly loaded a model"; fi
[[ "$(grep -c '^load-on-startup = false$' "$alternate_preset")" == 3 ]] || fail "startup-none policy omitted a tier"
[[ "$(grep -c '^cache-type-[kv] = q8_0$' "$alternate_preset")" == 2 ]] || fail "q8 KV cache profile missing"
[[ "$(grep -c '^spec-draft-type-[kv] = q8_0$' "$alternate_preset")" == 2 ]] || fail "q8 draft KV cache profile missing"
pass "startup-none and q8 KV presets"

# Every generated launcher argument is shell-escaped. Configuration paths and
# even the resolved server binary may contain shell metacharacters without
# becoming executable syntax.
inject_dir="$TEST_TMP/launcher injection"
inject_server="$inject_dir/llama;server"
inject_launcher="$inject_dir/generated launcher"
inject_log="$inject_dir/argv.log"
inject_marker="$TEST_TMP/launcher-injected"
inject_key="$inject_dir/key\"; touch $inject_marker; echo \""
inject_preset="$inject_dir/preset\"; touch $inject_marker; echo \""
mkdir -p "$inject_dir"
cat > "$inject_server" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "${INJECT_ARGV_LOG:?}"
EOF
chmod 755 "$inject_server"
MODEL_LOCK="$LOCK" LOCAL_AI_CONFIG_DIR="$TEST_TMP/inject-config" \
MODELS_DIR="$models" LOCAL_AI_SETUP_LIB_ONLY=1 bash -c '
  source "$1"
  KEY_FILE="$2"; PRESET_FILE="$3"
  write_server_launcher "$4" "$5"
' _ "$ENGINE" "$inject_key" "$inject_preset" "$inject_launcher" "$inject_server"
INJECT_ARGV_LOG="$inject_log" "$inject_launcher"
[[ ! -e "$inject_marker" ]] || fail "generated server launcher executed a configured path as shell syntax"
grep -Fx -- "$inject_key" "$inject_log" >/dev/null || fail "launcher did not preserve the API-key path as one argument"
grep -Fx -- "$inject_preset" "$inject_log" >/dev/null || fail "launcher did not preserve the preset path as one argument"
pass "generated server launcher quotes every executable argument"

if MOCK_MISSING_REASONING=1 SERVICE_HEALTHCHECK=0 SYSTEMCTL_LOG="$systemctl_log" \
    PATH="$mock_bin:$PATH" MODEL_LOCK="$LOCK" LOCAL_AI_CONFIG_DIR="$config" \
    MODELS_DIR="$models" LOCAL_BIN_DIR="$mock_bin" UNIT_DIR="$units" \
    "$ENGINE" service >/dev/null 2>&1; then
  fail "server option guard confused --reasoning-effort with missing --reasoning"
fi
pass "boundary-aware llama-server option guard"

# A download/no-op verification must not rewrite the active preset outside the
# service transaction.
preset_before_model="$(sha256sum "$preset")"
SYSTEMCTL_LOG="$systemctl_log" PATH="$mock_bin:$PATH" MODEL_LOCK="$LOCK" \
LOCAL_AI_CONFIG_DIR="$config" MODELS_DIR="$models" LOCAL_BIN_DIR="$mock_bin" \
  "$ENGINE" model everyday >/dev/null
[[ "$(sha256sum "$preset")" == "$preset_before_model" ]] || \
  fail "model command rewrote the live preset outside the service transaction"
pass "model download preserves active preset"

# A failed activation must restore the prior known-working preset, launcher,
# and unit instead of leaving the staged configuration installed.
service_before="$(sha256sum "$preset" "$launcher" "$unit")"
if FAIL_RESTART=1 SERVICE_HEALTHCHECK=0 SYSTEMCTL_LOG="$systemctl_log" \
    PATH="$mock_bin:$PATH" MODEL_LOCK="$LOCK" LOCAL_AI_CONFIG_DIR="$config" \
    MODELS_DIR="$models" LOCAL_BIN_DIR="$mock_bin" OMP_AGENT_DIR="$TEST_TMP/omp" \
    UNIT_DIR="$units" CTX=65536 "$ENGINE" service >/dev/null 2>&1; then
  fail "service activation failure returned success"
fi
[[ "$(sha256sum "$preset" "$launcher" "$unit")" == "$service_before" ]] || \
  fail "failed service activation did not restore prior files"
pass "transactional service rollback"

# Routine service regeneration may trust file-identity-bound receipts; the
# explicit audit command must still reread and hash every selected artifact.
real_sha256sum="$(command -v sha256sum)"
sha_mock_bin="$TEST_TMP/sha-bin"
sha_log="$TEST_TMP/sha256sum.log"
mkdir -p "$sha_mock_bin"
cat > "$sha_mock_bin/sha256sum" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${SHA256SUM_LOG:?}"
exec "${REAL_SHA256SUM:?}" "$@"
EOF
chmod 755 "$sha_mock_bin/sha256sum"
: > "$sha_log"
SERVICE_HEALTHCHECK=0 SYSTEMCTL_LOG="$systemctl_log" SHA256SUM_LOG="$sha_log" \
REAL_SHA256SUM="$real_sha256sum" PATH="$sha_mock_bin:$mock_bin:$PATH" MODEL_LOCK="$LOCK" \
LOCAL_AI_CONFIG_DIR="$config" MODELS_DIR="$models" LOCAL_BIN_DIR="$mock_bin" \
OMP_AGENT_DIR="$TEST_TMP/omp" UNIT_DIR="$units" \
  "$ENGINE" service >/dev/null
[[ ! -s "$sha_log" ]] || fail "routine service regeneration ignored valid verification receipts"
SHA256SUM_LOG="$sha_log" REAL_SHA256SUM="$real_sha256sum" \
PATH="$sha_mock_bin:$mock_bin:$PATH" MODEL_LOCK="$LOCK" \
LOCAL_AI_CONFIG_DIR="$config" MODELS_DIR="$models" \
  "$ENGINE" model-verify everyday >/dev/null
[[ -s "$sha_log" ]] || fail "model-verify trusted receipts instead of recomputing SHA-256"
receipt_probe="$(awk -F'|' '$1=="everyday" && $2=="UD-Q4_K_XL" && $10=="main" {n=split($7,p,"/"); print $4 "/" p[n]; exit}' "$LOCK")"
cp -p "$models/$receipt_probe" "$models/$receipt_probe.replacement"
mv "$models/$receipt_probe.replacement" "$models/$receipt_probe"
: > "$sha_log"
SERVICE_HEALTHCHECK=0 SYSTEMCTL_LOG="$systemctl_log" SHA256SUM_LOG="$sha_log" \
REAL_SHA256SUM="$real_sha256sum" PATH="$sha_mock_bin:$mock_bin:$PATH" MODEL_LOCK="$LOCK" \
LOCAL_AI_CONFIG_DIR="$config" MODELS_DIR="$models" LOCAL_BIN_DIR="$mock_bin" \
OMP_AGENT_DIR="$TEST_TMP/omp" UNIT_DIR="$units" \
  "$ENGINE" service >/dev/null
[[ -s "$sha_log" ]] || fail "artifact replacement did not invalidate its verification receipt"
probe_content="$(<"$models/$receipt_probe")"
probe_corrupt="X${probe_content#?}"
: > "$sha_log"
printf '%s' "$probe_corrupt" > "$models/$receipt_probe"
if SERVICE_HEALTHCHECK=0 SYSTEMCTL_LOG="$systemctl_log" SHA256SUM_LOG="$sha_log" \
    REAL_SHA256SUM="$real_sha256sum" PATH="$sha_mock_bin:$mock_bin:$PATH" MODEL_LOCK="$LOCK" \
    LOCAL_AI_CONFIG_DIR="$config" MODELS_DIR="$models" LOCAL_BIN_DIR="$mock_bin" \
    OMP_AGENT_DIR="$TEST_TMP/omp" UNIT_DIR="$units" \
      "$ENGINE" service >/dev/null 2>&1; then
  fail "same-size immediate overwrite reused a stale verification receipt"
fi
[[ -s "$sha_log" ]] || fail "same-size overwrite did not force full SHA-256 verification"
printf '%s' "$probe_content" > "$models/$receipt_probe"
PATH="$mock_bin:$PATH" MODEL_LOCK="$LOCK" LOCAL_AI_CONFIG_DIR="$config" MODELS_DIR="$models" \
  "$ENGINE" model-verify everyday >/dev/null
pass "verification receipt fast path, sub-second invalidation, and explicit full audit"

# A custom half of OMP's two-file configuration must preserve the pair; writing
# only the missing config.yml would leave broken selectors/providers.
custom_omp="$TEST_TMP/custom-omp"
custom_bin="$TEST_TMP/custom-bin"
mkdir -p "$custom_omp" "$custom_bin"
printf '# user-owned models\n' > "$custom_omp/models.yml"
set +e
MODEL_LOCK="$LOCK" LOCAL_AI_CONFIG_DIR="$config" MODELS_DIR="$models" \
LOCAL_BIN_DIR="$custom_bin" OMP_AGENT_DIR="$custom_omp" \
  "$ENGINE" routing >/dev/null 2>&1
custom_rc=$?
set -e
[[ "$custom_rc" == 2 ]] || fail "custom OMP pair was not preserved atomically"
grep -q '^# user-owned models$' "$custom_omp/models.yml" || fail "custom OMP models file changed"
[[ ! -e "$custom_omp/config.yml" ]] || fail "config.yml was installed beside custom models.yml"
[[ -f "$custom_omp/models.yml.local-ai-setup.example" && -f "$custom_omp/config.yml.local-ai-setup.example" ]] || fail "OMP pair examples missing"
[[ ! -e "$custom_bin/omp-everyday" ]] || fail "launchers changed while custom OMP pair was preserved"
pass "atomic OMP custom-config preservation"

custom_plan="$TEST_TMP/custom-plan.txt"
set +e
SYSTEMCTL_LOG="$systemctl_log" PATH="$mock_bin:$PATH" MODEL_LOCK="$LOCK" \
LOCAL_AI_CONFIG_DIR="$config" MODELS_DIR="$models" LOCAL_BIN_DIR="$custom_bin" \
OMP_AGENT_DIR="$custom_omp" UNIT_DIR="$units" \
  "$ENGINE" plan > "$custom_plan" 2>&1
custom_plan_rc=$?
set -e
[[ "$custom_plan_rc" == 1 ]] || fail "plan did not return its unresolved-gate status for a custom OMP pair"
grep -q 'gate: custom OMP routing pair will be preserved' "$custom_plan" || \
  fail "plan omitted its custom OMP preservation gate"
custom_models_before="$(sha256sum "$custom_omp/models.yml" | awk '{print $1}')"
set +e
SYSTEMCTL_LOG="$systemctl_log" PATH="$mock_bin:$PATH" MODEL_LOCK="$LOCK" \
LOCAL_AI_CONFIG_DIR="$config" MODELS_DIR="$models" LOCAL_BIN_DIR="$custom_bin" \
OMP_AGENT_DIR="$custom_omp" UNIT_DIR="$units" \
  "$ENGINE" apply >/dev/null 2>&1
custom_apply_rc=$?
set -e
[[ "$custom_apply_rc" == 1 ]] || fail "apply did not stop at the custom OMP preflight gate"
[[ "$custom_models_before" == "$(sha256sum "$custom_omp/models.yml" | awk '{print $1}')" ]] || \
  fail "blocked apply changed the custom OMP models file"
[[ ! -e "$custom_omp/config.yml" && ! -e "$custom_bin/omp-everyday" ]] || \
  fail "blocked apply partially installed the custom OMP pair or launchers"
pass "custom OMP pair gates plan/apply without mutation"

dangling_omp="$TEST_TMP/dangling-omp"
mkdir -p "$dangling_omp"
ln -s "$dangling_omp/missing-user-config.yml" "$dangling_omp/config.yml"
set +e
MODEL_LOCK="$LOCK" LOCAL_AI_CONFIG_DIR="$config" MODELS_DIR="$models" \
LOCAL_BIN_DIR="$TEST_TMP/dangling-bin" OMP_AGENT_DIR="$dangling_omp" \
  "$ENGINE" routing >/dev/null 2>&1
dangling_rc=$?
set -e
[[ "$dangling_rc" == 2 && -L "$dangling_omp/config.yml" ]] || \
  fail "dangling user OMP symlink was not preserved as custom configuration"
pass "dangling OMP symlink preservation"

version_bin="$TEST_TMP/version-bin"
mkdir -p "$version_bin"
cat > "$version_bin/omp" <<'EOF'
#!/usr/bin/env bash
echo 'omp 18.0.100'
EOF
chmod 755 "$version_bin/omp"
version_omp="$TEST_TMP/version-omp"
if PATH="$version_bin:$mock_bin:$PATH" MODEL_LOCK="$LOCK" LOCAL_AI_CONFIG_DIR="$config" \
    MODELS_DIR="$models" LOCAL_BIN_DIR="$TEST_TMP/version-local-bin" OMP_AGENT_DIR="$version_omp" \
    "$ENGINE" routing >/dev/null 2>&1; then
  fail "OMP version 18.0.100 passed an exact 18.0.10 schema guard"
fi
[[ ! -e "$version_omp/models.yml" ]] || fail "mismatched OMP version changed routing"
pass "exact OMP schema-version guard"

# A generic user-owned/symlinked launcher must never be followed or replaced by
# an ordinary routing refresh.
user_launcher_target="$TEST_TMP/user-omp-coder"
printf 'user-owned-launcher\n' > "$user_launcher_target"
ln -s "$user_launcher_target" "$mock_bin/omp-coder"

MODEL_LOCK="$LOCK" LOCAL_AI_CONFIG_DIR="$config" MODELS_DIR="$models" \
LOCAL_BIN_DIR="$mock_bin" OMP_AGENT_DIR="$TEST_TMP/omp" \
  "$ENGINE" routing >/dev/null
omp_config="$TEST_TMP/omp/config.yml"
omp_models="$TEST_TMP/omp/models.yml"
grep -q '^  task: llamacpp/qwen3.8-27b$' "$omp_config" || fail "sticky task role left the base tier"
grep -q '^  slow: llamacpp/qwen3.8-27b$' "$omp_config" || fail "sticky review role left the base tier"
grep -q '^  title: llamacpp/qwen3.8-27b$' "$omp_config" || fail "title role does not select the base tier"
grep -q '^  enabled: false$' "$omp_config" || fail "always-on senior advisor was enabled"
if grep -Eq '^[[:space:]]*(supersedeReads|dropUseless):[[:space:]]*false' "$omp_config"; then
  fail "OMP cache-aware pruning was explicitly disabled"
fi
grep -A2 '^  maxInFlightRequests:' "$omp_config" | grep -q 'llamacpp: 1' || fail "provider concurrency limit missing"
grep -q '^  - llama.cpp$' "$omp_config" || fail "implicit keyless llama.cpp provider was not disabled"
grep -q '^      - id: qwen3.8-27b$' "$omp_models" || fail "everyday OMP model missing"
grep -q '^      - id: coder$' "$omp_models" || fail "coder OMP model missing"
grep -A4 '^      - id: coder$' "$omp_models" | grep -q '^        reasoning: false$' || fail "coder was misclassified as thinking"
grep -q '^      - id: qwen3.5-122b-a10b$' "$omp_models" || fail "senior OMP model missing"
grep -q '^          efforts: \[low, medium, xhigh\]$' "$omp_models" || fail "Qwen3.8 effort surface is inaccurate"
awk '
  /^      - id: qwen3.5-122b-a10b$/ { senior=1; next }
  /^      - id:/ { senior=0 }
  senior && /^          efforts: \[low\]$/ { one=1 }
  senior && /^          supportsReasoningEffort: false$/ { noeffort=1 }
  END { exit !(one && noeffort) }
' "$omp_models" || fail "senior OMP model does not expose an accurate binary thinking surface"
if grep -q '^  subagents:' "$omp_config"; then fail "legacy advisor.subagents key was generated"; fi
[[ -L "$mock_bin/omp-coder" ]] || fail "user-owned OMP launcher was replaced"
grep -q '^user-owned-launcher$' "$user_launcher_target" || fail "OMP launcher write followed a user symlink"
grep -q '^export PI_NO_TITLE=1$' "$mock_bin/omp-everyday" || \
  fail "same-shell tier launcher omitted the title-request guard"
MODEL_LOCK="$LOCK" LOCAL_AI_CONFIG_DIR="$config" MODELS_DIR="$models" \
LOCAL_BIN_DIR="$mock_bin" OMP_AGENT_DIR="$TEST_TMP/omp" REASONING_EFFORT=xhigh \
  "$ENGINE" routing >/dev/null
grep -q '^          defaultLevel: xhigh$' "$omp_models" || fail "OMP default thinking level ignored REASONING_EFFORT"
MODEL_LOCK="$LOCK" LOCAL_AI_CONFIG_DIR="$config" MODELS_DIR="$models" \
LOCAL_BIN_DIR="$mock_bin" OMP_AGENT_DIR="$TEST_TMP/omp" ROUTING_PROFILE=balanced \
  "$ENGINE" routing >/dev/null
grep -q '^  task: llamacpp/coder$' "$omp_config" || fail "balanced task role did not select coder"
grep -q '^  slow: llamacpp/qwen3.8-27b$' "$omp_config" || fail "balanced review role left the base tier"
MODEL_LOCK="$LOCK" LOCAL_AI_CONFIG_DIR="$config" MODELS_DIR="$models" \
LOCAL_BIN_DIR="$mock_bin" OMP_AGENT_DIR="$TEST_TMP/omp" ROUTING_PROFILE=quality \
  "$ENGINE" routing >/dev/null
grep -q '^  task: llamacpp/coder$' "$omp_config" || fail "quality task role did not select coder"
grep -q '^  slow: llamacpp/qwen3.5-122b-a10b$' "$omp_config" || fail "quality review role did not select senior"
# Restore the default fixture configuration for subsequent assertions.
MODEL_LOCK="$LOCK" LOCAL_AI_CONFIG_DIR="$config" MODELS_DIR="$models" \
LOCAL_BIN_DIR="$mock_bin" OMP_AGENT_DIR="$TEST_TMP/omp" \
  "$ENGINE" routing >/dev/null
pass "OMP task routing generation"

# Missing tiers fall back to the first complete tier in everyday -> coder ->
# senior order; profile promotion must never point to an absent provider.
fallback_models="$TEST_TMP/fallback-models"
fallback_omp="$TEST_TMP/fallback-omp"
fallback_bin="$TEST_TMP/fallback-bin"
mkdir -p "$fallback_models" "$fallback_omp" "$fallback_bin"
cp -R "$models/." "$fallback_models/"
while IFS='|' read -r _t _v _id model_dir _repo _rev remote _bytes _sha _kind; do
  rm -f -- "$fallback_models/$model_dir/${remote##*/}"
done < <(awk -F'|' '$1=="everyday" && ($2=="UD-Q4_K_XL" || $2=="ALL") {print}' "$LOCK")
MODEL_LOCK="$LOCK" LOCAL_AI_CONFIG_DIR="$TEST_TMP/fallback-config" \
MODELS_DIR="$fallback_models" LOCAL_BIN_DIR="$fallback_bin" \
OMP_AGENT_DIR="$fallback_omp" ROUTING_PROFILE=quality \
  "$ENGINE" routing >/dev/null
grep -q '^  default: llamacpp/coder$' "$fallback_omp/config.yml" || fail "missing everyday did not promote coder to base"
grep -q '^  task: llamacpp/coder$' "$fallback_omp/config.yml" || fail "quality task selector pointed at an absent tier"
grep -q '^  slow: llamacpp/qwen3.5-122b-a10b$' "$fallback_omp/config.yml" || fail "quality architect selector missed installed senior"
while IFS='|' read -r _t _v _id model_dir _repo _rev remote _bytes _sha _kind; do
  rm -f -- "$fallback_models/$model_dir/${remote##*/}"
done < <(awk -F'|' '$1=="coder" {print}' "$LOCK")
MODEL_LOCK="$LOCK" LOCAL_AI_CONFIG_DIR="$TEST_TMP/fallback-config" \
MODELS_DIR="$fallback_models" LOCAL_BIN_DIR="$fallback_bin" \
OMP_AGENT_DIR="$fallback_omp" ROUTING_PROFILE=balanced \
  "$ENGINE" routing >/dev/null
grep -q '^  default: llamacpp/qwen3.5-122b-a10b$' "$fallback_omp/config.yml" || fail "senior-only install did not become base"
grep -q '^  task: llamacpp/qwen3.5-122b-a10b$' "$fallback_omp/config.yml" || fail "balanced selector pointed at absent coder"
grep -q '^  slow: llamacpp/qwen3.5-122b-a10b$' "$fallback_omp/config.yml" || fail "balanced review selector left senior-only base"
pass "OMP missing-tier fallback matrix"

# Installing models.yml and config.yml is transactional: a failure on the
# second rename must restore the first file too.
pair_bin="$TEST_TMP/pair-bin"
pair_omp="$TEST_TMP/pair-omp"
pair_local_bin="$TEST_TMP/pair-local-bin"
mkdir -p "$pair_bin" "$pair_omp" "$pair_local_bin"
cat > "$pair_bin/omp" <<'EOF'
#!/usr/bin/env bash
echo 'omp 18.0.10'
EOF
cat > "$pair_bin/mv" <<'EOF'
#!/usr/bin/env bash
last=''
for arg in "$@"; do last="$arg"; done
if [[ "${MOCK_FAIL_OMP_CONFIG_MV:-0}" == 1 && "$last" == */config.yml ]]; then
  exit 1
fi
/bin/mv "$@" || exit $?
if [[ "${MOCK_SIGNAL_OMP_MODELS:-0}" == 1 && "$last" == */models.yml ]]; then
  kill -TERM "$PPID"
fi
if [[ "${MOCK_SIGNAL_OMP_LAUNCHER:-0}" == 1 && "$last" == */omp-everyday ]]; then
  kill -TERM "$PPID"
fi
EOF
chmod 755 "$pair_bin/omp" "$pair_bin/mv"
printf '# Managed by local-ai-setup\nold-models\n' > "$pair_omp/models.yml"
printf '# Managed by local-ai-setup\nold-config\n' > "$pair_omp/config.yml"
pair_before="$(sha256sum "$pair_omp/models.yml" "$pair_omp/config.yml")"
if MOCK_FAIL_OMP_CONFIG_MV=1 PATH="$pair_bin:$mock_bin:$PATH" MODEL_LOCK="$LOCK" \
    LOCAL_AI_CONFIG_DIR="$config" MODELS_DIR="$models" LOCAL_BIN_DIR="$pair_local_bin" \
    OMP_AGENT_DIR="$pair_omp" "$ENGINE" routing >/dev/null 2>&1; then
  fail "second OMP pair rename failure returned success"
fi
[[ "$(sha256sum "$pair_omp/models.yml" "$pair_omp/config.yml")" == "$pair_before" ]] || \
  fail "failed OMP pair install did not restore both active files"
pass "transactional OMP routing-pair rollback"

pair_before="$(sha256sum "$pair_omp/models.yml" "$pair_omp/config.yml")"
set +e
MOCK_SIGNAL_OMP_MODELS=1 PATH="$pair_bin:$mock_bin:$PATH" MODEL_LOCK="$LOCK" \
  LOCAL_AI_CONFIG_DIR="$config" MODELS_DIR="$models" LOCAL_BIN_DIR="$pair_local_bin" \
  OMP_AGENT_DIR="$pair_omp" "$ENGINE" routing >/dev/null 2>&1
pair_signal_rc=$?
set -e
[[ "$pair_signal_rc" == 130 ]] || fail "signaled OMP pair update returned $pair_signal_rc instead of 130"
[[ "$(sha256sum "$pair_omp/models.yml" "$pair_omp/config.yml")" == "$pair_before" ]] || \
  fail "signaled OMP pair update left mismatched active files"
pass "signaled OMP routing update restores the active pair"

for tier in everyday coder senior; do
  printf '# Managed by local-ai-setup: old %s launcher\nold-%s\n' "$tier" "$tier" > "$pair_local_bin/omp-$tier"
done
bundle_before="$(sha256sum "$pair_omp/models.yml" "$pair_omp/config.yml" \
  "$pair_local_bin/omp-everyday" "$pair_local_bin/omp-coder" "$pair_local_bin/omp-senior")"
set +e
MOCK_SIGNAL_OMP_LAUNCHER=1 PATH="$pair_bin:$mock_bin:$PATH" MODEL_LOCK="$LOCK" \
  LOCAL_AI_CONFIG_DIR="$config" MODELS_DIR="$models" LOCAL_BIN_DIR="$pair_local_bin" \
  OMP_AGENT_DIR="$pair_omp" "$ENGINE" routing >/dev/null 2>&1
bundle_signal_rc=$?
set -e
[[ "$bundle_signal_rc" == 130 ]] || fail "signaled OMP launcher update returned $bundle_signal_rc instead of 130"
[[ "$(sha256sum "$pair_omp/models.yml" "$pair_omp/config.yml" \
  "$pair_local_bin/omp-everyday" "$pair_local_bin/omp-coder" "$pair_local_bin/omp-senior")" == "$bundle_before" ]] || \
  fail "signaled OMP launcher update did not restore the complete routing bundle"
pass "signaled OMP launcher update restores pair and every wrapper"

bench_log="$TEST_TMP/llama-bench.log"
if MOCK_BENCH_SUFFIX_ONLY=1 MOCK_SERVICE_INACTIVE=1 LLAMA_BENCH_LOG="$bench_log" \
    SYSTEMCTL_LOG="$systemctl_log" PATH="$mock_bin:$PATH" MODEL_LOCK="$LOCK" \
    LOCAL_AI_CONFIG_DIR="$config" MODELS_DIR="$models" \
    "$ENGINE" bench senior >/dev/null 2>&1; then
  fail "llama-bench option guard accepted suffixed lookalike flags"
fi
MOCK_SERVICE_INACTIVE=1 LLAMA_BENCH_LOG="$bench_log" SYSTEMCTL_LOG="$systemctl_log" \
PATH="$mock_bin:$PATH" MODEL_LOCK="$LOCK" LOCAL_AI_CONFIG_DIR="$config" \
MODELS_DIR="$models" "$ENGINE" bench everyday >/dev/null
MOCK_SERVICE_INACTIVE=1 LLAMA_BENCH_LOG="$bench_log" SYSTEMCTL_LOG="$systemctl_log" \
PATH="$mock_bin:$PATH" MODEL_LOCK="$LOCK" LOCAL_AI_CONFIG_DIR="$config" \
MODELS_DIR="$models" "$ENGINE" bench senior >/dev/null
everyday_bench="$(sed -n '1p' "$bench_log")"
senior_bench="$(sed -n '2p' "$bench_log")"
[[ "$everyday_bench" == *'--n-gpu-layers -1'* ]] || fail "everyday benchmark did not request current full-offload syntax"
[[ "$everyday_bench" != *'--fit-target'* ]] || fail "small-tier benchmark unexpectedly used auto-fit"
[[ "$senior_bench" == *'--fit-target 4096'* && "$senior_bench" == *'--verbose'* ]] || fail "senior benchmark omitted conservative auto-fit diagnostics"
[[ "$senior_bench" != *'--n-gpu-layers'* && "$senior_bench" != *'--fit-ctx'* ]] || fail "senior benchmark mixed fixed layers/context with auto-fit"
[[ "$everyday_bench" == *'--load-mode none'* && "$everyday_bench" == *'--flash-attn on'* ]] || fail "everyday benchmark ignored its load/flash profile"
[[ "$senior_bench" == *'--load-mode mmap'* && "$senior_bench" == *'--flash-attn on'* ]] || fail "senior benchmark ignored its load/flash profile"

everyday_file="$(awk -F'|' '$1=="everyday" && $2=="UD-Q4_K_XL" && $10=="main" {n=split($7,p,"/"); print $4 "/" p[n]; exit}' "$LOCK")"
cp -p "$models/$everyday_file" "$models/$everyday_file.saved"
printf 'X' | dd of="$models/$everyday_file" bs=1 seek=0 conv=notrunc 2>/dev/null
bench_lines="$(wc -l < "$bench_log" | tr -d ' ')"
if MOCK_SERVICE_INACTIVE=1 LLAMA_BENCH_LOG="$bench_log" SYSTEMCTL_LOG="$systemctl_log" \
    PATH="$mock_bin:$PATH" MODEL_LOCK="$LOCK" LOCAL_AI_CONFIG_DIR="$config" \
    MODELS_DIR="$models" "$ENGINE" bench everyday >/dev/null 2>&1; then
  fail "same-sized corrupt model reached llama-bench"
fi
[[ "$(wc -l < "$bench_log" | tr -d ' ')" == "$bench_lines" ]] || fail "corrupt model was passed to llama-bench"
mv "$models/$everyday_file.saved" "$models/$everyday_file"
pass "current llama-bench tier-specific flags"

cat > "$mock_bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${CURL_ARGV_LOG:?}"
if [[ "$*" == *'--config -'* ]]; then
  config="$(cat)"
  printf '%s\n' "$config" >> "${CURL_STDIN_LOG:?}"
fi
if [[ "${CURL_DOWN:-0}" == 1 ]]; then
  [[ "$*" != *'--write-out'* ]] || printf '000'
  exit 7
fi
if [[ "$*" == *'--write-out'* && "$*" != *'--config -'* ]]; then
  printf '401'
  exit 0
fi
if [[ "$*" == *'--write-out'* && "$*" == *'--config -'* && "$*" == *'__local_ai_auth_probe__'* ]]; then
  if [[ "${CURL_WRONG_KEY:-0}" == 1 ]]; then printf '401'; else printf '404'; fi
  exit 0
fi
if [[ "$*" == *'/v1/models'* ]]; then
  printf '%s' '{"object":"list","data":[{"id":"qwen3.8-27b","status":{"value":"loaded","progress":1}}]}'
  [[ "$*" != *'--write-out'* ]] || printf '\n200'
else
  printf '%s\n' '{"choices":[{"message":{"role":"assistant","content":"","reasoning_content":"READY"}}]}'
fi
EOF
chmod 755 "$mock_bin/curl"
curl_argv_log="$TEST_TMP/curl-argv.log"
curl_stdin_log="$TEST_TMP/curl-stdin.log"
# A generated key need not end in a newline; key loading must still succeed.
printf 'test-key-without-newline-0123456789abcdef' > "$config/llama.key"
CURL_ARGV_LOG="$curl_argv_log" CURL_STDIN_LOG="$curl_stdin_log" \
SYSTEMCTL_LOG="$systemctl_log" PATH="$mock_bin:$PATH" \
MODEL_LOCK="$LOCK" LOCAL_AI_CONFIG_DIR="$config" MODELS_DIR="$models" \
  "$ENGINE" smoke everyday >/dev/null
[[ "$(grep -c 'Authorization: Bearer test-key-without-newline-0123456789abcdef' "$curl_stdin_log")" == 2 ]] || fail "authenticated requests did not use curl's private stdin config"
if grep -q 'test-key-without-newline-0123456789abcdef' "$curl_argv_log"; then fail "bearer key leaked into curl argv"; fi
grep -q '"model":"qwen3.8-27b"' "$curl_argv_log" || fail "chat smoke test omitted router model id"
grep -q '__local_ai_auth_probe__' "$curl_argv_log" || fail "status did not test auth enforcement"
pass "auth-enforcement and model-specific API smoke test"

# Status must be machine-readable and observational: it may query catalog state
# with autoload disabled, but it must never send a real model generation.
: > "$curl_argv_log"
: > "$curl_stdin_log"
status_json="$TEST_TMP/status.json"
CURL_ARGV_LOG="$curl_argv_log" CURL_STDIN_LOG="$curl_stdin_log" \
SYSTEMCTL_LOG="$systemctl_log" PATH="$mock_bin:$PATH" \
MODEL_LOCK="$LOCK" LOCAL_AI_CONFIG_DIR="$config" MODELS_DIR="$models" \
  "$ENGINE" status --json > "$status_json"
jq -e '
  .schemaVersion == 1 and
  (.service | (.state|type)=="string" and .api=="authenticated" and
    (.port|type)=="number" and .authEnforced==true) and
  .loadedModel == "qwen3.8-27b" and
  (.models|length)==3 and
  ([.models[] | (.tier|type)=="string" and (.id|type)=="string" and
    (.artifacts=="installed" or .artifacts=="partial" or .artifacts=="absent") and
    (.runtime=="loaded" or .runtime=="loading" or .runtime=="unloaded" or
      .runtime=="sleeping" or .runtime=="failed" or .runtime=="unknown") and
    (.progress==null or (.progress|type)=="number")] | all) and
  (.config | .routingProfile=="sticky" and .startupTier=="everyday" and
    .modelsMax==1 and .kvCacheProfile=="f16" and
    .loadModes=={"everyday":"none","coder":"mmap","senior":"mmap"}) and
  (.system.rebootRequired|type)=="boolean"
' "$status_json" >/dev/null || fail "status JSON violated the version-1 contract"
grep -q '/v1/models?autoload=0' "$curl_argv_log" || fail "status catalog query could autoload a model"
if grep -q '"model":"qwen3.8-27b"' "$curl_argv_log"; then fail "status sent a model generation request"; fi

CURL_DOWN=1 CURL_ARGV_LOG="$curl_argv_log" CURL_STDIN_LOG="$curl_stdin_log" \
MOCK_SERVICE_INACTIVE=1 SYSTEMCTL_LOG="$systemctl_log" PATH="$mock_bin:$PATH" \
MODEL_LOCK="$LOCK" LOCAL_AI_CONFIG_DIR="$config" MODELS_DIR="$models" \
  "$ENGINE" status --json > "$TEST_TMP/status-down.json"
jq -e '.service.api=="down" and .loadedModel==null' "$TEST_TMP/status-down.json" >/dev/null || \
  fail "status did not report a stopped/down service without failing"
CURL_WRONG_KEY=1 CURL_ARGV_LOG="$curl_argv_log" CURL_STDIN_LOG="$curl_stdin_log" \
SYSTEMCTL_LOG="$systemctl_log" PATH="$mock_bin:$PATH" MODEL_LOCK="$LOCK" \
LOCAL_AI_CONFIG_DIR="$config" MODELS_DIR="$models" \
  "$ENGINE" status --json > "$TEST_TMP/status-wrong-key.json"
jq -e '.service.api=="unauthorized" and .service.authEnforced==true' \
  "$TEST_TMP/status-wrong-key.json" >/dev/null || \
  fail "status mislabeled a rejected local key"
pass "read-only status JSON contract"

# Missing one shard must make an otherwise present tier partial and fail an
# explicit verification instead of vacuously succeeding.
coder_missing="$(awk -F'|' '$1=="coder" && $10=="main" {n++; if(n==2){np=split($7,p,"/"); print $4 "/" p[np]; exit}}' "$LOCK")"
mv "$models/$coder_missing" "$models/$coder_missing.saved"
if MODEL_LOCK="$LOCK" LOCAL_AI_CONFIG_DIR="$config" MODELS_DIR="$models" \
    "$ENGINE" model-verify coder >/dev/null 2>&1; then
  fail "partial sharded tier passed model-verify"
fi
mv "$models/$coder_missing.saved" "$models/$coder_missing"
pass "partial-tier integrity rejection"

# SSH policy changes must verify both password paths and restore the prior file
# on an effective-setting mismatch or a daemon reload failure.
sshd_dir="$TEST_TMP/sshd_config.d"
sshd_dropin="$sshd_dir/20-local-ai-lan.conf"
ssh_home="$TEST_TMP/ssh-home"
mkdir -p "$sshd_dir" "$ssh_home"
ssh_test_env=(
  HOME="$ssh_home" PATH="$mock_bin:$PATH" MODEL_LOCK="$LOCK"
  LOCAL_AI_CONFIG_DIR="$config" MODELS_DIR="$models" LOCAL_BIN_DIR="$mock_bin"
  UNIT_DIR="$units" SSHD_DROPIN="$sshd_dropin" SYSTEMCTL_LOG="$systemctl_log"
  LOCAL_AI_SETUP_LIB_ONLY=1
)
printf 'user-owned-policy\n' > "$sshd_dropin"
if env "${ssh_test_env[@]}" bash -c \
    'source "$1"; if write_sshd_dropin no no; then exit 0; else exit 42; fi' _ "$ENGINE" >/dev/null 2>&1; then
  fail "SSH transaction overwrote a custom drop-in"
fi
grep -qx 'user-owned-policy' "$sshd_dropin" || fail "custom SSH drop-in was changed"
sshd_link_target="$sshd_dir/central-policy.conf"
printf 'central-policy\n' > "$sshd_link_target"
rm -f "$sshd_dropin"
ln -s "$sshd_link_target" "$sshd_dropin"
if env "${ssh_test_env[@]}" bash -c \
    'source "$1"; if write_sshd_dropin no no; then exit 0; else exit 42; fi' _ "$ENGINE" >/dev/null 2>&1; then
  fail "SSH transaction followed a centrally managed symlink"
fi
[[ -L "$sshd_dropin" ]] || fail "SSH transaction replaced a policy symlink"
grep -qx 'central-policy' "$sshd_link_target" || fail "SSH transaction changed the symlink target"
rm -f "$sshd_dropin"
printf '# Generated by setup-qwen38-pi.sh (remote / ssh-harden). LAN-only SSH policy.\nprior-policy\n' > "$sshd_dropin"
env "${ssh_test_env[@]}" bash -c 'source "$1"; write_sshd_dropin no no' _ "$ENGINE" >/dev/null
grep -q '^PasswordAuthentication no$' "$sshd_dropin" || fail "SSH password policy was not written"
grep -q '^KbdInteractiveAuthentication no$' "$sshd_dropin" || fail "SSH keyboard-interactive policy was not written"

printf '# Generated by setup-qwen38-pi.sh (remote / ssh-harden). LAN-only SSH policy.\nprior-kbd-policy\n' > "$sshd_dropin"
if env "${ssh_test_env[@]}" MOCK_SSH_KBD=yes bash -c \
    'source "$1"; if write_sshd_dropin no no; then exit 0; else exit 42; fi' _ "$ENGINE" >/dev/null 2>&1; then
  fail "SSH effective kbd mismatch returned success"
fi
grep -q '^prior-kbd-policy$' "$sshd_dropin" || fail "SSH kbd mismatch did not restore prior file"

printf '# Generated by setup-qwen38-pi.sh (remote / ssh-harden). LAN-only SSH policy.\nprior-root-policy\n' > "$sshd_dropin"
if env "${ssh_test_env[@]}" MOCK_SSH_ROOT=prohibit-password bash -c \
    'source "$1"; if write_sshd_dropin no no; then exit 0; else exit 42; fi' _ "$ENGINE" >/dev/null 2>&1; then
  fail "SSH effective root-login mismatch returned success"
fi
grep -q '^prior-root-policy$' "$sshd_dropin" || fail "SSH root-policy mismatch did not restore prior file"

printf '# Generated by setup-qwen38-pi.sh (remote / ssh-harden). LAN-only SSH policy.\nprior-reload-policy\n' > "$sshd_dropin"
if env "${ssh_test_env[@]}" FAIL_SSH_RELOAD=1 bash -c \
    'source "$1"; if write_sshd_dropin no no; then exit 0; else exit 42; fi' _ "$ENGINE" >/dev/null 2>&1; then
  fail "SSH reload failure returned success"
fi
grep -q '^prior-reload-policy$' "$sshd_dropin" || fail "SSH reload failure did not restore prior file"

printf '# Generated by setup-qwen38-pi.sh (remote / ssh-harden). LAN-only SSH policy.\nprior-inactive-policy\n' > "$sshd_dropin"
log_start="$(wc -l < "$systemctl_log" | tr -d ' ')"
env "${ssh_test_env[@]}" MOCK_SSH_INACTIVE=1 bash -c \
  'source "$1"; write_sshd_dropin no no' _ "$ENGINE" >/dev/null
new_systemctl_calls="$(tail -n "+$((log_start + 1))" "$systemctl_log")"
if grep -Eq '^(reload|restart|start) sshd$|^enable( --now)? sshd$' <<< "$new_systemctl_calls"; then
  fail "SSH policy transaction started/reloaded a previously inactive daemon"
fi
printf '# Generated by setup-qwen38-pi.sh (remote / ssh-harden). LAN-only SSH policy.\nprior-transition-policy\n' > "$sshd_dropin"
if env "${ssh_test_env[@]}" MOCK_SSH_STATE=activating bash -c \
    'source "$1"; if write_sshd_dropin no no; then exit 0; else exit 42; fi' _ "$ENGINE" >/dev/null 2>&1; then
  fail "SSH policy update accepted an activating daemon"
fi
grep -q '^prior-transition-policy$' "$sshd_dropin" || \
  fail "SSH transition-state refusal changed the prior policy"
pass "transactional SSH policy verification"

printf 'All offline self-tests passed.\n'
