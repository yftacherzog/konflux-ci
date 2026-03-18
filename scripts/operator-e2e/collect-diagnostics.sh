#!/usr/bin/env bash
# Dump Konflux CR and run generate-err-logs.sh (best-effort).
set -euo pipefail

REPO_ROOT="$(cd "${1:?usage: $0 REPO_ROOT}" && pwd)"
cd "$REPO_ROOT"

echo "Konflux CR:"
kubectl get konflux konflux -o yaml || true
./generate-err-logs.sh || true
