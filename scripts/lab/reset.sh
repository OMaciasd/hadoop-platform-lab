#!/usr/bin/env bash
#
# lab/reset.sh — destruye los datos del laboratorio (SÓLO los de este repo)
# Uso: ./scripts/lab/reset.sh --yes
# Nunca toca contenedores, volúmenes o redes de otros proyectos.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../lib/common.sh"

if [ "${1:-}" != "--yes" ]; then
  cat <<EOF
Esto eliminará DEFINITIVAMENTE:
  - contenedores y red de $PROJECT_NAME
  - $DATA_DIR (NameNode, DataNodes, logs, reportes)

No toca ningún otro proyecto ni contenedor.
Uso: $0 --yes
EOF
  exit 64
fi

require_cmd docker
section "1/2 Parar el stack"
dc down --remove-orphans --timeout 30 >/dev/null 2>&1 || true

section "2/2 Borrar datos locales del laboratorio"
case "$DATA_DIR" in
  */hadoop-platform-lab/data) rm -rf "$DATA_DIR"; ok "eliminado $DATA_DIR" ;;
  *) die "ruta de datos inesperada: $DATA_DIR (abortado)" ;;
esac

info "vuelve a levantar con ./scripts/lab/up.sh (se reformateará HDFS)"
