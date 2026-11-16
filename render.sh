#!/usr/bin/env bash
# Observability kit: renders kit.env + apps/<app>/ + templates/ into out/, ready to deploy.
#   cp kit.env.example kit.env   # once; edit it
#   ./render.sh                  # writes out/ and prints the next steps (also in out/NEXT-STEPS.txt)
#   KIT_ENV=staging.env OUT=out-staging ./render.sh    # another settings file / output folder
# Needs bash 4+, sed, awk (Linux, macOS with GNU tools, or Git Bash on Windows). Talks to nothing:
# only the printed commands (kubectl / docker / nomad / systemctl) change anything.
set -euo pipefail
cd "$(dirname "$0")"

OUT=${OUT:-out}
T=templates
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

die()  { echo "render.sh: $*" >&2; exit 1; }
warn() { echo "render.sh: warning: $*" >&2; }

KIT_ENV=${KIT_ENV:-kit.env}
[ -f "$KIT_ENV" ] || die "$KIT_ENV not found: cp kit.env.example kit.env, then edit it"
case $KIT_ENV in /*) ;; *) KIT_ENV=./$KIT_ENV ;; esac
set -a; . "$KIT_ENV"; set +a

# ============================================================================ settings
def() { [ -n "${!1:-}" ] || printf -v "$1" '%s' "$2"; }   # def VAR default: set when empty

def TARGET kubernetes
def STACK_NAME observability
def ENVIRONMENT production
def APPS ""
def SIZE medium
def GRAFANA_MODE bundled
def GRAFANA_PORT 3000
def INFRA_METRICS auto
def BIND_ADDRESS 0.0.0.0
def ADMIN_BIND_ADDRESS 127.0.0.1
def NOMAD_DATACENTERS '"dc1"'
def NOMAD_NAMESPACE default
def NOMAD_ADDR 'http://[[[ env "attr.unique.network.ip-address" ]]]:4646'
def CONFIG_DIR /etc/observability
def DATA_DIR /var/lib/observability
def DASHBOARD_NAMESPACE cattle-dashboards
def FEDERATE_FROM prometheus-operated.cattle-monitoring-system.svc:9090
def TRACE_SAMPLE_RATIO 1.0
def DROP_PATHS_REGEX '^/(health|healthz|livez?|readyz?|ping|metrics|actuator/(health|info|prometheus).*)$'
def GRAFANA_VOLUME 1Gi
for v in STORAGE_CLASS GRAFANA_INGRESS_HOST GRAFANA_INGRESS_CLASS SPAN_METRICS_DIMENSIONS \
         PROMETHEUS_URL_FOR_GRAFANA TEMPO_URL_FOR_GRAFANA NOMAD_NODE_NAME HOST_LABEL; do def "$v" ""; done
for v in IMAGE_OTEL_COLLECTOR IMAGE_PROMETHEUS IMAGE_TEMPO IMAGE_GRAFANA IMAGE_JAVA_AGENT \
         IMAGE_CADVISOR IMAGE_NODE_EXPORTER JAVA_AGENT_URL; do
  [ -n "${!v:-}" ] || die "$v is empty in kit.env"
done

case $TARGET in kubernetes|compose|nomad|host) ;; *) die "TARGET must be kubernetes, compose, nomad or host (is '$TARGET')" ;; esac
[[ $STACK_NAME =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || die "STACK_NAME '$STACK_NAME': lower-case letters, digits and '-' only"
case $GRAFANA_MODE in
  bundled|api) ;;
  sidecar) [ "$TARGET" = kubernetes ] || die "GRAFANA_MODE=sidecar needs TARGET=kubernetes (use bundled or api)" ;;
  *) die "GRAFANA_MODE must be bundled, sidecar or api (is '$GRAFANA_MODE')" ;;
esac
if [ "$INFRA_METRICS" = auto ]; then
  case $TARGET in kubernetes) INFRA_METRICS=federate ;; compose) INFRA_METRICS=cadvisor ;; nomad) INFRA_METRICS=nomad ;; host) INFRA_METRICS=node ;; esac
fi
case "$TARGET/$INFRA_METRICS" in
  kubernetes/federate|compose/cadvisor|nomad/nomad|host/node|*/none) ;;
  *) die "INFRA_METRICS=$INFRA_METRICS does not work with TARGET=$TARGET (see kit.env)" ;;
esac
[[ $TRACE_SAMPLE_RATIO =~ ^(0(\.[0-9]+)?|1(\.0+)?)$ ]] || die "TRACE_SAMPLE_RATIO must be between 0 and 1 (is '$TRACE_SAMPLE_RATIO')"
[[ $GRAFANA_PORT =~ ^[0-9]+$ ]] || die "GRAFANA_PORT must be a number"
[ "$TARGET" != nomad ] || [ -n "$NOMAD_NODE_NAME" ] || die "TARGET=nomad needs NOMAD_NODE_NAME (the node the stack's volumes live on)"
[ -n "$APPS" ] || warn "APPS is empty: only the stack is rendered (no dashboards, no instrumentation)"

# ---------------------------------------------------------------------------- sizing
#                     prom-time prom-size prom-vol prom-req prom-lim tempo-ret tempo-vol tempo-req tempo-lim gw-req gw-lim graf-req graf-lim
case $SIZE in
  small)  preset=(7d 4GB 6Gi 256Mi 1Gi 48h 10Gi 256Mi 1Gi 64Mi 256Mi 64Mi 256Mi) ;;
  medium) preset=(3d 8GB 10Gi 512Mi 3Gi 24h 30Gi 512Mi 4Gi 128Mi 512Mi 128Mi 512Mi) ;;   # measured: 10 Java services, ~260 req/s
  large)  preset=(3d 16GB 20Gi 1Gi 6Gi 24h 60Gi 1Gi 8Gi 256Mi 1Gi 256Mi 1Gi) ;;
  *) die "SIZE must be small, medium or large (is '$SIZE')" ;;
esac
sized=(PROMETHEUS_RETENTION_TIME PROMETHEUS_RETENTION_SIZE PROMETHEUS_VOLUME PROMETHEUS_MEMORY_REQUEST PROMETHEUS_MEMORY_LIMIT
       TEMPO_RETENTION TEMPO_VOLUME TEMPO_MEMORY_REQUEST TEMPO_MEMORY_LIMIT GATEWAY_MEMORY_REQUEST GATEWAY_MEMORY_LIMIT
       GRAFANA_MEMORY_REQUEST GRAFANA_MEMORY_LIMIT)
for i in "${!sized[@]}"; do def "${sized[$i]}" "${preset[$i]}"; done
for v in PROMETHEUS_MEMORY_REQUEST PROMETHEUS_MEMORY_LIMIT TEMPO_MEMORY_REQUEST TEMPO_MEMORY_LIMIT \
         GATEWAY_MEMORY_REQUEST GATEWAY_MEMORY_LIMIT GRAFANA_MEMORY_REQUEST GRAFANA_MEMORY_LIMIT \
         PROMETHEUS_VOLUME TEMPO_VOLUME GRAFANA_VOLUME; do
  [[ ${!v} =~ ^[1-9][0-9]*(Mi|Gi)$ ]] || die "$v must be a whole number of Mi or Gi (is '${!v}')"
done
mem_mb()      { local n=${1%??}; case $1 in *Gi) echo $((n * 1024)) ;; *) echo "$n" ;; esac; }
mem_compose() { local n=${1%??}; case $1 in *Gi) echo "${n}g" ;; *) echo "${n}m" ;; esac; }
mem_systemd() { local n=${1%??}; case $1 in *Gi) echo "${n}G" ;; *) echo "${n}M" ;; esac; }
for c in PROMETHEUS TEMPO GATEWAY GRAFANA; do
  lim="${c}_MEMORY_LIMIT"
  printf -v "${c}_MEMORY_LIMIT_MB" '%s' "$(mem_mb "${!lim}")"
  printf -v "${c}_MEMORY_LIMIT_COMPOSE" '%s' "$(mem_compose "${!lim}")"
  printf -v "${c}_MEMORY_LIMIT_SYSTEMD" '%s' "$(mem_systemd "${!lim}")"
done

# ---------------------------------------------------------------------------- apps (first pass)
declare -A APP_DASHBOARDS=()
needs_user_action=
for app in $APPS; do
  [[ $app =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || die "app name '$app': lower-case letters, digits and '-' only"
  [ -f "apps/$app/app.env" ] || die "apps/$app/app.env not found (copy apps/example)"
  dl=$(
    DASHBOARDS=
    set -a; . "apps/$app/app.env"; set +a
    if [ -z "$DASHBOARDS" ]; then
      DASHBOARDS="traces service-overview"
      case "$TARGET/$INFRA_METRICS" in
        kubernetes/federate) DASHBOARDS="$DASHBOARDS kubernetes-resources" ;;
        kubernetes/*|*/none) ;;
        *) DASHBOARDS="$DASHBOARDS containers-hosts" ;;
      esac
    fi
    echo "$DASHBOARDS"
  )
  for d in $dl; do
    [ -f "$T/dashboards/$d.json" ] || die "apps/$app: unknown dashboard '$d' (see templates/dashboards/)"
    [ "$d" != kubernetes-resources ] || [ "$INFRA_METRICS" = federate ] \
      || warn "apps/$app: kubernetes-resources needs INFRA_METRICS=federate; its resource panels stay empty"
    [ "$d" != containers-hosts ] || [ "$TARGET" != kubernetes ] \
      || warn "apps/$app: containers-hosts is for compose / nomad / host; use kubernetes-resources"
    [ "$d" != user-actions ] || needs_user_action=1
  done
  APP_DASHBOARDS[$app]=$dl
done

# Span metrics dimensions: "a, b" -> "a, b"; user-actions needs user.action.
SPAN_METRICS_DIMENSIONS=$(echo "$SPAN_METRICS_DIMENSIONS" | tr -d ' ' | sed 's/,/, /g')
if [ -n "$needs_user_action" ] && ! [[ ", $SPAN_METRICS_DIMENSIONS," == *", user.action,"* ]]; then
  SPAN_METRICS_DIMENSIONS=${SPAN_METRICS_DIMENSIONS:+$SPAN_METRICS_DIMENSIONS, }user.action
  echo "render.sh: note: added user.action to SPAN_METRICS_DIMENSIONS (an app uses the user-actions dashboard)"
fi

# ---------------------------------------------------------------------------- derived addresses
if [ -z "$HOST_LABEL" ]; then
  case $TARGET in
    nomad) HOST_LABEL=$NOMAD_NODE_NAME ;;
    *) HOST_LABEL=$(hostname 2>/dev/null || echo localhost)
       [ "$TARGET" = kubernetes ] || warn "HOST_LABEL is empty: using this machine's name '$HOST_LABEL' (set it if the stack runs elsewhere)" ;;
  esac
fi
# address the stack's own components use to reach ports bound to ADMIN_BIND_ADDRESS
if [ "$ADMIN_BIND_ADDRESS" = 0.0.0.0 ]; then ADMIN_LOCAL=127.0.0.1; else ADMIN_LOCAL=$ADMIN_BIND_ADDRESS; fi
if [ "$BIND_ADDRESS" = 0.0.0.0 ]; then OTLP_HOST=$HOST_LABEL; else OTLP_HOST=$BIND_ADDRESS; fi

case $TARGET in
  kubernetes)
    GATEWAY_HOST=otel-gateway; TEMPO_HOST=tempo; PROMETHEUS_HOST=prometheus
    TEMPO_OTLP_LISTEN=0.0.0.0:4317; TEMPO_OTLP_ENDPOINT=tempo:4317; COLLECTOR_INTERNAL_ADDRESS=0.0.0.0; OTLP_LISTEN_ADDRESS=0.0.0.0
    def PROMETHEUS_URL_FOR_GRAFANA "http://prometheus.$STACK_NAME.svc:9090"
    def TEMPO_URL_FOR_GRAFANA "http://tempo.$STACK_NAME.svc:3200"
    OTLP_ENDPOINT="http://otel-gateway.$STACK_NAME.svc:4317"
    LOGS_HINT="kubectl -n $STACK_NAME logs deploy/otel-gateway" ;;
  compose)
    GATEWAY_HOST=otel-collector; TEMPO_HOST=tempo; PROMETHEUS_HOST=prometheus
    TEMPO_OTLP_LISTEN=0.0.0.0:4317; TEMPO_OTLP_ENDPOINT=tempo:4317; COLLECTOR_INTERNAL_ADDRESS=0.0.0.0; OTLP_LISTEN_ADDRESS=0.0.0.0
    if [ "$GRAFANA_MODE" = bundled ]; then
      def PROMETHEUS_URL_FOR_GRAFANA http://prometheus:9090; def TEMPO_URL_FOR_GRAFANA http://tempo:3200
    fi
    OTLP_ENDPOINT="http://$OTLP_HOST:4317"
    LOGS_HINT="docker compose -p $STACK_NAME logs otel-collector" ;;
  nomad|host)
    GATEWAY_HOST=$ADMIN_LOCAL; TEMPO_HOST=$ADMIN_LOCAL; PROMETHEUS_HOST=$ADMIN_LOCAL
    TEMPO_OTLP_LISTEN=127.0.0.1:4319; TEMPO_OTLP_ENDPOINT=127.0.0.1:4319; COLLECTOR_INTERNAL_ADDRESS=$ADMIN_LOCAL
    OTLP_LISTEN_ADDRESS=$BIND_ADDRESS
    if [ "$GRAFANA_MODE" = bundled ]; then
      def PROMETHEUS_URL_FOR_GRAFANA "http://$ADMIN_LOCAL:9090"; def TEMPO_URL_FOR_GRAFANA "http://$ADMIN_LOCAL:3200"
    fi
    OTLP_ENDPOINT="http://$OTLP_HOST:4317"
    if [ "$TARGET" = nomad ]; then LOGS_HINT="nomad alloc logs -job $STACK_NAME otel-collector"
    else LOGS_HINT="journalctl -u $STACK_NAME-otel-collector"; fi ;;
esac
# api mode outside Kubernetes: how the existing Grafana reaches Prometheus / Tempo
if [ "$ADMIN_BIND_ADDRESS" = 0.0.0.0 ]; then admin_ext=$HOST_LABEL; else admin_ext=$ADMIN_BIND_ADDRESS; fi
def PROMETHEUS_URL_FOR_GRAFANA "http://$admin_ext:9090"
def TEMPO_URL_FOR_GRAFANA "http://$admin_ext:3200"
if [ "$GRAFANA_MODE" = api ] && [ "$TARGET" != kubernetes ] && [ "$admin_ext" = 127.0.0.1 ]; then
  warn "GRAFANA_MODE=api with ADMIN_BIND_ADDRESS=127.0.0.1: Grafana must run on the stack's host (outside Docker), or set PROMETHEUS_URL_FOR_GRAFANA / TEMPO_URL_FOR_GRAFANA and ADMIN_BIND_ADDRESS"
fi

if [ "$TRACE_SAMPLE_RATIO" = 1 ] || [[ $TRACE_SAMPLE_RATIO =~ ^1\.0+$ ]]; then
  OTEL_TRACES_SAMPLER=parentbased_always_on
else
  OTEL_TRACES_SAMPLER=parentbased_traceidratio
fi
case $TARGET in host) JAVA_AGENT_PATH=/opt/otel/opentelemetry-javaagent.jar ;; *) JAVA_AGENT_PATH=/otel/opentelemetry-javaagent.jar ;; esac

ver() { local t=${1##*:}; echo "${t#v}"; }
OTELCOL_VERSION=$(ver "$IMAGE_OTEL_COLLECTOR"); PROMETHEUS_VERSION=$(ver "$IMAGE_PROMETHEUS")
TEMPO_VERSION=$(ver "$IMAGE_TEMPO"); GRAFANA_VERSION=$(ver "$IMAGE_GRAFANA"); NODE_EXPORTER_VERSION=$(ver "$IMAGE_NODE_EXPORTER")
HOST_SERVICES="prometheus tempo otel-collector"
[ "$GRAFANA_MODE" = bundled ] && HOST_SERVICES="$HOST_SERVICES grafana"
[ "$INFRA_METRICS" = node ] && HOST_SERVICES="$HOST_SERVICES node-exporter"

# ---------------------------------------------------------------------------- template tags
TAGS="$TARGET infra-$INFRA_METRICS grafana-$GRAFANA_MODE"
[ -n "$STORAGE_CLASS" ] && TAGS="$TAGS storage-class"
if [ "$TARGET" = kubernetes ] && [ "$GRAFANA_MODE" = bundled ] && [ -n "$GRAFANA_INGRESS_HOST" ]; then
  TAGS="$TAGS ingress"; [ -n "$GRAFANA_INGRESS_CLASS" ] && TAGS="$TAGS ingress-class"
fi
[ "$TARGET" = compose ] && TAGS="$TAGS same-host"

# ============================================================================ helpers
# Placeholders @@KEY@@ are replaced by a sed script; values are literal text.
STACK_VARS=(TARGET STACK_NAME ENVIRONMENT GRAFANA_PORT BIND_ADDRESS ADMIN_BIND_ADDRESS STORAGE_CLASS
  GRAFANA_INGRESS_HOST GRAFANA_INGRESS_CLASS DASHBOARD_NAMESPACE FEDERATE_FROM
  NOMAD_DATACENTERS NOMAD_NAMESPACE NOMAD_NODE_NAME NOMAD_ADDR CONFIG_DIR DATA_DIR HOST_LABEL
  DROP_PATHS_REGEX SPAN_METRICS_DIMENSIONS TRACE_SAMPLE_RATIO OTEL_TRACES_SAMPLER
  "${sized[@]}" GRAFANA_VOLUME
  PROMETHEUS_MEMORY_LIMIT_MB TEMPO_MEMORY_LIMIT_MB GATEWAY_MEMORY_LIMIT_MB GRAFANA_MEMORY_LIMIT_MB
  PROMETHEUS_MEMORY_LIMIT_COMPOSE TEMPO_MEMORY_LIMIT_COMPOSE GATEWAY_MEMORY_LIMIT_COMPOSE GRAFANA_MEMORY_LIMIT_COMPOSE
  PROMETHEUS_MEMORY_LIMIT_SYSTEMD TEMPO_MEMORY_LIMIT_SYSTEMD GATEWAY_MEMORY_LIMIT_SYSTEMD GRAFANA_MEMORY_LIMIT_SYSTEMD
  GATEWAY_HOST TEMPO_HOST PROMETHEUS_HOST TEMPO_OTLP_LISTEN TEMPO_OTLP_ENDPOINT COLLECTOR_INTERNAL_ADDRESS OTLP_LISTEN_ADDRESS
  PROMETHEUS_URL_FOR_GRAFANA TEMPO_URL_FOR_GRAFANA OTLP_ENDPOINT LOGS_HINT JAVA_AGENT_PATH
  IMAGE_OTEL_COLLECTOR IMAGE_PROMETHEUS IMAGE_TEMPO IMAGE_GRAFANA IMAGE_JAVA_AGENT IMAGE_CADVISOR
  IMAGE_NODE_EXPORTER JAVA_AGENT_URL
  OTELCOL_VERSION PROMETHEUS_VERSION TEMPO_VERSION GRAFANA_VERSION NODE_EXPORTER_VERSION HOST_SERVICES)

sed_var() {   # sed_var SCRIPT KEY VALUE
  local v=$3
  [[ $v != *$'\n'* ]] || die "value of $2 contains a line break"
  v=${v//\\/\\\\}; v=${v//&/\\&}
  printf 's\001@@%s@@\001%s\001g\n' "$2" "$v" >> "$1"
}
STACK_SED=$TMP/stack.sed
: > "$STACK_SED"
for k in "${STACK_VARS[@]}"; do sed_var "$STACK_SED" "$k" "${!k}"; done
# container paths -> paths on the host / in the Nomad task
case $TARGET in
  nomad)
    printf '%s\n' 's#/etc/prometheus/rules/#/local/rules/#g' 's#/var/lib/grafana/dashboards#/local/dashboards#g' >> "$STACK_SED" ;;
  host)
    printf '%s\n' "s#/etc/prometheus/rules/#$CONFIG_DIR/prometheus/rules/#g" "s#/var/tempo#$DATA_DIR/tempo#g" \
      "s#/var/lib/grafana/dashboards#$CONFIG_DIR/grafana/dashboards#g" >> "$STACK_SED" ;;
esac

# filter_tags: keep lines between "#@if a|b|!c" and "#@endif" only when a tag matches (nestable)
filter_tags() {
  awk -v tags=" $TAGS " '
    function active(expr,   n, i, a, t, neg) {
      n = split(expr, a, "|")
      for (i = 1; i <= n; i++) {
        t = a[i]; neg = 0
        if (substr(t, 1, 1) == "!") { neg = 1; t = substr(t, 2) }
        if ((index(tags, " " t " ") > 0) != neg) return 1
      }
      return 0
    }
    BEGIN { depth = 0; ok[0] = 1 }
    /^[ \t]*#@if[ \t]/ { e = $0; sub(/^[ \t]*#@if[ \t]+/, "", e); sub(/[ \t\r]+$/, "", e)
                         depth++; ok[depth] = ok[depth - 1] && active(e); next }
    /^[ \t]*#@endif/   { if (depth == 0) { print "render.sh: unbalanced #@endif in " FILENAME > "/dev/stderr"; exit 1 }
                         depth--; next }
    ok[depth] { print }
    END { if (depth != 0) { print "render.sh: unclosed #@if in " FILENAME > "/dev/stderr"; exit 1 } }' "$1"
}

# render SRC DST [SED]: tags, then placeholders
render() {
  mkdir -p "$(dirname "$2")"
  filter_tags "$1" | sed -f "${3:-$STACK_SED}" > "$2"
}

# replace_marker FILE MARKER CONTENT: the line holding @@MARKER@@ becomes CONTENT, indented like it
# (an empty CONTENT removes the line)
replace_marker() {
  awk -v m="@@$2@@" -v c="$3" '
    index($0, m) { ind = $0; sub(/[^ ].*$/, "", ind)
                   while ((getline l < c) > 0) print (l == "" ? "" : ind l)
                   close(c); next }
    { print }' "$1" > "$1.tmp" && mv "$1.tmp" "$1"
}

# load_app APP: app settings in the current (sub)shell + its sed script in $APP_SED
load_app() {
  local kit_env=$ENVIRONMENT
  APP_NAME=; ENVIRONMENT=; SERVICE_REGEX=; DASHBOARD_FOLDER=; DASHBOARD_UID_PREFIX=; DASHBOARD_TITLE_PREFIX=
  CONTAINER_REGEX=; APP_NAMESPACE=; TARGETS=
  set -a; . "apps/$1/app.env"; set +a
  APP_NAME=${APP_NAME:-$1}
  ENVIRONMENT=${ENVIRONMENT:-$kit_env}
  CONTAINER_REGEX=${CONTAINER_REGEX:-.*}
  DASHBOARD_FOLDER=${DASHBOARD_FOLDER:-$APP_NAME}
  [ -n "$SERVICE_REGEX" ] || die "apps/$1: SERVICE_REGEX is empty"
  [[ $DASHBOARD_FOLDER != */* ]] || die "apps/$1: DASHBOARD_FOLDER may not contain '/'"
  if [ "$TARGET" = kubernetes ]; then def APP_NAMESPACE "$APP_NAME"; else APP_NAMESPACE=${APP_NAMESPACE:-none}; fi
  APP_SED=$TMP/app-$1.sed
  : > "$APP_SED"
  sed_var "$APP_SED" APP_NAME "$APP_NAME"
  sed_var "$APP_SED" ENVIRONMENT "$ENVIRONMENT"
  sed_var "$APP_SED" SERVICE_REGEX "$SERVICE_REGEX"
  sed_var "$APP_SED" CONTAINER_REGEX "$CONTAINER_REGEX"
  sed_var "$APP_SED" APP_NAMESPACE "$APP_NAMESPACE"
  sed_var "$APP_SED" UID_PREFIX "$DASHBOARD_UID_PREFIX"
  sed_var "$APP_SED" TITLE_PREFIX "$DASHBOARD_TITLE_PREFIX"
  cat "$STACK_SED" >> "$APP_SED"   # app values first: they win
}

# ============================================================================ output
if [ -d "$OUT" ]; then   # files first: on Windows a folder that is a shell's cwd cannot be removed
  find "$OUT" -mindepth 1 -type f -delete
  find "$OUT" -mindepth 1 -depth -type d -empty -delete 2>/dev/null || true
fi
S=$OUT/stack
mkdir -p "$S"

# Grafana admin password (bundled): generated once, kept in secrets/ (not in out/, not in git)
GRAFANA_ADMIN_PASSWORD=
if [ "$GRAFANA_MODE" = bundled ]; then
  if [ ! -s secrets/grafana-admin-password ]; then
    mkdir -p secrets
    pw=$(head -c 32 /dev/urandom | base64 | tr -d '/+=\n')
    (umask 077; printf '%s\n' "${pw:0:24}" > secrets/grafana-admin-password)
    echo "render.sh: generated secrets/grafana-admin-password"
  fi
  GRAFANA_ADMIN_PASSWORD=$(tr -d '\r\n' < secrets/grafana-admin-password)
fi

# ---------------------------------------------------------------------------- common configs
CFG=$S/config
render "$T/common/otel-collector/config.yaml" "$CFG/otel-collector/config.yaml"
render "$T/common/prometheus/prometheus.yml" "$CFG/prometheus/prometheus.yml"
render "$T/common/prometheus/rules/alerts.yml" "$CFG/prometheus/rules/alerts.yml"
render "$T/common/tempo/tempo.yaml" "$CFG/tempo/tempo.yaml"

# Prometheus: per-app federation selectors (kubernetes) and optional extra scrape jobs
federate=$TMP/federate.yml; : > "$federate"
if [ "$INFRA_METRICS" = federate ]; then
  for app in $APPS; do
    (
      load_app "$app"
      cat <<EOF
# app $APP_NAME: its pods and deployments in $APP_NAMESPACE
- '{__name__=~"container_cpu_usage_seconds_total|container_memory_working_set_bytes|kube_pod_container_status_restarts_total|kube_pod_info", namespace="$APP_NAMESPACE", pod=~"($SERVICE_REGEX)-[a-z0-9]+-[a-z0-9]+"}'
- '{__name__=~"kube_deployment_status_replicas_ready|kube_deployment_spec_replicas", namespace="$APP_NAMESPACE", deployment=~"$SERVICE_REGEX"}'
EOF
    ) >> "$federate"
  done
fi
replace_marker "$CFG/prometheus/prometheus.yml" FEDERATE_APPS "$federate"
if [ -f extra-scrape.yml ]; then
  replace_marker "$CFG/prometheus/prometheus.yml" EXTRA_SCRAPE extra-scrape.yml
else
  replace_marker "$CFG/prometheus/prometheus.yml" EXTRA_SCRAPE /dev/null
fi

# Grafana datasources + dashboard provider (bundled: provisioning files)
DS=$TMP/datasources.yaml
render "$T/common/grafana/datasources.yaml" "$DS"

# ---------------------------------------------------------------------------- dashboards
# Every app's dashboards into $TMP/dash/<app>/<app>-<dashboard>.json
for app in $APPS; do
  (
    load_app "$app"
    for d in ${APP_DASHBOARDS[$app]}; do
      render "$T/dashboards/$d.json" "$TMP/dash/$app/$app-$d.json" "$APP_SED"
    done
    printf '%s\n' "$DASHBOARD_FOLDER" > "$TMP/dash/$app/.folder"
  )
done
folder_of() { cat "$TMP/dash/$1/.folder"; }
if [ "$TARGET" = kubernetes ] && [ "$GRAFANA_MODE" = bundled ]; then
  dup=$(for app in $APPS; do folder_of "$app"; done | sort | uniq -d | head -1)
  [ -z "$dup" ] || die "two apps use DASHBOARD_FOLDER '$dup': with TARGET=kubernetes and GRAFANA_MODE=bundled each app needs its own folder"
fi

# bundled Grafana outside Kubernetes: provisioning folder next to the stack
if [ "$GRAFANA_MODE" = bundled ] && [ "$TARGET" != kubernetes ]; then
  mkdir -p "$S/grafana/provisioning/datasources" "$S/grafana/provisioning/dashboards"
  cp "$DS" "$S/grafana/provisioning/datasources/datasources.yaml"
  render "$T/common/grafana/dashboards-provider.yaml" "$S/grafana/provisioning/dashboards/provider.yaml"
  for app in $APPS; do
    f=$(folder_of "$app"); mkdir -p "$S/grafana/dashboards/$f"
    cp "$TMP/dash/$app/"*.json "$S/grafana/dashboards/$f/"
  done
fi

# api: import script + datasources + dashboards
if [ "$GRAFANA_MODE" = api ]; then
  G=$OUT/grafana-api
  render "$T/common/grafana/import.sh" "$G/import.sh"; chmod +x "$G/import.sh"
  render "$T/common/grafana/api/obs-prometheus.json" "$G/datasources/obs-prometheus.json"
  render "$T/common/grafana/api/obs-tempo.json" "$G/datasources/obs-tempo.json"
  for app in $APPS; do
    mkdir -p "$G/dashboards/$app"
    cp "$TMP/dash/$app/"*.json "$G/dashboards/$app/"
    title=$(folder_of "$app"); title=${title//\\/\\\\}; title=${title//\"/\\\"}
    printf '{"uid":"obs-%s","title":"%s"}\n' "$app" "$title" > "$G/dashboards/$app/folder.json"
  done
fi

# ============================================================================ per target
case $TARGET in
# ---------------------------------------------------------------------------- kubernetes
kubernetes)
  for f in namespace rbac otel-gateway prometheus tempo kustomization; do
    render "$T/kubernetes/core/$f.yaml" "$S/$f.yaml"
  done

  case $GRAFANA_MODE in
  bundled)
    K=$OUT/grafana
    render "$T/kubernetes/grafana/grafana.yaml" "$K/grafana.yaml"
    cp "$DS" "$K/datasources.yaml"
    render "$T/common/grafana/dashboards-provider.yaml" "$K/provider.yaml"
    printf '%s' "$GRAFANA_ADMIN_PASSWORD" > "$K/admin-password"
    mounts=$TMP/mounts.yml; vols=$TMP/vols.yml; gens=$TMP/gens.yml; : > "$mounts"; : > "$vols"; : > "$gens"
    for app in $APPS; do
      f=$(folder_of "$app")
      mkdir -p "$K/dashboards/$app"; cp "$TMP/dash/$app/"*.json "$K/dashboards/$app/"
      printf -- '- name: dashboards-%s\n  mountPath: "/var/lib/grafana/dashboards/%s"\n  readOnly: true\n' "$app" "$f" >> "$mounts"
      printf -- '- name: dashboards-%s\n  projected:\n    sources:\n' "$app" >> "$vols"
      for j in "$K/dashboards/$app/"*.json; do
        b=$(basename "$j" .json)
        printf -- '      - configMap: { name: dash-%s }\n' "$b" >> "$vols"
        printf -- '  - name: dash-%s\n    files: [dashboards/%s/%s.json]\n' "$b" "$app" "$b" >> "$gens"
      done
    done
    replace_marker "$K/grafana.yaml" DASHBOARD_MOUNTS "$mounts"
    replace_marker "$K/grafana.yaml" DASHBOARD_VOLUMES "$vols"
    {
      echo "# Bundled Grafana of the observability stack $STACK_NAME. Generated by render.sh."
      echo "#   kubectl apply -k .     (after the stack: kubectl apply -k ../stack)"
      echo "apiVersion: kustomize.config.k8s.io/v1beta1"
      echo "kind: Kustomization"
      echo "namespace: $STACK_NAME"
      echo "labels:"
      echo "  - pairs:"
      echo "      app.kubernetes.io/part-of: $STACK_NAME"
      echo "resources: [grafana.yaml]"
      echo "secretGenerator:"
      echo "  - name: grafana-admin"
      echo "    files: [password=admin-password]"
      echo "configMapGenerator:"
      echo "  - name: grafana-datasources"
      echo "    files: [datasources.yaml]"
      echo "  - name: grafana-dashboard-provider"
      echo "    files: [provider.yaml]"
      cat "$gens"
    } > "$K/kustomization.yaml"
    ;;
  sidecar)
    mkdir -p "$OUT/grafana"
    render "$T/kubernetes/grafana/values-grafana.yaml" "$OUT/grafana/values-grafana.yaml"
    sed -n '/^datasources:/,$p' "$DS" | sed '1d; s/^  //' > "$TMP/ds-list.yml"
    replace_marker "$OUT/grafana/values-grafana.yaml" DATASOURCES "$TMP/ds-list.yml"
    for app in $APPS; do
      (
        load_app "$app"
        D=$OUT/apps/$app/dashboards; mkdir -p "$D"; cp "$TMP/dash/$app/"*.json "$D/"
        {
          echo "# Grafana dashboards of app $APP_NAME (Grafana dashboard sidecar). Generated by render.sh."
          echo "#   kubectl apply -k ."
          echo "apiVersion: kustomize.config.k8s.io/v1beta1"
          echo "kind: Kustomization"
          echo "namespace: $DASHBOARD_NAMESPACE"
          echo "generatorOptions:"
          echo "  disableNameSuffixHash: true"
          echo "  labels:"
          echo "    grafana_dashboard: \"1\""
          echo "    app.kubernetes.io/part-of: $STACK_NAME"
          echo "    observability.app: $APP_NAME"
          echo "  annotations:"
          echo "    grafana_folder: \"$DASHBOARD_FOLDER\""
          echo "configMapGenerator:"
          for j in "$D/"*.json; do
            b=$(basename "$j" .json)
            printf '  - name: %s-%s\n    files: [%s.json]\n' "$STACK_NAME" "$b" "$b"
          done
        } > "$D/kustomization.yaml"
      )
    done
    ;;
  esac

  # instrumentation: one strategic-merge patch per deployment
  for app in $APPS; do
    (
      load_app "$app"
      I=$OUT/apps/$app/instrumentation; mkdir -p "$I"
      deps=()
      for t in $TARGETS; do
        IFS=: read -r dep cont mode <<< "$t"
        cont=${cont:-$dep}; mode=${mode:-java}
        case $mode in java) tpl=java-agent-patch ;; env) tpl=env-patch ;; *) die "apps/$app: TARGETS '$t': mode must be java or env" ;; esac
        [[ $dep =~ ^[a-z0-9]([-a-z0-9.]*[a-z0-9])?$ ]] || die "apps/$app: '$dep' is not a deployment name"
        [[ $dep =~ ^($SERVICE_REGEX)$ ]] || warn "apps/$app: deployment $dep does not match SERVICE_REGEX '$SERVICE_REGEX' (it will not show in the dashboards)"
        deps+=("$dep")
        dsed=$TMP/dep-$app-$dep.sed
        : > "$dsed"
        sed_var "$dsed" DEPLOYMENT "$dep"; sed_var "$dsed" CONTAINER "$cont"; sed_var "$dsed" SERVICE "$dep"
        cat "$APP_SED" >> "$dsed"
        patch=$I/$dep.yaml
        render "$T/kubernetes/instrumentation/$tpl.yaml" "$patch" "$dsed"
        render "$T/kubernetes/instrumentation/otel-env.yaml" "$TMP/env-$app-$dep.yml" "$dsed"
        replace_marker "$patch" OTEL_ENV "$TMP/env-$app-$dep.yml"
        o=apps/$app/overrides/$dep.yaml;      [ -f "$o" ] || o=/dev/null
        replace_marker "$patch" CONTAINER_OVERRIDES "$o"
        o=apps/$app/overrides/$dep.init.yaml; [ -f "$o" ] || o=/dev/null
        replace_marker "$patch" INIT_OVERRIDES "$o"
      done
      [ ${#deps[@]} -gt 0 ] || { warn "apps/$app: TARGETS is empty, no instrumentation"; exit 0; }

      cat > "$I/apply.sh" <<EOF
#!/usr/bin/env bash
# Adds OpenTelemetry to app $APP_NAME (namespace $APP_NAMESPACE). Generated by render.sh.
#   ./apply.sh                     all deployments
#   ./apply.sh ${deps[0]}          one deployment (try one first)
#   DRY_RUN=server ./apply.sh      validate only, changes nothing
# Each patch is a rolling restart of that deployment. All are patched first and waited for after,
# so they roll in parallel; every deployment still replaces one pod at a time.
# Undo for one deployment: kubectl -n $APP_NAMESPACE rollout undo deployment/<name>
set -euo pipefail
cd "\$(dirname "\$0")"
NAMESPACE=$APP_NAMESPACE
DEPLOYMENTS=(${deps[*]})
[ \$# -gt 0 ] && DEPLOYMENTS=("\$@")
for d in "\${DEPLOYMENTS[@]}"; do
  kubectl -n "\$NAMESPACE" patch deployment "\$d" --type strategic --patch-file "\$d.yaml" \${DRY_RUN:+--dry-run=\$DRY_RUN}
done
[ -n "\${DRY_RUN:-}" ] && exit 0
for d in "\${DEPLOYMENTS[@]}"; do
  kubectl -n "\$NAMESPACE" rollout status deployment "\$d" --timeout=45m
done
EOF
      cat > "$I/helm-post-renderer.sh" <<'EOF'
#!/usr/bin/env bash
# Helm post-renderer for Helm-managed apps: applies the patches in this folder to the chart's
# Deployments, so `helm upgrade` keeps OpenTelemetry. Generated by render.sh.
#   helm upgrade <release> <chart> -n <namespace> --reuse-values --post-renderer <path>/helm-post-renderer.sh
# Reads the chart's manifests on stdin, writes them patched to stdout. Needs kubectl (kustomize).
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
dir=$(mktemp -d); trap 'rm -rf "$dir"' EXIT
cat > "$dir/all.yaml"
{ echo "resources: [all.yaml]"; echo "patches:"; } > "$dir/kustomization.yaml"
for f in "$here"/*.yaml; do
  d=$(basename "$f" .yaml)
  { printf 'apiVersion: apps/v1\nkind: Deployment\nmetadata:\n  name: %s\n' "$d"; grep -v '^#' "$f"; } > "$dir/patch-$d.yaml"
  printf '  - path: patch-%s.yaml\n    target: {kind: Deployment, name: %s}\n' "$d" "$d" >> "$dir/kustomization.yaml"
done
kubectl kustomize "$dir"
EOF
      chmod +x "$I/apply.sh" "$I/helm-post-renderer.sh"
    )
  done
  ;;

# ---------------------------------------------------------------------------- compose
compose)
  render "$T/compose/docker-compose.yml" "$S/docker-compose.yml"
  if [ "$GRAFANA_MODE" = bundled ]; then
    (umask 077; printf '# Grafana admin password (first start only). Generated by render.sh.\nGRAFANA_ADMIN_PASSWORD=%s\n' "$GRAFANA_ADMIN_PASSWORD" > "$S/.env")
  fi
  ;;

# ---------------------------------------------------------------------------- nomad
nomad)
  render "$T/nomad/observability.nomad.hcl" "$S/observability.nomad.hcl"
  render "$T/nomad/client-host-volumes.hcl" "$S/client-host-volumes.hcl"
  [ "$INFRA_METRICS" = nomad ] && render "$T/nomad/infra.nomad.hcl" "$S/infra.nomad.hcl"
  tpls=$TMP/dash-templates.hcl; : > "$tpls"
  if [ "$GRAFANA_MODE" = bundled ]; then
    for app in $APPS; do
      f=$(folder_of "$app")
      for j in "$TMP/dash/$app/"*.json; do
        b=$(basename "$j")
        cat >> "$tpls" <<EOF
template {
  data            = file("grafana/dashboards/$f/$b")
  destination     = "local/dashboards/$f/$b"
  left_delimiter  = "[[["
  right_delimiter = "]]]"
  change_mode     = "noop"
}
EOF
      done
    done
    replace_marker "$S/observability.nomad.hcl" GRAFANA_DASHBOARD_TEMPLATES "$tpls"
  fi
  ;;

# ---------------------------------------------------------------------------- host
host)
  render "$T/host/install.sh" "$S/install.sh"; chmod +x "$S/install.sh"
  for s in $HOST_SERVICES; do render "$T/host/systemd/$s.service" "$S/systemd/$s.service"; done
  if [ "$GRAFANA_MODE" = bundled ]; then
    (umask 077; printf 'GF_SECURITY_ADMIN_PASSWORD=%s\n' "$GRAFANA_ADMIN_PASSWORD" > "$S/grafana-admin.env")
  fi
  ;;
esac

# ---------------------------------------------------------------------------- instrumentation (not kubernetes)
if [ "$TARGET" != kubernetes ]; then
  for app in $APPS; do
    (
      load_app "$app"
      I=$OUT/apps/$app/instrumentation
      render "$T/instrumentation/otel.env" "$I/otel.env" "$APP_SED"
      case $TARGET in
        compose) render "$T/instrumentation/docker-compose.otel.yml" "$I/docker-compose.otel.yml" "$APP_SED" ;;
        nomad)   render "$T/instrumentation/otel-task.nomad.hcl" "$I/otel-task.nomad.hcl" "$APP_SED" ;;
        host)    render "$T/instrumentation/systemd-otel.conf" "$I/systemd-otel.conf" "$APP_SED" ;;
      esac
    )
  done
fi

# ============================================================================ checks
if grep -rIn '@@[A-Z_]*@@' "$OUT" >&2; then
  die "unreplaced placeholders (above): a template uses a value render.sh does not know"
fi
if grep -rIln $'\r' "$OUT" >/dev/null 2>&1; then
  warn "some output files contain CR (Windows line endings): check kit.env / app.env / overrides"
fi

# ============================================================================ next steps
N=$OUT/NEXT-STEPS.txt
{
  echo "Observability kit: stack '$STACK_NAME', target $TARGET, size $SIZE, Grafana $GRAFANA_MODE, infra metrics $INFRA_METRICS"
  echo "Apps: ${APPS:-(none)}"
  echo
  case $TARGET in
  kubernetes)
    echo "1. Stack (once per cluster; again after changing kit.env or adding an app):"
    echo "     kubectl diff -k $S ; kubectl apply -k $S"
    case $GRAFANA_MODE in
      bundled) echo "2. Grafana:  kubectl apply -k $OUT/grafana"
               if [ -n "$GRAFANA_INGRESS_HOST" ]; then echo "     https://$GRAFANA_INGRESS_HOST  (user admin, password in secrets/grafana-admin-password)"
               else echo "     kubectl -n $STACK_NAME port-forward svc/grafana 3000  ->  http://localhost:3000 (admin / secrets/grafana-admin-password)"; fi ;;
      sidecar) echo "2. Grafana datasources: merge $OUT/grafana/values-grafana.yaml into the Grafana Helm release (see the file)"
               echo "   Dashboards per app:   kubectl apply -k $OUT/apps/<app>/dashboards" ;;
      api)     echo "2. Grafana:  GRAFANA_URL=... GRAFANA_TOKEN=... $OUT/grafana-api/import.sh" ;;
    esac
    echo "3. Per app, OpenTelemetry on its deployments (rolling restarts):"
    echo "     DRY_RUN=server $OUT/apps/<app>/instrumentation/apply.sh     # validate"
    echo "     $OUT/apps/<app>/instrumentation/apply.sh <one-deployment>   # try one"
    echo "     $OUT/apps/<app>/instrumentation/apply.sh                    # the rest"
    echo "   Helm-managed apps: see README (helm-post-renderer.sh)." ;;
  compose)
    echo "1. Copy $S to the Docker host, then in that folder:  docker compose up -d"
    [ "$GRAFANA_MODE" = bundled ] && echo "   Grafana: http://$OTLP_HOST:$GRAFANA_PORT  (admin / secrets/grafana-admin-password)"
    [ "$GRAFANA_MODE" = api ] && echo "2. Grafana:  GRAFANA_URL=... GRAFANA_TOKEN=... $OUT/grafana-api/import.sh"
    echo "3. Per app: $OUT/apps/<app>/instrumentation/ (otel.env + docker-compose.otel.yml); apps send OTLP to $OTLP_ENDPOINT" ;;
  nomad)
    echo "1. On node $NOMAD_NODE_NAME: create the host volumes in $S/client-host-volumes.hcl (see the file)"
    [ "$GRAFANA_MODE" = bundled ] && echo "2. nomad var put -namespace $NOMAD_NAMESPACE nomad/jobs/$STACK_NAME grafana_admin_password=\"\$(cat secrets/grafana-admin-password)\""
    echo "3. cd $S && nomad job run observability.nomad.hcl"
    [ "$INFRA_METRICS" = nomad ] && echo "   nomad job run infra.nomad.hcl      (node-exporter + cAdvisor on every client)"
    [ "$GRAFANA_MODE" = bundled ] && echo "   Grafana: http://$NOMAD_NODE_NAME:$GRAFANA_PORT  (admin / secrets/grafana-admin-password)"
    [ "$GRAFANA_MODE" = api ] && echo "4. Grafana:  GRAFANA_URL=... GRAFANA_TOKEN=... $OUT/grafana-api/import.sh"
    echo "5. Per app: blocks in $OUT/apps/<app>/instrumentation/otel-task.nomad.hcl (gateway found as service $STACK_NAME-otlp)" ;;
  host)
    echo "1. Copy $S to the monitoring host, then:  sudo ./install.sh --download   (or without --download, see install.sh)"
    [ "$GRAFANA_MODE" = bundled ] && echo "   Grafana: http://$OTLP_HOST:$GRAFANA_PORT  (admin / secrets/grafana-admin-password)"
    [ "$GRAFANA_MODE" = api ] && echo "2. Grafana:  GRAFANA_URL=... GRAFANA_TOKEN=... $OUT/grafana-api/import.sh"
    echo "3. Per app: $OUT/apps/<app>/instrumentation/ (otel.env + systemd drop-in); apps send OTLP to $OTLP_ENDPOINT" ;;
  esac
  echo
  echo "Sizing: Prometheus ${PROMETHEUS_RETENTION_TIME} / ${PROMETHEUS_RETENTION_SIZE}, memory ${PROMETHEUS_MEMORY_LIMIT};" \
       "Tempo ${TEMPO_RETENTION}, memory ${TEMPO_MEMORY_LIMIT}; gateway ${GATEWAY_MEMORY_LIMIT}; trace sampling ${TRACE_SAMPLE_RATIO}"
} > "$N"

echo "Rendered into $OUT/:"
find "$OUT" -type f ! -name admin-password ! -name '.env' ! -name 'grafana-admin.env' | sort | sed 's/^/  /'
echo
cat "$N"
