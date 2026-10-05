#!/bin/sh
# Build and run the randomised renderer test (sim/vrender0/tb_render_rand.cpp).
set -e
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
sh "$ROOT/scripts/sim/vl_build.sh" "$ROOT/build/vl_render_rand" vr0_render tb_render_rand "$ROOT/rtl/vrender0/vr0_render.sv" \
  "$ROOT/sim/vrender0/tb_render_rand.cpp $ROOT/sim/reference/crystal_ref.cpp"
"$ROOT/build/vl_render_rand/tb_render_rand.exe" "$@"
