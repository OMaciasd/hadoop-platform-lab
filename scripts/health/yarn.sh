#!/usr/bin/env bash
#
# health/yarn.sh — salud de YARN (ResourceManager + NodeManagers + recursos)
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../lib/common.sh"

# 1. ResourceManager
if ! container_healthy hl-resourcemanager; then
  emit FAIL yarn.resourcemanager.container "hl-resourcemanager no está healthy"
  exit 1
fi
emit PASS yarn.resourcemanager.container "hl-resourcemanager healthy"

info=$(curl -sf -m 5 http://localhost:8088/ws/v1/cluster/info 2>/dev/null)
if [ -z "$info" ]; then
  emit FAIL yarn.resourcemanager.rest "sin respuesta en :8088/ws/v1/cluster/info"; exit 1
fi
state=$(printf '%s' "$info" | grep -oP '"state":"\K[A-Z]+' | head -1)
ha=$(printf '%s' "$info" | grep -oP '"haState":"\K[A-Z]+' | head -1)
# sin HA el RM reporta STARTED; con HA, ACTIVE/STANDBY
if [ "$state" = "STARTED" ] || [ "$state" = "ACTIVE" ] || [ "$ha" = "ACTIVE" ]; then
  emit PASS yarn.resourcemanager.state "state=${state:-?} haState=${ha:-?}"
else
  emit FAIL yarn.resourcemanager.state "estado=${state:-desconocido}"; exit 1
fi

# 2. NodeManagers registrados
nodes=$(exec_client "yarn node -list -all" 2>/dev/null)
# filas de la tabla: <node-id> <state> <http> <containers>
total=$(printf '%s\n' "$nodes" | grep -oP 'Total Nodes:\s*\K[0-9]+' | head -1)
running=$(printf '%s\n' "$nodes" | grep -cP '^\S+\s+RUNNING\s')
total=${total:-0}
if [ "$running" -ge 2 ]; then
  emit PASS yarn.nodes "$running/2 NodeManagers RUNNING"
elif [ "$running" -eq 1 ]; then
  emit DEGRADED yarn.nodes "1/2 NodeManagers (capacidad reducida)"
else
  emit FAIL yarn.nodes "0 NodeManagers RUNNING (total=$total)"; exit 1
fi

# 3. Recursos disponibles
metrics=$(curl -sf -m 5 http://localhost:8088/ws/v1/cluster/metrics 2>/dev/null)
avail_mb=$(printf '%s' "$metrics" | grep -oP '"availableMB":\K[0-9]+' | head -1)
apps_running=$(printf '%s' "$metrics" | grep -oP '"appsRunning":\K[0-9]+' | head -1)
if [ -n "$avail_mb" ] && [ "$avail_mb" -gt 0 ]; then
  emit PASS yarn.resources "${avail_mb} MB disponibles, ${apps_running:-0} apps en ejecución"
elif [ -n "$avail_mb" ]; then
  emit DEGRADED yarn.resources "0 MB disponibles (¿trabajos colgados?)"
else
  emit FAIL yarn.resources "sin métricas del clúster"; exit 1
fi

exit 0
