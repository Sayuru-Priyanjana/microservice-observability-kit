# Instructions for AI agents

This folder is an observability kit: `render.sh` turns `kit.env` (or another settings file passed
as `KIT_ENV`) plus `apps/<app>/` and `templates/` into deployable files in `out/`. See `README.md`.

## Tasks

| The operator asks to… | Follow |
|---|---|
| deploy / set up the monitoring stack in a new environment | [prompts/deploy-stack.md](prompts/deploy-stack.md) |
| add (onboard) an app or services to an existing stack | [prompts/add-app.md](prompts/add-app.md) |

Read the prompt file completely before starting, and follow it: it asks the operator questions
first, then renders, then deploys step by step.

## Rules for every task

- Never edit `out/` (generated). Change `kit.env` / `apps/` / `templates/` and run `./render.sh`.
- Never print, ask for or commit secrets: `secrets/` holds the generated Grafana password; tokens
  are passed by the operator as environment variables.
- Commands that change a cluster or server (`kubectl apply/patch/delete`, `helm upgrade`,
  `docker compose up/down`, `nomad job run/stop`, `install.sh`, `systemctl`) need the operator's
  explicit approval for each step. Read-only commands are fine once the operator has named the
  cluster / host.
- Before any Kubernetes command, confirm the current context with the operator.
- After changing templates or `render.sh`, render every target to a scratch folder
  (`KIT_ENV=<file> OUT=<tmp> ./render.sh`) and check the output parses; Kubernetes output must build
  with `kubectl kustomize`.
- Settings files are substituted as text: no `#`, `&`, `"` or backslashes in values.
