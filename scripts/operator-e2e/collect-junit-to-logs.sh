#!/usr/bin/env bash
# Copy JUnit XML into logs/junit/ under repo root for archival.
set -euo pipefail

REPO_ROOT="$(cd "${1:?usage: $0 REPO_ROOT JUNIT_SRC}" && pwd)"
JUNIT_SRC="${2:-${JUNIT_REPORT_PATH:-${GITHUB_WORKSPACE:-}/junit-conformance.xml}}"

mkdir -p "${REPO_ROOT}/logs/junit"
if [[ -f "$JUNIT_SRC" ]]; then
  cp "$JUNIT_SRC" "${REPO_ROOT}/logs/junit/"
fi
