#!/bin/sh
# Build and run the audio differential test (sim/audio/tb_sound.cpp).
set -e
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
sh "$ROOT/scripts/sim/vl_build.sh" "$ROOT/build/vl_sound" vr0_sound_top tb_sound \
  "$ROOT/rtl/memory/crystal_ram.sv $ROOT/rtl/vrender0/vr0_sound_regs.sv $ROOT/rtl/vrender0/vr0_sound.sv $ROOT/sim/audio/vr0_sound_top.sv" \
  "$ROOT/sim/audio/tb_sound.cpp $ROOT/sim/reference/crystal_ref.cpp"
"$ROOT/build/vl_sound/tb_sound.exe" "$@"
