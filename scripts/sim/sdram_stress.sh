#!/bin/sh
# Build and run the SDRAM controller stress test (sim/memory/tb_sdram.cpp).
set -e
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
sh "$ROOT/scripts/sim/vl_build.sh" "$ROOT/build/vl_sdram" crystal_sdram tb_sdram "$ROOT/rtl/memory/crystal_sdram.sv" "$ROOT/sim/memory/tb_sdram.cpp"
"$ROOT/build/vl_sdram/tb_sdram.exe" "$@"
