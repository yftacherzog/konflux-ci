# Component monitoring

How Konflux operator deploys Prometheus metrics scraping for controller components
(build-service, integration-service, and others).

For auth options, Kind/OCP validation notes, and operator self-metrics work, see
[monitoring-authentication.md](./monitoring-authentication.md).

## Repo layout

Each component that exposes controller metrics follows this split:

```
operator/upstream-kustomizations/<component>/
├── kustomization.yaml      # includes core + monitoring (+ certmanager where needed)
├── core/                   # operand: Deployment, Service, RBAC, webhooks, …
│   └── …                   # patches that *remove* upstream ServiceMonitor + scrape SA/Secret
└── monitoring/             # operator-owned scrape contract (ServiceMonitor + metrics-reader RBAC)
    └── kustomization.yaml
```

Built manifests land in `operator/pkg/manifests/<component>/manifests.yaml` via
`operator/pkg/manifests/process-component.sh`.

**Rule:** upstream remote kustomizations may ship monitoring scaffolding; `core/` strips
those so they are not duplicated. `monitoring/` is the single source of truth for what
the operator reconciles.

## Target architecture (unified)

Aligns with [kubebuilder v4 metrics](https://book.kubebuilder.io/reference/metrics) and
the Konflux operator’s own metrics server.

| Piece | Target |
|-------|--------|
| Metrics server | HTTPS `:8443`, controller-runtime `WithAuthenticationAndAuthorization` (no kube-rbac-proxy) |
| Server TLS | cert-manager `Certificate` → `metrics-server-cert` (or OpenShift serving CA) |
| ServiceMonitor | `scheme: https`, `port: https`, `bearerTokenFile` (Prometheus pod token) |
| TLS verify | `tlsConfig.ca` + `serverName` — **not** `insecureSkipVerify: true` |
| Authorization | `<component>-metrics-reader` ClusterRole bound to the **Prometheus scraper SA** (e.g. `prometheus-k8s` on OpenShift UWM) |
| Scrape credentials | **No** long-lived `kubernetes.io/service-account-token` Secrets |

Reference implementation: `operator/config/prometheus/monitor.yaml` + cert-manager patches
under `operator/config/default/operator-rbac/`.

## Interim solution (shipped today)

Legacy infra-deployments parity while upstream controllers are still migrating.

| Piece | Interim |
|-------|---------|
| Metrics server | build-service / image-controller: HTTPS `:8443` with auth filters. integration-service / release-service: HTTP `:8080` (no auth on metrics yet). |
| Server TLS | Self-signed or dev certs; ServiceMonitor uses `insecureSkipVerify: true` where HTTPS is used |
| ServiceMonitor | In `monitoring/`; `bearerTokenSecret` → dedicated scrape Secret |
| Authorization | `<component>-metrics-reader` ClusterRole bound to a dedicated **`metrics-reader` ServiceAccount** in the component namespace |
| Scrape credentials | Legacy SA token Secret (`type: kubernetes.io/service-account-token`) |

Example (build-service): `operator/upstream-kustomizations/build-service/monitoring/`.

Example (integration-service, HTTP): ServiceMonitor uses `scheme: http`, `port: http`.

**Why interim:** Prometheus can scrape now without waiting for every upstream controller
to enable `--metrics-secure`, cert-manager metrics certs, and verified TLS. Behavior
matches what infra-deployments used for years.

## Migrate a component: interim → unified

Do these in order. Skip steps that already apply to the component.

### 1. Upstream controller (service repository)

- [ ] Bind metrics on `:8443` with `--metrics-secure=true`
- [ ] Remove kube-rbac-proxy sidecar if present
- [ ] Keep `metrics_auth_role*` and `metrics_reader_role` in upstream RBAC
- [ ] Stop shipping upstream ServiceMonitor, scrape SA, and static token Secret in `config/default`

**Check:** `kubectl create token …` + `curl -k -H "Authorization: Bearer …" https://…:8443/metrics` → 200; no token → 401.

### 2. Operator `core/` + cert-manager

- [ ] Add or extend `certmanager/` with a metrics `Certificate` (secret `metrics-server-cert`)
- [ ] Patch Deployment: mount cert volume, `--metrics-cert-path=…`
- [ ] Add kustomize `replacements` for ServiceMonitor `serverName` (see operator deploy kustomization)
- [ ] Keep `core/` patches that delete upstream monitoring resources

### 3. Operator `monitoring/` overlay

**Remove:**

- [ ] `v1_secret_*-metrics-reader.yaml`
- [ ] `v1_serviceaccount_*-metrics-reader.yaml`

**Keep:**

- [ ] `<component>-metrics-reader` ClusterRole

**Change ServiceMonitor:**

- [ ] `bearerTokenSecret` → `bearerTokenFile: /var/run/secrets/kubernetes.io/serviceaccount/token`
- [ ] `scheme: https`, `port: https`
- [ ] Replace `insecureSkipVerify: true` with `tlsConfig.ca` from `metrics-server-cert` and correct `serverName`

**Change ClusterRoleBinding:**

- [ ] Subject: Prometheus scraper SA (e.g. `prometheus-k8s` in `appstudio-workload-monitoring` on OCP; `prometheus` in `monitoring` on Kind CI) — **not** the component’s `metrics-reader` SA

### 4. Operator controller RBAC

- [ ] Ensure kubebuilder markers allow binding `<component>-metrics-reader` and the scraper CRB
- [ ] Run `make manifests` in `operator/`

### 5. Rebuild and verify

```bash
cd operator/pkg/manifests
bash process-component.sh <component> /path/to/konflux-ci
```

- [ ] Prometheus target **up** with verified TLS
- [ ] Legacy scrape Secret gone from the namespace
- [ ] Grafana / UWM dashboards still resolve metrics

## Component status (manual — update when migrating)

| Component | Interim | Blocker for unified |
|-----------|---------|---------------------|
| build-service | Shipped | Add cert-manager metrics cert; switch SM + CRB subject |
| integration-service | Shipped (HTTP SM) | Upstream `--metrics-secure`; then same as build-service |
| image-controller | Overlay not wired | Wire `monitoring/` + migration |
| release-service | Overlay not wired | Upstream HTTP `:8080` + wire `monitoring/` |

## Related paths

| Topic | Location |
|-------|----------|
| Detailed auth comparison & Kind/OCP phases | [monitoring-authentication.md](./monitoring-authentication.md) |
| Operator self-metrics (reference) | `operator/config/prometheus/` |
| Embedded manifests | `operator/pkg/manifests/<component>/manifests.yaml` |
| Legacy infra reference | `infra-deployments/components/<component>/base/monitoring.yaml` |
| Cluster integration tests | `test/go-tests/metricsintegration/` + `test/fixtures/metrics-targets.yaml` (via `scripts/operator-e2e/run-metrics-integration-tests.sh`, hooked in `test/e2e/run-e2e.sh`) |
