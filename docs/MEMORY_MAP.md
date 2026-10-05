# Crystal System memory map (SE3208 view)

Source: `crystal.cpp` `main_map`, `vrender0.cpp` `regs_map`/`audiovideo_map` (MAME c2334733). 32-bit little-endian
bus; unmapped reads return 0, unmapped writes are ignored. "Used" = accessed by crysking in the first 3600 frames
of attract (reference model statistics, `crystal_sim --stats`).

| Range | Size | Function | Width / notes | Used |
| --- | --- | --- | --- | --- |
| `00000000-0001FFFF` | 128 KiB | BIOS EPROM (MX27L1000) | read-only, writes ignored; vectors at 4·n | fetch (IRQ vectors, boot) |
| `01200000-01200003` | | P1/P2 inputs (read), coin counters (write, byte lane 0, bits 0-1) | 32-bit, active low | R |
| `01200004-01200007` | | P3/P4 inputs | | — |
| `01200008-0120000B` | | `(SYSTEM << 16) \| DSW \| 0xFF00FF00` | | R |
| `01280000-01280003` | | flash bank select: `bank = (data >> 1) & 7` | any width | W (1873) |
| `01320000-01320003` | | lamps: byte lanes 0 and 2 (`umask 0x00FF00FF`) | | — |
| `01400000-0140FFFF` | 64 KiB | NVRAM (battery SRAM, GM76C256 32 KiB on PCB; MAME maps 64 KiB) | RAM | W |
| `01800000-01FFFFFF` | | VRender0 system registers (docs/VRENDER0_SYSTEM.md) | 32-bit handlers | R/W |
| `01802004` | | PIOLDAT (board: DS1302 CE b24, SCLK b25, IO b28; PIC data b29, reset b30) | | R/W |
| `01802008` | | PIOEDAT: DS1302 IO → b28, PIC line → b29 | read | R |
| `02000000-027FFFFF` | 8 MiB | work RAM (SDRAM) | RAM | fetch/R/W |
| `02800000-02FFFFFF` | | work RAM mirror | | (donghaer) |
| `03000000-0300FFFF` | | video engine registers (docs/VRENDER0_VIDEO.md) | 16-bit handlers | R/W |
| `03800000-03FFFFFF` | 8 MiB | texture RAM (display lists, textures, palettes, samples) | RAM | W |
| `04000000-047FFFFF` | 8 MiB | frame RAM (frame buffers, samples) | RAM | R/W |
| `04800000-04800FFF` | | sound engine registers (docs/VRENDER0_AUDIO.md) | 16-bit handlers | W |
| `05000000-05FFFFFF` | 16 MiB | cartridge flash window, banked | read; `05000000` dword = command/ID register | R |
| `44414F4C-44414F7F` | | MAME-only reset patch RAM | not implemented in the core | — |

## Flash window details

* Bank `b < populated` maps flash bytes `b·16 MiB …`; other banks read as erased (`0xFF…`).
* The dword at `05000000` is special (MAME `flashcmd_r/w`): writes store the command; reads return the array
  dword when `cmd & 0xFF == 0xFF`, `0x00180089` (Intel 28F128J3A ID: manufacturer 0x89, device 0x18) when
  `0x90`, otherwise 0. Unpopulated bank: `0xFFFFFFFF` for both 0xFF and 0x90. Only the dword at offset 0 is
  affected; the rest of the window always reads the array.
* crysking writes the command register 12 times and reads it 54 times during boot (cartridge detection).
