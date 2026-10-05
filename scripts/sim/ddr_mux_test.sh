#!/bin/sh
# Build and run the DDR3 port arbiter bench (sim/memory/tb_ddr_mux.sv, Verilator --timing).
set -e
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
export PATH=/c/msys64/ucrt64/bin:/c/msys64/usr/bin:$PATH
OUT=$ROOT/build/vl_ddrmux
mkdir -p "$OUT"; cd "$OUT"
verilator --cc --exe --main --timing -O2 -Wno-fatal -Wno-WIDTH -Wno-CASEINCOMPLETE -Wno-UNOPTFLAT -Wno-LATCH -Wno-TIMESCALEMOD \
  --top-module tb_ddr_mux -CFLAGS "-std=c++20" --Mdir obj \
  "$ROOT/rtl/memory/crystal_ram.sv" "$ROOT/rtl/memory/crystal_ddr_mux.sv" \
  "$ROOT/sim/memory/tb_ddr_mux.sv" > verilate.log 2>&1 || { grep -E "%Error" verilate.log | head -30; exit 1; }
cd obj
INC="-I. -IC:/msys64/ucrt64/share/verilator/include -IC:/msys64/ucrt64/share/verilator/include/vltstd"
DEF="-DVERILATOR=1 -DVM_COVERAGE=0 -DVM_SC=0 -DVM_TIMING=1 -DVM_TRACE=0 -DVM_TRACE_FST=0 -DVM_TRACE_VCD=0 -DVM_TRACE_SAIF=0 -DVM_VPI=0 -DVL_TIME_CONTEXT"
rm -f *.o; for f in $(ls V*.cpp | grep -v __ALL) /c/msys64/ucrt64/share/verilator/include/verilated.cpp          /c/msys64/ucrt64/share/verilator/include/verilated_threads.cpp /c/msys64/ucrt64/share/verilator/include/verilated_timing.cpp; do
  g++ -pipe -O1 -std=c++20 -fcoroutines -faligned-new -w $INC $DEF -c "$f" -o "$(basename "$f" .cpp).o"
done
g++ -static V*.o verilated.o verilated_threads.o verilated_timing.o -o ../tb_ddr_mux.exe -pthread
cd ..
./tb_ddr_mux.exe
