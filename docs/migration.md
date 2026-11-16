# Adopting the kit for a stack that already runs

Use this when an environment already has a hand-made tracing stack (an OTel Collector, Prometheus,
Tempo, dashboards, agent patches) and you want the kit to manage it from now on, without losing data
or breaking dashboards. The approach: describe what runs today in `kit.env` / `apps/`, render, and
make `kubectl diff` (or `nomad job plan`, `git diff` of the configs) show only intended changes
before applying anything.

## 1. Describe the existing stack

| What runs today | Kit setting |
|---|---|
| Namespace / project of the stack | `STACK_NAME` (keep the same, so PVCs and Services are reused) |
| Environment label on telemetry | `ENVIRONMENT` |
| Prometheus / Tempo retention, memory, volume sizes | the sizing settings (start from the closest `SIZE`, then set the values explicitly) |
| StorageClass of the existing PVCs | `STORAGE_CLASS` |
| Existing Grafana | `GRAFANA_MODE=sidecar` or `api`; `bundled` only if the stack had its own Grafana |
| Cluster Prometheus used for Kubernetes metrics | `FEDERATE_FROM` |
| Each instrumented application | one `apps/<app>/` folder: `APP_NAMESPACE`, `SERVICE_REGEX`, `TARGETS` |
| Extra container settings added with the agent (startup probes, securityContext) | `apps/<app>/overrides/` |

**Volumes must not change.** StatefulSet volume templates cannot be changed in place and PVCs cannot
shrink: set `PROMETHEUS_VOLUME` / `TEMPO_VOLUME` to the sizes of the existing PVCs
(`kubectl -n <ns> get pvc`).

## 2. Keep dashboard links working

Grafana identifies dashboards by uid. If people have bookmarks or links:

- set `DASHBOARD_UID_PREFIX` so the kit's uids equal the existing ones (an empty prefix gives
  `traces`, `service-overview`, `service-monitoring-k8s`, `actions`, `containers-hosts`);
- keep the datasource uids `obs-prometheus` / `obs-tempo` — if the existing datasources use other
  uids, either rename them in Grafana or expect to re-select the datasource in old copies of the
  dashboards.

Two ConfigMaps or files with the same dashboard uid make Grafana flip between them, so **remove the
old dashboards before applying the kit's** (sidecar: delete the old ConfigMaps in the dashboard
namespace; bundled / api: delete them in Grafana).

## 3. Render and compare

```bash
./render.sh
kubectl diff -k out/stack               # Kubernetes
```

Expected: ConfigMap content changes (and therefore rolling restarts of the gateway, Prometheus and
Tempo). Not acceptable: a changed StatefulSet `volumeClaimTemplates`, a different namespace, or
resources being deleted that you still need. Adjust the settings until the diff is what you want.

Differences you will usually see, all harmless:

- the gateway also drops health / metrics endpoint spans (`DROP_PATHS_REGEX`);
- Prometheus gets an `environment` external label;
- the federation job is called `federate`;
- agent patches gain `OTEL_TRACES_SAMPLER` / `OTEL_TRACES_SAMPLER_ARG`, so re-applying them rolls
  each instrumented deployment once.

## 4. Switch over

1. `kubectl apply -k out/stack`; wait until all pods are ready.
2. Remove the old dashboards, then apply the kit's (`out/apps/<app>/dashboards`, `out/grafana`, or
   `import.sh`).
3. Datasources: unchanged if uids and URLs match; otherwise apply `values-grafana.yaml` / bundled /
   `import.sh`.
4. Instrumentation: `DRY_RUN=server out/apps/<app>/instrumentation/apply.sh`, then one deployment,
   then the rest.
5. Check: Prometheus targets up, traces arriving in Tempo, dashboards filled
   (see [operations.md](operations.md#troubleshooting)).
6. Retire the old manifests / scripts so nobody applies them again; from now on change the kit's
   settings and re-render.
