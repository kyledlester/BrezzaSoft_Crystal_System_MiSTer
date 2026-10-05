# Crystal of Kings protection

## Hardware

The cartridge (PCB AMG0111B) carries an 18-pin PIC labelled "dgSMART-PR3 MAGIC EYES" (probably PIC16F84A) with a
3.579545 MHz crystal. Per ElSemi's note in `crystal.cpp` the PIC talks to the SE3208 over a software UART bit-banged
on PIO bit 29 (8 data bits, even parity, 1 stop bit, no clock), with PIO bit 30 as the PIC reset; the PIC supplies
code words that the dump has replaced with garbage. MAME master hooks a PIC16F84A to those lines
(`pic_porta_r/w`, PIOEDAT bit 29 = line level, open-drain with pull-up: writing PIO bit 29 = 1 pulls it low) but
the crysking PIC is **not dumped** (`NO_DUMP`), so MAME still relies on the patches below.

## MAME-compatible substitution (current behaviour)

`crystal_state::init_crysking()` (MAME c2334733, unchanged since 0.289) writes eight little-endian 16-bit words
into the `flash` region. In the dump every one of these words is `0xDEAD`:

| Flash byte offset (bank 0) | Dump | Substituted | Instruction |
| --- | --- | --- | --- |
| `0x007BB6` | `DEAD` | `DF01` | `CALL +2` (relative, offset 0x01·2) |
| `0x007BB8` | `DEAD` | `9C00` | `POP %PC` (return) |
| `0x00976A` | `DEAD` | `901C` | `PUSH %R4-%R2` |
| `0x00976C` | `DEAD` | `9001` | `PUSH %R0` |
| `0x008096` | `DEAD` | `90FC` | `PUSH %R7-%R2` |
| `0x008098` | `DEAD` | `9001` | `PUSH %R0` |
| `0x008A52` | `DEAD` | `4000` | `LERI 0x0` |
| `0x008A54` | `DEAD` | `403C` | `LERI 0x3c` |

These are function prologues and an extension-immediate pair: the PIC presumably delivers them at run time
(ElSemi: "it supplies some opcodes that have been replaced with garbage").

## Core implementation

`rtl/crystal/crystal_prot_overlay.sv` (isolated from all generic logic) substitutes exactly these eight words in
the download stream while the MRA's index-0 stream is written to the volatile DDR3 flash store. It is enabled
only when the MRA board record (index 1) says game id 1. The ZIP, the MRA and the stored ROM files are never
modified; nothing patched is written back or distributed. Disable it by using game id 0 in the board record.

Equivalence to MAME: MAME patches the flash region once at init; all CPU flash reads see the patched bytes. The
core stores the patched bytes in the flash store at load; all flash reads (CPU and DMA) see them. Identical.

## Future work (accuracy, category D)

A faithful implementation needs the PIC program (not dumped) plus the PIO bit-29 serial protocol at the right bit
timing (the SE3208/PIC clocks must be close to real hardware, cf. `topbladv` in MAME master, which runs its dumped
PIC16F628A). Until a dump exists the overlay is the only option.
