#!/usr/bin/env bash
#
# lab/down.sh — detiene el laboratorio sin borrar datos
# Los bind mounts de ./data y el estado HDFS sobreviven al down/up y al reboot.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../lib/common.sh"

require_cmd docker
section "Deteniendo $PROJECT_NAME"
dc down --remove-orphans 2>&1 | sed -E 's/^[[:space:]]+//'
ok "contenedores y red $LAB_NETWORK retirados"
info "los datos persisten en $DATA_DIR"
info "para borrarlos: ./scripts/lab/reset.sh --yes"
