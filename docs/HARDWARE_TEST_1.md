# Hardware test 1 — first DE10-Nano run

Purpose: confirm on real hardware what simulation already shows (BIOS boot, cartridge recognised, attract mode
graphics, controls, sound) and collect the observations simulation cannot give (SDRAM/DDR3 behaviour on the real
modules, HDMI/analog output, input mapping, audio level).

## Files

| File | Copy to |
| --- | --- |
| `Releases/Crystal_YYYYMMDD.rbf` (newest) | `/media/fat/_Arcade/cores/` |
| `mra/The Crystal of Kings.mra` | `/media/fat/_Arcade/` |
| `crysking.zip`, `crysbios.zip` (your MAME sets) | `/media/fat/games/mame/` |

## Expected sequence (full-core simulation; times include the ~1 s ROM download)

| Time after load | Expected picture | Sound |
| --- | --- | --- |
| 0-1 s | black, then thin vertical blue/green lines (BIOS self test, the board's "vertical line" boot screen) | none |
| ~11-13 s | BrezzaSoft logo fading in on light grey | none |
| ~15-20 s | "Insert Coin" top left/right, story text "It was an age known as ..." | none (attract is silent in MAME too) |
| ~25-60 s | red castle scenes, "Crystal of Kings" title art, blue night scene with armies | none |

Insert coin (Select) → start (Start) → "How to Play" screens → "SELECT WARRIOR" (4 characters) → gameplay with
music and sound effects.

## What to report (most useful first)

1. Does the BrezzaSoft logo appear? (yes / no / garbled — a photo helps)
2. Attract text/scenes correct? Any flicker, tearing, wrong colours, missing sprites, shifted lines?
3. After coin + start: does the character select work, does gameplay start?
4. Sound in gameplay: present? distorted? pitch/tempo plausible?
5. Controls: joystick directions, buttons A/B/X, start, coin.
6. HDMI picture stable? Analog/CRT (if available): stable 15 kHz sync?
7. Any hang: at which screen, after how long.
8. Your SDRAM module size (32/64/128 MB).
