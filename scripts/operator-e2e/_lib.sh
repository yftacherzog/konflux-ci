#!/usr/bin/env bash
# Shared helpers for operator-e2e scripts. Source with: source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
set -euo pipefail

operator_e2e_script_dir() {
  cd "$(dirname "${BASH_SOURCE[0]}")" && pwd
}

# Default konflux-ci repo root: $1 if set, else $KONFLUX_REPO_ROOT, else error.
operator_e2e_repo_root() {
  if [[ -n "${1:-}" ]]; then
    cd "$1" && pwd
    return
  fi
  if [[ -n "${KONFLUX_REPO_ROOT:-}" ]]; then
    cd "$KONFLUX_REPO_ROOT" && pwd
    return
  fi
  echo "error: pass repo root as first argument or set KONFLUX_REPO_ROOT" >&2
  exit 1
}
