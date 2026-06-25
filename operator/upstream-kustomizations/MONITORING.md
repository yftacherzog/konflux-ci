# Monitoring overlays

Operator-owned Prometheus scrape resources live under each component’s `monitoring/`
directory. See **[../docs/component-monitoring.md](../docs/component-monitoring.md)** for
target architecture, the current interim approach, and migration steps.

Quick layout:

```
<component>/
├── core/        # strips upstream ServiceMonitor + scrape SA/Secret
└── monitoring/  # ServiceMonitor + *-metrics-reader RBAC (+ token SA/Secret in interim)
```

Rebuild after changes:

```bash
bash operator/pkg/manifests/process-component.sh <component> <repo-root>
```
