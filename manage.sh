#!/usr/bin/env bash
#
# manage.sh — interactive control panel for the local-ai-setup repo.
#
# A friendly menu over setup-qwen38-pi.sh: pick your coding agent (pi or omp),
# run the setup steps, tune configuration, wire up remote access, and check
# status — without memorizing subcommands.
#
#   ./manage.sh
#
# Everything it does is just a call to ./setup-qwen38-pi.sh <subcommand>, so
# nothing here is magic and every action stays scriptable on its own.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE="$HERE/setup-qwen38-pi.sh"
SETUP_ENV="${SETUP_ENV:-$HOME/.config/local-ai/setup.env}"
PORT="${PORT:-8080}"

[[ -x "$ENGINE" ]] || chmod +x "$ENGINE" 2>/dev/null || true
[[ -f "$ENGINE" ]] || { echo "Can't find setup-qwen38-pi.sh next to manage.sh" >&2; exit 1; }

# ------------------------------- styling ------------------------------------

if [[ -t 1 ]]; then
  B=$'\033[1m'; DIM=$'\033[2m'; R=$'\033[0m'
  GRN=$'\033[1;32m'; YLW=$'\033[1;33m'; RED=$'\033[1;31m'; ORG=$'\033[38;5;208m'
else
  B=""; DIM=""; R=""; GRN=""; YLW=""; RED=""; ORG=""
fi

cfg() {  # read one persisted key, else print the fallback ($2)
  local k="$1" def="${2:-}"
  [[ -f "$SETUP_ENV" ]] && awk -F= -v k="$k" '$1==k{v=$2} END{if(v!=""){print v; exit}}' "$SETUP_ENV" && return 0
  printf '%s' "$def"
}

pause() { read -r -p $'\n'"${DIM}Press Enter to continue…${R}" _ || true; }

engine() {  # run an engine subcommand, surfacing failures without killing the menu
  echo "${DIM}\$ ./setup-qwen38-pi.sh $*${R}"
  "$ENGINE" "$@" || warn "'$*' exited non-zero — review the output above."
}
warn() { printf '%swarn%s %s\n' "$YLW" "$R" "$*"; }

# ------------------------------- status line --------------------------------

agent_now() { cfg AGENT pi; }

svc_state() {
  systemctl --user is-active llama-server.service 2>/dev/null || echo "inactive"
}

api_state() {
  if curl -s --max-time 3 "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1 \
     || curl -s --max-time 3 "http://127.0.0.1:${PORT}/v1/models" >/dev/null 2>&1; then
    echo "reachable"
  else
    echo "down"
  fi
}

banner() {
  local a s api abin
  a="$(agent_now)"; s="$(svc_state)"; api="$(api_state)"
  abin=$(command -v "$a" >/dev/null 2>&1 && echo "installed" || echo "${RED}not installed${R}")
  clear 2>/dev/null || true
  cat <<EOF
${ORG}${B}  local-ai · control panel${R}
${DIM}  Qwen 3.8 27B · llama.cpp (Vulkan, MTP) · Framework Desktop / Strix Halo${R}

   agent    ${B}${a}${R}  (${abin})
   server   $( [[ "$s" == active ]] && echo "${GRN}active${R}" || echo "${YLW}${s}${R}" )   api $( [[ "$api" == reachable ]] && echo "${GRN}reachable${R}" || echo "${RED}${api}${R}" )
   config   quant=$(cfg QUANT UD-Q4_K_XL)  ctx=$(cfg CTX 131072)  reasoning=$(cfg REASONING_EFFORT medium)
EOF
}

# --------------------------------- actions ----------------------------------

choose_agent() {
  banner
  cat <<EOF

${B}Choose your coding agent${R}

   ${B}1)${R} pi   ${DIM}— minimal, fast, hackable. Rock-solid baseline.${R}
                ${DIM}https://pi.dev${R}
   ${B}2)${R} omp  ${DIM}— oh-my-pi: IDE wired in (LSP, debugger, subagents, 32 tools),${R}
                ${DIM}hashline edits, tuned for local models. https://omp.sh${R}
   ${B}b)${R} back
EOF
  local c; read -r -p $'\n'"select [1/2/b]: " c || return 0
  case "$c" in
    1) engine save-config AGENT=pi ;  echo; read -r -p "Install pi now? [Y/n] " y || true; [[ "${y:-Y}" =~ ^[Nn]$ ]] || engine pi ;;
    2) engine save-config AGENT=omp; echo; read -r -p "Install omp now? [Y/n] " y || true; [[ "${y:-Y}" =~ ^[Nn]$ ]] || engine omp ;;
    *) return 0 ;;
  esac
  pause
}

tune_config() {
  banner
  cat <<EOF

${B}Tune configuration${R}  ${DIM}(applied to the server on next (re)start)${R}

   ${B}1)${R} reasoning effort   now: $(cfg REASONING_EFFORT medium)   ${DIM}xhigh | medium | low | none${R}
   ${B}2)${R} context window     now: $(cfg CTX 131072)   ${DIM}e.g. 131072, 200000, 262144${R}
   ${B}3)${R} quant              now: $(cfg QUANT UD-Q4_K_XL)   ${DIM}UD-Q4_K_XL | Q8_0${R}
   ${B}4)${R} MTP draft tokens   now: $(cfg DRAFT_N 4)   ${DIM}3–7; AMD suggests 4 here${R}
   ${B}b)${R} back
EOF
  local c v; read -r -p $'\n'"select: " c || return 0
  case "$c" in
    1) read -r -p "reasoning effort [xhigh/medium/low/none]: " v && [[ -n "$v" ]] && engine save-config "REASONING_EFFORT=$v" ;;
    2) read -r -p "context window (tokens): " v && [[ "$v" =~ ^[0-9]+$ ]] && engine save-config "CTX=$v" ;;
    3) read -r -p "quant [UD-Q4_K_XL/Q8_0]: " v && [[ -n "$v" ]] && engine save-config "QUANT=$v" ;;
    4) read -r -p "MTP draft tokens: " v && [[ "$v" =~ ^[0-9]+$ ]] && engine save-config "DRAFT_N=$v" ;;
    *) return 0 ;;
  esac
  if [[ "$c" =~ ^[1234]$ ]]; then
    echo; read -r -p "Rewrite + restart the server now to apply? [Y/n] " y || true
    [[ "${y:-Y}" =~ ^[Nn]$ ]] || engine service
  fi
  pause
}

main_menu() {
  banner
  cat <<EOF

   ${B}1)${R} Full setup            ${DIM}check → install → model → server → agent${R}
   ${B}2)${R} Choose agent          ${DIM}pi ⇄ omp (currently: $(agent_now))${R}
   ${B}3)${R} Install / upgrade agent
   ${B}4)${R} (Re)start model server
   ${B}5)${R} Tune configuration    ${DIM}reasoning · context · quant · MTP${R}
   ${B}6)${R} Remote access         ${DIM}LAN-only SSH + mosh + ai-session${R}
   ${B}7)${R} Harden SSH            ${DIM}switch to key-only auth${R}
   ${B}8)${R} Install LSP servers   ${DIM}(omp IDE features)${R}
   ${B}9)${R} Kernel GTT tweak      ${DIM}unlock ~115 GiB for the GPU (reboot)${R}
   ${B}s)${R} Status                ${B}b)${R} Benchmark                ${B}c)${R} Show config
   ${B}q)${R} Quit
EOF
  local c; read -r -p $'\n'"select: " c || { echo; exit 0; }
  case "$c" in
    1) engine all; pause ;;
    2) choose_agent ;;
    3) engine agent; pause ;;
    4) engine service; pause ;;
    5) tune_config ;;
    6) engine remote; pause ;;
    7) engine ssh-harden; pause ;;
    8) engine omp-lsp; pause ;;
    9) engine kernel-tweaks; pause ;;
    s|S) engine status; pause ;;
    b|B) engine bench; pause ;;
    c|C) engine show-config; pause ;;
    q|Q) exit 0 ;;
    *) ;;
  esac
}

# ---------------------------------- loop ------------------------------------

while true; do main_menu; done
