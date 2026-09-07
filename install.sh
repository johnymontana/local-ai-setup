#!/usr/bin/env bash
# Install the everyday baseline onto an already installed Omarchy desktop.
set -euo pipefail
case "${1:-}" in
  -h|--help|help)
    echo 'Usage: ./install.sh'
    echo 'Install the pinned everyday model, local service, agent, and desktop launchers.'
    echo 'Update Omarchy and reboot first. See README.md for the fresh-install walkthrough.'
    exit 0
    ;;
esac
(( $# == 0 )) || { echo 'Usage: ./install.sh' >&2; exit 2; }
LOCAL_AI_REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
exec bash "$LOCAL_AI_REPO/setup-qwen38-pi.sh" all
