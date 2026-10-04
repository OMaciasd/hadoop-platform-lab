#!/usr/bin/env bash
#
# diagnostics/collect.sh — paquete de soporte (solo lectura) para incidentes
# Genera data/reports/diag-<ts>.tar.gz con estado, logs de error y métricas.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../lib/common.sh"

require_cmd docker curl tar
load_env
ensure_dirs
STAMP=$(date -u +"%Y%m%dT%H%M%SZ")
WORK="$REPORTS_DIR/diag-$STAMP"

section "Recopilando evidencias en $WORK"
mkdir -p "$WORK"

{
  echo "# Recopilado: $(ts)"
  echo "## host"; uname -a; free -h; df -h / | tail -1
  echo "## docker"; docker ps -a --format '{{.Names}}|{{.Image}}|{{.Status}}|{{.Ports}}'
} > "$WORK/system.txt" 2>&1

dc ps -a > "$WORK/compose-ps.txt" 2>&1
docker inspect hl-namenode hl-datanode1 hl-datanode2 hl-resourcemanager \
  hl-nodemanager1 hl-nodemanager2 hl-client > "$WORK/inspect.json" 2>&1

# endpoints
for u in "http://localhost:9870/jmx" "http://localhost:9870/api/v1/cluster" \
         "http://localhost:8088/ws/v1/cluster/info" "http://localhost:8088/ws/v1/cluster/metrics" \
         "http://localhost:8088/ws/v1/cluster/nodes"; do
  name=$(printf '%s' "$u" | sed 's|http://localhost:||; s|[/:]|-|g')
  curl -sf -m 8 "$u" > "$WORK/http-$name.json" 2>&1 || echo "sin respuesta: $u" > "$WORK/http-$name.json"
done

# comandos de clúster (desde el cliente)
if docker ps --format '{{.Names}}' | grep -q '^hl-client$'; then
  exec_client "hdfs dfsadmin -report"        > "$WORK/hdfs-report.txt"   2>&1
  exec_client "hdfs dfsadmin -safemode get"  > "$WORK/hdfs-safemode.txt" 2>&1
  exec_client "hdfs dfs -ls -R /"            > "$WORK/hdfs-ls.txt"       2>&1
  exec_client "yarn node -list -all"         > "$WORK/yarn-nodes.txt"    2>&1
  exec_client "yarn application -list"       > "$WORK/yarn-apps.txt"     2>&1
fi

# errores de los logs
mkdir -p "$WORK/errors"
for d in "$LOGS_DIR"/*/; do
  s=$(basename "$d")
  grep -hE ' (ERROR|FATAL|Exception) ' "$d"/*.log 2>/dev/null | tail -100 > "$WORK/errors/$s.txt"
  docker logs --tail 300 "hl-$s" > "$WORK/errors/$s.console.log" 2>&1 || true
done

# red y puertos
docker network inspect "$LAB_NETWORK" > "$WORK/network.json" 2>&1
ss -tlnp > "$WORK/ports.txt" 2>&1

TARBALL="$REPORTS_DIR/diag-$STAMP.tar.gz"
tar -czf "$TARBALL" -C "$REPORTS_DIR" "diag-$STAMP" && rm -rf "$WORK"

ok "paquete listo: $TARBALL ($(du -h "$TARBALL" | cut -f1))"
info "contiene: estado de contenedores, JMX/REST, dfsadmin, yarn, errores de log, red y puertos"
