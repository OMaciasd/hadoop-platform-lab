#!/usr/bin/env bash
#
# inventory/run.sh — inventario completo (sistema + docker + puertos)
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../lib/common.sh"

require_cmd docker ss
STAMP=$(date -u +"%Y%m%dT%H%M%SZ")
REPORT="$INVENTORY_DIR/inventory-$STAMP.txt"

section "Inventario completo ($STAMP)"
{
  "$HERE/system.sh" /dev/stdout
  echo
  "$HERE/docker.sh" /dev/stdout
  echo
  "$HERE/ports.sh" /dev/stdout
} > "$REPORT" 2>&1

grep -E '^(PASS|FAIL|DEGRADED|NOT_CONFIGURED)' "$REPORT" || true
echo
info "informe guardado en $REPORT"
# el código de salida refleja los conflictos de puertos
"$HERE/ports.sh" /dev/null >/dev/null 2>&1
