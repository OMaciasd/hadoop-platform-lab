#!/usr/bin/env bash
#
# health/hdfs.sh — salud de HDFS (NameNode + DataNodes + escritura real)
# Emite líneas de estado: PASS | FAIL | DEGRADED | NOT_CONFIGURED
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../lib/common.sh"

roundtrip() {
  # escritura/lectura/borrado real desde el contenedor cliente
  local f="/lab/healthcheck/roundtrip-$$.txt"
  exec_client "hdfs dfs -mkdir -p /lab/healthcheck &&
               printf 'lab-%s\n' \"\$(date -u +%s)\" > /tmp/.rt &&
               hdfs dfs -put -f /tmp/.rt '$f' &&
               hdfs dfs -cat '$f' | grep -q '^lab-' &&
               hdfs dfs -rm -f '$f' >/dev/null" >/dev/null 2>&1
}

# 1. contenedor
if ! container_healthy hl-namenode; then
  emit FAIL hdfs.namenode.container "hl-namenode no está healthy"
  exit 1
fi
emit PASS hdfs.namenode.container "hl-namenode healthy"

# 2. HTTP/JMX
code=$(http_code http://localhost:9870/jmx 5)
if [ "$code" = "200" ]; then emit PASS hdfs.namenode.http "JMX HTTP 200"
else emit FAIL hdfs.namenode.http "HTTP $code en :9870"; exit 1; fi

# 3. safe mode
safemode=$(exec_client "hdfs dfsadmin -safemode get" | tr -d '\r')
if echo "$safemode" | grep -qi "OFF"; then
  emit PASS hdfs.safemode "Safe mode OFF"
elif echo "$safemode" | grep -qi "ON"; then
  emit DEGRADED hdfs.safemode "$safemode (¿formándose o con datos pendientes?)"
else
  emit FAIL hdfs.safemode "sin respuesta de dfsadmin"; exit 1
fi

# 4. DataNodes vivos
report=$(exec_client "hdfs dfsadmin -report" 2>/dev/null)
live=$(printf '%s' "$report" | grep -A1 'Live datanodes' | grep -oP '\(\K[0-9]+' | head -1)
live=${live:-0}
if [ "$live" -ge 2 ]; then
  emit PASS hdfs.datanodes.live "$live/2 DataNodes"
elif [ "$live" -eq 1 ]; then
  emit DEGRADED hdfs.datanodes.live "1/2 DataNodes (réplica incompleta)"
else
  emit FAIL hdfs.datanodes.live "0/2 DataNodes"; exit 1
fi

# 5. capacidad
cap=$(printf '%s' "$report" | grep -i 'DFS Used' | head -3 | tr '\n' ' ')
pct=$(printf '%s' "$report" | grep -oP 'DFS Used%:\s+\K[0-9.]+' | head -1)
if [ -n "$pct" ]; then
  int=${pct%%.*}
  if [ "${int:-0}" -ge 90 ]; then emit DEGRADED hdfs.capacity "uso ${pct}% (>=90%)"
  else emit PASS hdfs.capacity "uso ${pct}% — ${cap}"; fi
else
  emit DEGRADED hdfs.capacity "no se pudo leer la capacidad"
fi

# 6. roundtrip real
if roundtrip; then emit PASS hdfs.write_read "put/cat/rm OK desde el cliente"
else emit FAIL hdfs.write_read "fallo en put/cat/rm"; fi

# 7. persistencia local
if [ -f "$DATA_DIR/namenode/current/VERSION" ]; then
  emit PASS hdfs.persistence "fsimage en $DATA_DIR/namenode (bind mount)"
elif docker exec hl-namenode test -f /hadoop/dfs/name/current/VERSION 2>/dev/null; then
  emit DEGRADED hdfs.persistence "fsimage dentro del contenedor, no en ./data"
else
  emit FAIL hdfs.persistence "no hay fsimage formateado"
fi

exit 0
