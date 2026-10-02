#!/usr/bin/env bash
#
# inventory/docker.sh — inventario de contenedores, redes, volúmenes e imágenes
# Salida: stdout + data/inventory/docker.txt (solo lectura)
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

OUT="${1:-$INVENTORY_DIR/docker.txt}"
mkdir -p "$(dirname "$OUT")"

{
  echo "# Inventario Docker — $(ts)"
  echo
  echo "## Contenedores"
  docker ps -a --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' 2>&1
  echo
  echo "## Redes (subnets)"
  docker network ls --format '{{.Name}}\t{{.Driver}}\t{{.Scope}}' | while read -r n d s; do
    sub=$(docker network inspect "$n" --format '{{range .IPAM.Config}}{{.Subnet}} {{end}}' 2>/dev/null)
    echo "- $n [$d/$s] ${sub:-(sin subnet)}"
  done
  echo
  echo "## Volúmenes con datos de laboratorio"
  docker volume ls --format '{{.Name}}' 2>/dev/null | grep -E "^(hadoop|${PROJECT_NAME}|hl)" || echo "(ninguno del laboratorio)"
  echo
  echo "## Imágenes de Hadoop/Spark"
  docker images --format '{{.Repository}}:{{.Tag}}\t{{.Size}}' | grep -iE 'hadoop|spark' || echo "(ninguna)"
  echo
  echo "## Uso de disco Docker"
  docker system df 2>&1
} | tee "$OUT" >/dev/null

[ "$OUT" = "/dev/stdout" ] || cat "$OUT"
