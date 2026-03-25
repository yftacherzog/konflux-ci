# Operator E2E helper scripts

Shared entry points for **operator deploy + integration + conformance** tests. GitHub composite actions under `.github/actions/operator-e2e-*` call these scripts; Tekton Tasks and local runs can use the same paths.

All scripts take the **konflux-ci repository root** as the first argument unless noted (absolute or relative path is fine).

## Scripts

| Script | Purpose |
|--------|---------|
| `prep-free-disk-apparmor.sh` | Free disk on GitHub Ubuntu runners; relax AppArmor for Kind. Skip with `SKIP_FREE_DISK=1` / `SKIP_APPARMOR=1`. |
| `install-kind-kubectl.sh` | Install `kind` and `kubectl` to `/usr/local/bin` (needs `sudo`). Env: `KIND_VERSION`, `KUBECTL_VERSION`, `ARCH`. |
| `apply-overrides.sh` | Low-level: **`COMPONENT_SOURCES_FILE`** (`name` + `git[]` rules only) and optional **`IMAGE_OVERRIDES`**. Requires `yq`, `jq`, `kustomize`. |
| `apply-overrides-from-yaml.sh` | Read override YAML → `.tmp/component-sources.json` → `apply-overrides.sh`. Optional `KONFLUX_READY_TIMEOUT` for log message. |
| `post-deploy-sanity.sh` | `kubectl`/`kind` version and `kubectl get namespace`. |
| `run-deploy-test-resources.sh` | Runs `./deploy-test-resources.sh` from repo root. Honors `SKIP_SAMPLE_COMPONENTS` (default `true` in script). |
| `run-integration-tests.sh` | `go test . ./pkg/...` under `test/go-tests`. |
| `prepare-conformance-env.sh` | Sets `RELEASE_SERVICE_CATALOG_REVISION` and `CUSTOM_DOCKER_BUILD_OCI_TA_MIN_PIPELINE_BUNDLE`. With `GITHUB_ENV` set, appends to it; otherwise prints `export` lines for `eval`/`source`. |
| `run-conformance-tests.sh` | Conformance Ginkgo tests. Requires `GH_ORG`, `GH_TOKEN`, `QUAY_DOCKERCONFIGJSON`, `RELEASE_CATALOG_TA_QUAY_TOKEN`. Args: `REPO_ROOT` `[JUNIT_REPORT_PATH]`. Optional: `RELEASE_TA_OCI_STORAGE`, `E2E_APPLICATIONS_NAMESPACE`. |
| `collect-diagnostics.sh` | `kubectl get konflux konflux -o yaml` and `./generate-err-logs.sh` (best-effort). |
| `collect-junit-to-logs.sh` | Copy JUnit XML into `logs/junit/`. Args: `REPO_ROOT` `JUNIT_SRC`. |
| `run-all.sh` | Local orchestrator: optional `OVERRIDES_YAML_PATH` or `OVERRIDES_YAML`, then `deploy-local.sh`, sanity, test resources, integration, conformance env + tests, diagnostics. Assumes tools and cluster env already configured. |

**Override YAML** (each item): **`name`**, **`git`** (array of rules; can be `[]` if only images), **`images`** (array of `{ orig, replacement }`; can be `[]` if only git). At least one of `git` or `images` must be non-empty per item.

Each **git** rule: **`sourceRepo`** (`org/repo` or `https://github.com/org/repo`) plus **`remote: { repo, ref }`** *or* **`localPath`** (clone root). First matching `sourceRepo` per URL wins. **`remote.ref`**: branch, tag, or SHA.

## Env contract (deploy / tests)

Align with `test/e2e/e2e.env.template` where possible:

- **Deploy (`deploy-local.sh`)**: `GITHUB_APP_ID`, `GITHUB_PRIVATE_KEY`, `WEBHOOK_SECRET`, `QUAY_TOKEN`, `QUAY_ORGANIZATION`, `SMEE_CHANNEL`, optional `KIND_CLUSTER`, `KONFLUX_CR`, `KONFLUX_READY_TIMEOUT`, `OPERATOR_INSTALL_METHOD`, …
- **Conformance**: `GH_ORG`, `GH_TOKEN`, `QUAY_DOCKERCONFIGJSON`, `RELEASE_CATALOG_TA_QUAY_TOKEN`; `QUAY_TOKEN` should be empty for the conformance step (the script clears it).

## `_lib.sh`

Optional helpers for other scripts (`operator_e2e_repo_root`, etc.). Source from bash if extending.
