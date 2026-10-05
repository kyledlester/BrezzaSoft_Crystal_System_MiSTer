#!/bin/sh
# Common Verilator build helper (MSYS2 ucrt64 toolchain on Windows).
#   vl_build.sh OUTDIR TOP EXE "sv files" "cpp files" [extra verilator args]
# Make/GCC child processes on this machine cannot see a temp directory (collect2/as fall back to C:\Windows),
# so objects are compiled with -pipe through Verilator's makefile and the final link is done here directly.
set -e
export PATH=/c/msys64/ucrt64/bin:/c/msys64/usr/bin:$PATH
OUT=$1; TOP=$2; EXE=$3; SV=$4; CPP=$5; shift 5
mkdir -p "$OUT"
cd "$OUT"
verilator --cc --exe -O3 --x-assign fast --x-initial fast -Wno-fatal -Wno-WIDTH -Wno-CASEINCOMPLETE \
  -Wno-UNOPTFLAT -Wno-LATCH -Wno-TIMESCALEMOD --top-module "$TOP" -CFLAGS "-std=c++17" --Mdir obj "$@" $SV $CPP \
  > verilate.log 2>&1 || { grep -E "%Error" verilate.log | head -30; exit 1; }
make -C obj -f "V$TOP.mk" -j 8 VM_PARALLEL_BUILDS=0 OPT_SLOW="-O1 -pipe" OPT_GLOBAL="-O1 -pipe" OPT_FAST="-O2 -pipe" CXX="g++ -pipe" \
  "V${TOP}__ALL.a" $(for f in $CPP; do b=$(basename "$f" .cpp); echo "$b.o"; done) verilated.o verilated_threads.o \
  > make.log 2>&1 || { grep -E "error|Error" make.log | head -30; exit 1; }
cd obj
g++ -static $(for f in $CPP; do b=$(basename "$f" .cpp); echo "$b.o"; done) verilated.o verilated_threads.o \
  "V${TOP}__ALL.a" -o "../$EXE.exe" -pthread
