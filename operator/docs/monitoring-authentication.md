# Monitoring authentication options

> **Operational guide:** For component monitoring layout (target vs interim, migration
> checklist), see [component-monitoring.md](./component-monitoring.md).

Design comparison for enabling Prometheus metrics collection via the Konflux
operator. This document covers approaches that **do not use long-lived
credentials** (legacy `kubernetes.io/service-account-token` secrets).

## Background

### What infra-deployments does today

Legacy Konflux overlays authenticate metric scrapes with:

1. **kube-rbac-proxy** — a sidecar in front of the controller's `/metrics`
   endpoint. It terminates HTTPS and validates a bearer token via
   TokenReview / SubjectAccessReview against a `*-metrics-reader` ClusterRole.
2. **A static scrape token** — a Secret of type
   `kubernetes.io/service-account-token`, referenced from the ServiceMonitor
   as `bearerTokenSecret` (or `authorization.credentials`).

That pattern provides RBAC-protected metrics, but the scrape credential never
rotates. Kubernetes has discouraged this secret type since 1.24, and Konflux is
moving away from it elsewhere (for example, short-lived bound ServiceAccount
tokens for Dex in [konflux-ci#6962](https://github.com/konflux-ci/konflux-ci/pull/6962)).

### What the operator has today

- `config/prometheus/monitor.yaml` is unused kubebuilder scaffold and was never
  deployed. It already follows the **v4+ model** (no kube-rbac-proxy):
  `bearerTokenFile` + HTTPS on port `8443`, with `insecureSkipVerify: true`
  until cert-manager integration is enabled.
- The operator binary itself already follows the **current kubebuilder model**:
  controller-runtime `filters.WithAuthenticationAndAuthorization` on an HTTPS
  metrics server (`--metrics-secure`, cert-manager optional). No
  kube-rbac-proxy sidecar.
- `operator/upstream-kustomizations/*/monitoring/` still copies the legacy
  infra-deployments pattern (static `metrics-reader` secrets). Those
  directories are not wired into reconciliation yet.

### Constraints for the new solution

- **No long-lived scrape tokens.**
- **No kube-rbac-proxy** — align with current kubebuilder / controller-runtime
  and prior team guidance to drop the sidecar.
- **Parity with legacy monitoring** — ServiceMonitors picked up by OpenShift
  user-workload Prometheus (UWM), Grafana dashboards continue to work.
- **Operator-managed** — auth resources created and owned by the operator
  when monitoring is enabled on a component.

### Kubebuilder guidance (does it mean mTLS?)

The [Kubebuilder metrics documentation](https://book.kubebuilder.io/reference/metrics#recommended-enabling-certificates-for-production-disabled-by-default)
does **not** drive towards mTLS as the authentication model. It describes two
**separate layers**:

| Layer | Kubebuilder mechanism | Purpose |
|-------|----------------------|---------|
| **Transport** | cert-manager `Certificate` for the metrics server (replaces dev self-signed certs) | Encrypt traffic; Prometheus verifies the **server** via `tlsConfig.ca` + `serverName` |
| **Application** | `filters.WithAuthenticationAndAuthorization` + `bearerTokenFile` on the ServiceMonitor | Authenticate the scraper via Kubernetes TokenReview; authorize via RBAC (`metrics-reader` ClusterRole) |

Kubebuilder is explicit: *"You use those certificates to secure the transport
layer (TLS). The token authentication using authn/authz … serves as the
application-level credential."*

That matches **option 1** in this document (bearer token + verified server
TLS), not **option 2** (mTLS). The scaffolded `monitor_tls_patch.yaml`
references `cert` / `keySecret` from the same `metrics-server-cert` secret
as the server CA — Prometheus may present those fields, but controller-runtime
does **not** require or verify client certificates by default. They are not a
substitute for bearer-token auth in the kubebuilder model.

Other relevant kubebuilder points:

- **kube-rbac-proxy is deprecated** — projects on v4.1.0+ should use
  controller-runtime auth filters instead ([discussion](https://github.com/kubernetes-sigs/kubebuilder/discussions/3907)).
- **NetworkPolicy** is an optional extra layer; kubebuilder notes it does not
  handle authn/authz.
- **ClusterRoleBinding is manual** — kubebuilder scaffolds `metrics-reader`
  but intentionally does not bind it to a scraper SA; the operator must create
  that binding for `prometheus-k8s` (or equivalent).

---

## Options

All options below avoid legacy SA-token secrets. They differ in *how* the
scrape is authenticated and what rotates automatically.

### 1. Kubernetes RBAC bearer token + server TLS (kubebuilder default)

This is the model described in the
[Kubebuilder metrics guide](https://book.kubebuilder.io/reference/metrics):
cert-manager (or OpenShift serving CA) for **transport**, projected SA token
for **application auth**.

**How it works**

| Layer | Mechanism |
|-------|-----------|
| Metrics server | Controller serves HTTPS on `:8443` with `filters.WithAuthenticationAndAuthorization` (built into controller-runtime, replaces kube-rbac-proxy). |
| Server TLS | cert-manager `Certificate` ([recommended for production](https://book.kubebuilder.io/reference/metrics#recommended-enabling-certificates-for-production-disabled-by-default)) or OpenShift service serving certificate. |
| Scrape auth | Prometheus presents its **own** projected ServiceAccount token via `bearerTokenFile: /var/run/secrets/kubernetes.io/serviceaccount/token`. The kubelet rotates this token automatically. |
| Authorization | `ClusterRole` `*-metrics-reader` (`nonResourceURLs: [/metrics], verbs: [get]`) bound to the **Prometheus scraper** ServiceAccount (e.g. `prometheus-k8s` in UWM). |

**ServiceMonitor sketch**

```yaml
spec:
  endpoints:
  - path: /metrics
    port: https
    scheme: https
    bearerTokenFile: /var/run/secrets/kubernetes.io/serviceaccount/token
    tlsConfig:
      ca:
        secret:
          name: <server-ca-secret>
          key: ca.crt
      serverName: <service>.<namespace>.svc
```

**Pros**

- Native kubebuilder / controller-runtime path; operator `main.go` already uses it.
- Scrape credential rotates without operator intervention.
- Well-understood on OpenShift UWM (same model as platform federation ServiceMonitors in infra-deployments).
- Minimal new infrastructure — RBAC + ServiceMonitor + server TLS certs.

**Cons**

- Still bearer-token based (short-lived, but a token nonetheless).
- Each controller must expose metrics with controller-runtime auth filters (upstream services on `:8080` HTTP need migration).
- Server TLS must be managed (cert-manager or OpenShift serving CA).

---

### 2. Mutual TLS (mTLS)

**Not the kubebuilder default.** Kubebuilder uses certs for server TLS and
keeps bearer-token RBAC as the application credential. mTLS would **replace**
that application layer with client-certificate identity.

**How it works**

| Layer | Mechanism |
|-------|-----------|
| Metrics server | HTTPS with **client certificate required** (`tls.RequireAndVerifyClientCert`). Only holders of an approved client cert can connect. |
| Server TLS | cert-manager or OpenShift serving certificate. |
| Scrape auth | Prometheus presents a **client certificate** via ServiceMonitor `tlsConfig.cert` / `tlsConfig.keySecret`, issued by cert-manager to a dedicated scrape identity (ServiceAccount or per-cluster CA). |
| Authorization | Identity is the client cert's CN/URI/SAN — no bearer token, no Kubernetes RBAC check at scrape time (unless combined with option 1). |

**ServiceMonitor sketch**

```yaml
spec:
  endpoints:
  - path: /metrics
    port: https
    scheme: https
    tlsConfig:
      ca:
        secret: { name: metrics-server-ca, key: ca.crt }
      cert:
        secret: { name: prometheus-scrape-client-cert, key: tls.crt }
      keySecret: { name: prometheus-scrape-client-cert, key: tls.key }
      serverName: <service>.<namespace>.svc
```

**Pros**

- No bearer tokens at all; aligns with the high-level mTLS discussion.
- Strong cryptographic identity for scraper and server.
- cert-manager can issue short-lived certificates and renew them automatically.

**Cons**

- **Not the kubebuilder default** — controller-runtime metrics server would need custom TLS configuration to verify client certificates and maintain a client CA.
- More moving parts: server cert, client cert, client CA distribution, renewal, and potentially **per-scraper** or **per-service** cert management across all Konflux components.
- Upstream Konflux services do not implement this today; operator would own the full stack.
- Debugging scrape failures is harder (cert expiry, SAN mismatch, CA trust).

---

### 3. TLS encryption + NetworkPolicy (network segmentation only)

**How it works**

| Layer | Mechanism |
|-------|-----------|
| Metrics server | HTTPS (or HTTP on a cluster-internal port) without application-level authentication. |
| Access control | `NetworkPolicy` allows ingress to the metrics port **only** from the Prometheus namespace (or pods labeled as scrapers). The operator scaffold already has an example (`config/network-policy/allow-metrics-traffic.yaml`). |
| Scrape | Plain ServiceMonitor — no `bearerTokenFile`, no client cert. |

**Pros**

- Simplest to implement; no token or client-cert lifecycle.
- No long-lived credentials by definition.
- Composes well as a **baseline** alongside another option.

**Cons**

- **Not authentication** — any compromised pod in an allowed namespace can scrape metrics.
- Does not meet defense-in-depth expectations for multi-tenant clusters.
- Unlikely to satisfy security review on its own for production Konflux environments.

---

### 4. OpenShift service serving certificate (server TLS only)

**How it works**

OpenShift's service CA signs the Service's serving certificate. Prometheus
verifies the server using `service-ca.crt` (ConfigMap or projected secret).
This is how etcd-shield configures **server** TLS in infra-deployments, though
that ServiceMonitor still pairs it with a static bearer token (which we want
to drop).

Can be combined with option 1 (bearer + verified server TLS) or option 3
(network policy only).

**Pros**

- No cert-manager required on OpenShift; serving certs rotate with the
  service.
- Eliminates `insecureSkipVerify: true` common in legacy ServiceMonitors.

**Cons**

- OpenShift-specific; vanilla Kubernetes needs cert-manager instead.
- Server TLS alone does not authenticate the scraper.

---

### 5. Projected scrape token (dedicated identity)

A refinement of option 1. Instead of reusing the Prometheus pod's default
projected token, mount a **dedicated** projected ServiceAccount token (with
`expirationSeconds` and optional `audience`) into the Prometheus pod and
point `bearerTokenFile` at that mount path.

This is the same mechanism Konflux uses for UI backend tokens and the
direction of [konflux-ci#6962](https://github.com/konflux-ci/konflux-ci/pull/6962)
for Dex — short-lived, bound, audience-scoped credentials.

**Pros**

- Principle of least privilege: scrape token can be bound to a dedicated SA
  with only `*-metrics-reader`, separate from Prometheus's API-access token.
- Explicit TTL and audience control.

**Cons**

- Requires UWM / Prometheus Operator support for custom volume mounts or
  accepting `bearerTokenFile` paths beyond the default SA token (verify for
  `appstudio-workload-monitoring` Prometheus).
- More configuration than option 1 with marginal benefit if Prometheus SA is
  already minimally privileged.

---

## Comparison summary

| Option | Scrape credential | Rotates automatically | kube-rbac-proxy | Upstream fit | Operational complexity |
|--------|-------------------|----------------------|-----------------|--------------|------------------------|
| **1. Bearer token + server TLS** | Projected SA token (`bearerTokenFile`) | Yes (kubelet) | No — controller-runtime filters | Strong — [kubebuilder default](https://book.kubebuilder.io/reference/metrics) | Low |
| **2. mTLS** | Client certificate | Yes (cert-manager) | No | Not kubebuilder default — greenfield | High |
| **3. NetworkPolicy only** | None | N/A | No | Partial — NP scaffold exists | Very low |
| **4. OpenShift serving TLS** | None (server TLS only) | Yes (service CA) | No | Partial — used for server side | Low (OpenShift only) |
| **5. Projected scrape token** | Bound projected SA token | Yes (kubelet) | No | Strong — matches #6962 direction | Medium |

---

## Recommended direction

**Primary: option 1 (bearer token + verified server TLS)** — this is what
Kubebuilder documents as the production path:

1. Enable cert-manager metrics certificates on each controller (or OpenShift
   serving CA — option 4).
2. ServiceMonitor with `bearerTokenFile` + `tlsConfig.ca` / `serverName`
   (not `insecureSkipVerify: true`).
3. `ClusterRoleBinding` from the Prometheus scraper SA to `*-metrics-reader`.

This gives:

- No kube-rbac-proxy ([deprecated by kubebuilder](https://book.kubebuilder.io/reference/metrics)).
- No long-lived secrets.
- Direct alignment with kubebuilder v4+ and the operator's `main.go`.
- A clear migration from legacy infra-deployments: keep the `*-metrics-reader`
  ClusterRole semantics, but bind the **Prometheus scraper SA** (not a
  `metrics-reader` SA) and drop the static token Secret.

**mTLS (option 2)** is a distinct, stronger model that goes **beyond** what
Kubebuilder recommends. It is viable if security requirements explicitly
mandate client-certificate authentication *instead of* bearer tokens, but
expect custom controller-runtime TLS configuration across every Konflux
component. Treat it as optional hardening, not what the kubebuilder cert-manager
section implies.

**NetworkPolicy (option 3)** — kubebuilder lists this as an optional
supplement that does not replace authn/authz; use alongside option 1.

---

## Migration notes

| Legacy artifact | New approach |
|-----------------|--------------|
| kube-rbac-proxy sidecar | Remove; enable `metrics-secure` + controller-runtime auth filters on upstream controllers |
| `Secret` type `kubernetes.io/service-account-token` | Remove |
| `bearerTokenSecret: metrics-reader` | `bearerTokenFile` on Prometheus SA (option 1) |
| `ClusterRoleBinding` → `metrics-reader` SA | Rebind to `prometheus-k8s` (or UWM Prometheus SA) |
| ServiceMonitor in `appstudio-workload-monitoring` with `namespaceSelector` | Keep if UWM Prometheus requires it; auth model changes regardless of placement |
| `config/prometheus/monitor.yaml` | Use as a starting point: enable cert-manager patches per kubebuilder; replace `insecureSkipVerify` with CA verification; wire via operator reconciliation |

## Validation phases

Incremental plan to prove the recommended approach on the **operator's own
kubebuilder metrics** before rolling it out to Konflux components.

### What is already deployed

The operator ships with half of the recommended stack enabled by default:

| Piece | Config | Deployed? |
|-------|--------|-----------|
| HTTPS metrics on `:8443` | `manager_metrics_patch.yaml` | Yes |
| `filters.WithAuthenticationAndAuthorization` | `cmd/main.go` | Yes |
| Metrics `Service` | `metrics_service.yaml` | Yes |
| `metrics-auth-role` on controller SA | `metrics_auth_role_binding.yaml` | Yes |
| `metrics-reader` ClusterRole | `metrics_reader_role.yaml` | Yes (as `konflux-operator-metrics-reader`) |
| Scraper `ClusterRoleBinding` | — | **No** (kubebuilder leaves this manual) |
| cert-manager metrics certs | `../certmanager` | No (`config/certmanager/` missing) |
| `ServiceMonitor` | `../prometheus` | No |

### Phase 1 — Auth only (manual)

**Goal:** Verify bearer-token RBAC auth on `/metrics` without Prometheus or
cert-manager. Uses the dev self-signed server certificate (`curl -k`).

**Prerequisites:** Operator running (e.g. `make deploy` on Kind).

**Steps:**

1. Confirm metrics endpoint is enabled:

   ```bash
   kubectl get svc -n konflux-operator \
     konflux-operator-controller-manager-metrics-service
   ```

2. Create the scraper binding (kubebuilder does not scaffold this):

   ```bash
   kubectl create clusterrolebinding konflux-operator-metrics-scraper \
     --clusterrole=konflux-operator-metrics-reader \
     --serviceaccount=konflux-operator:konflux-operator-controller-manager
   ```

   In production the subject would be the **Prometheus scraper SA**, not the
   controller SA. Binding the controller SA is sufficient for a manual curl
   smoke test.

3. **Positive test** — token from a SA with `metrics-reader`:

   ```bash
   TOKEN=$(kubectl create token konflux-operator-controller-manager -n konflux-operator)
   kubectl run curl-metrics --rm -it --restart=Never \
     --image=curlimages/curl:8.5.0 -n konflux-operator -- \
     curl -sk -H "Authorization: Bearer ${TOKEN}" \
     https://konflux-operator-controller-manager-metrics-service.konflux-operator.svc:8443/metrics
   ```

   Expect **HTTP 200** and Prometheus text exposition (e.g. `workqueue_*`,
   `controller_runtime_*`).

4. **Negative test — no token:**

   ```bash
   kubectl run curl-metrics --rm -it --restart=Never \
     --image=curlimages/curl:8.5.0 -n konflux-operator -- \
     curl -sk -o /dev/null -w "HTTP %{http_code}\n" \
     https://konflux-operator-controller-manager-metrics-service.konflux-operator.svc:8443/metrics
   ```

   Expect **HTTP 401**.

5. **Negative test — token without permission:**

   ```bash
   TOKEN=$(kubectl create token default -n konflux-operator)
   kubectl run curl-metrics --rm -it --restart=Never \
     --image=curlimages/curl:8.5.0 -n konflux-operator -- \
     curl -sk -o /dev/null -w "HTTP %{http_code}\n" \
     -H "Authorization: Bearer ${TOKEN}" \
     https://konflux-operator-controller-manager-metrics-service.konflux-operator.svc:8443/metrics
   ```

   Expect **HTTP 403**.

**Phase 1 results (Kind cluster `kind-konflux`, 2026-06-23):**

| Test | Expected | Actual |
|------|----------|--------|
| Authorized bearer token | 200 | **200** |
| No `Authorization` header | 401 | **401** |
| `default` SA token (no binding) | 403 | **403** |

Binding used for the test: `konflux-operator-metrics-scraper-test` →
`konflux-operator-metrics-reader` → `konflux-operator-controller-manager`.

### Phase 2 — Full path on Kind (cert-manager + Prometheus)

**Goal:** Enable the kubebuilder production stack and verify Prometheus scrapes
via `bearerTokenFile` with verified server TLS (`insecureSkipVerify: false`).

**Prerequisites:** Phase 1 passing; cert-manager already installed on cluster.

#### What was implemented

1. **`config/certmanager/`** — metrics `Issuer` + `Certificate` (secret
   `metrics-server-cert`) and `kustomizeconfig.yaml` so `namePrefix` rewrites
   `issuerRef.name` correctly (`konflux-operator-selfsigned-issuer`).

2. **Enabled in `config/default/operator-rbac/kustomization.yaml`:**
   - `../../certmanager` and `../../prometheus` resources
   - `cert_metrics_manager_patch.yaml` (mounts certs, `--metrics-cert-path`)
   - `replacements` for Certificate DNS names and ServiceMonitor `serverName`
   - `monitor_tls_patch.yaml` in `config/prometheus/kustomization.yaml`

3. **`config/prometheus-stack/`** — Kind-only Prometheus instance (not part of
   production operator deploy):
   - `Prometheus` CR in `monitoring` namespace
   - `prometheus` ServiceAccount + discovery RBAC
   - `ClusterRoleBinding` `prometheus-konflux-operator-metrics-reader`

4. **Cluster setup:**
   - Prometheus Operator v0.77.1 (`kubectl apply --server-side` — required on
     Kind to avoid CRD annotation size errors)
   - Restart `prometheus-operator` after CRDs are installed (operator logs
     `prometheuses not installed` if started too early)
   - `kubectl apply` of `kustomize build config/default`
   - `kubectl apply` of `kustomize build config/prometheus-stack`

#### Gotcha fixed during testing

The initial `Certificate` stayed in `Issuing` because `namePrefix` renamed the
`Issuer` but not `spec.issuerRef.name` until `kustomizeconfig.yaml` was added.

#### Phase 2 results (Kind cluster `kind-konflux`, 2026-06-23)

| Check | Result |
|-------|--------|
| `Certificate` `konflux-operator-metrics-certs` Ready | **Yes** |
| Secret `metrics-server-cert` created | **Yes** |
| Operator pod uses `--metrics-cert-path` | **Yes** |
| `ServiceMonitor` created with `bearerTokenFile` + CA from `metrics-server-cert` | **Yes** |
| Prometheus target health | **up** |
| `workqueue_depth` series scraped | **Yes** (15 series) |

Prometheus scrape URL:
`https://<operator-pod-ip>:8443/metrics` via ServiceMonitor
`konflux-operator-controller-manager-metrics-monitor`.

Scraper auth: `prometheus` SA in `monitoring` namespace (projected token via
`bearerTokenFile`) bound to `konflux-operator-metrics-reader`.

#### Reproduce locally

```bash
# Prometheus Operator (server-side apply for Kind)
curl -fsSL -o /tmp/po-bundle.yaml \
  https://github.com/prometheus-operator/prometheus-operator/releases/download/v0.77.1/bundle.yaml
kubectl apply --server-side --force-conflicts -f /tmp/po-bundle.yaml
kubectl rollout restart deployment/prometheus-operator -n default

# Operator with metrics certs + ServiceMonitor
cd operator && bin/kustomize build config/default | kubectl apply -f -
kubectl wait certificate/konflux-operator-metrics-certs -n konflux-operator \
  --for=condition=Ready --timeout=120s
kubectl rollout status deployment/konflux-operator-controller-manager -n konflux-operator

# Kind Prometheus stack
bin/kustomize build config/prometheus-stack | kubectl apply -f -

# Verify (after ~30s scrape interval)
kubectl exec -n monitoring prometheus-prometheus-0 -c prometheus -- \
  wget -qO- 'http://localhost:9090/api/v1/targets' | jq '.data.activeTargets[] | select(.labels.namespace=="konflux-operator") | {health,lastError}'
```

### Phase 3 — Automated e2e

**Goal:** CI-durable test covering Phase 2.

**Work items:**

1. Create `operator/test/e2e/` (Makefile references it but directory is empty).
2. Suite setup: Kind → cert-manager → Prometheus Operator → operator deploy
   with a test kustomize overlay enabling metrics certs + ServiceMonitor.
3. Assert: `Certificate` Ready, Prometheus target up, metrics query returns data,
   unauthenticated scrape fails.

### Phase 4 — OpenShift UWM integration

**Goal:** Parity with legacy infra-deployments monitoring on
`development-operator`.

**Work items:**

1. Reconcile `ServiceMonitor` with label `prometheus: appstudio-workload` if
   required by UWM Prometheus in `appstudio-workload-monitoring`.
2. Bind `prometheus-k8s` SA (confirm name per cluster) to `metrics-reader`.
3. Use OpenShift serving CA or cert-manager for server TLS verification.
4. Confirm Grafana dashboards still resolve operator metrics.

---

## Open questions

1. **Upstream controllers** — build-service and image-controller bind metrics on
   `:8443` without kube-rbac-proxy in operator manifests, but release-service
   and integration-service still use `:8080` HTTP. Does monitoring enablement
   include patching all components to the secure metrics model?
2. **UWM Prometheus SA name** — confirm the scraper SA in
   `appstudio-workload-monitoring` (legacy: `prometheus-k8s`) for
   ClusterRoleBindings.
3. **mTLS vs kubebuilder model** — confirm stakeholders understand kubebuilder
   cert-manager integration is **server TLS + bearer token**, not mTLS. Is
   option 2 a separate mandate beyond that?
4. **cert-manager dependency** — on non-OpenShift clusters, is cert-manager
   already a Konflux operator dependency for webhooks (reuse for metrics
   server certs)?
