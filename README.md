# BrezzaSoft Crystal System for MiSTer

A MiSTer FPGA core for the **BrezzaSoft Crystal System** (2001), a cartridge arcade platform built around the
MagicEyes **VRender0** system-on-chip (ADChips SE3208 32-bit EISC CPU, 2D texture-mapping renderer, 32-voice
wavetable sound). First target game: **The Crystal of Kings** (`crysking`).

**Status: in development — first hardware test build.** Progress and evidence: [docs/MILESTONES.md](docs/MILESTONES.md).

## Requirements

* MiSTer DE10-Nano with an SDRAM module (32 MiB or larger). The 48 MiB cartridge image is kept in the DE10-Nano's
  DDR3; work, texture and frame RAM are in SDRAM.
* MAME ROM sets `crysking.zip` and `crysbios.zip` (verified against MAME 0.289 and master c2334733).
  ROMs are not included; you must supply your own.

## Install

1. Copy `Releases/Crystal_YYYYMMDD.rbf` to `/media/fat/_Arcade/cores/`.
2. Copy `mra/The Crystal of Kings.mra` to `/media/fat/_Arcade/` (optional: `mra/_alternatives/_The Crystal of Kings/`
   to `/media/fat/_Arcade/_alternatives/` for the AMG0110D BIOS version).
3. Put `crysking.zip` and `crysbios.zip` in `/media/fat/games/mame/`.
4. Load "The Crystal of Kings" from the Arcade menu. Loading the 48 MiB set takes a few seconds.

## Controls

MAME `crystal` input layout. Map them in MiSTer's controller setup:

| MiSTer | Crystal System |
| --- | --- |
| D-pad / stick | 8-way joystick (players 1-4 from joysticks 1-4) |
| Button 1 (A) | Button 1 (attack) |
| Button 2 (B) | Button 2 |
| Button 3 (X) | Button 3 (magic) |
| Button 4 (Y) | Button 4 |
| Start | Start (per player) |
| Coin (Select) | Coin 1 (player 1 joystick) / Coin 2 (player 2 joystick) |
| Service (R) | Service 1 |
| OSD "Test switch (SW3)" | the board's test switch |

The Crystal of Kings: A = attack, A+B = emergency avoidance, C (button 3) = magic (from the in-game "How to play").

## DIP switches (MRA, OSD)

Pause, Free Play, DSW 3-7 (unknown, as MAME), Test. Defaults: all Off.

## OSD

* **Aspect ratio**, **Scandoubler Fx**: as other MiSTer arcade cores.
* **CRT Adjust** submenu (native 15-kHz output, Scandoubler Fx None): *CRT Adjust* Off/On, *CRT H-Size* -12..+10 %,
  *CRT H-Position* -48..+42 pixels, *CRT V-Shift* -8..+7 lines (negative values stop at -3 so VSync never lands
  on the picture). Same menu, bits and behaviour as the NA-1/NA-2 and NB-1 cores; the sync never changes, so the
  CRT keeps its lock while adjusting. Off is a true bypass. Implementation: `rtl/crystal/crystal_crt_adjust.sv`
  around the unmodified MiSTer-CRT-Adjust `rtl/vendor/crt_adjust.sv` (rmonic79, GPL-3.0).
* **Test switch (SW3)**: enters the BIOS/game test menu.
* **CPU speed**: *MAME (14.3 MIPS)* reproduces MAME master's SE3208 rate; *Unlimited* removes the pacing
  (diagnostic).
* **Stereo mix**.

## Building

Quartus Prime Lite 17.0: `powershell -File scripts\build.ps1` (prints a PASS/FAIL summary; the RBF is copied to
`Releases/`). Simulations: `scripts/sim/*.sh` (Verilator 5, MSYS2 ucrt64); see docs/ARCHITECTURE.md.

## Documentation

[Architecture](docs/ARCHITECTURE.md) · [Memory map](docs/MEMORY_MAP.md) · [ROM layout](docs/ROM_LAYOUT.md) ·
[SE3208](docs/SE3208.md) · [VRender0 system](docs/VRENDER0_SYSTEM.md) · [video](docs/VRENDER0_VIDEO.md) ·
[audio](docs/VRENDER0_AUDIO.md) · [Protection](docs/PROTECTION.md) · [SDRAM/DDR3](docs/SDRAM_BANDWIDTH.md) ·
[MAME reference](docs/MAME_REFERENCE.md) · [Reuse & licenses](docs/REUSE_AND_LICENSES.md) ·
[Known issues](docs/KNOWN_ISSUES.md) · [Milestones](docs/MILESTONES.md)

## License

GPL-3.0-or-later. The MiSTer framework in `sys/` is GPL-2.0+ (`LICENSE.MiSTer`). The reference model in
`sim/reference` is derived from BSD-3-Clause MAME sources (see file headers).
