#!/bin/sh
# Build and run the renderer differential test (sim/vrender0/tb_render.cpp).
set -e
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
sh "$ROOT/scripts/sim/vl_build.sh" "$ROOT/build/vl_render" vr0_render tb_render "$ROOT/rtl/vrender0/vr0_render.sv" \
  "$ROOT/sim/vrender0/tb_render.cpp $ROOT/sim/reference/crystal_ref.cpp"
"$ROOT/build/vl_render/tb_render.exe" "$@"
