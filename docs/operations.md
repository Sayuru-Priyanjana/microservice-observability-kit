# Operating the stack

## Changing settings

Edit `kit.env` / `apps/<app>/app.env`, run `./render.sh`, apply again. What re-applying does:

| Target | Command | Effect |
|---|---|---|
| kubernetes | `kubectl apply -k out/stack` | changed configs get new ConfigMap names → only the affected pods restart |
| compose | `docker compose up -d` | recreates containers whose definition changed; for config-file-only changes: `docker compose restart <service>` (Prometheus: `curl -X POST localhost:9090/-/reload`) |
| nomad | `nomad job run observability.nomad.hcl` | changed templates restart their task |
| host | `sudo ./install.sh` | replaces configs and restarts all services (data is kept) |

Re-running a Kubernetes `apply.sh` restarts the app's pods only when its patch changed.

## Alerts

Rules in `templates/common/prometheus/rules/alerts.yml`, visible in Prometheus `/alerts` and Grafana
(Alerting → Alert rules, "Data source-managed"). No Alertmanager is deployed, so nothing is sent.
To get notifications, either point Prometheus at an existing Alertmanager (add an `alerting:` block
to `templates/common/prometheus/prometheus.yml`), or recreate the rules as Grafana-managed alerts with
a contact point.

| Alert | Meaning / first check |
|---|---|
| HighErrorRate | >5% of a service's HTTP requests return 5xx for 5 min → Traces dashboard, *Error traces* |
| HighLatencyP95 | p95 > 1 s for 10 min → *Slow traces*, then the span breakdown |
| CollectorDroppingData | the gateway cannot export → is Tempo / Prometheus up? gateway logs |
| CollectorRefusingData | gateway at its memory limit → raise `GATEWAY_MEMORY_LIMIT` or lower `TRACE_SAMPLE_RATIO` |
| PrometheusRuleEvaluationFailures | a rule fails (usually after editing alerts.yml) |

## Watching capacity (first week after adding an app)

| Query (Prometheus) | Watch for |
|---|---|
| `prometheus_tsdb_head_series` | series count; ~95k for 10 Java services. Memory grows with it |
| `rate(tempo_distributor_bytes_received_total[1h]) * 86400` | trace bytes per day × retention ≈ disk needed |
| `container_memory_working_set_bytes{namespace="<STACK_NAME>"}` (k8s) / `container_memory_working_set_bytes{name=~"<stack>.*"}` (compose) | close to the limit → raise it |
| `kube_pod_container_status_restarts_total{namespace="<STACK_NAME>"}` | OOM kills |
| `otelcol_exporter_queue_size` | a growing queue: the backend is too slow |

Too much: lower `TRACE_SAMPLE_RATIO` (traces and span metrics shrink, app metrics stay complete),
shorten retention, or remove high-cardinality `SPAN_METRICS_DIMENSIONS`.

## Troubleshooting

| Symptom | Check |
|---|---|
| No data for a service | `OTEL_SERVICE_NAME` matches `SERVICE_REGEX`? Service log shows OTLP export errors? Firewall to 4317? |
| Traces but empty HTTP panels | the service exports no metrics (`OTEL_METRICS_EXPORTER=otlp`) or uses other metric names |
| Empty service graph | needs client **and** server spans of both services in the same trace (propagation) |
| Empty Kubernetes / container panels | `INFRA_METRICS`; k8s: `FEDERATE_FROM` reachable, target `federate` up in Prometheus `/targets` |
| Dashboards missing (sidecar) | ConfigMaps in `DASHBOARD_NAMESPACE` with label `grafana_dashboard=1`; sidecar logs in the Grafana pod |
| Grafana "datasource not found" | datasource uids must be `obs-prometheus` / `obs-tempo` |
| Grafana admin password wrong | it is only applied when Grafana creates its database; reset with `grafana cli admin reset-admin-password` |
| Nomad: no infra targets | Prometheus needs the Nomad API (`NOMAD_ADDR`); with ACLs add a token: `authorization: { credentials: <token> }` under `nomad_sd_configs` in `templates/common/prometheus/prometheus.yml` (token with `node:read` and `namespace:read-job`) |
| Host: a service does not start | `journalctl -u <STACK_NAME>-<service> -e` |

## Ports

| Port | Component | Exposed |
|---|---|---|
| 4317 / 4318 | gateway OTLP gRPC / HTTP | to the apps (`BIND_ADDRESS`) |
| 3000 (`GRAFANA_PORT`) | Grafana (bundled) | to users |
| 9090 | Prometheus | `ADMIN_BIND_ADDRESS` (default loopback) |
| 3200 | Tempo HTTP | `ADMIN_BIND_ADDRESS` |
| 8888 / 8889 / 13133 | gateway own metrics / app metrics / health | internal (nomad/host: `ADMIN_BIND_ADDRESS`) |
| 4319 | Tempo OTLP (nomad / host) | loopback |
| 9095 / 7946 | Tempo internal gRPC / memberlist (nomad / host) | all interfaces: block on the firewall |
| 9100 / 9338 | node-exporter / cAdvisor (nomad infra job) | to the stack's node only |

## Rollback

```bash
# Kubernetes
kubectl -n <app-namespace> rollout undo deployment/<deployment>   # agent off for one deployment
kubectl delete -k out/apps/<app>/dashboards                       # an app's dashboards (sidecar)
kubectl delete -k out/grafana                                     # bundled Grafana (PVC grafana-data is deleted too)
kubectl delete -k out/stack                                       # the stack (StatefulSet PVCs are kept)
# Compose
docker compose down            # keep data;   docker compose down -v   also deletes the volumes
# Nomad
nomad job stop -purge <STACK_NAME> ; nomad job stop -purge <STACK_NAME>-infra
# Host
sudo systemctl disable --now <STACK_NAME>-{otel-collector,tempo,prometheus,grafana}
```
Removing instrumentation outside Kubernetes: drop the env file / drop-in / compose overlay and restart
the service.

## Upgrading component versions

Change the `IMAGE_*` (and `JAVA_AGENT_URL`) values in `kit.env`, re-render, apply. Read the release
notes first: collector processors and Tempo config keys change between versions (the alert rules
already match collector metrics with and without `_total`). Try on a test environment
(`KIT_ENV=test.env OUT=out-test ./render.sh`) before production.
