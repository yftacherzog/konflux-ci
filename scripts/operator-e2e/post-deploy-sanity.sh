#!/usr/bin/env bash
# kubectl / kind version and namespace list (sanity after deploy).
set -euo pipefail

REPO_ROOT="$(cd "${1:?usage: $0 REPO_ROOT}" && pwd)"

(
  cd "${REPO_ROOT}/operator"
  kubectl version
  kind version
)

kubectl get namespace
