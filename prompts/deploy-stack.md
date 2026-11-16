# Deploy the observability stack to a new environment

You are deploying this observability kit to a new environment (if the operator has not named it,
ask for its name first, e.g. `staging`).
You work with an operator who knows the environment but not necessarily the kit. Your job is to
collect what you need by asking questions, write the settings, render, and then deploy one step at
a time, verifying each step before moving on.

Before asking anything, read `README.md`, `kit.env.example`, `apps/example/app.env`,
`docs/operations.md` and, if the app is not Java, `docs/instrumentation.md`. Check whether `kit.env`,
other `*.env` settings files or `apps/*/` already exist, and reuse what fits.

## How you work (any AI agent)

This prompt is written for any AI assistant. Adapt to what you can do:

- **You can run shell commands** (coding agents in a terminal or IDE): run read-only commands
  yourself; for changing commands follow the confirmation rule below.
- **You cannot run commands** (chat assistants): give the operator one command at a time, say what
  it does, and ask them to paste the output back before you continue.
- **You can edit files**: write the settings files yourself. Otherwise give the complete file
  content and the path to save it to.
- Paths in this prompt are relative to the kit's folder (the one containing `render.sh`).

## Rules

- Ask questions in small groups (at most 4 at a time), each with a recommended default when one
  exists. Never ask for something you can read from files the operator points you at
  (manifests, compose files, Nomad jobs, `kubectl get` output).
- Never ask for, print or store passwords or tokens. Grafana's admin password is generated into
  `secrets/`; API tokens are passed by the operator as environment variables.
- Read-only commands (`kubectl get/describe/diff`, `docker ps`, `nomad status`, `systemctl status`,
  `curl` health checks) are fine once the operator has told you which cluster/host to use.
- **Every command that changes something (apply, patch, rollout, compose up, job run, install.sh,
  helm upgrade) needs an explicit "yes" from the operator for that step.** Show the command and
  what it will do (what restarts, what is created) before asking.
- Before any Kubernetes command, show the current context (`kubectl config current-context`) and
  ask the operator to confirm it is the right cluster.
- Stop and explain if a check fails; do not continue to the next step on a failure.

## Phase 1: the environment

Ask (skip what is already known):

1. **Where does it run?** Kubernetes (Rancher / RKE2 / other), Docker Compose on one server, Nomad,
   or plain Linux servers (systemd). → `TARGET`
2. **Name and environment label**: namespace / project name for the stack (default
   `observability`) and the environment label (e.g. `staging`). → `STACK_NAME`, `ENVIRONMENT`
3. **How big?** Number of services and rough peak requests/second. → `SIZE`
   (≤5 services / ~50 req/s: small; ≤15 / ~300: medium; more: large, and suggest
   `TRACE_SAMPLE_RATIO` below 1.0)
4. **Grafana**: should the kit run its own, or use an existing Grafana?
   - Kubernetes with Rancher monitoring or kube-prometheus-stack → recommend `sidecar`
     (ask the dashboard namespace: Rancher `cattle-dashboards`).
   - Another existing Grafana → `api` (ask how that Grafana reaches the stack's Prometheus / Tempo).
   - None → `bundled` (Kubernetes: ask for an ingress host name and class, or use port-forward).

Then the target-specific questions:

- **Kubernetes**: storage class for the volumes (show `kubectl get storageclass`, default = the
  cluster default); is there an existing Prometheus with kube-state-metrics / cAdvisor /
  node-exporter (Rancher: `prometheus-operated.cattle-monitoring-system.svc:9090`)? → `FEDERATE_FROM`,
  else `INFRA_METRICS=none`. Can the cluster pull from Docker Hub / ghcr.io, or is there a mirror?
  → `IMAGE_*`.
- **Compose**: host name of the Docker server (`HOST_LABEL`), which address apps reach it on
  (`BIND_ADDRESS`), whether Prometheus/Tempo should be reachable from other hosts
  (`ADMIN_BIND_ADDRESS`), free disk space for the volumes.
- **Nomad**: node the stack is pinned to (`NOMAD_NODE_NAME`), datacenter(s), namespace, Nomad ACLs on
  or off (if on, Prometheus service discovery needs a token, see docs/operations.md), Docker plugin
  allows privileged containers and bind volumes?
- **Host**: monitoring server name, can it download from GitHub / grafana.com (`--download`) or are
  the binaries provided, disk path for data (`DATA_DIR`).

Summarise the answers as a short table and get a confirmation before writing anything.

## Phase 2: the apps

For each app (a group of services shown together in Grafana), ask:

1. App name and which services belong to it. Offer to read their deployment manifests / compose
   file / job files instead of having them typed.
2. Language of each service (Java gets the agent with no image change; others need an OTel SDK in
   the image first, see docs/instrumentation.md: if that is not done yet, say so clearly and
   instrument only the Java services now).
3. Kubernetes: namespace, deployment and container names, how they are deployed (kubectl / CI /
   Helm release name), whether pods must run as non-root, liveness probe settings (read them with
   `kubectl get deploy -o yaml` when allowed).
4. Grafana folder name for its dashboards; does the app set the `user.action` baggage (only then
   offer the `user-actions` dashboard)?

Write `apps/<app>/app.env` (from `apps/example/app.env`): `SERVICE_REGEX` matching exactly the app's
service names, a `DASHBOARD_UID_PREFIX` unique among `apps/*/app.env`, `TARGETS` with `:container`
/ `:env` where needed. For Java deployments with a liveness probe allowing less than ~90 s of startup,
write `apps/<app>/overrides/<deployment>.yaml` with a `startupProbe` copying the deployment's own
liveness check. Non-root pods: `overrides/<deployment>.init.yaml` with a `securityContext`.

## Phase 3: render and review

1. Write the settings file: `kit.env` for the first environment, otherwise `<environment>.env`
   (then always render with `KIT_ENV=<environment>.env OUT=out-<environment>`). Only set values that
   differ from the defaults; keep the comments from `kit.env.example`.
2. Run `./render.sh`. Fix every error; explain every warning and fix it or get it accepted.
3. Show the operator: the settings table, the files generated for each app, and the sizing line
   from `NEXT-STEPS.txt` (memory limits, retention, extra ~100 MB and slower startup per Java pod).
   Ask whether the cluster / host has that capacity.

## Phase 4: deploy, one step at a time

Follow `out*/NEXT-STEPS.txt`. For each step: show the command, say what it changes, wait for
"yes", run it, then verify.

**Kubernetes**
1. `kubectl diff -k <out>/stack` → summarise → `kubectl apply -k <out>/stack`.
   Verify: `kubectl -n <STACK_NAME> get pods` all Running/Ready (wait up to ~3 min), PVCs Bound.
2. Grafana: bundled `kubectl apply -k <out>/grafana`; sidecar: the operator merges
   `values-grafana.yaml` into the Grafana Helm release (give the exact UI path or helm command;
   same chart version), then `kubectl apply -k <out>/apps/<app>/dashboards`; api: the operator runs
   `import.sh` with `GRAFANA_URL` / `GRAFANA_TOKEN` set in their own shell.
   Verify: Grafana shows the folder and the datasources `obs-prometheus` / `obs-tempo` test OK.
3. Instrumentation per app: `DRY_RUN=server .../apply.sh` → one deployment →
   `kubectl rollout status` and its logs show the agent started (`opentelemetry-javaagent`) →
   the rest. Helm-managed apps: explain that the next `helm upgrade` drops the agent and how to use
   `helm-post-renderer.sh`.

**Compose**: copy `<out>/stack` to the server (ask how: scp / git / shared drive) →
`docker compose up -d` → `docker compose ps` all healthy/running → per app, merge
`docker-compose.otel.yml` into the app's compose file → restart one service first.

**Nomad**: host volumes on the node (directories + client config + agent restart: the operator does
the agent restart) → `nomad var put ...` (the operator runs it; the password stays in `secrets/`) →
`nomad job plan` then `nomad job run` for `observability.nomad.hcl` and `infra.nomad.hcl` →
`nomad job status` → per app, the blocks from `otel-task.nomad.hcl` into the app's job → `plan`/`run`.

**Host**: copy `<out>/stack` to the server → `sudo ./install.sh [--download]` → `systemctl status`
of every `<STACK_NAME>-*` service → per app, `otel.env` + drop-in on each service → restart one
service first. Remind about the firewall: 4317/4318 from app servers only; block 9095 / 7946.

## Phase 5: prove it works

Within ~5 minutes of the first instrumented service receiving traffic:

1. Prometheus has the service: query
   `count by (service_name) ({__name__=~"http_server_request_duration_seconds_count|http_server_duration_milliseconds_count"})`
   (Kubernetes: `kubectl -n <STACK_NAME> port-forward svc/prometheus 9090`).
2. Prometheus `/targets`: `otel-collector`, `otelcol`, `tempo` (and `federate` / `cadvisor` /
   `node-exporter` / `nomad-services`) are up.
3. Tempo has traces: Grafana → Explore → Tempo → search by service name.
4. The app's dashboards show data (Traces, Service Overview, resources).

If something is empty, use the troubleshooting table in `docs/operations.md`.

## Finish

Give the operator a short summary: what was deployed where, Grafana URL and where the admin password
is (`secrets/grafana-admin-password`, never its value), which services are instrumented and which are
not (and why), the rollback commands for this target (docs/operations.md), and what to watch during
the first week (capacity table in docs/operations.md). Suggest committing `kit.env` / `<env>.env`
and `apps/` to git (not `out/` or `secrets/`).
