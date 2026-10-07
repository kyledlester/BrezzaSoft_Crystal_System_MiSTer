#!/bin/sh
# Build and run the CRT Adjust bench (sim/video/tb_crt.sv, Verilator --timing).
set -e
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
export PATH=/c/msys64/ucrt64/bin:/c/msys64/usr/bin:$PATH
WIDE=${WIDE:-0}
OUT=$ROOT/build/vl_crt$WIDE
mkdir -p "$OUT"; cd "$OUT"
verilator --cc --exe --main --timing -O2 -Wno-fatal -Wno-WIDTH -Wno-CASEINCOMPLETE -Wno-UNOPTFLAT -Wno-LATCH -Wno-TIMESCALEMOD \
  --top-module tb_crt -GWIDE=$WIDE -CFLAGS "-std=c++20" --Mdir obj \
  "$ROOT/rtl/crystal/crystal_raster.sv" "$ROOT/rtl/vendor/crt_adjust.sv" "$ROOT/rtl/crystal/crystal_crt_adjust.sv" \
  "$ROOT/sim/video/tb_crt.sv" > verilate.log 2>&1 || { grep -E "%Error" verilate.log | head -30; exit 1; }
cd obj
INC="-I. -IC:/msys64/ucrt64/share/verilator/include -IC:/msys64/ucrt64/share/verilator/include/vltstd"
DEF="-DVERILATOR=1 -DVM_COVERAGE=0 -DVM_SC=0 -DVM_TIMING=1 -DVM_TRACE=0 -DVM_TRACE_FST=0 -DVM_TRACE_VCD=0 -DVM_TRACE_SAIF=0 -DVM_VPI=0 -DVL_TIME_CONTEXT"
rm -f *.o; for f in $(ls V*.cpp | grep -v __ALL) /c/msys64/ucrt64/share/verilator/include/verilated.cpp          /c/msys64/ucrt64/share/verilator/include/verilated_threads.cpp /c/msys64/ucrt64/share/verilator/include/verilated_timing.cpp; do
  g++ -pipe -O1 -std=c++20 -fcoroutines -faligned-new -w $INC $DEF -c "$f" -o "$(basename "$f" .cpp).o"
done
g++ -static V*.o verilated.o verilated_threads.o verilated_timing.o -o ../tb_crt.exe -pthread
cd ..
./tb_crt.exe
