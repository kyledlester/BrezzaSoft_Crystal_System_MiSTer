# Crystal System protection

Each cartridge carries a PIC microcontroller ("dgSMART-PR" family) that talks to the CPU over one data line
(PIO bit 29, reset on PIO bit 30). Per game:

| Game | PIC | MAME | Core |
| --- | --- | --- | --- |
| The Crystal of Kings | PIC16F84A, undumped | `init_crysking()` patches 8 flash words | the same words substituted while loading (overlay, game id 1) |
| Evolution Soccer | PIC16F84A, undumped | `init_evosocc()` patches 8 words in flash bank 2 | the same, game id 2 |
| Top Blade V | PIC16F628A, dumped | emulated (pic16x8x), VR0 at 80 MHz | `crystal_pic16` runs the firmware (MRA index 3), clock as MAME |
| Office Yeoin Cheonha | PIC16F84A, dumped | emulated (pic16x8x) | `crystal_pic16` runs the firmware |
| Donggul Donggul Haerong | PIC16F84A, undumped | `init_donghaer()` patches 8 words; the game's own PIC challenges still fail (MAME: not working) | MAME's 8 words plus 4 that make the challenges pass, game id 5 (below) |

The PIC core is verified instruction by instruction against `sim/reference/pic16_ref.h` (a port of MAME's
pic16x8x) by `scripts/sim/pic_difftest.sh`: both firmwares (2 M instructions each) and 40 random programs.
Without the PIC, Top Blade V stops at its version screen and Office Yeoin Cheonha at the BIOS boot.

## Donggul Donggul Haerong: why MAME marks it not working, and the fix

MAME's `init_donghaer()` restores four function prologues, which is enough to boot. The game also checks the PIC
continuously, and with no PIC every check fails. Found with the reference model (`crystal_sim --game donghaer`, RAM
watchpoints `--watch`, and the SE3208 disassembler from MAME) on the program the game decrypts into RAM:

* The protection module (RAM 0x020100a4-0x02012cd7, flash = RAM - 0x200f4a0) is stored XOR-encrypted with the
  32-bit key 0x2a401ae9 (the value the BIOS writes into its flag table at boot) and decrypted into RAM at start-up.
* A check routine (RAM 0x020120d8) runs up to four bit-banged PIC challenges (0x020118f4: the PIC must return 19
  bytes equal to a table at 0x02012a38; 0x020117b8, 0x02011c42, 0x02011f80). Each pass sets a flag (0x02012a0c,
  0x02012a10, 0x02012a14) and ORs a bit into 0x02012a18; each failure sets 0x02012a1c/20/24 and ORs into 0x02012a28.
  All passing gives a flag sum of 10.
* The timer-2 interrupt (IRQ 9, handler 0x0201142e) sums the eight flags every 21 ticks. If the sum is not 10 it
  corrupts 8 random work-RAM words (base 0x02010000 + random % 1 MiB): MAME's "very randomly corrupts itself". In
  the reference model the first visible damage is a heap pointer losing its top byte (frame 4166), which garbles the
  next level's background at frame 5004.
* Another routine (0x020115f8, called when 0x02012a28 is non-zero) spins forever: MAME's hangs.

Core (overlay entries 8-11, game id 5): the four challenge `CALL`s become `LDI 0x1,%R0` (the `LERI` before each
leaves R0 non-zero), so every challenge passes. Encrypted flash words: 0x2C76 = 0xC241, 0x2CAE = 0xC241,
0x2CBC = 0xF2E8, 0x2CF6 = 0xC241 (`word ^ 0x1AE9` at RAM addresses = 0 mod 4, `^ 0x2A40` otherwise; each checked to
decrypt to the original `CALL` before replacing it). Results in the reference model, same 2-player input script,
30,000 frames (8 min): MAME behaviour (`crystal_sim --mame-prot`) goes black at about frame 3,600 and crashes at
frame 23,501; with the fix the whole session plays (2-player split screen, continue, name entry, ranking, attract)
with no invalid instruction. The 20,000-frame attract loop is clean too.

## The Crystal of Kings

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
