# Milestones

Status values: DONE (acceptance evidence recorded), IN PROGRESS, TODO.

## M0 — Project / toolchain / MiSTer skeleton — DONE

* Goal: reproducible build of a MiSTer core shell. Scope: sys/, PLL (85.909 MHz), reset, test raster, Quartus
  project, build + summary scripts. Non-goals: any game function.
* Evidence: `scripts/build.ps1` → `QUARTUS: PASS (timing: MET)`, `Releases/Crystal_20261004.rbf` (2,525,112 B).
  Toolchain: Quartus 17.0 Lite, Verilator 5.050 + g++ 16.2 (MSYS2 ucrt64), Python 3.10.

## M1 — Hardware archaeology / source-of-truth spec — DONE

* Deliverables: `docs/MAME_REFERENCE.md` (pinned c2334733, deltas vs 0.289), `MEMORY_MAP.md`, `SE3208.md`,
  `VRENDER0_SYSTEM.md`, `VRENDER0_VIDEO.md`, `VRENDER0_AUDIO.md`, `PROTECTION.md`, `KNOWN_ISSUES.md`.
* Executable specification: `sim/reference` (SE3208 + board), validated by booting crysking through BIOS, logo,
  attract and (with coin/start) how-to-play / character select, matching MAME 0.289 screenshots in content.
* Measured usage (`crystal_sim --stats`): opcode coverage, I/O registers, renderer modes, memory traffic.
* Unknowns by category: none in A/B/C at this point; D items in KNOWN_ISSUES.

## M2 — ROM verification / MRA / memory plan — DONE

* Both BIOS files and the three flash chips verified (CRC32) against MAME; `mra/The Crystal of Kings.mra` and the
  AMG0110D-BIOS alternative; `scripts/mra_stream.py` validates and rebuilds the stream; layout in
  `docs/ROM_LAYOUT.md`; memory plan in `docs/SDRAM_BANDWIDTH.md`.
* Pending (with M5): RTL test that CPU-visible addresses return the expected ROM bytes.

## M3 — SE3208 reference harness — TODO
## M4 — Synthesizable SE3208 — TODO
## M5 — Board bus / BIOS boot — TODO
## M6 — Flash interface / protection overlay — TODO
## M7 — VRender0 system registers / IRQ — TODO
## M8 — Timers — TODO
## M9 — DMA — TODO
## M10 — Inputs / PIO / NVRAM / RTC — TODO
## M11 — SDRAM architecture — TODO
## M12 — Video command trace — partially available from the reference model (`--packets`)
## M13-M17 — Renderer, textures, scaling, blending, CRTC scanout — TODO
## M18 — First attract-mode video gate — TODO
## M19 — Controls — TODO
## M20-M21 — Audio — TODO
## M22 — First complete playable core — TODO
