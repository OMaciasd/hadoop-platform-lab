#!/usr/bin/env bash
#
# inventory/ports.sh — verifica puertos y subnets antes de asignarlos
# Código de salida: 0 = sin conflictos, 1 = conflicto detectado
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

OUT="${1:-$INVENTORY_DIR/ports.txt}"
mkdir -p "$(dirname "$OUT")"
conflicts=0

{
  echo "# Puertos y redes — $(ts)"
  echo
  echo "## Puertos en uso (host)"
  ss -tlnH | awk '{print $4}' | sed 's/.*://' | sort -n -u | tr '\n' ' '; echo
  echo
  echo "## Puertos reservados por el laboratorio"
  for p in "${LAB_PORTS[@]}"; do
    if port_listening "$p"; then
      owner=$(port_owner "$p")
      if docker ps --format '{{.Names}}' 2>/dev/null | grep -qE "^hl-"; then
        # ¿lo escucha un contenedor del laboratorio?
        if docker ps --format '{{.Names}} {{.Ports}}' | grep -qE "^hl- .*:$p->"; then
          echo "- $p: USADO POR EL LABORATORIO ($owner)"
        else
          echo "- $p: CONFLICTO — ocupado por '$owner'"
          conflicts=1
        fi
      else
        echo "- $p: CONFLICTO — ocupado por '${owner:-desconocido}'"
        conflicts=1
      fi
    else
      echo "- $p: libre"
    fi
  done
  echo
  echo "## Red del laboratorio"
  if docker network inspect "$LAB_NETWORK" >/dev/null 2>&1; then
    echo "- $LAB_NETWORK existe: $(docker network inspect "$LAB_NETWORK" --format '{{range .IPAM.Config}}{{.Subnet}} {{end}}')"
  else
    echo "- $LAB_NETWORK no existe todavía (se creará en $LAB_SUBNET)"
  fi
  echo "- subnets en uso:"
  docker network ls -q | while read -r id; do
    docker network inspect "$id" --format '{{.Name}}={{range .IPAM.Config}}{{.Subnet}} {{end}}' 2>/dev/null
  done | sed 's/^/    /'
} | tee "$OUT" >/dev/null

[ "$OUT" = "/dev/stdout" ] || cat "$OUT"
if [ "$conflicts" -ne 0 ]; then
  printf '\n%sFAIL%s hay conflictos de puertos; libéralos antes de arrancar el stack\n' "$C_RED" "$C_RESET"
  exit 1
fi
printf '\n%sPASS%s sin conflictos de puertos ni de red\n' "$C_GREEN" "$C_RESET"
