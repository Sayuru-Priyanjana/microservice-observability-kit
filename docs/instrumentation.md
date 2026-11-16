# Instrumenting services

The stack accepts OTLP (gRPC 4317, HTTP 4318) from any OpenTelemetry SDK or agent. The dashboards need
three things from every service:

| What | Why |
|---|---|
| `service.name` (`OTEL_SERVICE_NAME`) matching the app's `SERVICE_REGEX` | every dashboard filters on it |
| `host.name` = node / machine name | becomes the `instance` label (host filter, joins with infra metrics) |
| `deployment.environment` | lets one stack hold several environments |
| traces **and** metrics exported over OTLP, metric interval 15 s | span metrics come from traces; HTTP / JVM panels from metrics |
| `tracecontext,baggage` propagators | traces continue across services; `user.action` travels along |

The kit's generated files set all of these. What they set, for reference:

```
OTEL_SERVICE_NAME=<service>
OTEL_RESOURCE_ATTRIBUTES=deployment.environment=<env>,host.name=<node>
OTEL_EXPORTER_OTLP_ENDPOINT=http://<gateway>:4317
OTEL_EXPORTER_OTLP_PROTOCOL=grpc
OTEL_TRACES_EXPORTER=otlp
OTEL_METRICS_EXPORTER=otlp
OTEL_LOGS_EXPORTER=none
OTEL_PROPAGATORS=tracecontext,baggage
OTEL_METRIC_EXPORT_INTERVAL=15000
OTEL_TRACES_SAMPLER=parentbased_always_on      # or parentbased_traceidratio + OTEL_TRACES_SAMPLER_ARG
```

## Java (no code change)

The OpenTelemetry Java agent instruments Spring, servlet containers, JDBC, HTTP clients, Kafka, JMS,
Redis and more. It is loaded with `JAVA_TOOL_OPTIONS=-javaagent:<path>`, so start scripts are unchanged.

- **Kubernetes** (`TARGETS` mode `java`, the default): an init container copies the jar from
  `IMAGE_JAVA_AGENT` into an `emptyDir`; the app image is unchanged.
- **Compose**: the one-shot `otel-agent` service in `docker-compose.otel.yml` does the same with a volume.
- **Nomad**: an `artifact` block downloads `JAVA_AGENT_URL` into the task (`otel-task.nomad.hcl`).
- **Host**: put the jar at `/opt/otel/opentelemetry-javaagent.jar` and add the systemd drop-in
  (`systemd-otel.conf`).

Cost: ~100 MB more memory per instance and 10-60 s more startup. On Kubernetes add a
`startupProbe` (`apps/<app>/overrides/<deployment>.yaml`) when the liveness probe is short.
If the pod must run as non-root, give the init container a `securityContext`
(`overrides/<deployment>.init.yaml`).

## Other languages (Kubernetes mode `env`, or the env file elsewhere)

Add OpenTelemetry to the image once; the kit then only sets the environment above.

| Language | Zero-code option | Notes |
|---|---|---|
| Node.js | `npm i @opentelemetry/auto-instrumentations-node` and `NODE_OPTIONS=--require @opentelemetry/auto-instrumentations-node/register` | set `OTEL_NODE_RESOURCE_DETECTORS=env,host,os` |
| Python | `pip install opentelemetry-distro opentelemetry-exporter-otlp && opentelemetry-bootstrap -a install`, start with `opentelemetry-instrument <cmd>` | exclude health URLs with `OTEL_PYTHON_<FRAMEWORK>_EXCLUDED_URLS` |
| .NET | OpenTelemetry .NET automatic instrumentation (`otel-dotnet-auto-install.sh`, `instrument.sh`) | or the SDK + `AddOtlpExporter()` |
| Go | SDK in code (`go.opentelemetry.io/otel`, `otelhttp`, `otelgrpc`); eBPF auto-instrumentation is an option | the SDK reads the same `OTEL_*` variables |
| PHP / Ruby | language SDK + auto-instrumentation packages | |

HTTP server metrics: the dashboards read both the stable names (`http.server.request.duration`,
seconds; Java agent 2.x and current SDKs) and the old ones (`http.server.duration`, ms). JVM panels
need the Java agent; other runtimes show HTTP and trace panels only.

## user.action (optional `user-actions` dashboard)

The `user-actions` dashboard groups every span of a user action (e.g. `POST /orders`) across all
services. It needs the span attribute `user.action` on the spans of every service involved:

1. The entry service (usually the API behind the UI) sets `user.action=<route template>` as a span
   attribute **and** as a W3C baggage entry, so it travels to every downstream call.
2. Every service copies that baggage entry onto its spans with a `BaggageSpanProcessor`
   (Python: `opentelemetry-processor-baggage`; Java: the `baggage-processor` module of
   opentelemetry-java-contrib, usable as a Java agent extension). Without it only the entry
   service's spans carry the attribute.

This is app code, not something the kit can add. When an app lists `user-actions`, `render.sh` adds
`user.action` to Tempo's span-metrics dimensions (the `user_action` label). Keep the values few
(route templates, never URLs with ids): every value is a new set of time series.

## Checking a service

1. Grafana → Explore → Tempo → Search, service name = the service: traces appear within ~30 s.
2. Prometheus: `count by (service_name) ({__name__=~"http_server_request_duration_seconds_count|http_server_duration_milliseconds_count"})`
3. Nothing arrives: the service's log shows OTLP export errors (wrong endpoint, firewall); the gateway's
   own metrics `otelcol_receiver_accepted_spans` show whether anything reaches it.
