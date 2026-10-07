# Milestones

Status values: DONE (acceptance evidence recorded), IN PROGRESS, TODO. Evidence commands are listed so every
result can be reproduced (`scripts/sim/*.sh`; ROMs and generated streams live outside the repository).

## M0 — Project / toolchain / MiSTer skeleton — DONE

Quartus 17.0 Lite, Verilator 5.050 + g++ 16.2 (MSYS2 ucrt64), Python 3.10. `scripts/build.ps1` prints a PASS/FAIL
summary (`scripts/quartus_summary.py`) and copies the RBF to `Releases/`. First skeleton: timing met.

## M1 — Hardware archaeology / source-of-truth spec — DONE

`docs/*.md`; executable specification `sim/reference` (SE3208 + board, MAME c2334733), validated against MAME 0.289
screenshots (same attract content) and audio (attract silent in both). Usage statistics (`crystal_sim --stats`).

## M2 — ROM verification / MRA / memory plan — DONE

CRCs verified, MRA + alternative BIOS MRA, `scripts/mra_stream.py`. CPU-visible ROM bytes are checked on every
instruction by the board lock-step test (M5) and the flash store image by the core simulation.

## M3/M4 — SE3208 reference harness + synthesizable CPU — DONE

`scripts/sim/cpu_difftest.sh --seeds 500 --insns 20000`: **PASS, 10,000,000 random instructions**, all 74
operations, random memory latency, random interrupts (vectored and auto), unaligned accesses, illegal opcodes
reported. CPU synthesizes (Quartus). Throughput work (M25 early): pre-decode, fetch issued from DONE, early I-cache
read, D-cache + posted writes, direct bus path: the full core runs at the MAME rate (pacing-limited).

## M5 — Board bus / BIOS boot — DONE

`scripts/sim/board_lockstep.sh`: the RTL board (CPU, decode, VRender0 system/video/sound registers, DS1302,
renderer) against the reference CPU with its own copy of every RAM/ROM: **120 M instructions / 740 frames, zero
mismatches** in PC, opcode, registers, SR/SP/ER, every CPU data access (address, size, data), RAM read data and
device register read-back; interrupts identical in number (60 timer-2 IRQs by frame 80). Bug found and fixed:
device read data sampled one clock early.

## M6 — Flash interface / protection overlay — DONE

Bank register, erased banks, 0xFF/0x90 command semantics (board), DDR3 flash store with read buffers, loader
substitution of the 8 MAME words (`rtl/crystal/crystal_prot_overlay.sv`, switchable by the MRA game id). The core
simulation verifies the DDR3 image: identical to the ROM files except exactly the 8 protection words.

## M7/M8/M9/M10 — INTC, timers, DMA, inputs/PIO/RTC — DONE (functional), see KNOWN_ISSUES for unverified modes

Covered by the board lock-step (register read-back checks, interrupt chronology). DMA is implemented with MAME
master timing but crysking does not use it; it has no dedicated test yet (K10).

## M11 — SDRAM architecture — DONE

`scripts/sim/sdram_stress.sh`: 6 clients, random bursts, bank conflicts: **0 JEDEC timing violations**, data
checked, 0.737 words/clock under a random row-miss mix. Full-core simulation: 0 violations, 0 scanout underflows.

## M12–M16 — Display lists, renderer, textures, scaling, blending — DONE for crysking's feature set

`scripts/sim/render_difftest.sh --frames 7000 --input ...` (attract + gameplay): **PASS, 177,713 packets,
78,852 quads, 886,672,471 pixels identical** to the reference (8 bpp linear and tiled, transparency, shading,
scaling, alpha blending src=0x02 dst=0x21/0x22, fills, palettes, flips). 4/16 bpp, rotation and clamp are implemented
but not exercised by the game stream (K11).

## M17 / M18 — CRTC, scanout, full-core integration — DONE in simulation

Raster from the programmed CRTC (455 x 262, 320 x 240, 7.159 MHz), line-buffered scanout. Full-core simulation
(`scripts/sim/core_sim.sh`: crystal_core + SDRAM chip model + DDR3 model, real hps_io download of the MRA stream):
download + flash-store check pass, BIOS boot, BrezzaSoft logo, attract ("Insert Coin", story text) and, with
coin/start inputs (`--input 900:coin1:on ...`), the "How to Play" and "Select Warrior" screens with sprites, scaling
and alpha blending — rendered by the RTL renderer into SDRAM and read back by the scanout. 1950 frames, 0 scanout
underflows, 0 SDRAM protocol violations.

## M19 — Controls — DONE in simulation

Coin 1 / Start 1 / Button 1 from the MiSTer joystick bits reach the game in the full-core simulation (credit
accepted, game started, warrior selection). DIP switches and Test/Service via OSD: see README.

## M20/M21 — Audio — DONE for crysking's feature set

`scripts/sim/audio_difftest.sh`: **4,783,055 samples (1,711,365 non-zero, gameplay) identical** to the reference,
Status register identical. Envelope/loop/16-bit/8-bit implemented per MAME, not exercised by the game (K5).
Every CPU read of the sound registers is compared too. Full core: `tb_core --wav` captures audio_l/audio_r at the
44.19 kHz output rate; silent during attract, non-zero from the coin onwards (peak 10,775) in the gameplay run.

## M22 — Complete core, first hardware build — READY FOR HARDWARE TEST

Quartus 17.0 Lite: fit successful, 16,828 / 41,910 ALMs (40 %), 24,407 registers, 173 / 553 M10K (31 %),
57 / 112 DSP. Timing met at every clock: clk_sys (85.909 MHz) setup +0.241 ns / hold +0.254 ns, HDMI +0.361 ns,
SDRAM_CLK +2.619 ns, TNS 0. Closure came from register/pipeline changes only (renderer P2W/P6/P7 stages, registered
tag lookups, per-client SDRAM timing flags, single-adder ALU, two-clock shifts, registered fetch translation,
pipelined timer start, two-clock envelope/mix) -- all benches re-run identical after each change.
RBF: `Releases/Crystal_YYYYMMDD.rbf`; MRA: `MRA/The Crystal of Kings.mra`. Procedure: docs/HARDWARE_TEST_1.md.

### Hardware test 1 (owner, 128 MB SDRAM, 15-kHz CRT) and fixes

Result: boot, attract, coin/start, gameplay, controls and sound work. Findings and fixes (build 2026-10-05):
* CRT lost sync during the MiSTer loading screen -> the raster runs on its own reset through ROM download/reset.
* Moving sprites jittered, lines flashed around animations -> reproduced in simulation by comparing the full core
  frame by frame with the reference model over the How-to-Play demo (`scripts/sim/frame_compare.py`): the tested
  RTL differs on **86 of 361 frames** (sprites drawn with a mix of neighbouring animation poses); fixed RTL:
  **361 of 361 identical**. Causes: flips at vblank before the renderer finished the list, and in-place texture
  uploads overtaking the renderer. Fixes: flip waits for the renderer (K17), ordered texture-write queue (K19),
  texture snoop at write completion, double-buffered segment write-back (renderer 2.42 -> 1.32 clk/pixel).
* CRT Adjust added (NA/NB menu and bits; `scripts/sim/crt_test.sh` 1,182 checks PASS).
Quartus: timing met, clk_sys +0.556 ns, HDMI +0.449 ns, SDRAM_CLK +2.617 ns; 189 / 553 RAM blocks.

## M23–M28 — TODO (after hardware feedback)
