#!/usr/bin/env bash
#
# diagnostics/diagnose.sh <servicio> — apunta a la causa raíz de un fallo
# Uso: ./scripts/diagnostics/diagnose.sh namenode|datanode1|...|yarn|spark|red
# No cambia nada: sólo inspecciona y recomienda el siguiente comando.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../lib/common.sh"

target="${1:-}"
[ -n "$target" ] || die "uso: $0 <namenode|datanode1|datanode2|resourcemanager|nodemanager1|nodemanager2|client|yarn|spark|red|disk>"

found=0

container_status() {
  local c="hl-$1"
  docker inspect -f 'estado={{.State.Status}} salud={{if .State.Health}}{{.State.Health.Status}}{{else}}-{{end}} salida={{.State.ExitCode}} oom={{.State.OOMKilled}} reinicios={{.RestartCount}}' "$c" 2>/dev/null
}

section "Diagnóstico de '$target'"
case "$target" in
  namenode|datanode1|datanode2|resourcemanager|nodemanager1|nodemanager2|client)
    cname="hl-$target"
    if ! docker inspect "$cname" >/dev/null 2>&1; then
      fail "el contenedor $cname no existe"
      hint "./scripts/lab/up.sh"
      exit 1
    fi
    info "estado: $(container_status "$target")"
    if [ "$(docker inspect -f '{{.State.Status}}' "$cname")" != "running" ]; then
      found=1
      fail "$target no está en ejecución"
      hint "docker logs --tail 80 $cname"
      hint "docker start $cname"
    fi
    # puertos publicados ocupados por otro proceso
    for p in $(docker inspect -f '{{range $k,$v := .NetworkSettings.Ports}}{{$k}}{{end}}' "$cname" 2>/dev/null | tr -d '/tcp' | tr ' ' '\n' | grep -v '^$'); do
      if port_listening "$p" && ! docker ps --format '{{.Names}} {{.Ports}}' | grep -qE "^$cname .*:$p->"; then
        found=1
        fail "el puerto $p publicado por $cname lo ocupa otro proceso ($(port_owner "$p"))"
        hint "libera el puerto o cambia el mapeo en compose.yaml"
      fi
    done
    # errores recientes en log de fichero
    if [ -d "$LOGS_DIR/$target" ]; then
      # 'RECEIVED SIGNAL 15: SIGTERM' es el apagado limpio, no un fallo
      errs=$(grep -hE ' (ERROR|FATAL) ' "$LOGS_DIR/$target"/*.log 2>/dev/null \
               | grep -v 'RECEIVED SIGNAL' | tail -5)
      if [ -n "$errs" ]; then
        found=1
        warn "últimos ERROR/FATAL en ficheros:"
        printf '%s\n' "$errs" | sed 's/^/    /'
        hint "./scripts/diagnostics/logs.sh $target --errors"
      fi
    fi
    [ "$found" -eq 0 ] && ok "sin anomalías evidentes en $target"
    ;;

  yarn)
    nodes=$(exec_client "yarn node -list -all" 2>&1)
    if printf '%s' "$nodes" | grep -qi 'no such'; then
      fail "el cliente no puede hablar con YARN"
      hint "comprueba resourcemanager: docker logs hl-resourcemanager | tail"
    fi
    info "nodos: $(printf '%s' "$nodes" | grep -oP 'Total Nodes:\s*\K[0-9]+' | head -1)"
    metrics=$(curl -sf -m 5 http://localhost:8088/ws/v1/cluster/metrics 2>/dev/null)
    if [ -z "$metrics" ]; then
      fail "ResourceManager REST caído"
      hint "curl -s localhost:8088/ws/v1/cluster/info"
      hint "./scripts/diagnostics/logs.sh resourcemanager --errors"
    else
      ok "RM responde: appsRunning=$(printf '%s' "$metrics" | grep -oP '"appsRunning":\K[0-9]+') \
failed=$(printf '%s' "$metrics" | grep -oP '"appsFailed":\K[0-9]+')"
      printf '%s' "$metrics" | grep -q '"availableMB":0' && {
        warn "sin memoria disponible en YARN"
        hint "yarn application -list  (mata aplicaciones colgadas)"
      }
    fi
    ;;

  spark)
    if ! container_healthy hl-client; then
      fail "contenedor cliente unhealthy"
      hint "./scripts/lab/status.sh"
    else
      ok "cliente sano; prueba: ./scripts/health/spark.sh --full"
      [ -f "$REPORTS_DIR/spark-pi.log" ] && tail -5 "$REPORTS_DIR/spark-pi.log" | sed 's/^/    /'
    fi
    ;;

  red)
    if docker network inspect "$LAB_NETWORK" >/dev/null 2>&1; then
      ok "red $LAB_NETWORK: $(docker network inspect "$LAB_NETWORK" --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}')"
      docker network inspect "$LAB_NETWORK" --format 'contenedores:{{range .Containers}} {{.Name}}{{end}}'
    else
      fail "la red $LAB_NETWORK no existe"
      hint "./scripts/lab/up.sh"
    fi
    # ¿solape de subnets con otros proyectos?
    dup=$(docker network ls -q | while read -r id; do
            docker network inspect "$id" --format '{{.Name}} {{range .IPAM.Config}}{{.Subnet}} {{end}}' 2>/dev/null
          done | awk -v me="$LAB_SUBNET" '$2==me && $1!="'$LAB_NETWORK'" {print $1}')
    [ -n "$dup" ] && { fail "subnet $LAB_SUBNET duplicada en: $dup"; hint "revisa los compose vecinos"; }
    ;;

  disk)
    info "espacio de $DATA_DIR: $(du -sh "$DATA_DIR" 2>/dev/null | cut -f1)"
    info "espacio del host: $(df -h / | awk 'NR==2{print $4" libres ("$5" usado)"}')"
    perms=$(ls -ld "$DATA_DIR/namenode" 2>/dev/null || echo "no existe")
    info "$perms"
    if [ ! -d "$DATA_DIR/namenode" ]; then
      fail "no existe $DATA_DIR/namenode"
      hint "./scripts/lab/up.sh"
    elif [ "$(stat -c '%u' "$DATA_DIR/namenode")" != "1000" ]; then
      fail "propietario distinto de uid 1000 (hadoop no puede escribir)"
      hint "sudo chown -R 1000:1000 $DATA_DIR"
    else
      ok "permisos de datos correctos (uid 1000)"
    fi
    ;;

  *) die "objetivo desconocido: $target" ;;
esac

echo
info "miradas de detalle:"
hint "./scripts/diagnostics/logs.sh $target --errors"
hint "./scripts/diagnostics/collect.sh        # paquete de soporte completo"
