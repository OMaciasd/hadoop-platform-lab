#!/usr/bin/env bash
#
# diagnostics/logs.sh — lectura de logs (fichero + docker) de un servicio
# Uso: ./scripts/diagnostics/logs.sh <servicio> [--errors] [--lines N] [--follow]
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../lib/common.sh"

svc="${1:-}"; shift || true
[ -n "$svc" ] || die "uso: $0 <namenode|datanode1|datanode2|resourcemanager|nodemanager1|nodemanager2|client> [--errors] [--lines N] [--follow]"

errors=0; lines=50; follow=0
while [ $# -gt 0 ]; do
  case "$1" in
    --errors) errors=1 ;;
    --lines)  lines="$2"; shift ;;
    --follow) follow=1 ;;
    *) die "opción desconocida: $1" ;;
  esac
  shift
done

cname="hl-$svc"
logdir="$LOGS_DIR/$svc"
pattern=' (ERROR|FATAL|Exception|Caused by) '

section "Logs de $svc"
if [ -d "$logdir" ]; then
  info "ficheros: $logdir"
  ls -lh "$logdir" 2>/dev/null | tail -n +2 | sed 's/^/  /'
else
  warn "no hay directorio de logs en $logdir"
fi

if [ -d "$logdir" ] && compgen -G "$logdir/*" >/dev/null; then
  section "Últimas líneas del fichero"
  if [ "$errors" -eq 1 ]; then
    grep -hE "$pattern" "$logdir"/* 2>/dev/null | tail -n "$lines" | sed 's/^/  /'
    total=$(grep -hE "$pattern" "$logdir"/* 2>/dev/null | wc -l | tr -d ' ')
    info "coincidencias totales: $total"
  else
    tail -n "$lines" "$logdir"/* 2>/dev/null | sed 's/^/  /'
  fi
fi

if docker inspect "$cname" >/dev/null 2>&1; then
  if [ "$follow" -eq 1 ]; then
    section "docker logs -f $cname"
    exec docker logs -f --tail "$lines" "$cname"
  fi
  section "Salida de consola (docker logs)"
  if [ "$errors" -eq 1 ]; then
    docker logs --tail 500 "$cname" 2>&1 | grep -E "$pattern" | tail -n "$lines" | sed 's/^/  /'
  else
    docker logs --tail "$lines" "$cname" 2>&1 | sed 's/^/  /'
  fi
else
  warn "el contenedor $cname no existe (¿stack parado?)"
fi

section "Próximo paso"
hint "./scripts/diagnostics/diagnose.sh $svc"
