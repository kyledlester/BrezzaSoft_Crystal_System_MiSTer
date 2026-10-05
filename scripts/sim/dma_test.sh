#!/bin/sh
# Build and run the VRender0 DMA test (sim/vrender0/tb_dma.cpp).
set -e
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
sh "$ROOT/scripts/sim/vl_build.sh" "$ROOT/build/vl_dma" vr0_sys tb_dma "$ROOT/rtl/vrender0/vr0_sys.sv" "$ROOT/sim/vrender0/tb_dma.cpp"
"$ROOT/build/vl_dma/tb_dma.exe" "$@"
