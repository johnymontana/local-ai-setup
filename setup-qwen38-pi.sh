#!/usr/bin/env bash
#
# setup-qwen38-pi.sh
#
# Repeatable setup for local agentic coding on a Framework Desktop
# (AMD Ryzen AI Max+ 395 "Strix Halo", 128GB unified RAM) running Arch Linux:
#
#   Qwen 3.8 27B (unsloth GGUF, MTP speculative decoding)
#     served by llama.cpp (llama-server, Vulkan backend, router mode)
#     driven by the pi coding agent (https://pi.dev)
#
# Tip: run `./manage.sh` for a friendly interactive menu over all of this.
#
# Usage:
#   ./setup-qwen38-pi.sh all              # check + install + model + service + agent
#   ./setup-qwen38-pi.sh check            # verify hardware/OS prerequisites
#   ./setup-qwen38-pi.sh install          # install Arch packages
#   ./setup-qwen38-pi.sh model            # download model GGUFs (resumable)
#   ./setup-qwen38-pi.sh service          # write + enable systemd user service
#   ./setup-qwen38-pi.sh agent            # install the selected coding agent (pi or omp)
#   ./setup-qwen38-pi.sh pi               # force-install the pi agent (https://pi.dev)
#   ./setup-qwen38-pi.sh omp              # force-install oh-my-pi / omp (https://omp.sh)
#   ./setup-qwen38-pi.sh omp-lsp          # OPTIONAL: install common LSP servers for omp
#   ./setup-qwen38-pi.sh kernel-tweaks    # OPTIONAL: raise GPU-addressable memory (needs reboot)
#   ./setup-qwen38-pi.sh remote           # LAN-only SSH/mosh access + agent-session tmux helper
#   ./setup-qwen38-pi.sh ssh-harden       # disable SSH password auth once keys are installed
#   ./setup-qwen38-pi.sh bench            # llama-bench sanity benchmark
#   ./setup-qwen38-pi.sh status           # service status + API smoke test
#   ./setup-qwen38-pi.sh show-config      # print the persisted configuration
#   ./setup-qwen38-pi.sh save-config K=V  # persist tunables (e.g. AGENT=omp REASONING_EFFORT=high)
#
# Tunables (env vars; persisted in ~/.config/local-ai/setup.env, all optional):
#   AGENT=pi                coding agent to install/use: pi | omp
#   QUANT=UD-Q4_K_XL        quant to download/serve (UD-Q4_K_XL | Q8_0)
#   CTX=131072              context window given to llama-server
#   PORT=8080               llama-server port
#   MODELS_DIR=~/llm/models GGUF storage location
#   REASONING_EFFORT=medium xhigh | medium | low | none  (Qwen3.8 thinking budget)
#   DRAFT_N=4               MTP draft tokens (AMD recommends 4 on Ryzen AI Max)
#   GTT_GIB=115             GPU-addressable memory target for kernel-tweaks
#   LAN_CIDR=...            home subnet for the firewall (default: auto-detected)
#
# Precedence for tunables: explicit env var  >  saved setup.env  >  built-in default.
# Re-running any subcommand is safe: every step is idempotent.

set -euo pipefail

# ----------------------------- configuration --------------------------------

# Load persisted tunables as fallbacks (never overriding an explicit env var).
SETUP_ENV="${SETUP_ENV:-$HOME/.config/local-ai/setup.env}"
if [[ -f "$SETUP_ENV" ]]; then
  while IFS='=' read -r _k _v; do
    [[ "$_k" =~ ^[A-Z_][A-Z0-9_]*$ ]] || continue
    printf -v "$_k" '%s' "${!_k:-$_v}"   # := semantics: keep already-set env
  done < "$SETUP_ENV"
fi

AGENT="${AGENT:-pi}"
QUANT="${QUANT:-UD-Q4_K_XL}"
CTX="${CTX:-131072}"
PORT="${PORT:-8080}"
MODELS_DIR="${MODELS_DIR:-$HOME/llm/models}"
REASONING_EFFORT="${REASONING_EFFORT:-medium}"
DRAFT_N="${DRAFT_N:-4}"
GTT_GIB="${GTT_GIB:-115}"

MODEL_NAME="Qwen3.8-27B"
HF_REPO="unsloth/Qwen3.8-27B-GGUF"
HF_BASE="https://huggingface.co/${HF_REPO}/resolve/main"
MODEL_DIR="${MODELS_DIR}/${MODEL_NAME}"

MMPROJ_FILE="mmproj-F16.gguf"
MMPROJ_BYTES=927607488

# Known-good file sizes (bytes) for integrity checks, from the HF repo.
model_file()  {
  case "$1" in
    UD-Q4_K_XL) echo "Qwen3.8-27B-UD-Q4_K_XL.gguf" ;;
    Q8_0)       echo "Qwen3.8-27B-Q8_0.gguf" ;;
    *)          echo "Qwen3.8-27B-${1}.gguf" ;;
  esac
}
model_bytes() {
  case "$1" in
    UD-Q4_K_XL) echo 17559178144 ;;
    Q8_0)       echo 29047086048 ;;
    *)          echo 0 ;;  # unknown quant: skip size verification
  esac
}

LAUNCHER="$HOME/.local/bin/llama-qwen38-server"
UNIT_DIR="$HOME/.config/systemd/user"
UNIT_NAME="llama-server.service"

# ------------------------------- helpers ------------------------------------

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m ok\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarn\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31merror\033[0m %s\n' "$*" >&2; exit 1; }

# Persist the current tunables so the menu and every subcommand agree.
save_config() {
  mkdir -p "$(dirname "$SETUP_ENV")"
  { for k in AGENT QUANT CTX PORT MODELS_DIR REASONING_EFFORT DRAFT_N GTT_GIB; do
      printf '%s=%s\n' "$k" "${!k}"
    done
  } > "$SETUP_ENV"
}

CONFIG_KEYS="AGENT QUANT CTX PORT MODELS_DIR REASONING_EFFORT DRAFT_N GTT_GIB"

need_arch() {
  command -v pacman >/dev/null 2>&1 || die "pacman not found — this script targets Arch Linux."
  [[ $EUID -ne 0 ]] || die "Run as your normal user, not root (sudo is used where needed)."
}

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
  if [[ "$(printf '%s\n' "6.16.9" "${kver%%-*}" | sort -V | head -1)" == "6.16.9" ]]; then
    ok "Kernel ${kver} (>= 6.16.9)"
  else
    warn "Kernel ${kver} is older than 6.16.9 — update Arch (sudo pacman -Syu) for full unified-memory support."
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

  info "Current GPU-addressable (GTT) memory:"
  if [[ -r /sys/module/ttm/parameters/pages_limit ]]; then
    local pages gib
    pages=$(cat /sys/module/ttm/parameters/pages_limit)
    gib=$((pages * 4 / 1024 / 1024))
    echo "    ttm pages_limit = ${pages} pages (~${gib} GiB)"
    if (( gib < 100 )); then
      echo "    (Fine for the default Q4 model. Run 'kernel-tweaks' to unlock ~${GTT_GIB} GiB for Q8/larger models.)"
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
  sudo pacman -S --needed --noconfirm \
    llama-cpp ggml-cpu ggml-vulkan \
    vulkan-radeon vulkan-icd-loader vulkan-tools \
    curl jq nodejs npm

  ok "Installed. llama-server: $(command -v llama-server || echo 'NOT FOUND')"
  llama-server --version 2>&1 | head -2 || true

  info "GPU devices visible to llama.cpp:"
  llama-server --list-devices 2>/dev/null || warn "Could not list devices (a reboot after first GPU driver install can help)."
}

cmd_model() {
  info "Downloading ${MODEL_NAME} (${QUANT}) into ${MODEL_DIR}"
  mkdir -p "$MODEL_DIR"

  local file bytes
  file=$(model_file "$QUANT")
  bytes=$(model_bytes "$QUANT")

  download "${HF_BASE}/${file}" "${MODEL_DIR}/${file}" "$bytes"
  download "${HF_BASE}/${MMPROJ_FILE}" "${MODEL_DIR}/${MMPROJ_FILE}" "$MMPROJ_BYTES"

  ok "Model files ready:"
  ls -lh "$MODEL_DIR"
}

download() {
  local url="$1" dest="$2" expected="$3"

  if [[ -f "$dest" ]]; then
    local actual
    actual=$(stat -c%s "$dest")
    if [[ "$expected" == "0" || "$actual" == "$expected" ]]; then
      ok "$(basename "$dest") already downloaded"
      return 0
    fi
    warn "$(basename "$dest") exists but is ${actual} bytes (expected ${expected}) — resuming/redownloading."
  fi

  info "Fetching $(basename "$dest") (resumable)"
  curl -L --fail --retry 5 --retry-delay 5 -C - -o "${dest}.part" "$url"
  if [[ "$expected" != "0" ]]; then
    local got
    got=$(stat -c%s "${dest}.part")
    [[ "$got" == "$expected" ]] || die "Size mismatch for $(basename "$dest"): got ${got}, expected ${expected}. Delete ${dest}.part and retry."
  fi
  mv "${dest}.part" "$dest"
  ok "$(basename "$dest") downloaded"
}

cmd_service() {
  info "Writing launcher: ${LAUNCHER}"
  mkdir -p "$(dirname "$LAUNCHER")" "$UNIT_DIR" "$MODELS_DIR"

  # Generate a local API key so a stray browser tab (or anything else on the
  # loopback interface) can't drive the model via CORS '*'. Read from a file so
  # the key never appears in `ps`/the process list.
  local keydir="$HOME/.config/local-ai"
  local keyfile="$keydir/llama.key"
  mkdir -p "$keydir"; chmod 700 "$keydir"
  if [[ ! -s "$keyfile" ]]; then
    if command -v openssl >/dev/null 2>&1; then
      openssl rand -hex 32 > "$keyfile"
    else
      head -c32 /dev/urandom | od -An -tx1 | tr -d ' \n' > "$keyfile"
    fi
    chmod 600 "$keyfile"
    ok "Generated llama API key at ${keyfile}"
  else
    ok "Reusing existing llama API key at ${keyfile}"
  fi

  cat > "$LAUNCHER" <<EOF
#!/usr/bin/env bash
# llama.cpp server for local agentic coding (generated by setup-qwen38-pi.sh).
# Edit freely, then: systemctl --user restart ${UNIT_NAME}
set -euo pipefail

# Router mode: serves every model under \$MODELS_DIR and loads them on demand.
# The pi coding agent discovers and switches models via /llama.
#
# Notes:
#  --jinja                     correct Qwen3.8 chat template + tool calling
#                              (default in current builds; kept explicit)
#  --no-mmap                   recommended on Strix Halo unified memory
#  --spec-type draft-mtp       Qwen3.8's built-in multi-token prediction head
#                              => ~2x generation speed, lossless (verified drafts)
#  -np 1                       MTP speculative decoding needs a single slot
#  --cache-reuse 256           reuse the prompt-cache prefix across turns; with a
#                              single slot this is what keeps agent turns fast, so
#                              keep conversation history append-only (both pi/omp)
#  preserve_thinking:true      keep <think> blocks across turns — stabilizes the
#                              cached prefix (omp's local-model guidance relies on it)
#  reasoning_effort            xhigh|medium|low|none — thinking budget per Qwen3.8
#
# If MTP ever misbehaves on your build, remove the two --spec-* lines.
# To pin a specific GPU backend (e.g. with ggml-hip also installed):
#   llama-server --list-devices   then add: --device Vulkan0
exec llama-server \\
  --host 127.0.0.1 \\
  --port ${PORT} \\
  --api-key-file "${keyfile}" \\
  --models-dir "${MODELS_DIR}" \\
  --models-max 2 \\
  --jinja \\
  --no-mmap \\
  -ngl 999 \\
  -c ${CTX} \\
  -fa on \\
  -np 1 \\
  --cache-reuse 256 \\
  --spec-type draft-mtp \\
  --spec-draft-n-max ${DRAFT_N} \\
  --temp 1.0 --top-p 0.95 --top-k 20 --min-p 0.0 \\
  --chat-template-kwargs '{"reasoning_effort":"${REASONING_EFFORT}","preserve_thinking":true}'
EOF
  chmod +x "$LAUNCHER"

  info "Writing systemd user unit: ${UNIT_DIR}/${UNIT_NAME}"
  cat > "${UNIT_DIR}/${UNIT_NAME}" <<EOF
[Unit]
Description=llama.cpp server (Qwen3.8-27B, Vulkan, MTP) for pi agentic coding

[Service]
ExecStart=${LAUNCHER}
Restart=on-failure
RestartSec=3
# llama.cpp's MTP path is new; if you ever observe slow RAM growth over
# multi-day sessions, uncomment to recycle the server daily:
# RuntimeMaxSec=86400
# --- sandboxing: contain a malicious/buggy GGUF parse to as little as possible.
# The server only needs to READ the rest of the system and READ+WRITE the models
# dir (pi's /llama downloads land there). Loosen ReadWritePaths if you relocate.
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=${MODELS_DIR}
PrivateTmp=true
ProtectControlGroups=true
ProtectKernelTunables=true
ProtectKernelModules=true
RestrictSUIDSGID=true
RestrictNamespaces=true
LockPersonality=true
# GPU access needs the render/video device nodes and the dri devices:
DeviceAllow=char-drm rw
SupplementaryGroups=render video

[Install]
WantedBy=default.target
EOF

  systemctl --user daemon-reload
  systemctl --user enable --now "$UNIT_NAME"
  local me
  me="${USER:-$(id -un)}"
  loginctl enable-linger "$me" 2>/dev/null || sudo loginctl enable-linger "$me" || \
    warn "Could not enable lingering — the server will stop when you log out."

  ok "Service enabled. Logs: journalctl --user -fu ${UNIT_NAME}"
}

cmd_pi() {
  info "Installing the pi coding agent"
  if command -v pi >/dev/null 2>&1; then
    ok "pi already installed: $(pi --version 2>/dev/null || echo 'version unknown')"
  else
    curl -fsSL https://pi.dev/install.sh | sh
    ok "pi installed (you may need to open a new shell for PATH changes)"
  fi

  # Older pi builds ship llama.cpp integration as an extension; harmless if built in.
  if command -v pi >/dev/null 2>&1; then
    pi install npm:pi-llama-cpp >/dev/null 2>&1 || true
  fi

  # Starter global config — written only if you don't already have one, so your
  # own settings are never clobbered. Local-first defaults: telemetry off.
  local pidir="$HOME/.pi/agent"
  mkdir -p "$pidir"
  if [[ ! -f "$pidir/settings.json" ]]; then
    cat > "$pidir/settings.json" <<'EOF'
{
  "enableInstallTelemetry": false,
  "enableAnalytics": false,
  "compaction": { "enabled": true, "keepRecentTokens": 24000 }
}
EOF
    ok "wrote starter ~/.pi/agent/settings.json (telemetry off; auto-compaction on)"
  else
    ok "existing ~/.pi/agent/settings.json found — leaving it alone"
  fi

  local keyfile="$HOME/.config/local-ai/llama.key"
  cat <<EOF

  Connect pi to your local server (one-time, inside pi):

     1.  export LLAMA_BASE_URL=http://127.0.0.1:${PORT}
         export LLAMA_API_KEY=\$(cat ${keyfile})     # server now requires this
     2.  cd into a project and run:  pi
     3.  /llama    -> load ${MODEL_NAME} (also downloads new models from HF)
     4.  /model    -> select it for the session
     5.  give it a task

  Make it permanent (do this once):
     echo 'export LLAMA_BASE_URL=http://127.0.0.1:${PORT}' >> ~/.bashrc
     echo 'export LLAMA_API_KEY=\$(cat ${keyfile})'        >> ~/.bashrc

  NOTE: the server is API-key protected as of this version. If pi reports 401 /
  unauthorized, the LLAMA_API_KEY export above is missing from your shell.

EOF
}

# ------------------------------- oh-my-pi (omp) ------------------------------

cmd_omp() {
  info "Installing oh-my-pi (omp) — the IDE-wired coding-agent fork of pi"

  if ! command -v omp >/dev/null 2>&1; then
    # omp runs on Bun; its installer usually handles that, but make sure Bun is
    # present as a fallback path (Arch has no official bun package).
    if ! command -v bun >/dev/null 2>&1; then
      info "Installing the Bun runtime (omp's engine)"
      curl -fsSL https://bun.sh/install | bash || warn "Bun install script failed; will still try omp.sh."
      export BUN_INSTALL="${BUN_INSTALL:-$HOME/.bun}"
      export PATH="$BUN_INSTALL/bin:$PATH"
    fi
    curl -fsSL https://omp.sh/install | sh \
      || { command -v bun >/dev/null 2>&1 && bun install -g @oh-my-pi/pi-coding-agent; } \
      || die "omp install failed. See https://github.com/can1357/oh-my-pi#install"
    ok "omp installed (open a new shell if 'omp' isn't on PATH yet)"
  else
    ok "omp already installed: $(omp --version 2>/dev/null || echo 'version unknown')"
  fi

  local ompdir="$HOME/.omp/agent"
  local keyfile="$HOME/.config/local-ai/llama.key"
  mkdir -p "$ompdir"

  # models.yml — point omp's llama.cpp provider at our API-key-protected server.
  # `apiKey: LLAMA_API_KEY` is omp's env-var form (it resolves the *name* to the
  # env value). discovery surfaces whatever the router has loaded; the explicit
  # model guarantees `--model llamacpp/Qwen3.8-27B` works from the first run.
  if [[ ! -f "$ompdir/models.yml" ]]; then
    cat > "$ompdir/models.yml" <<EOF
providers:
  llamacpp:
    baseUrl: http://127.0.0.1:${PORT}/v1
    api: openai-completions
    apiKey: LLAMA_API_KEY
    authHeader: true
    discovery:
      type: llama.cpp
    models:
      - id: ${MODEL_NAME}
        name: Qwen 3.8 27B (local)
        reasoning: true
        input: [text, image]
        contextWindow: ${CTX}
        maxTokens: 32768
        cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }
        compat:
          supportsStore: false
          supportsDeveloperRole: false
EOF
    ok "wrote ~/.omp/agent/models.yml (llamacpp provider -> ${MODEL_NAME})"
  else
    ok "existing ~/.omp/agent/models.yml found — leaving it alone"
  fi

  # config.yml — the local-Qwen tuning that matters. The compaction flags keep
  # the conversation prefix append-only so the llama.cpp prompt cache survives
  # across turns (critical with -np 1); modelRoles.default means bare `omp` uses
  # the local model with no --model flag.
  if [[ ! -f "$ompdir/config.yml" ]]; then
    cat > "$ompdir/config.yml" <<EOF
setupVersion: 1
symbolPreset: nerd
modelRoles:
  default: llamacpp/${MODEL_NAME}
compaction:
  # keep history append-only -> stable prompt-cache prefix on the single slot
  supersedeReads: false
  dropUseless: false
memory:
  backend: "off"
EOF
    ok "wrote ~/.omp/agent/config.yml (local-Qwen prompt-cache discipline)"
  else
    ok "existing ~/.omp/agent/config.yml found — leaving it alone"
  fi

  # Persist the env omp needs. PI_NO_TITLE stops between-turn title-generation
  # calls from evicting the single KV slot; OMPX_PARSER_ACTIVE turns on the
  # output-parser repair path that catches local models emitting tool calls as
  # fenced prose. These are omp's documented local-model reliability toggles.
  add_bashrc_line 'export LLAMA_BASE_URL=http://127.0.0.1:'"${PORT}"
  add_bashrc_line 'export LLAMA_CPP_BASE_URL=http://127.0.0.1:'"${PORT}"
  # shellcheck disable=SC2016  # the $(cat ...) is meant to be literal in ~/.bashrc
  add_bashrc_line 'export LLAMA_API_KEY=$(cat '"${keyfile}"')'
  add_bashrc_line 'export PI_NO_TITLE=1'
  add_bashrc_line 'export OMPX_PARSER_ACTIVE=1'

  cat <<EOF

  oh-my-pi is ready. In a new shell (so the exports load):

     cd <your-project>
     omp                       # uses llamacpp/${MODEL_NAME} via modelRoles.default
     # or explicitly:  omp --model llamacpp/${MODEL_NAME}

  Optional but recommended for omp's IDE features:
     ./$(basename "$0") omp-lsp   # install language servers (LSP is wired into edits)

  If omp reports 401/unauthorized, the LLAMA_API_KEY export is missing from your
  shell. If it emits tool calls as text, confirm OMPX_PARSER_ACTIVE=1 is set.

EOF
}

# Append a line to ~/.bashrc only if an equivalent one isn't already there.
add_bashrc_line() {
  local line="$1" rc="$HOME/.bashrc"
  touch "$rc"
  grep -qxF "$line" "$rc" || printf '%s\n' "$line" >> "$rc"
}

cmd_omp_lsp() {
  info "Installing common language servers for omp's LSP integration"
  # These power omp's rename/refactor/diagnostics-on-edit. Install what matches
  # the languages you work in; the rest are harmless to skip.
  if command -v pacman >/dev/null 2>&1; then
    sudo pacman -S --needed --noconfirm \
      bash-language-server typescript-language-server \
      python-lsp-server gopls rust-analyzer clang 2>/dev/null \
      || warn "Some LSP packages weren't found in the repos — install the ones you need by hand."
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

cmd_show_config() {
  info "Persisted configuration ($SETUP_ENV):"
  local k
  for k in $CONFIG_KEYS; do printf '    %-18s= %s\n' "$k" "${!k}"; done
  [[ -f "$SETUP_ENV" ]] || echo "    (no saved file yet — these are defaults/env)"
}

# save-config KEY=VALUE [KEY=VALUE ...]  — persist tunables.
cmd_save_config() {
  local pair k v
  for pair in "$@"; do
    [[ "$pair" == *=* ]] || die "Expected KEY=VALUE, got: $pair"
    k="${pair%%=*}"; v="${pair#*=}"
    case " $CONFIG_KEYS " in
      *" $k "*) printf -v "$k" '%s' "$v" ;;
      *) die "Unknown config key: $k (allowed: $CONFIG_KEYS)" ;;
    esac
  done
  save_config
  cmd_show_config
}

cmd_kernel_tweaks() {
  need_arch
  info "OPTIONAL: raise GPU-addressable unified memory to ~${GTT_GIB} GiB"
  echo
  echo "  Not needed for the default ${QUANT} model (fits in the stock ~64 GiB GTT)."
  echo "  Needed for: Q8_0 + 262K context, BF16-class models, or larger models later."
  echo
  echo "  This writes /etc/modprobe.d/99-strix-halo-llm.conf and rebuilds the"
  echo "  initramfs (mkinitcpio -P). Takes effect after a reboot. Reversible by"
  echo "  deleting the file and rebuilding again."
  echo
  local reply=""
  read -r -p "Proceed? [y/N] " reply || true
  [[ "$reply" =~ ^[Yy]$ ]] || { warn "Skipped."; return 0; }

  local mib pages
  mib=$((GTT_GIB * 1024))
  pages=$((GTT_GIB * 262144))  # 4 KiB pages per GiB = 262144

  sudo tee /etc/modprobe.d/99-strix-halo-llm.conf >/dev/null <<EOF
# Allow the Strix Halo iGPU to map ~${GTT_GIB} GiB of unified RAM (GTT).
# Generated by setup-qwen38-pi.sh — delete this file + 'sudo mkinitcpio -P' to revert.
options amdgpu gttsize=${mib}
options ttm pages_limit=${pages} page_pool_size=${pages}
EOF
  sudo mkinitcpio -P

  ok "Done. Reboot to apply."
  echo
  echo "  Optional extra (~6% memory bandwidth): add 'amd_iommu=off' to your kernel"
  echo "  command line if you don't need VFIO/passthrough:"
  echo "    - systemd-boot: append to the options line in /boot/loader/entries/*.conf"
  echo "    - GRUB: add to GRUB_CMDLINE_LINUX_DEFAULT in /etc/default/grub,"
  echo "            then: sudo grub-mkconfig -o /boot/grub/grub.cfg"
  echo
  echo "  BIOS reminder (Framework Desktop): leave iGPU Memory Allocation at the"
  echo "  small/default (512MB) setting — on Linux, models live in GTT, not the"
  echo "  dedicated carveout."
}

cmd_bench() {
  local file
  file="${MODEL_DIR}/$(model_file "$QUANT")"
  [[ -f "$file" ]] || die "Model not downloaded yet — run: $0 model"
  command -v llama-bench >/dev/null 2>&1 || die "llama-bench not found — run: $0 install"
  info "Benchmarking ${QUANT} (pp512 = prompt processing, tg128 = generation)"
  llama-bench -m "$file" -ngl 999 -fa 1 -mmp 0 -p 512 -n 128
  echo
  echo "  Rough expectations on Ryzen AI Max+ 395 for this dense 27B:"
  echo "    generation ~10-14 t/s raw; ~20-35 t/s in real use with MTP enabled."
}

cmd_status() {
  info "Configuration: agent=${AGENT}  quant=${QUANT}  ctx=${CTX}  reasoning=${REASONING_EFFORT}"
  local abin
  abin=$(command -v "$AGENT" 2>/dev/null || echo "NOT INSTALLED — run: $0 agent")
  echo "    ${AGENT} binary: ${abin}"
  echo
  info "Service:"
  systemctl --user --no-pager status "$UNIT_NAME" || true
  echo
  info "API check (http://127.0.0.1:${PORT}):"
  curl -s --max-time 10 "http://127.0.0.1:${PORT}/v1/models" | jq . || \
    warn "Server not answering (yet). Logs: journalctl --user -fu ${UNIT_NAME}"
  echo
  info "Chat smoke test (first call may take a minute while the model loads):"
  curl -s --max-time 300 "http://127.0.0.1:${PORT}/v1/chat/completions" \
    -H 'Content-Type: application/json' \
    -d '{"messages":[{"role":"user","content":"Reply with exactly: READY"}],"max_tokens":2048}' \
    | jq -r '.choices[0].message.content' || warn "Smoke test failed — check logs."
}

# ------------------------- remote access (LAN-only) --------------------------

SSHD_DROPIN="/etc/ssh/sshd_config.d/20-local-ai-lan.conf"

write_sshd_dropin() {
  local pw="$1" me
  me="${USER:-$(id -un)}"
  sudo tee "$SSHD_DROPIN" >/dev/null <<EOF
# Generated by setup-qwen38-pi.sh (remote / ssh-harden). LAN-only SSH policy.
# Re-run 'setup-qwen38-pi.sh ssh-harden' after installing keys on every device.
PermitRootLogin no
AllowUsers ${me}
PubkeyAuthentication yes
PasswordAuthentication ${pw}
KbdInteractiveAuthentication ${pw}
MaxAuthTries 3
X11Forwarding no
AllowAgentForwarding no
ClientAliveInterval 60
ClientAliveCountMax 10
EOF

  # Validate the WHOLE config before touching the running daemon — a syntax
  # error here could otherwise lock you out on the next restart.
  if ! sudo sshd -t; then
    warn "sshd config failed validation; removing the drop-in and leaving sshd untouched."
    sudo rm -f "$SSHD_DROPIN"
    return 1
  fi
  sudo systemctl reload sshd 2>/dev/null || sudo systemctl restart sshd

  # Verify the RESOLVED setting actually took effect. Because sshd uses
  # first-match-wins, a PasswordAuthentication line earlier in the main config
  # (before the Include) would silently override this drop-in. Catch that.
  local effective
  effective=$(sudo sshd -T 2>/dev/null | awk '$1=="passwordauthentication"{print $2}' || true)
  if [[ -n "$effective" && "$effective" != "$pw" ]]; then
    warn "sshd reports passwordauthentication=${effective}, but this drop-in set ${pw}."
    warn "Something earlier in /etc/ssh/sshd_config wins (first-match). Check the Include"
    warn "line is near the TOP of /etc/ssh/sshd_config, above any PasswordAuthentication."
    return 1
  fi
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

install_session_helper() {
  info "Installing the ai-session helper to /usr/local/bin"
  local tmp
  tmp=$(mktemp)
  cat > "$tmp" <<'EOF'
#!/usr/bin/env bash
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

# Pick the agent: explicit env > saved setup.env > pi.
env_file="$HOME/.config/local-ai/setup.env"
if [[ -z "${AGENT:-}" && -f "$env_file" ]]; then
  AGENT=$(awk -F= '$1=="AGENT"{print $2}' "$env_file" | tail -1)
fi
AGENT="${AGENT:-pi}"

if [[ $# -eq 0 ]]; then
  echo "agent sessions:"
  tmux ls 2>/dev/null | grep '^ai-' || echo "  (none)"
  echo "usage: ai-session <project-dir>   (agent: $AGENT)"
  exit 0
fi

dir=$(realpath -e "$1" 2>/dev/null) || { echo "no such directory: $1" >&2; exit 1; }
[[ -d "$dir" ]] || { echo "not a directory: $dir" >&2; exit 1; }

base=$(basename "$dir")
name="ai-${base//[^A-Za-z0-9_-]/-}"

if ! tmux has-session -t "=$name" 2>/dev/null; then
  tmux new-session -d -s "$name" -c "$dir"
  tmux send-keys -t "=$name" "$AGENT" C-m
fi
exec tmux attach-session -t "=$name"
EOF
  sudo install -m 0755 "$tmp" /usr/local/bin/ai-session
  # Keep pi-session as a compatibility alias.
  sudo ln -sf /usr/local/bin/ai-session /usr/local/bin/pi-session
  rm -f "$tmp"
  ok "ai-session installed (pi-session kept as an alias)"
}

configure_firewall() {
  if systemctl is-active --quiet firewalld 2>/dev/null; then
    warn "firewalld is active — skipping ufw. Add equivalent rules yourself, e.g.:"
    echo "    firewall-cmd --permanent --add-rich-rule='rule family=ipv4 source address=<LAN_CIDR> port port=22 protocol=tcp accept'"
    echo "    firewall-cmd --permanent --add-rich-rule='rule family=ipv4 source address=<LAN_CIDR> port port=60000-61000 protocol=udp accept'"
    echo "    firewall-cmd --reload"
    return 0
  fi

  local cidr
  if ! cidr=$(detect_lan_cidr); then
    warn "Could not auto-detect your LAN subnet."
    warn "Re-run as:  LAN_CIDR=192.168.1.0/24 $0 remote"
    return 0
  fi

  info "Firewall: restrict SSH/mosh/mDNS to your home subnet (${cidr})"
  echo "  (address/prefix form is fine — the firewall masks it to the subnet)"
  local reply=""
  read -r -p "Apply ufw rules and enable the firewall now? [Y/n] " reply || true
  if [[ "$reply" =~ ^[Nn]$ ]]; then warn "Skipped firewall setup."; return 0; fi

  # Ensure ufw also manages ip6tables. If IPV6=no, IPv6 inbound is left to the
  # kernel default (often ACCEPT) — and many home ISPs hand out a globally
  # routable IPv6 address via SLAAC, which would expose sshd to the internet.
  if [[ -f /etc/default/ufw ]] && ! grep -qE '^IPV6=yes' /etc/default/ufw; then
    sudo sed -i 's/^IPV6=.*/IPV6=yes/' /etc/default/ufw
    grep -qE '^IPV6=' /etc/default/ufw || echo 'IPV6=yes' | sudo tee -a /etc/default/ufw >/dev/null
    ok "Set IPV6=yes in /etc/default/ufw (IPv6 now default-denied too)"
  fi

  sudo ufw default deny incoming
  sudo ufw default deny routed
  sudo ufw default allow outgoing
  # 'limit' rate-limits new SSH connections (>=6 in 30s from one source get
  # dropped) — cheap brute-force resistance for the LAN-facing port.
  sudo ufw limit from "$cidr" to any port 22 proto tcp comment 'ssh (LAN only, rate-limited)'
  sudo ufw allow from "$cidr" to any port 60000:61000 proto udp comment 'mosh (LAN only)'
  sudo ufw allow from "$cidr" to any port 5353 proto udp comment 'mDNS (LAN only)'
  sudo ufw --force enable
  sudo systemctl enable --now ufw >/dev/null 2>&1 || true
  sudo ufw status verbose

  # Defense in depth against password brute force during the bootstrap window.
  if sudo pacman -S --needed --noconfirm fail2ban >/dev/null 2>&1; then
    sudo mkdir -p /etc/fail2ban/jail.d
    sudo tee /etc/fail2ban/jail.d/sshd.local >/dev/null <<'EOF'
# Generated by setup-qwen38-pi.sh — ban hosts that fail SSH auth repeatedly.
[sshd]
enabled = true
backend = systemd
maxretry = 4
findtime = 10m
bantime = 1h
EOF
    sudo systemctl enable --now fail2ban >/dev/null 2>&1 || true
    ok "fail2ban enabled (bans a source after 4 failed SSH logins in 10 min)"
  else
    warn "Could not install fail2ban — brute-force protection relies on ufw rate-limiting only."
  fi

  ok "Inbound traffic is blocked except SSH/mosh/mDNS from ${cidr}."
  ok "Do NOT port-forward 22 on your router — nothing here should be internet-facing."
}

cmd_remote() {
  need_arch
  info "Setting up LAN-only remote access (SSH + mosh + tmux + mDNS)"
  sudo pacman -S --needed --noconfirm openssh mosh tmux avahi ufw

  # Make sure key-based logins have somewhere to land.
  mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
  touch "$HOME/.ssh/authorized_keys" && chmod 600 "$HOME/.ssh/authorized_keys"

  sudo systemctl enable --now sshd
  write_sshd_dropin yes || warn "SSH policy drop-in did not fully apply — see warnings above."
  ok "sshd enabled (password auth ON for bootstrap — run '$0 ssh-harden' once keys are installed)"

  sudo systemctl enable --now avahi-daemon
  ok "mDNS enabled — this machine is reachable as $(hostname).local on your LAN"

  if [[ ! -f "$HOME/.tmux.conf" ]]; then
    cat > "$HOME/.tmux.conf" <<'EOF'
# Defaults for phone-friendly pi sessions (generated; edit freely).
set -g mouse on                       # touch scrolling on iPhone/iPad
set -g history-limit 50000
set -s escape-time 10
setw -g mode-keys vi

# pi needs extended keys so Shift+Enter / Ctrl+Enter aren't seen as plain Enter.
# (per pi's tmux guide; csi-u form needs tmux >= 3.5, guarded below.)
set -g extended-keys on
%if "#{>=:#{version},3.5}"
set -g extended-keys-format csi-u
%endif

# Truecolor + focus events so pi's TUI renders correctly over SSH.
set -g default-terminal "tmux-256color"
set -ga terminal-features ",*:RGB"
set -g focus-events on
EOF
    ok "wrote ~/.tmux.conf (mouse + extended-keys tuned for pi)"
  else
    ok "existing ~/.tmux.conf found — leaving it alone"
  fi

  install_session_helper
  configure_firewall

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

  Laptop (macOS / Linux):
     ssh-copy-id ${me}@${host}.local                      # once per laptop
     ssh -t ${me}@${host}.local ai-session ~/some-project
     mosh ${me}@${host}.local -- ai-session ~/some-project    # survives sleep/roaming

  iPhone / iPad — Blink Shell (best mosh support) or Termius:
     1. Generate a key in the app and copy the public key
     2. Connect once with your password (host ${host}.local, user ${me}) and:
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
  local keys=0
  if [[ -f "$HOME/.ssh/authorized_keys" ]]; then
    keys=$(grep -cEv '^[[:space:]]*(#|$)' "$HOME/.ssh/authorized_keys" || true)
    keys="${keys:-0}"
  fi
  (( keys > 0 )) || die "No keys in ~/.ssh/authorized_keys — add a key from each device first, or you'll lock yourself out."
  if write_sshd_dropin no; then
    ok "Password auth disabled — SSH is now key-only (${keys} authorized key(s))."
    ok "Confirm from a SECOND session before closing this one:  ssh ${USER:-$(id -un)}@localhost true"
  else
    die "Hardening did NOT take effect (see warnings). Password auth may still be ON — do not assume you're locked down."
  fi
}

cmd_all() {
  save_config          # persist the agent/tunables this run used
  cmd_check
  cmd_install
  cmd_model
  cmd_service
  cmd_agent
  echo
  ok "All done (agent: ${AGENT}). Try:  $0 status   then:  cd <project> && ${AGENT}"
  echo "   Optional: $0 remote   — SSH/mosh access from your phones and laptops (LAN-only)"
}

# --------------------------------- main --------------------------------------

case "${1:-all}" in
  all)            cmd_all ;;
  check)          cmd_check ;;
  install)        cmd_install ;;
  model)          cmd_model ;;
  service)        cmd_service ;;
  agent)          cmd_agent ;;
  pi)             AGENT=pi;  cmd_pi ;;
  omp)            AGENT=omp; cmd_omp ;;
  omp-lsp)        cmd_omp_lsp ;;
  kernel-tweaks)  cmd_kernel_tweaks ;;
  remote)         cmd_remote ;;
  ssh-harden)     cmd_ssh_harden ;;
  bench)          cmd_bench ;;
  status)         cmd_status ;;
  show-config)    cmd_show_config ;;
  save-config)    shift; cmd_save_config "$@" ;;
  *) die "Unknown subcommand: $1 (use: all|check|install|model|service|agent|pi|omp|omp-lsp|kernel-tweaks|remote|ssh-harden|bench|status|show-config|save-config)" ;;
esac
