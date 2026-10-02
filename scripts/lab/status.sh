#!/usr/bin/env bash
#
# lab/status.sh — estado rápido del laboratorio y de sus vecinos
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../lib/common.sh"

section "Contenedores del laboratorio"
if ! compose_running; then
  warn "el stack no está en marcha (./scripts/lab/up.sh)"
else
  dc ps --format 'table {{.Name}}\t{{.Status}}\t{{.Ports}}'
fi

section "Endpoints"
declare -A endpoints=(
  [namenode_ui]="http://localhost:9870/jmx"
  [rm_rest]="http://localhost:8088/ws/v1/cluster/info"
  [dn1_ui]="http://localhost:9864/jmx"
  [dn2_ui]="http://localhost:9865/jmx"
  [nm1_rest]="http://localhost:8042/ws/v1/node/info"
  [nm2_rest]="http://localhost:8043/ws/v1/node/info"
)
for name in "${!endpoints[@]}"; do
  code=$(http_code "${endpoints[$name]}" 5)
  case "$code" in
    2*) ok "$name → HTTP $code" ;;
    000) fail "$name → sin respuesta (${endpoints[$name]})" ;;
    *) warn "$name → HTTP $code" ;;
  esac
done | sort

section "Servicios vecinos (reutilización)"
declare -A neighbors=(
  [prometheus]="http://localhost:9091/-/healthy"
  [grafana]="http://localhost:3001/api/health"
  [airflow]="http://localhost:8080/health"
  [spark_standalone]="http://localhost:18080/"
)
for name in "${!neighbors[@]}"; do
  code=$(http_code "${neighbors[$name]}" 5)
  case "$code" in
    2*|3*) ok "$name → HTTP $code" ;;
    000) warn "$name → no responde (¿detenido?)" ;;
    *) warn "$name → HTTP $code" ;;
  esac
done | sort

section "Uso de recursos"
docker stats --no-stream --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}' \
  $(dc ps -q 2>/dev/null) 2>/dev/null || info "sin contenedores activos"
echo
info "validación completa: ./scripts/validate/validate.py"
