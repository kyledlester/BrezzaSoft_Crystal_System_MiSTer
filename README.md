# BrezzaSoft Crystal System for MiSTer

A MiSTer FPGA core for the **BrezzaSoft Crystal System** (2001), a cartridge arcade platform built around the
MagicEyes **VRender0** system-on-chip (ADChips SE3208 32-bit EISC CPU, 2D texture-mapping renderer, 32-voice
wavetable sound). First target game: **The Crystal of Kings** (`crysking`).

**Status: in development, not yet usable on hardware.** Progress and evidence: [docs/MILESTONES.md](docs/MILESTONES.md).

## Requirements (planned)

* MiSTer DE10-Nano with an SDRAM module (32 MiB or larger).
* MAME ROM sets `crysking.zip` and `crysbios.zip` (verified against MAME 0.289 / master c2334733).
  ROMs are not included; you must supply your own.

## Install (planned)

1. Copy `Releases/Crystal_YYYYMMDD.rbf` to `/media/fat/_Arcade/cores/`.
2. Copy `mra/The Crystal of Kings.mra` to `/media/fat/_Arcade/` (and `mra/_alternatives/` to
   `/media/fat/_Arcade/_alternatives/` for the AMG0110D BIOS version).
3. Put `crysking.zip` and `crysbios.zip` in `/media/fat/games/mame/`.

## Building

Quartus Prime Lite 17.0: `powershell -File scripts\build.ps1` (prints a PASS/FAIL summary; the RBF is copied to
`Releases/`). Reference model and simulations: see `docs/ARCHITECTURE.md` and `sim/`.

## Documentation

[Architecture](docs/ARCHITECTURE.md) · [Memory map](docs/MEMORY_MAP.md) · [ROM layout](docs/ROM_LAYOUT.md) ·
[SE3208](docs/SE3208.md) · [VRender0 system](docs/VRENDER0_SYSTEM.md) · [video](docs/VRENDER0_VIDEO.md) ·
[audio](docs/VRENDER0_AUDIO.md) · [Protection](docs/PROTECTION.md) · [SDRAM/DDR3](docs/SDRAM_BANDWIDTH.md) ·
[MAME reference](docs/MAME_REFERENCE.md) · [Reuse & licenses](docs/REUSE_AND_LICENSES.md) ·
[Known issues](docs/KNOWN_ISSUES.md)

## License

GPL-3.0-or-later. The MiSTer framework in `sys/` is GPL-2.0+ (`LICENSE.MiSTer`). The reference model in
`sim/reference` is derived from BSD-3-Clause MAME sources (see file headers).
