# Add an app to the observability kit

Onboard an app (a group of services) into this observability kit; ask for its name if the
operator has not given it. Read `README.md`, `kit.env` (or
`kit.env.example` if there is no `kit.env`) and `apps/example/app.env` first.

1. Find out (from the user, or by reading their manifests / compose files / job files if they point
   you at them):
   - the services and what language / runtime each uses (Java gets the agent; others need an
     OpenTelemetry SDK in the image, see `docs/instrumentation.md`);
   - Kubernetes: namespace, deployment names, container names when they differ, how they are
     deployed (kubectl / Jenkins / Helm release), liveness probe timings, whether pods must run as
     non-root;
   - compose / nomad / host: the service names they will use as `OTEL_SERVICE_NAME`.
   Ask only for what you cannot read.
2. Create `apps/<app>/app.env` from `apps/example/app.env`:
   - `SERVICE_REGEX` matches every service name and nothing of other apps;
   - `DASHBOARD_UID_PREFIX` unique among `apps/*/app.env`; `DASHBOARD_FOLDER` (unique with
     kubernetes + bundled Grafana);
   - `TARGETS` (Kubernetes) with `:container` / `:env` where needed.
3. Kubernetes: for Java deployments whose liveness probe allows less than ~90 s for startup, add
   `apps/<app>/overrides/<deployment>.yaml` with a `startupProbe` using the deployment's own
   liveness check (path/port or command). Non-root pods: `overrides/<deployment>.init.yaml` with a
   `securityContext` for the agent init container.
4. Add the app to `APPS` in the kit settings file and run `./render.sh`. Fix any error or warning it
   prints (an unmatched `SERVICE_REGEX` warning means the dashboards would not show that service).
5. Show the user the generated files for the app and the next steps from `out/NEXT-STEPS.txt`.
   Point out:
   - Kubernetes: `kubectl apply -k out/stack` again (adds the app's resource metrics), then
     `DRY_RUN=server` → one deployment → the rest; each patch is a rolling restart;
   - Helm-managed deployments lose the agent on the next `helm upgrade` unless it uses
     `helm-post-renderer.sh`;
   - expected extra load (~100 MB memory and slower startup per Java pod; stack sizing in README).

## How you work (any AI agent)

This prompt is written for any AI assistant. Adapt to what you can do:

- **You can run shell commands** (coding agents in a terminal or IDE): run read-only commands
  yourself; for changing commands follow the confirmation rule below.
- **You cannot run commands** (chat assistants): give the operator one command at a time, say what
  it does, and ask them to paste the output back before you continue.
- **You can edit files**: write the settings files yourself. Otherwise give the complete file
  content and the path to save it to.
- Paths in this prompt are relative to the kit's folder (the one containing `render.sh`).

Do not run kubectl / docker / nomad / systemctl commands that change anything unless the user asks.
