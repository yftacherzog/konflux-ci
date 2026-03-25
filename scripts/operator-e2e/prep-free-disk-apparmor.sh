#!/usr/bin/env bash
# Free disk space on GitHub-hosted Ubuntu runners; relax AppArmor for Kind (Ubuntu 24.04+).
# Skip parts with SKIP_FREE_DISK=1 or SKIP_APPARMOR=1 (e.g. Tekton).
set -euo pipefail

if [[ "${SKIP_FREE_DISK:-0}" != "1" ]] && command -v sudo &>/dev/null; then
  sudo rm -rf /usr/share/dotnet /usr/local/lib/android /opt/ghc /opt/hostedtoolcache/CodeQL 2>/dev/null || true
fi

if [[ "${SKIP_APPARMOR:-0}" != "1" ]] && [[ "$(uname -s)" == "Linux" ]] && command -v sudo &>/dev/null; then
  sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0
fi
