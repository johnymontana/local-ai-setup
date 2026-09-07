#!/usr/bin/env bash
# Backward-compatible entry point for contributors and existing automation.
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
exec bash "$ROOT/tests/run.sh" offline
