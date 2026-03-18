#!/usr/bin/env bash
# Run full operator e2e flow locally (after sourcing test/e2e/e2e.env or equivalent).
# Does not run prep-free-disk-apparmor or install-kind-kubectl (assume tools installed).
# Usage: run-all.sh REPO_ROOT [JUNIT_REPORT_PATH]
# Env: same as deploy-local.sh + conformance; OVERRIDES_YAML_PATH or OVERRIDES_YAML optional.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${1:?usage: $0 REPO_ROOT [junit-path]}" && pwd)"
JUNIT="${2:-${JUNIT_REPORT_PATH:-$REPO_ROOT/junit-conformance.xml}}"

if [[ -n "${OVERRIDES_YAML_PATH:-}" ]] || [[ -n "${OVERRIDES_YAML:-}" ]]; then
  bash "${SCRIPT_DIR}/apply-overrides-from-yaml.sh" "$REPO_ROOT"
fi

cd "$REPO_ROOT"
./scripts/deploy-local.sh
bash "${SCRIPT_DIR}/post-deploy-sanity.sh" "$REPO_ROOT" || true

export SKIP_SAMPLE_COMPONENTS="${SKIP_SAMPLE_COMPONENTS:-true}"
bash "${SCRIPT_DIR}/run-deploy-test-resources.sh" "$REPO_ROOT"
bash "${SCRIPT_DIR}/run-integration-tests.sh" "$REPO_ROOT"

eval "$(bash "${SCRIPT_DIR}/prepare-conformance-env.sh" "$REPO_ROOT")"
bash "${SCRIPT_DIR}/run-conformance-tests.sh" "$REPO_ROOT" "$JUNIT"

bash "${SCRIPT_DIR}/collect-diagnostics.sh" "$REPO_ROOT" || true
bash "${SCRIPT_DIR}/collect-junit-to-logs.sh" "$REPO_ROOT" "$JUNIT" || true
