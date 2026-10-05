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

## M17 — CRTC / scanout — IN PROGRESS

Raster from the programmed CRTC (455 x 262, 320 x 240, 7.159 MHz), line-buffered scanout; full-core simulation shows
the BIOS boot picture through SDRAM + scanout. Waiting for the long simulation to reach attract.

## M20/M21 — Audio — DONE for crysking's feature set

`scripts/sim/audio_difftest.sh`: **4,783,055 samples (1,711,365 non-zero, gameplay) identical** to the reference,
Status register identical. Envelope/loop/16-bit/8-bit implemented per MAME, not exercised by the game (K5).

## M18, M19, M22–M28 — TODO
