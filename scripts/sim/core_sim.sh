#!/bin/sh
# Build and run the full-core simulation (sim/integration/tb_core.cpp).
set -e
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
SV=$(grep SYSTEMVERILOG_FILE "$ROOT/files.qip" | awk '{print $4}' | grep -v "^Crystal.sv" | sed "s#^#$ROOT/#" | tr '\n' ' ')
sh "$ROOT/scripts/sim/vl_build.sh" "$ROOT/build/vl_core" crystal_core tb_core "$SV" "$ROOT/sim/integration/tb_core.cpp"
"$ROOT/build/vl_core/tb_core.exe" "$@"
