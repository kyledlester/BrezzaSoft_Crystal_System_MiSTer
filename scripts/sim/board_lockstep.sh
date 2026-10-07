#!/bin/sh
# Build and run the board-level lock-step test (sim/integration/tb_board.cpp).
#   scripts/sim/board_lockstep.sh [tb_board args...]   (default stream: C:/Users/klest/Crystal_research/stream)
set -e
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
R=$ROOT/rtl
SV="$R/memory/crystal_ram.sv $R/cpu/se3208/se3208_cpu.sv $R/vrender0/vr0_sys.sv $R/vrender0/vr0_video_regs.sv $R/vrender0/vr0_sound_regs.sv $R/vrender0/vr0_render.sv $R/vrender0/vr0_sound.sv \
 $R/crystal/crystal_pic16.sv $R/crystal/crystal_ds1302.sv $R/crystal/crystal_raster.sv $R/crystal/crystal_board.sv"
sh "$ROOT/scripts/sim/vl_build.sh" "$ROOT/build/vl_board" crystal_board tb_board "$SV" "$ROOT/sim/integration/tb_board.cpp"
"$ROOT/build/vl_board/tb_board.exe" --stream C:/Users/klest/Crystal_research/stream "$@"
