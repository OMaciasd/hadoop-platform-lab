#!/usr/bin/env bash
#
# common.sh — utilidades compartidas de hadoop-platform-lab
# Incluir con: . "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
#
set -uo pipefail

# ------------------------------------------------------------------ raíz
if [ -z "${LAB_ROOT:-}" ]; then
  LAB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi
export LAB_ROOT
DATA_DIR="$LAB_ROOT/data"
REPORTS_DIR="$DATA_DIR/reports"
METRICS_DIR="$DATA_DIR/metrics"
LOGS_DIR="$DATA_DIR/logs"
INVENTORY_DIR="$DATA_DIR/inventory"
COMPOSE_FILE="$LAB_ROOT/compose.yaml"
PROJECT_NAME="hadoop-platform-lab"
LAB_NETWORK="hadoop_lab"
LAB_SUBNET="172.28.0.0/16"

# Puertos reservados por el laboratorio (verificados libres en el inventario)
LAB_PORTS=(8020 8042 8043 8088 9864 9865 9870 9871)

# ------------------------------------------------------------------ color
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'
  C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
  C_BLUE=$'\033[34m'; C_GRAY=$'\033[90m'
else
  C_RESET=""; C_BOLD=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_GRAY=""
fi

ts()      { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
section() { printf '\n%s== %s ==%s\n' "$C_BOLD$C_BLUE" "$*" "$C_RESET"; }
info()    { printf '%s·%s %s\n' "$C_GRAY" "$C_RESET" "$*"; }
ok()      { printf '%sPASS%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn()    { printf '%sDEGRADED%s %s\n' "$C_YELLOW" "$C_RESET" "$*"; }
fail()    { printf '%sFAIL%s %s\n' "$C_RED" "$C_RESET" "$*"; }
notcfg()  { printf '%sNOT_CONFIGURED%s %s\n' "$C_BLUE" "$C_RESET" "$*"; }
die()     { printf '%sERROR%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }

# Estados normalizados (usados por health/ y validate/)
STATE_PASS=PASS STATE_FAIL=FAIL STATE_DEGRADED=DEGRADED STATE_NOT_CONFIGURED=NOT_CONFIGURED
emit() {
  # emit <STATE> <check> <detalle>
  local state="$1" check="$2" detail="${3:-}"
  printf '%-16s %-28s %s\n' "$state" "$check" "$detail"
  case "$state" in
    PASS) return 0 ;;
    FAIL) return 1 ;;
    DEGRADED) return 2 ;;
    NOT_CONFIGURED) return 3 ;;
    *) return 4 ;;
  esac
}

hint()      { printf '  \xe2\x86\x92 %s\n' "$*"; }   # -> siguiente paso sugerido

require_cmd() {
  local missing=0 c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || { printf '%sERROR%s falta el comando: %s\n' "$C_RED" "$C_RESET" "$c" >&2; missing=1; }
  done
  [ "$missing" -eq 0 ] || exit 127
}

# ------------------------------------------------------------------ docker
dc() { docker compose -f "$COMPOSE_FILE" --project-name "$PROJECT_NAME" "$@"; }

compose_running() { dc ps --status running -q 2>/dev/null | grep -q .; }

container_healthy() {
  local name="$1" st
  st=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$name" 2>/dev/null) || return 2
  [ "$st" = "healthy" ] && return 0
  return 1
}

# ------------------------------------------------------------------ red
port_listening() {
  # port_listening <puerto> -> 0 si alguien escucha
  ss -tlnH "sport = :$1" 2>/dev/null | grep -q . || nc -z -w 1 127.0.0.1 "$1" >/dev/null 2>&1
}

port_owner() {
  ss -tlnpH "sport = :$1" 2>/dev/null | grep -oP 'users:\(\("\K[^"]+' | head -1
}

# http_code <url> [timeout_seg]
http_code() {
  curl -s -o /dev/null -w '%{http_code}' -m "${2:-8}" "$1" 2>/dev/null || echo 000
}

# wait_http <url> <timeout_seg> -> 0 cuando responde 2xx/3xx
wait_http() {
  local url="$1" timeout="${2:-60}" waited=0
  while [ "$waited" -lt "$timeout" ]; do
    local code; code=$(http_code "$url" 5)
    case "$code" in 2*|3*) return 0 ;; esac
    sleep 2; waited=$((waited + 2))
  done
  return 1
}

# ------------------------------------------------------------------ cliente
# exec_client <cmd...> -> ejecuta en el contenedor cliente (timeout acotado)
exec_client() {
  timeout "${CLIENT_TIMEOUT:-60}" docker compose -f "$COMPOSE_FILE" --project-name "$PROJECT_NAME" \
    exec -T client bash -lc "$*" 2>/dev/null
}

ensure_dirs() {
  mkdir -p "$REPORTS_DIR" "$METRICS_DIR" "$INVENTORY_DIR" \
           "$LOGS_DIR"/{namenode,datanode1,datanode2,resourcemanager,nodemanager1,nodemanager2,client} \
           "$DATA_DIR"/{namenode,datanode1,datanode2} \
           "$DATA_DIR/yarn/nm1/local" "$DATA_DIR/yarn/nm1/logs" \
           "$DATA_DIR/yarn/nm2/local" "$DATA_DIR/yarn/nm2/logs"
}

load_env() {
  [ -f "$LAB_ROOT/.env" ] && set -a && . "$LAB_ROOT/.env" && set +a
  return 0
}
