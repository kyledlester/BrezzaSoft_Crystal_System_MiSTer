#!/bin/sh
# Build and run the SE3208 RTL-vs-reference differential test (sim/cpu/tb_cpu.cpp).
#   scripts/sim/cpu_difftest.sh [tb_cpu args...]
set -e
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
sh "$ROOT/scripts/sim/vl_build.sh" "$ROOT/build/vl_cpu" se3208_cpu tb_cpu "$ROOT/rtl/cpu/se3208/se3208_cpu.sv" "$ROOT/sim/cpu/tb_cpu.cpp"
"$ROOT/build/vl_cpu/tb_cpu.exe" "$@"
