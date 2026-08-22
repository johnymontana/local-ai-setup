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
# Usage:
#   ./setup-qwen38-pi.sh all              # check + install + model + service + pi
#   ./setup-qwen38-pi.sh check            # verify hardware/OS prerequisites
#   ./setup-qwen38-pi.sh install          # install Arch packages
#   ./setup-qwen38-pi.sh model            # download model GGUFs (resumable)
#   ./setup-qwen38-pi.sh service          # write + enable systemd user service
#   ./setup-qwen38-pi.sh pi               # install the pi coding agent
#   ./setup-qwen38-pi.sh kernel-tweaks    # OPTIONAL: raise GPU-addressable memory (needs reboot)
#   ./setup-qwen38-pi.sh bench            # llama-bench sanity benchmark
#   ./setup-qwen38-pi.sh status           # service status + API smoke test
#
# Tunables (env vars, all optional):
#   QUANT=UD-Q4_K_XL        quant to download/serve (UD-Q4_K_XL | Q8_0)
#   CTX=131072              context window given to llama-server
#   PORT=8080               llama-server port
#   MODELS_DIR=~/llm/models GGUF storage location
#   REASONING_EFFORT=medium xhigh | medium | low | none  (Qwen3.8 thinking budget)
#   DRAFT_N=4               MTP draft tokens (AMD recommends 4 on Ryzen AI Max)
#   GTT_GIB=115             GPU-addressable memory target for kernel-tweaks
#
# Re-running any subcommand is safe: every step is idempotent.

set -euo pipefail

# ----------------------------- configuration --------------------------------

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
#  reasoning_effort            xhigh|medium|low|none — thinking budget per Qwen3.8
#
# If MTP ever misbehaves on your build, remove the two --spec-* lines.
# To pin a specific GPU backend (e.g. with ggml-hip also installed):
#   llama-server --list-devices   then add: --device Vulkan0
exec llama-server \\
  --host 127.0.0.1 \\
  --port ${PORT} \\
  --models-dir "${MODELS_DIR}" \\
  --models-max 2 \\
  --jinja \\
  --no-mmap \\
  -ngl 999 \\
  -c ${CTX} \\
  -fa on \\
  -np 1 \\
  --spec-type draft-mtp \\
  --spec-draft-n-max ${DRAFT_N} \\
  --temp 1.0 --top-p 0.95 --top-k 20 --min-p 0.0 \\
  --chat-template-kwargs '{"reasoning_effort":"${REASONING_EFFORT}"}'
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

  cat <<EOF

  Connect pi to your local server (one-time, inside pi):

     1.  export LLAMA_BASE_URL=http://127.0.0.1:${PORT}   # or use /login llama.cpp
     2.  cd into a project and run:  pi
     3.  /llama    -> load ${MODEL_NAME} (also downloads new models from HF)
     4.  /model    -> select it for the session
     5.  give it a task

  Add the export to your shell rc to make it permanent, e.g.:
     echo 'export LLAMA_BASE_URL=http://127.0.0.1:${PORT}' >> ~/.bashrc

EOF
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

cmd_all() {
  cmd_check
  cmd_install
  cmd_model
  cmd_service
  cmd_pi
  echo
  ok "All done. Try:  $0 status   then:  cd <your-project> && pi"
}

# --------------------------------- main --------------------------------------

case "${1:-all}" in
  all)            cmd_all ;;
  check)          cmd_check ;;
  install)        cmd_install ;;
  model)          cmd_model ;;
  service)        cmd_service ;;
  pi)             cmd_pi ;;
  kernel-tweaks)  cmd_kernel_tweaks ;;
  bench)          cmd_bench ;;
  status)         cmd_status ;;
  *) die "Unknown subcommand: $1 (use: all|check|install|model|service|pi|kernel-tweaks|bench|status)" ;;
esac
