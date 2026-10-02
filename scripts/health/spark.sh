#!/usr/bin/env bash
#
# health/spark.sh — salud de Spark sobre YARN (cliente propio del laboratorio)
#   --full  además envía un job real (pi) a YARN (~30-60 s)
# El Spark standalone de azure-data-engineering-lab se comprueba en aux.sh.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../lib/common.sh"

full=0
[ "${1:-}" = "--full" ] && full=1

# 1. contenedor cliente
if ! container_healthy hl-client; then
  emit FAIL spark.client.container "hl-client no está healthy"
  exit 1
fi
emit PASS spark.client.container "hl-client healthy"

# 2. binario y versión
if ! exec_client "test -x /opt/spark/bin/spark-submit" >/dev/null; then
  emit FAIL spark.client.binary "spark-submit ausente en la imagen"; exit 1
fi
# spark-submit --version escribe en stderr: se mezcla dentro del contenedor
ver=$(exec_client "spark-submit --version 2>&1" | grep -oP 'version \K[0-9.]+' | head -1)
if [ -n "$ver" ]; then emit PASS spark.client.version "Spark $ver instalado"
else emit FAIL spark.client.version "no se pudo leer la versión"; fi

# 3. integración con YARN (sin enviar job)
if exec_client "test -f /opt/lab/conf/yarn-site.xml && test -n \"\$SPARK_HOME\"" >/dev/null; then
  emit PASS spark.yarn.conf "SPARK_HOME y yarn-site.xml disponibles"
else
  emit FAIL spark.yarn.conf "falta configuración de YARN para Spark"; exit 1
fi

# 4. job real (opcional)
if [ "$full" -eq 1 ]; then
  info "enviando job pi a YARN (puede tardar ~60 s)..."
  if CLIENT_TIMEOUT=180 exec_client \
      "spark-submit --master yarn --deploy-mode client \
        --executor-memory 512m --executor-cores 1 --driver-memory 512m \
        --conf spark.sql.shuffle.partitions=4 \
        /opt/spark/examples/src/main/python/pi.py 20" 2>&1 | tee "$REPORTS_DIR/spark-pi.log" | grep -q "Pi is roughly"; then
    emit PASS spark.job.yarn "job pi completado en YARN"
  else
    emit FAIL spark.job.yarn "job pi falló (ver data/reports/spark-pi.log)"
  fi
else
  emit NOT_CONFIGURED spark.job.yarn "no ejecutado (usa --full para enviar el job)"
fi

exit 0
