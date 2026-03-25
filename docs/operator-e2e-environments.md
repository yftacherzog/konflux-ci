# Operator deployment and E2E tests across environments

This document describes how **Konflux operator deployment** and **operator E2E tests** (integration + conformance) are intended to run in three places:

- **GitHub Actions** — hosted runners (and optionally self-hosted).
- **Tekton** — Pipelines / PipelineRuns on a cluster (e.g. Konflux CI, PAC-triggered PR runs).
- **Local development** — engineer laptop (Linux/macOS).

The goal is a **single behavioral contract** implemented by **shared shell scripts** in this repository. GitHub composite actions, Tekton Tasks, and local invocations become **thin adapters**: they set environment, checkout or mount source, provide credentials, and call the same scripts.

> **Status:** GitHub composite actions (`.github/actions/operator-e2e-*`) call shared scripts under **`scripts/operator-e2e/`**. Tekton Tasks can mount the repo workspace and invoke the same scripts; a single `prep.sh` that verifies tools is still optional/future.

---

## Conceptual phases (shared across environments)

| Phase | Purpose |
|-------|---------|
| **1. Prep** | Ensure toolchain and host/cluster preconditions (GitHub: free disk, AppArmor, Go, kind/kubectl on runner; Tekton: rely on task image + remote kubeconfig; Local: same as GitHub or assume tools installed). |
| **2. Apply overrides** (optional) | `git[]` rules (`sourceRepo` + `remote` or `localPath`) and `images[]` (`apply-overrides-from-yaml.sh`). |
| **3. Deploy** | Install Kind (if applicable), build/install operator, apply Konflux CR, wait for ready (`deploy-local.sh`). |
| **4. Post-deploy sanity** | `kubectl` / `kind` version, namespace listing (optional but useful for logs). |
| **5. Test resources** | `deploy-test-resources.sh` (demo users, sample apps, etc.). |
| **6. Integration tests** | `go test` packages under `test/go-tests` (non-conformance). |
| **7. Conformance env** | Export `RELEASE_SERVICE_CATALOG_REVISION`, `CUSTOM_DOCKER_BUILD_OCI_TA_MIN_PIPELINE_BUNDLE`, and conformance-related secrets behavior (e.g. `QUAY_TOKEN` empty, use `QUAY_DOCKERCONFIGJSON`). |
| **8. Conformance tests** | `go test ./tests/conformance` (Ginkgo). |
| **9. Diagnostics & artifacts** | `kubectl get konflux`, `generate-err-logs.sh`, JUnit path; publish logs (GitHub: `upload-artifact`; Tekton: OCI push / workspace; Local: files on disk). |

Phases **2–9** are the core **shared** story. Phase **1** differs most by environment.

---

## Script layout (shared)

All paths are relative to the **konflux-ci repository root** (`KONFLUX_REPO_ROOT` or first argument to each script).

| Script | Role | Notes |
|--------|------|--------|
| **`scripts/operator-e2e/prep-free-disk-apparmor.sh`** | Prep (partial) | GitHub: free disk + AppArmor. Tekton: usually skip with `SKIP_FREE_DISK=1` / `SKIP_APPARMOR=1`. |
| **`scripts/operator-e2e/install-kind-kubectl.sh`** | Prep (partial) | Installs kind/kubectl; GitHub prep also uses `actions/setup-go`. |
| **`scripts/operator-e2e/prep.sh`** | Prep (optional future) | Single script to verify `go`/`kind`/`kubectl`/`yq`/`jq` — not required for GitHub today. |
| **`scripts/operator-e2e/apply-overrides.sh`** | Overrides (low-level) | Env: `COMPONENT_SOURCES_FILE` (JSON), optional `IMAGE_OVERRIDES`. |
| **`scripts/operator-e2e/apply-overrides-from-yaml.sh`** | Overrides from YAML | `git[]` + `images[]` per component. `OVERRIDES_YAML_PATH` or `OVERRIDES_YAML`. |
| **`scripts/deploy-local.sh`** | Deploy Kind + operator + CR | Env-driven (`KIND_CLUSTER`, `KONFLUX_CR`, `KONFLUX_READY_TIMEOUT`, …). Optional **`KONFLUX_OVERRIDES_YAML_PATH`** (in `deploy-local.env`) runs **`apply-overrides-from-yaml.sh`** before operator build/deploy (`local` / `build` / `none` only). |
| **`scripts/operator-e2e/post-deploy-sanity.sh`** | Sanity | `kubectl`/`kind` version + `kubectl get ns`. |
| **`scripts/operator-e2e/run-deploy-test-resources.sh`** | Test fixtures | Wraps `./deploy-test-resources.sh`. |
| **`deploy-test-resources.sh`** | Test fixtures | *Existing* at repo root; called by wrapper above. |
| **`scripts/operator-e2e/run-integration-tests.sh`** | Integration `go test` | |
| **`scripts/operator-e2e/prepare-conformance-env.sh`** | Conformance env | `GITHUB_ENV` or printed `export` lines. |
| **`scripts/operator-e2e/run-conformance-tests.sh`** | Conformance `go test` | Ginkgo + JUnit path argument. |
| **`scripts/operator-e2e/collect-diagnostics.sh`** | Diagnostics | Konflux CR + `generate-err-logs.sh`. |
| **`scripts/operator-e2e/collect-junit-to-logs.sh`** | JUnit → `logs/junit/` | For artifacts. |
| **`scripts/operator-e2e/run-all.sh`** | Local orchestrator | Optional `OVERRIDES_YAML`; not used by GitHub (actions stay granular). |

See **`scripts/operator-e2e/README.md`** for env details.

---

## Environment-specific structure

### GitHub Actions

| Artifact | Role |
|----------|------|
| **Workflows** (e.g. `operator-test-e2e.yaml`, `operator-e2e-action-test.yaml`) | Job matrix, secrets → `env`, checkout ref, optional free-disk action. |
| **Composite actions** (`operator-e2e-prep`, `operator-e2e-deploy`, `operator-e2e-tests`, `operator-e2e-logs`, meta `run-operator-e2e`) | **One step per action** in the workflow for log readability; each action runs `bash "$KONFLUX_ROOT/scripts/operator-e2e/<script>.sh"` (absolute path via `inputs.konflux-repo-root`). |
| **Runner** | Kind runs **on the runner**; `KUBECONFIG` default location. No kubeconfig Secret. |
| **`KIND_LOAD_IMAGES`** (`deploy-local.env`) | Optional space/comma-separated images to `kind load` after cluster creation (local Docker/Podman only). |

**Specific handling**

- Map **repository secrets** to **environment variables** (same names as `test/e2e/e2e.env.template` where possible).
- **`upload-artifact`** for logs/JUnit (no OCI required).
- **`actions/setup-go`**, **`actions/checkout`** — GitHub-only; prep script may assume `go` already on PATH after setup-go step.

---

### Tekton (Konflux CI / PAC)

| Artifact | Role |
|----------|------|
| **Pipeline** (e.g. under `.tekton/`, alongside `build-pipeline.yaml`) | Declares params, workspaces, and **Task** sequence: provision cluster (optional, often external catalog task) → clone/fetch source → deploy → e2e → logs → cleanup. |
| **PipelineRun** (e.g. pattern of `konflux-operator-pull-request.yaml`) | PAC annotations, `pipelineRef`, params (`revision`, image tags, cluster secret name, OCI log ref, …). |
| **Tasks hosted in this repo** | Local `Task` YAML pointing at **images** that include `bash`, `go`, `kubectl`, `git`, `yq`, `jq` (reuse or extend patterns from `tekton-integration-catalog/utils`). Steps invoke **`scripts/operator-e2e/*.sh`** from a **workspace** mounted with the konflux-ci source. |

**Specific handling**

- **`KUBECONFIG`**: mounted from a **Secret** (kubeconfig for target cluster — often Kind-on-AWS or shared test cluster). Deploy and tests run **against that API**, not in-cluster Kind inside the step container (unless you explicitly design that).
- **Credentials**: map **Kubernetes Secrets** (keys as files or env) to the same variable names the scripts expect (`GITHUB_APP_ID`, `QUAY_DOCKERCONFIGJSON`, …).
- **Logs / JUnit**: use **OCI push** (e.g. `secure-push-oci` / catalog patterns) or workspace results — not `upload-artifact`.
- **Prep**: usually **omit** or no-op in script; cluster provisioning is a **separate Task** (`kind-aws-provision` from integration-catalog, etc.).
- **Overrides**: pass YAML as **param** or **ConfigMap**; write to file before `apply-overrides.sh`.

---

### Local development

| Artifact | Role |
|----------|------|
| **`test/e2e/e2e.env` / `e2e.env.template`** | Export secrets and options (documented today). |
| **`scripts/deploy-local.env`** | Same pattern for **`deploy-local.sh`**; optional **`KONFLUX_OVERRIDES_YAML_PATH`** mirrors E2E overrides without a separate manual step. |
| **Shell** | `source test/e2e/e2e.env` then `scripts/operator-e2e/run-all.sh` or individual phase scripts. |

**Specific handling**

- Developer installs **kind**, **kubectl**, **go**, **yq**, **jq**, **kustomize** when using overrides (or prep script checks and errors with install hints).
- **macOS**: `deploy-local.sh` already handles some platform differences.
- **Smee / Quay / GitHub App**: same env vars as CI; no Secret indirection.

---

## Shared vs environment-specific (summary)

| Concern | Shared (scripts / repo) | GitHub-specific | Tekton-specific | Local-specific |
|--------|-------------------------|-----------------|-----------------|----------------|
| Clone / source tree | Repo content | `actions/checkout` | **Workspace** + git-clone task / PAC | `git clone` / existing tree |
| Toolchain bootstrap | `prep-free-disk-apparmor.sh`, `install-kind-kubectl.sh` (optional `prep.sh` later) | `setup-go` + those scripts | **Container image** choice | OS packages / Homebrew |
| Cluster creation | `deploy-local.sh` (Kind) | On runner | **Separate provision Task** + kubeconfig Secret | Same as GitHub |
| Deploy + wait | `deploy-local.sh` | Env from secrets | Env from mounted secrets | `e2e.env` |
| Overrides | `apply-overrides.sh` | `inputs.overrides` → file | Param / ConfigMap → file | File or env; **`deploy-local.env`**: `KONFLUX_OVERRIDES_YAML_PATH` |
| Go tests | `run-integration-tests.sh`, `run-conformance-tests.sh` | Same | Same | Same |
| Diagnostics | `collect-diagnostics.sh` | Same | Same | Same |
| **Publish results** | JUnit path on disk | `upload-artifact` | **OCI / results** step | Open files locally |

---

## Relationship to `.tekton/` in this repo

- **`build-pipeline.yaml` / `konflux-operator-pull-request.yaml`** — Build and push the **operator image**; separate concern from **full cluster E2E**.
- **Future additions (planned)**  
  - **Pipeline** definition for operator deploy + E2E (new file, e.g. `operator-e2e-pipeline.yaml`).  
  - **PipelineRun** template for PR triggers (new file, analogous to `konflux-operator-pull-request.yaml` but `pipelines.appstudio.openshift.io/type` or annotations appropriate for testing).  
  - **Task** manifests colocated under `.tekton/` (or `tasks/operator-e2e/`) that reference the **same scripts** as GitHub.

Keeping Pipeline YAML in **this** repo tracks **how Konflux CI should run** the same flows as GitHub, while **tekton-integration-catalog** can continue to host generic tasks (e.g. `kind-aws-provision`) that this pipeline **references** by bundle resolver or git resolver.

---

## Migration notes (for contributors)

1. **Prefer** changing behavior in `scripts/operator-e2e/*.sh` rather than duplicating logic in composite actions.  
2. **Tekton Tasks** should invoke the same script paths from a mounted workspace.  
3. **Env vars** are documented in `scripts/operator-e2e/README.md` and `test/e2e/e2e.env.template`.

This keeps **one place** to fix behavior (scripts) and three thin integration layers (GitHub, Tekton, local).
