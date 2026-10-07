# ROM layout

## MAME sets (verified)

All files in the user's MAME 0.289 sets match MAME master's `ROM_START` definitions byte for byte (CRC32 checked by
`scripts/mra_stream.py`).

| Set | File | Size | CRC32 | MAME region / offset |
| --- | --- | --- | --- | --- |
| `crysbios` | `mx27l1000.u14` | 131072 | `beff39a9` | `maincpu` 0x00000, system BIOS 0 "amg0110b" (default) |
| `crysbios` | `mx27l1000-alt.u14` | 131072 | `1e8175c8` | `maincpu` 0x00000, system BIOS 1 "amg0110d" ("newer?") |
| `crysking` | `bcsv0004f01.u1` | 16777216 | `8feff120` | `flash` (`ROM_REGION32_LE`) 0x0000000 |
| `crysking` | `bcsv0004f02.u2` | 16777216 | `0e799845` | `flash` 0x1000000 |
| `crysking` | `bcsv0004f03.u3` | 16777216 | `659e2d17` | `flash` 0x2000000 |
| `crysking` | `crysking_pic16f84a.u14` | 0x4280 | NO_DUMP | `pic` (not needed: protection overlay) |

Byte order: `ROM_REGION32_LE` + plain `ROM_LOAD` means file byte *i* is CPU byte address *i* in the little-endian
32-bit space (the SE3208 reads `u32 = b0 | b1<<8 | b2<<16 | b3<<24`). No swapping. The BIOS reset vector
(`read32(0)`) and the flash header were checked by booting the reference model on the raw files.

## MiSTer download stream (MRA index 0)

| Stream offset | Length | Content | Core destination |
| --- | --- | --- | --- |
| `0x0000000` | `0x1000000` | `bcsv0004f01.u1` flash bank 0 | DDR3 flash store |
| `0x1000000` | `0x1000000` | `bcsv0004f02.u2` flash bank 1 | DDR3 |
| `0x2000000` | `0x1000000` | `bcsv0004f03.u3` flash bank 2 | DDR3 |
| `0x3000000` | `0x20000` | BIOS (`mx27l1000.u14`, or `-alt` in the alternative MRA) | SDRAM bank 3 |

Total 0x3020000 bytes. Games with fewer/more flash chips use the same scheme (bank *n* at n·16 MiB, BIOS after the
last populated bank) and declare the bank count in the board record:

| Game | Flash banks (stream) | BIOS | Stream size |
| --- | --- | --- | --- |
| crysking | `bcsv0004f01.u1`-`f03.u3` (3) | `mx27l1000.u14` (crysbios) | 0x3020000 |
| evosocc | `bcsv0001u01`-`u03` (3) | `mx27l1000.u14` (crysbios) | 0x3020000 |
| topbladv | `flash.u1` (1) | `mx27l1000.u14` (crysbios) | 0x1020000 |
| officeye | `flash.u1`, `flash.u2` (2) | `bios.u14` (its own, from officeye.zip) | 0x2020000 |

## MRA index 3: protection PIC firmware

The MAME `pic` region, byte for byte (16-bit little-endian words): program memory at word 0, configuration word at
word 0x2007, EEPROM byte *i* at word 0x2100 + *i*. Top Blade V: PIC16F628A, 0x4300 bytes
(`top_blade_v_pic16f628a.u14`, CRC `9cdea57b`; older sets: `top_blade_v_pic16c727.bin`). Office Yeoin Cheonha:
PIC16F84A, 0x4280 bytes (`office_yeo_in_cheon_ha_pic16f84a.u14`, CRC `7561cdf5`). The MRA matches by CRC. The
loader writes program words and EEPROM into `crystal_pic16`; the configuration word is not used (both have the
watchdog disabled).

## MRA index 1: board record (16 bytes)

| Byte | Meaning |
| --- | --- |
| 0-3 | `"CRYS"` magic |
| 4 | record version (1) |
| 5 | game id: 0 = generic (no overlay), 1 = crysking, 2 = evosocc, 3 = topbladv, 4 = officeye |
| 6 | populated flash banks (1-8) |
| 7-15 | reserved, 0 |

## Generated files

`scripts/mra_stream.py MRA --out DIR` reproduces the exact streams the core receives (used by simulations).
Generated streams contain copyrighted data and live only in `C:\Users\klest\Crystal_research\stream`, never in
the repository.
