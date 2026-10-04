#!/usr/bin/env bash
#
# entrypoint.sh — hadoop-platform-lab
#
# Entrada única y auditable para los contenedores Hadoop del laboratorio.
# Responsabilidades (en orden):
#   1. preparar entorno (config, rutas, DNS)
#   2. esperar la dependencia indicada en WAITFOR (con tope de tiempo)
#   3. formatear el NameNode una sola vez si no existe (idempotente)
#   4. arrancar el daemon indicado en el comando de compose
#
# Todo fallo es explícito y sale con código != 0 para que Docker lo marque
# como unhealthy/failed (visibles con ./scripts/lab/status.sh).
#
set -euo pipefail

export HADOOP_HOME="${HADOOP_HOME:-/opt/hadoop}"
export HADOOP_CONF_DIR="${HADOOP_CONF_DIR:-/opt/lab/conf}"
export HADOOP_LOG_DIR="${HADOOP_LOG_DIR:-/hadoop/logs}"
export HADOOP_YARN_HOME="${HADOOP_YARN_HOME:-$HADOOP_HOME}"
export PATH="$HADOOP_HOME/bin:$HADOOP_HOME/sbin:$PATH"
export HADOOP_OPTS="${HADOOP_OPTS:-} -Dhadoop.log.dir=${HADOOP_LOG_DIR} -Djava.net.preferIPv4Stack=true"

CLUSTER_ROLE="${CLUSTER_ROLE:-unknown}"
CLUSTER_ID="${HADOOP_CLUSTER_ID:-hadoop-platform-lab}"
WAITFOR_TIMEOUT="${WAITFOR_TIMEOUT:-180}"

log() { printf '[entrypoint:%s] %s\n' "$CLUSTER_ROLE" "$*"; }

# ---------------------------------------------------------------- 1. conf
if [ ! -f "$HADOOP_CONF_DIR/core-site.xml" ]; then
  echo "[entrypoint:$CLUSTER_ROLE] ERROR: no se encuentra core-site.xml en $HADOOP_CONF_DIR" >&2
  exit 78   # EX_CONFIG
fi
mkdir -p "$HADOOP_LOG_DIR"

# ------------------------------------------------- 2. espera acotada de dependencia
if [ -n "${WAITFOR:-}" ]; then
  host="${WAITFOR%%:*}"
  port="${WAITFOR##*:}"
  log "esperando a $host:$port (tope ${WAITFOR_TIMEOUT}s)"
  for _ in $(seq 1 "$WAITFOR_TIMEOUT"); do
    if nc -z -w 2 "$host" "$port" >/dev/null 2>&1; then
      log "dependencia disponible: $host:$port"
      break
    fi
    sleep 1
  done
  if ! nc -z -w 2 "$host" "$port" >/dev/null 2>&1; then
    echo "[entrypoint:$CLUSTER_ROLE] ERROR: dependencia $host:$port no disponible tras ${WAITFOR_TIMEOUT}s" >&2
    exit 69   # EX_UNAVAILABLE
  fi
fi

# ------------------------------------------------- 3. formateo idempotente del NN
if [ "$CLUSTER_ROLE" = "namenode" ]; then
  NAME_DIR="/hadoop/dfs/name"
  if [ ! -f "$NAME_DIR/current/VERSION" ]; then
    log "formato inicial de HDFS (clusterid=$CLUSTER_ID)"
    mkdir -p "$NAME_DIR"
    hdfs namenode -format -force -clusterid "$CLUSTER_ID"
  else
    log "HDFS ya formateado, se reutiliza el estado persistente"
  fi
fi

# ------------------------------------------------- 4. daemon
log "arrancando: $*"
exec "$@"
