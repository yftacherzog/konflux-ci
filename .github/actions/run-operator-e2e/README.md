# Run Operator E2E

Runs Konflux operator e2e tests (integration + conformance) the same way as [operator-test-e2e.yaml](../../workflows/operator-test-e2e.yaml): Kind cluster, deploy deps, deploy operator (build method), deploy test resources, run tests. Konflux CR and test scope are fixed (same as in-repo workflow).

This action is a **thin wrapper** around four smaller composite actions (prep → deploy → tests → logs). For **clearer GitHub log grouping** (separate top-level steps), call those actions from your workflow instead—see [operator-e2e-action-test.yaml](../../workflows/operator-e2e-action-test.yaml).

| Action | Purpose |
|--------|---------|
| [operator-e2e-prep](../operator-e2e-prep/action.yml) | Free disk, AppArmor workaround, Go, kind + kubectl |
| [operator-e2e-deploy](../operator-e2e-deploy/action.yml) | Optional overrides, `deploy-local.sh`, restore manifests, `kubectl`/`kind` sanity |
| [operator-e2e-tests](../operator-e2e-tests/action.yml) | Test resources, integration tests, conformance env + Ginkgo e2e |
| [operator-e2e-logs](../operator-e2e-logs/action.yml) | Konflux dump, `generate-err-logs.sh`, optional JUnit collect + artifact |

## Inputs

| Input | Default | Description |
|-------|---------|-------------|
| `konflux-ci-ref` | `main` | Branch, tag, or SHA of konflux-ci/konflux-ci to run. Ignored when `working-directory` is set. |
| `working-directory` | (empty) | If set, use as konflux-ci repo root (no checkout). Use from konflux-ci CI with `github.workspace`. |
| `overrides` | (empty) | YAML list of component overrides; update runs for each entry. Each item: `name`, `ref` (git SHA), `image.orig` (released image), `image.replacement` (e.g. PR-built image). |
| `runner-arch` | `amd64` | `amd64` or `arm64` for kind/kubectl. |
| `konflux-ready-timeout` | `15m` | Max time to wait for Konflux CR to become Ready. Use a longer value (e.g. `30m`) when using overrides so image build+push can finish before the wait step. |

## Required env (secrets)

The job that uses this action must set these env vars (e.g. from secrets). Mapping matches [operator-test-e2e.yaml](../../workflows/operator-test-e2e.yaml):

- **GitHub App / webhook:** `GITHUB_APP_ID`, `GITHUB_PRIVATE_KEY`, `WEBHOOK_SECRET`
- **Test org / token:** `GH_ORG`, `GH_TOKEN` (and `MY_GITHUB_ORG` if tests read it)
- **Deploy (image-controller):** `QUAY_TOKEN` (OAuth token), `QUAY_ORGANIZATION` (e.g. from `QUAY_ORG` secret)
- **E2E conformance (quay-repository secret):** `QUAY_DOCKERCONFIGJSON` (raw Docker config JSON)
- **Release catalog:** `RELEASE_CATALOG_TA_QUAY_TOKEN` (token must have push access to the trusted-artifacts repo)
- **Smee (e2e):** `SMEE_CHANNEL`

**Optional:** `RELEASE_TA_OCI_STORAGE` — OCI repository for release trusted artifacts (e.g. `quay.io/myorg/my-trusted-artifacts`). When set, the release pipeline pushes to this repo instead of the catalog default (`quay.io/konflux-ci/release-service-trusted-artifacts`). Ensure `RELEASE_CATALOG_TA_QUAY_TOKEN` has push access to this repository.

## Upstream image builds (Tekton) and waiting for images

When this action is used from an **upstream repo** (e.g. segment-bridge), the overridden images are often built by a **Tekton pipeline** on the same PR, not by a GitHub Actions workflow. The image tag is predictable (e.g. commit SHA), but the action may start before the image is pushed.

**Chosen approach (Option 2):** Deploy immediately with overrides; do **not** poll for images beforehand. Let Kubernetes perform image pulls and retries (ImagePullBackOff), and rely on the “wait for Konflux CR ready” step to eventually succeed once images are available. Use the `konflux-ready-timeout` input to allow more time when images are built in a parallel job (e.g. Tekton).

**Trade-off:** If an overridden image never appears or is very late, the run fails with a generic “Konflux not ready” (or timeout) and you must inspect pod events (e.g. ImagePullBackOff) to see that the image was missing. For clearer “image not ready” failures, The action prints each replaced image and notes that they must exist within the configured timeout.


## Embedding the PR branch revision in overrides

When running from an upstream repo (e.g. segment-bridge), the **git ref** and **image tags** in overrides should match what your build pipeline produces. Use the same revision in both so the operator pulls the image built from that commit.

| Context | Use for `remote.ref` | Use for image tag |
|--------|----------------|--------------------|
| **PR head commit** | `github.sha` (full SHA) | `on-pr-${{ github.sha }}` or `pr-${{ github.sha }}` |
| **Branch** | Branch name (e.g. `main`) in `remote.ref` | Only if your build tags match that branch workflow |
| **Fork** | Set `remote.repo` to `https://github.com/you/segment-bridge` (or `you/segment-bridge`); keep `sourceRepo` as the upstream `org/repo` from kustomize | Same as build output |

**Suggested pattern:** Use `github.sha` for `remote.ref` and the image tag. `sourceRepo` names the GitHub `org/repo` segment in the existing kustomize URL (what you are replacing).

```yaml
overrides: |
  - name: segment-bridge
    git:
      - sourceRepo: konflux-ci/segment-bridge
        remote:
          repo: https://github.com/konflux-ci/segment-bridge
          ref: ${{ github.sha }}
    images:
      - orig: quay.io/konflux-ci/segment-bridge
        replacement: quay.io/my-org/segment-bridge:${{ github.sha }}
```

If the build uses a different tag scheme (e.g. `on-pr-${SHORT_SHA}`), set `replacement` to that exact tag and use the same revision for `remote.ref` as the one the build used.

## Example (segment-bridge PR)

When running e2e from [konflux-ci/segment-bridge](https://github.com/konflux-ci/segment-bridge) on a PR, use `github.sha` (the PR head commit) for both the git `ref` and the image tag so they match the image built by your pipeline (e.g. Tekton pushing `on-pr-<sha>`):

```yaml
- uses: konflux-ci/konflux-ci/.github/actions/run-operator-e2e@main
  with:
    konflux-ci-ref: main
    konflux-ready-timeout: 30m
    overrides: |
      - name: segment-bridge
        git:
          - sourceRepo: konflux-ci/segment-bridge
            remote:
              repo: https://github.com/konflux-ci/segment-bridge
              ref: ${{ github.sha }}
        images:
          - orig: quay.io/konflux-ci/segment-bridge
            replacement: quay.io/redhat-user-workloads/konflux-vanguard-tenant/segment-bridge/segment-bridge:on-pr-${{ github.sha }}
```

On PR head commit `8bdc1aa1c15711a64d1a0f77d5b88f6655531410`, this uses `remote.ref` `8bdc1aa...` and image tag `on-pr-8bdc1aa1c15711a64d1a0f77d5b88f6655531410`, matching the built image.

## Example (upstream repo)

```yaml
- uses: konflux-ci/konflux-ci/.github/actions/run-operator-e2e@main
  with:
    konflux-ci-ref: main
    konflux-ready-timeout: 30m   # allow time for Tekton to build and push images
    overrides: |
      - name: segment-bridge
        git:
          - sourceRepo: konflux-ci/segment-bridge
            remote:
              repo: https://github.com/konflux-ci/segment-bridge
              ref: ${{ github.sha }}
        images:
          - orig: quay.io/konflux-ci/segment-bridge
            replacement: quay.io/my-org/segment-bridge:${{ github.sha }}
      - name: release
        git:
          - sourceRepo: konflux-ci/release-service
            remote:
              repo: https://github.com/konflux-ci/release-service
              ref: ${{ github.sha }}
        images:
          - orig: quay.io/konflux-ci/release-service
            replacement: quay.io/my-org/release-service:${{ github.sha }}
```

## Example (konflux-ci own CI)

```yaml
- uses: actions/checkout@v4
- uses: ./.github/actions/run-operator-e2e
  with:
    working-directory: ${{ github.workspace }}
    konflux-ci-ref: ${{ github.sha }}
```
