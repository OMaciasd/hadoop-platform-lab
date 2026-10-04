#!/usr/bin/env bash
#
# health/aux.sh — servicios auxiliares: vecinos reutilizados y ausentes
# Distingue claramente "no existe" (NOT_CONFIGURED) de "existe y falla" (DEGRADED).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../lib/common.sh"

check_http() {
  # check_http <nombre> <url> <tipo: reutilizado|propio>
  local name="$1" url="$2" kind="${3:-propio}" code
  code=$(http_code "$url" 5)
  case "$code" in
    2*|3*) emit PASS "$name" "HTTP $code ($url)" ;;
    000)
      if [ "$kind" = "reutilizado" ]; then
        emit DEGRADED "$name" "no responde en $url (vecino detenido)"
      else
        emit FAIL "$name" "sin respuesta en $url"
      fi ;;
    *) emit DEGRADED "$name" "HTTP $code en $url" ;;
  esac
}

section "Infraestructura reutilizada"
check_http aux.prometheus     http://localhost:9091/-/healthy  reutilizado
check_http aux.grafana        http://localhost:3001/api/health reutilizado
check_http aux.airflow        http://localhost:8080/health     reutilizado
# Spark standalone: el maestro expone RPC en 7077 y WebUI en 18080
if port_listening 7077; then
  check_http aux.spark_standalone http://localhost:18080/ reutilizado
else
  emit DEGRADED aux.spark_standalone "puerto 7077 cerrado (vecino detenido)"
fi

section "Componentes no requeridos por este laboratorio"
emit NOT_CONFIGURED aux.postgres_lab "el lab no usa SQL (ver docs/integration.md §1)"
emit NOT_CONFIGURED aux.messaging     "no hay Kafka/RabbitMQ en el equipo"
emit NOT_CONFIGURED aux.object_store  "MinIO no está activo; HDFS es el almacén"
emit NOT_CONFIGURED aux.log_aggregation "sin Loki/OTel; logs en ./data/logs"

section "Observabilidad propia del laboratorio"
if [ -d "$LOGS_DIR/namenode" ] && [ -n "$(ls -A "$LOGS_DIR/namenode" 2>/dev/null)" ]; then
  emit PASS lab.logs "ficheros en $LOGS_DIR/namenode"
else
  emit FAIL lab.logs "sin logs en $LOGS_DIR/namenode"
fi
code=$(http_code http://localhost:9870/jmx 5)
if [ "$code" = "200" ]; then emit PASS lab.metrics_nn "métricas JMX en :9870/jmx"
else emit FAIL lab.metrics_nn "JMX no responde (HTTP $code)"; fi
code=$(http_code http://localhost:8088/jmx 5)
if [ "$code" = "200" ]; then emit PASS lab.metrics_rm "métricas JMX en :8088/jmx"
else emit DEGRADED lab.metrics_rm "JMX del RM HTTP $code"; fi
check_http lab.exporter http://localhost:9871/health propio
code=$(http_code http://localhost:9871/metrics 5)
if [ "$code" = "200" ]; then emit PASS lab.metrics_prom "métricas Prometheus en :9871/metrics"
else emit DEGRADED lab.metrics_prom "exportador HTTP $code"; fi

exit 0
