# Run Operator E2E

Runs Konflux operator e2e tests (integration + conformance) the same way as [operator-test-e2e.yaml](../../workflows/operator-test-e2e.yaml): Kind cluster, deploy deps, deploy operator (build method), deploy test resources, run tests. Konflux CR and test scope are fixed (same as in-repo workflow).

## Inputs

| Input | Default | Description |
|-------|---------|-------------|
| `konflux-ci-ref` | `main` | Branch, tag, or SHA of konflux-ci/konflux-ci to run. Ignored when `working-directory` is set. |
| `working-directory` | (empty) | If set, use as konflux-ci repo root (no checkout). Use from konflux-ci CI with `github.workspace`. |
| `ref-overrides` | `{}` | JSON: component name → git revision (e.g. `{"release-service":"abc123"}`). Updates `?ref=` and `newTag` in that component’s kustomizations and rebuilds manifests. |
| `image-overrides` | (empty) | Multiline: one per line `released_image\|output_image` (e.g. `quay.io/konflux-ci/segment-bridge\|quay.io/org/segment-bridge:on-pr-xyz`). In kustomization files, entries that use `digest:` for the released image are replaced with `newName` + `newTag` so CI can use the PR-built image. Built manifests are also updated. |
| `runner-arch` | `amd64` | `amd64` or `arm64` for kind/kubectl. |

## Required env (secrets)

The job that uses this action must set these env vars (e.g. from secrets):

- **GitHub App / webhook:** `GITHUB_APP_ID`, `GITHUB_PRIVATE_KEY`, `WEBHOOK_SECRET`
- **Test org / token:** `GH_ORG`, `GH_TOKEN` (and `MY_GITHUB_ORG` if tests read it)
- **Quay:** `QUAY_TOKEN`, `QUAY_ORGANIZATION`
- **E2E / release catalog:** `QUAY_DOCKERCONFIGJSON`, `RELEASE_CATALOG_TA_QUAY_TOKEN`
- **Smee (e2e):** `SMEE_CHANNEL`

## Example (upstream repo)

```yaml
jobs:
  e2e:
    runs-on: ubuntu-latest
    env:
      GITHUB_APP_ID: ${{ secrets.GITHUB_APP_ID }}
      GITHUB_PRIVATE_KEY: ${{ secrets.GITHUB_PRIVATE_KEY }}
      WEBHOOK_SECRET: ${{ secrets.WEBHOOK_SECRET }}
      GH_ORG: ${{ secrets.GH_ORG }}
      GH_TOKEN: ${{ secrets.GH_TOKEN }}
      QUAY_TOKEN: ${{ secrets.QUAY_TOKEN }}
      QUAY_ORGANIZATION: ${{ secrets.QUAY_ORG }}
      QUAY_DOCKERCONFIGJSON: ${{ secrets.QUAY_DOCKERCONFIGJSON }}
      RELEASE_CATALOG_TA_QUAY_TOKEN: ${{ secrets.RELEASE_CATALOG_TA_QUAY_TOKEN }}
      SMEE_CHANNEL: ${{ secrets.SMEE_CHANNEL }}
    steps:
      - uses: konflux-ci/konflux-ci/.github/actions/run-operator-e2e@main
        with:
          konflux-ci-ref: main
          ref-overrides: '{"release-service":"${{ github.sha }}"}'
          image-overrides: |
            quay.io/konflux-ci/release-service|quay.io/my-org/release-service:on-pr-${{ github.sha }}
```

## Example (konflux-ci own CI)

```yaml
- uses: actions/checkout@v4
- uses: ./.github/actions/run-operator-e2e
  with:
    working-directory: ${{ github.workspace }}
    konflux-ci-ref: ${{ github.sha }}
```
