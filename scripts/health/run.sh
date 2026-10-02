#!/usr/bin/env bash
#
# health/run.sh — batería completa de salud (HDFS + YARN + Spark + auxiliares)
#   --full   incluye el envío de un job real a YARN (~60 s extra)
# Salida: tabla de estados en pantalla + data/reports/health-<ts>.txt
# Código de salida: 0 sin FAIL, 1 si hay algún FAIL
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../lib/common.sh"

require_cmd docker curl
load_env
ensure_dirs
STAMP=$(date -u +"%Y%m%dT%H%M%SZ")
OUT="$REPORTS_DIR/health-$STAMP.txt"
rc=0

echo "# Salud del laboratorio — $STAMP" > "$OUT"

run() {
  local script="$1"; shift
  local name out st
  name=$(basename "$script" .sh)
  out=$(bash "$script" "$@" 2>&1); st=$?
  section "$name"
  printf '%s\n' "$out" | sed 's/^/  /'
  { echo; echo "## $name"; printf '%s\n' "$out"; } >> "$OUT"
  [ "$st" -eq 1 ] && rc=1
  return 0
}

run "$HERE/hdfs.sh"
run "$HERE/yarn.sh"
run "$HERE/spark.sh" "$@"
run "$HERE/aux.sh"

section "Resumen"
p=$(grep -c '^\s*PASS ' "$OUT" || true); f=$(grep -c '^\s*FAIL ' "$OUT" || true)
d=$(grep -c '^\s*DEGRADED ' "$OUT" || true); n=$(grep -c '^\s*NOT_CONFIGURED ' "$OUT" || true)
printf '  %sPASS%s=%s  %sFAIL%s=%s  %sDEGRADED%s=%s  %sNOT_CONFIGURED%s=%s\n' \
  "$C_GREEN" "$C_RESET" "$p" "$C_RED" "$C_RESET" "$f" \
  "$C_YELLOW" "$C_RESET" "$d" "$C_BLUE" "$C_RESET" "$n"
info "informe: $OUT"
[ "$f" -eq 0 ] || rc=1
exit "$rc"
