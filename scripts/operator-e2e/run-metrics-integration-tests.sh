#!/usr/bin/env bash
# Run cluster metrics integration tests (Prometheus-style HTTPS scrape).
#
# Usage: run-metrics-integration-tests.sh [REPO_ROOT]
set -euo pipefail

REPO_ROOT="$(cd "${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}" && pwd)"

cd "${REPO_ROOT}/test/go-tests"
export KONFLUX_REPO_ROOT="${REPO_ROOT}"
echo "Running metrics integration tests..."
go test -mod=mod ./metricsintegration -v -timeout 15m -ginkgo.label-filter=metrics "$@"
