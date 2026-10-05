# MAME reference

## Pinned revisions

| Role | Revision | Notes |
| --- | --- | --- |
| **Primary behavioural reference** | MAME master `c233473382353a00fb2d8b00d98c197cee910854` (2026-10-04) | Source of `sim/reference/*`. |
| Local executable | MAME **0.289** (`mame0289`, commit `f34f02505e32c1993c6a782b6814232cbfc74e36`, tag object `d0b7160e…`) at `C:\Users\klest\Downloads\mame\mame.exe` | Used for screenshots / Lua captures. |

Sources were fetched with a sparse, blob-less clone into `C:\Users\klest\Crystal_research\mame` (outside the repo).
Files studied: `src/mame/misc/crystal.cpp`, `src/devices/cpu/se3208/se3208.{cpp,h}`, `se3208dis.{cpp,h}`,
`src/devices/machine/vrender0.{cpp,h}`, `vr0uart.cpp`, `src/devices/video/vrender0.{cpp,h}`,
`src/devices/sound/vrender0.{cpp,h}`, `src/devices/machine/ds1302.{cpp,h}`, `intelfsh.{cpp,h}` and the other
VRender0 drivers (`psattack`, `menghong`, `trivrus`, `ddz`, `crospuzl`) for context.

## Differences 0.289 → master that matter

| Area | 0.289 | master (reference) | Effect on this core |
| --- | --- | --- | --- |
| SE3208 timing | 1 cycle / instruction (42.95 MIPS) | **3 cycles / instruction (14.32 MIPS)** | Core paces the CPU at 6 clk_sys (85.909 MHz) per instruction on average. 0.289 boots the same game 3x faster (screens appear earlier); content identical. |
| DMA | instantaneous block copy | **timed: first unit 2 VR0 clocks after enable, then one unit per 4 clocks**, IRQ when count reaches 0, counter masked to 24 bits | crysking does not use DMA in attract (measured); RTL follows master. |
| PIO bit 29 | reads 0 (no PIC device) | PIC hookup: reads `!written bit 29` (undumped PIC never drives), bit 30 = PIC reset | Reference model default = master (`--pic289` reproduces 0.289). |
| CRTC status | coarse | HSYNC/display bits per `hpos/vpos` | Software polls `CRTMOD` only in the BIOS (measured 33 reads). |
| Light pen / LIGHTC regs | in crtc array | separate | Not used by crysking. |
| `execute_flipping` | flips whenever render started | **skips when flip count is 0** | Implemented as master. |

## Reference model (`sim/reference`)

`se3208_ref.h` (CPU) and `crystal_ref.{h,cpp}` (board) are a restructured transcription of the files above into
a single-threaded, deterministic model with one time base, the VRender0 clock = core `clk_sys` = 85.909080 MHz:

| Event | MAME | Model |
| --- | --- | --- |
| CPU instruction | 3 cycles of 42.95 MHz | every 6 ticks, interrupt check after each instruction (as `execute_run`) |
| Timer n expiry | `2 * (pd+1) * (tcv+1)` VR0 clocks | same, ticks |
| DMA unit | 2 clocks after enable, then every 4 | same |
| Render pipeline | one packet per 1100 VR0 clocks (`clock()/1100` Hz) | same |
| Pixel clock | 14318180 [x2 if CRTTIM b7] / (div+1) | ticks/pixel = 6·(div+1) [/2] (always integral) |
| Vblank IRQ | screen vblank start = line `vdisp` | same; new CRTC geometry takes effect at the next frame |
| Sound sample | `clock()/972`, sound clock = VR0/2 → 44191.4 Hz | every 1944 ticks |
| DS1302 | wall clock | fixed start 2001-01-01, ticking seconds |

MAME's scheduler interleaves devices at timeslice granularity, so absolute instruction counts at which an
interrupt arrives differ from MAME; content and ordering are what the model guarantees. The model was checked
against MAME 0.289 screenshots (same attract content, same palette values once fades complete).

Bus semantics reproduced exactly: unmapped reads return 0; 16-bit handler regions (video and sound registers)
are called once per accessed 16-bit lane; 32-bit handlers receive data in its byte lane with a mem_mask; the
CPU splits unaligned 16/32-bit accesses into byte accesses.

## MAME quirks kept bit-exact in the model (documented, see KNOWN_ISSUES.md)

* Sound `status_r`/`noteon_r`/`intmask_r`/`intpend_r` shift the 32-bit value by 4, not 16, for the high half.
* Sound renderer `break`s out of the channel loop when a non-looping voice ends (remaining voices skip that sample).
* Palette conversion nudges colours that collide with the transparent colour or `NOTRANSCOLOR` (0xecda).
* SE3208 shift-by-zero carry follows the host CPU's masked shift count.

## Workarounds in MAME and their category

| Workaround | Category | Core policy |
| --- | --- | --- |
| `init_crysking` flash word patches (protection) | 2/4: substitutes the PIC's contribution | Isolated runtime overlay (`docs/PROTECTION.md`), switchable. |
| `patchreset` code at `0x44414f4c` (test-menu reset jumps to "LOAD") | 3: MAME-only convenience (software bug tolerated by hardware in some way unknown) | Not implemented; revisit in M23. |
| Palette colour nudging | 3: artifact of not emulating dither | Not reproduced in RTL unless a trace shows a visible difference. |
| Pipeline 1100-clock packet rate | 4: unknown real timing | RTL renders at its own measured rate; queue registers progress realistically. |
