# BrezzaSoft Crystal System for MiSTer

<img width="640" height="480" alt="image" src="https://github.com/user-attachments/assets/44f2e451-28d4-4d14-b592-9e8910246c3d" />

A MiSTer FPGA core for the **BrezzaSoft Crystal System** (2001), a cartridge arcade
platform built around the MagicEyes **VRender0** system-on-chip. Supported games:
**The Crystal of Kings**, **Evolution Soccer**, **Top Blade V** and **Office Yeoin Cheonha**.
One core (`Crystal`) is written for the whole board; each game has its own MRA.

I created this core because I wanted to play these games on my MiSTer FPGA. I am posting it here and open sourcing it for everyone to enjoy and give feedback/make improvements. This core was created with the assistance of AI tooling.

**Status: beta.** All four games boot, run their attract modes and are playable
on real MiSTer hardware, with sound, controls, DIP switches, NVRAM saves, HDMI and
15 kHz CRT output, OSD orientation, and CRT adjustment tools.

## Requirements

* MiSTer DE10-Nano with an **SDRAM module (32 MB or larger)**. The 48 MB cartridge
  image is kept in the DE10-Nano's DDR3; work, texture and frame RAM are in SDRAM.

## Quick start

1. Copy the core from [`Releases/`](Releases/) (`Crystal_YYYYMMDD.rbf`) to
   **`/media/fat/_Arcade/cores/`**.
2. Copy the MRA files from [`MRA/`](MRA/) to **`/media/fat/_Arcade/`**.
   For the alternative BIOS set, copy the `_The Crystal of Kings` folder from
   [`MRA/_alternatives/`](MRA/_alternatives/) to **`/media/fat/_Arcade/_alternatives/`**.
3. Put the MAME 0.289 ROM zips in **`/media/fat/games/mame/`**: **`crysbios.zip`** (the
   Crystal System BIOS, needed by every game except Office Yeoin Cheonha) and the game zips
   **`crysking.zip`**, **`evosocc.zip`**, **`topbladv.zip`**, **`officeye.zip`**.
4. Load the game from the **Arcade** menu. Loading the 48 MB set takes a few seconds.

ROMs are not included. You must supply your own.

## Supported games

| Game | MAME set | Year | Genre | Board | Status |
| --- | --- | --- | --- | --- | --- |
| The Crystal of Kings | `crysking` | 2001 | Hack and slash | Crystal System (AMG0110B BIOS) | Playable on hardware |
| Evolution Soccer | `evosocc` | 2001 | Soccer | Crystal System (AMG0110B BIOS) | Playable on hardware |
| Top Blade V | `topbladv` | 2003 | Spinning-top battle | Crystal System, PIC16F628A protection, 80 MHz VRender0 | Playable on hardware |
| Office Yeoin Cheonha (version 1.2) | `officeye` | 2001 | Party / reaction (3 players) | Crystal System hardware, own BIOS, PIC16F84A protection | Playable on hardware |

The protection microcontrollers of Top Blade V and Office Yeoin Cheonha are dumped (MAME), so the core runs
their firmware on a PIC16 core of its own; The Crystal of Kings and Evolution Soccer use MAME's protection
patches, applied while loading (the ROM files are never modified).

### Alternatives

These use the same core and the same game, with a different ROM set.

| Game | MAME set | Year | Parent game | Status |
| --- | --- | --- | --- | --- |
| The Crystal of Kings (AMG0110D BIOS) | `crysking` | 2001 | The Crystal of Kings | Same game, later board BIOS |

## Controls

MAME `crystal` input layout. Map them in MiSTer's controller setup:

| MiSTer | Crystal System |
| --- | --- |
| D-pad / stick | 8-way joystick (players 1-2 from joysticks 1-2) |
| Button 1 (A) | Button 1 |
| Button 2 (B) | Button 2 |
| Button 3 (X) | Button 3 |
| Button 4 (Y) | Button 4 |
| Start | Start (per player) |
| Coin (Select) | Coin 1 |
| Service (R) | Service 1 |

Game-specific layouts (MAME): **Top Blade V** uses buttons 1-2 for players 1-2. **Office Yeoin Cheonha** is a
three-player game with three coloured buttons each: Button 1 = Red, Button 2 = Green, Button 3 = Blue, Start
per player (players 1-3 from joysticks 1-3).

The Crystal of Kings: A = attack, A+B = emergency avoidance, C (button 3) = magic.

## OSD options

* **Aspect ratio**, **Scandoubler Fx**: as other MiSTer arcade cores.
* **Orientation**:
  * *Original* (default).
  * *Flipped*: the picture turned 180 degrees inside the core. It works on every
    output (HDMI, analog / CRT, Direct Video) and adds no latency, because it is
    part of the native picture rather than a frame buffer.
  * *Rotate CW* / *Rotate CCW*: the HDMI picture turned 90 degrees through the
    MiSTer scaler, for a vertical monitor. The analog output keeps the original
    picture and Direct Video is not rotated. The aspect ratio follows (3:4 when
    rotated).
* **DIP Switches**: Pause, Free Play, DSW 3-7 (unused but implemented as per the mainboard) and Test (DSW:8).
  All Off by default. *Test* On boots into the BIOS set-up menu ("PLEASE DIP 8 OFF"
  when leaving it).
* **CRT Adjust** (native 15 kHz output, Scandoubler Fx None): *CRT H-Size* -12..+10 %,
  *CRT H-Position* -48..+42 pixels, *CRT V-Shift* -8..+7 lines. The same menu and
  behaviour as the NA-1/NA-2 and NB-1 cores, thanks to rmonic79/MiSTer-CRT-Adjust.
  The sync never changes, so the CRT keeps its lock while adjusting; Off is a true
  bypass.
* **Test switch (SW3)**: enters the BIOS/game test menu.
* **CPU speed**: *MAME (14.3 MIPS)* (default) reproduces MAME's SE3208 rate;
  *Unlimited* removes the pacing (diagnostic only).
* **Stereo mix**, **Reset**.

## Accuracy

MAME's `crystal` driver (0.289) is the behavioural reference. During development the
core was compared against a C++ model of the MAME driver in simulation:

* the SE3208 CPU instruction by instruction (10 million random instructions, and
  120 million instructions of the real BIOS and game in lock-step),
* the renderer pixel for pixel (about 887 million pixels across attract and gameplay),
* the sound sample for sample (4.8 million samples of gameplay audio),
* the whole core frame by frame over the How to Play demo.

The core differs from MAME in one place on purpose. MAME's renderer finishes every
display list instantly, so MAME can flip the frame at vblank no matter what. A real
renderer takes time, so the core waits for the renderer to reach the end of the
frame's list before flipping, and keeps texture uploads behind the lists that use
the old textures. Without this, moving sprites jitter and lines flash around
animations.

## About the hardware

The Crystal System main board (AMG0110B/D) is built around the MagicEyes
**VRender0** system-on-chip:

* ADChips **SE3208** 32-bit EISC CPU.
* A 2D texture-mapping renderer with scaling, alpha blending and palettes, drawing
  into frame RAM.
* A 32-voice wavetable sound engine.
* Interrupt controller, four timers, two DMA channels, UARTs, PIO and a CRTC.
* Three 8 MB SDRAMs (work, texture and frame RAM), a 128 KB BIOS ROM,
  battery-backed SRAM and a DS1302 real-time clock, on a 14.31818 MHz crystal.
* Games come on cartridges with up to eight 16 MB Intel flash chips and a
  protection PIC.

## About the core

* Original RTL for the SE3208 CPU and the VRender0 blocks (system, video and sound);
  no earlier HDL implementation of either existed. The CPU and VRender0 blocks have
  no game-specific code; the MRA carries a small board record (game id, number of
  flash banks).
* Runs the genuine Crystal System BIOS from `crysbios.zip`.
* Cartridge flash in DDR3, with the board's flash banking and command behaviour.
* Protection: the cartridge PIC has never been dumped, so the core applies the same
  small set of word substitutions MAME uses. See [docs/PROTECTION.md](docs/PROTECTION.md).
* Full video: textured, tiled, scaled and alpha-blended quads, fills and palettes,
  read out of frame RAM through line buffers so the display never waits on memory.
* Sound: all 32 voices at MAME's 44.19 kHz sample rate, stereo, with an optional
  stereo mix.
* Battery RAM saved to the SD card as `.nvm`.
* Native 15 kHz output for CRTs, with optional CRT Adjust.
* Timing closes at the full 85.909 MHz system clock (6 × 14.31818 MHz) on every
  clock domain.

### Known issues

* The BIOS briefly sets up a 640 x 480 (about 31 kHz) mode during boot before the
  320 x 240 game mode, as on the real board. A 15 kHz CRT may roll for a moment
  just after the loading screen.
* Sound matches MAME, which means the VRender0's reverb, ping-pong loops and sustain
  are not emulated (they are not documented anywhere). The Crystal of Kings has not
  been seen using them.
* The real CPU's per-instruction timing and the real renderer's speed are unknown;
  the core uses MAME's rates.

More detail: [docs/KNOWN_ISSUES.md](docs/KNOWN_ISSUES.md).

## Releases

Builds are in [`Releases/`](Releases/) as `Crystal_YYYYMMDD.rbf`. The MRA names the
core without the date (`<rbf>Crystal</rbf>`), and MiSTer loads the newest dated file
in `_Arcade/cores/`. You are welcome to run your own build if you'd prefer.

## Building

Quartus Prime Lite 17.0: `powershell -File scripts\build.ps1` (prints a PASS/FAIL
summary and copies a dated RBF into `Releases/`). Simulations: `scripts/sim/*.sh`
(Verilator 5, MSYS2 ucrt64); see [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Documentation

* [Architecture](docs/ARCHITECTURE.md)
* [Memory map](docs/MEMORY_MAP.md) · [ROM layout](docs/ROM_LAYOUT.md)
* [SE3208 CPU](docs/SE3208.md)
* [VRender0 system](docs/VRENDER0_SYSTEM.md) · [video](docs/VRENDER0_VIDEO.md) ·
  [audio](docs/VRENDER0_AUDIO.md)
* [Protection](docs/PROTECTION.md) · [SDRAM / DDR3](docs/SDRAM_BANDWIDTH.md)
* [MAME reference](docs/MAME_REFERENCE.md)
* [Known issues](docs/KNOWN_ISSUES.md) · [Milestones](docs/MILESTONES.md)
* [Credits and third-party components](docs/REUSE_AND_LICENSES.md)

## Credits

* **CRT Adjust**: [rmonic79/MiSTer-CRT-Adjust](https://github.com/rmonic79/MiSTer-CRT-Adjust)
  by Umberto Parisi (rmonic79) with Andrea Bogazzi (@asturur). The OSD CRT Adjust
  menu (H-size, H-position, V-shift) is their module, included unmodified as
  `rtl/vendor/crt_adjust.sv` (GPL-3.0-or-later).
* **MiSTer framework**: [MiSTer-devel/Template_MiSTer](https://github.com/MiSTer-devel/Template_MiSTer)
  by Sorgelig and the MiSTer contributors, in `sys/`, including the scaler and the
  `screen_rotate` module used for the Rotate CW / CCW orientations.
* **MAME**: the `crystal` driver and VRender0 devices by ElSemi and Angelo Salese,
  the SE3208 CPU core by ElSemi and the DS1302 by Curt Coder are the behavioural
  reference for this core. The simulation reference model in `sim/reference` is
  derived from them (BSD-3-Clause).
* **ADChips**: the SE3208 quick reference card, used as a reference for the CPU.

Full list with revisions and file paths:
[docs/REUSE_AND_LICENSES.md](docs/REUSE_AND_LICENSES.md).

## License

GPL-3.0-or-later (see [LICENSE](LICENSE)). The MiSTer framework in `sys/` keeps its
own notices ([LICENSE.MiSTer](LICENSE.MiSTer)); CRT Adjust is GPL-3.0-or-later. The
reference model in `sim/reference` is derived from BSD-3-Clause MAME sources (see the
file headers). See [docs/REUSE_AND_LICENSES.md](docs/REUSE_AND_LICENSES.md).

No ROMs, BIOS images or other game data are included in this repository.
