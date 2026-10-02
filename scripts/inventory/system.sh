#!/usr/bin/env bash
#
# inventory/system.sh — inventario del sistema operativo y recursos
# Salida: stdout + data/inventory/system.txt (solo lectura, no destructivo)
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

OUT="${1:-$INVENTORY_DIR/system.txt}"
mkdir -p "$(dirname "$OUT")"

{
  echo "# Inventario de sistema — $(ts)"
  echo
  echo "## SO"
  echo "- host: $(hostname)"
  echo "- kernel: $(uname -sr)"
  [ -f /etc/os-release ] && echo "- os: $(. /etc/os-release && echo "$PRETTY_NAME")"
  echo
  echo "## CPU"
  echo "- vCPU: $(nproc)"
  lscpu 2>/dev/null | grep -E '^(Model name|Architecture|CPU max MHz)' | sed 's/^/- /'
  echo
  echo "## Memoria"
  free -h | sed 's/^/  /'
  echo
  echo "## Disco"
  df -h --output=target,size,used,avail,pcent 2>/dev/null | grep -vE 'tmpfs|udev|snap|drvfs' | sed 's/^/  /'
  echo
  echo "## Herramientas"
  for t in docker kubectl terraform git python3 java curl jq ss nc gh hdfs yarn spark-submit; do
    if p=$(command -v "$t" 2>/dev/null); then
      v=$("$t" --version 2>&1 | head -1 || true)
      echo "- $t: $p — ${v:0:80}"
    else
      echo "- $t: NO INSTALADO"
    fi
  done
  echo
  echo "## Docker"
  docker info --format '- server={{.ServerVersion}} contenedores={{.Containers}} activos={{.ContainersRunning}} imágenes={{.Images}}' 2>&1
} | tee "$OUT" >/dev/null

[ "$OUT" = "/dev/stdout" ] || cat "$OUT"
