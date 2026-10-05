# VRender0 system block (base 0x01800000)

Source: MAME `machine/vrender0.cpp` (c2334733). All registers are 32-bit handlers; byte/word writes are merged
with the access mask (COMBINE_DATA). "crysking" column = reads/writes in 3600 frames of attract.

| Offset | Register | Behaviour | crysking |
| --- | --- | --- | --- |
| `0000` | SYSID | reads `0x00000A00` (VRender0+ id 0x0a, rev 0) | — |
| `0004` | CFGR | reads `0x00000041` (strapping) | — |
| `0010-0017` | watchdog | no-op | — |
| `0800/0810` | DMACx control | see DMA | W 2 (init) |
| `0804/0814` | DMASAx | source address | — |
| `0808/0818` | DMADAx | destination | — |
| `080C/081C` | DMATCx | count, 24 bits | W 2 |
| `0C04` | INTVEC | read: `int_high << 8`; write: byte 0 → clear pending bit `data & 0x1f`, byte 1 → `int_high = (data >> 8) & 7` | W 61 |
| `0C08` | INTEN | enable mask; writing also masks pending (`intst &= inten`) | R/W 75 |
| `0C0C` | INTST | pending; writes ignored | — |
| `1000-103F` | UART0/1 | UCON(+0), USTAT(+4), TX(+8), RX(+C), UBDR(+10); idle model | — |
| `1400+8n` | TMCONn | b0 enable, b1 periodic, b15:8 prescaler `pd`; reset `0xFF00` | R/W (timer 2/3) |
| `1404+8n` | TMCNTn | 16-bit reload (`tcv`), low lane only | W |
| `2004` | PIOLDAT | board-defined (Crystal: DS1302/PIC lines) | R/W 820 |
| `2008` | PIOEDAT | external pin levels | R 112 |
| `3400-3437` | CRTC | see below | W 2 (all regs, BIOS) |
| `3448` | LIGHTC | 2 bits | — |
| other | | reads 0 / writes ignored | `0008,0018,001C,0400,0408,2000,2408-2414,3438-3444,4000,4004` written once by the BIOS (memory controller, chip selects, PLL: no effect) |

## Interrupt controller

* `int_req(n)`: if `inten` bit n: `intst |= 1<<n` and the CPU IRQ line is asserted (level). Masked requests are
  **dropped** (MAME TODO says real HW probably latches them; kept as MAME).
* The line deasserts when `intst` becomes 0 (INTVEC clear or INTEN write).
* Acknowledge vector (CPU AUT mode): `(int_high << 5) | lowest set bit of intst`.
* Sources: 0 timer0, 1 timer1, 2 wave synth, 3 SIO, 5/6 ext0/1, 7/8 DMA0/1, 9 timer2, 10 timer3, 11/12 ext2/3,
  13-15 UART0 err/rx/tx, 16-18 UART1, 24 vblank, 26 PWM. Crystal board: coin 1 → 12, coin 2 → 19 (requested on
  the press edge by `coin_inserted`).

## Timers

Enable (b0 0→1) starts a one-shot of `2·(pd+1)·(tcv+1)` VR0 clocks; on expiry: if b1 restart, else clear b0;
then request its interrupt. Disabling cancels. There is no readable running count in MAME (TMCNT reads the reload
value). crysking polls TMCON3 190 K times (delay loop on b0 of a one-shot) — the core must clear b0 at expiry.

## DMA (MAME master)

On a 0→1 write of DMACx b10: start 2 clocks later, one unit every 4 clocks: `dst ← src` (width b1:0 = 8/16/32),
`src += ±w` unless hold b5 (dir b4), `dst` likewise (hold b3, dir b2), `count--`; when count is 0 clear b10 and
request IRQ 7+x. Repeat modes (b7:6 ≥ 2) are not emulated by MAME. crysking does not start any DMA in attract.

## CRTC (0x3400)

`CRTMOD(00)`, `CRTTIM(04)` (b2:0 divider, b3 VCLK select = internal 14.318 MHz, b7 double), `HSWBP(08)`,
`HDISP(0C)` (+1 = visible pixels), `HSFP(10)`, `FWINB(14)`, `VSBP(18)`, `VDISP(1C)`, `HTOT(20)` (written only if b10),
`VTOT(24)` (only if b11), `HLBP(28)`, `STAD0(2C)`, `STAD1(30)` (b0 = 0 → interlace). Write-protect via CRTMOD b8.
Status read of CRTMOD returns b15 (h display), b14 (v display), b13 (both) from the raster position.

MAME screen derivation (`crtc_update`): `htot = HTOT+1` (or derived from porches), `vtot = VTOT` →
non-interlaced `vtot/2 + 1 + 9`; visible `HDISP+1 × VDISP`. crysking's BIOS ends with
`455 × 262`, 320 × 240, CRTTIM divider 2 (7.159 MHz pixel clock) → 60.05 Hz, i.e. exactly MAME's default screen.
On the way it programs 640×480 / 831×617 (the "20 kHz" boot mode seen on real boards).

## Board PIO usage (crystal.cpp)

PIOLDAT write: b24 → DS1302 CE, b25 → SCLK, b28 → IO; (master) b29 → PIC data (low when 1), b30 → PIC reset.
PIOEDAT read: b28 = DS1302 IO, b29 = PIC data line (master).
