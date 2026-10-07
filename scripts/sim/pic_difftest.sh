#!/bin/sh
# Build and run the PIC16 difftest (sim/pic/tb_pic.cpp: crystal_pic16 vs the MAME-derived reference).
set -e
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
R=$ROOT/rtl
sh "$ROOT/scripts/sim/vl_build.sh" "$ROOT/build/vl_pic" crystal_pic16 tb_pic "$R/memory/crystal_ram.sv $R/crystal/crystal_pic16.sv" "$ROOT/sim/pic/tb_pic.cpp"
"$ROOT/build/vl_pic/tb_pic.exe" "$@"
