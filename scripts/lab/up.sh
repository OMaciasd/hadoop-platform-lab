#!/usr/bin/env bash
#
# lab/up.sh — levanta el laboratorio de forma segura
#   1. verifica comandos y puertos libres
#   2. crea ./data con permisos del usuario (uid 1000 == hadoop)
#   3. arranca el stack y espera los health checks (tope configurable)
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../lib/common.sh"

WAIT_TIMEOUT="${1:-${UP_WAIT_TIMEOUT:-240}}"

require_cmd docker curl ss
docker info >/dev/null 2>&1 || die "el demonio Docker no responde"
load_env

section "1/4 Verificación de puertos y red"
if ports_out=$("$HERE/../inventory/ports.sh" /dev/stdout 2>&1); then
  printf '%s\n' "$ports_out"
else
  printf '%s\n' "$ports_out"
  die "hay conflictos de puertos; revisa data/inventory/ports.txt"
fi

section "2/4 Directorios de datos"
ensure_dirs
info "raíz de datos: $DATA_DIR ($(du -sh "$DATA_DIR" 2>/dev/null | cut -f1 || echo 0))"

section "3/4 Arranque del stack"
info "construyendo cliente (si hace falta) y arrancando servicios..."
dc up -d --build 2>&1 | sed -E 's/^[[:space:]]+//'

section "4/4 Espera de health checks (tope ${WAIT_TIMEOUT}s)"
deadline=$(( $(date +%s) + WAIT_TIMEOUT ))
services=(namenode datanode1 datanode2 resourcemanager nodemanager1 nodemanager2 client metrics)
while :; do
  pending=()
  for s in "${services[@]}"; do
    cname="hl-$s"
    st=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$cname" 2>/dev/null || echo absent)
    [ "$st" = "healthy" ] || pending+=("$s:$st")
  done
  if [ ${#pending[@]} -eq 0 ]; then
    ok "todos los servicios están healthy"
    break
  fi
  if [ "$(date +%s)" -ge "$deadline" ]; then
    fail "tope de espera agotado; pendientes: ${pending[*]}"
    info "usa ./scripts/lab/status.sh y ./scripts/diagnostics/diagnose.sh <servicio>"
    exit 1
  fi
  printf '  esperando: %s\r' "${pending[*]}"
  sleep 3
done

section "Resumen"
dc ps --format 'table {{.Name}}\t{{.Status}}\t{{.Ports}}'
cat <<URLS

  NameNode UI          http://localhost:9870
  ResourceManager UI   http://localhost:8088
  DataNode 1 / 2       http://localhost:9864 / http://localhost:9865
  NodeManager 1 / 2    http://localhost:8042 / http://localhost:8043
  Métricas Prometheus  http://localhost:9871/metrics

  Validación:          ./scripts/validate/validate.py
  Salud HDFS/YARN:     ./scripts/health/run.sh
URLS
