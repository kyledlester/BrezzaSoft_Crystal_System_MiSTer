# VRender0 video engine

Source: MAME `video/vrender0.cpp` (c2334733). Registers at `0x03000000` (16-bit handlers, called per 16-bit lane).

| Offset | Register | Behaviour |
| --- | --- | --- |
| `80` | CMDQ front (R/W) | software's write pointer (11 bits) |
| `82` | CMDQ rear (R) | engine's read pointer (11 bits) |
| `8C` | render control | b7 draw select (draw to front), b3 reset (clears both pointers), b2 start, b1:0 dither |
| `8E` | display bank (R) | current display bank bit |
| `90` | bank1 select | b15: bank 1 at frame RAM `0x400000` instead of `0x100000` |
| `A6` | flip count | write byte 1 → increment, 0 → clear; read value (polled by idle loops) |

## Display list

Packets are 32 16-bit words in texture RAM at `queue_index · 64` bytes (2048 entries = first 128 KiB). The
engine consumes one packet per `1100` VR0 clocks in MAME (an approximation: 78 K packets/s) while `start` is set,
no flip-sync is pending and `rear != front`.

| Word | Content |
| --- | --- |
| 0 | flags: b0 flip-sync, b7 flip-async (both end the packet), b1 alpha-blend, b2 transparency, b3 texture enable, b4 shade, b5 clamp, b6 load palette, b8 draw, b9 has tx/ty, b10 has deltas, b11 has blend state, b12 has shade colour, b13 has transparent colour, b14 has texture state |
| 1-4 | dx (10 bit), dy (9), endx (10), endy (9) — inclusive destination rectangle |
| 5-8 | tx, ty: 21-bit fixed point (9 fractional bits); defaults 0 |
| 9-16 | txdx, tydx, txdy, tydy (21 bit, 9 frac); defaults identity |
| 17-20 | src/dst alpha colour (24 bit) + blend selects (6 bit) |
| 21-22 | shade colour (24 bit RGB) |
| 23-24 | transparent colour (24 bit RGB888, compared after RGB565 conversion) |
| 25-28 | tile map offset (·128), texture offset (·128), palette offset (·1024 / 8), w28: b2:0 width = 8<<n, b5:3 height, b7:6 format (0 4bpp, 1 8bpp, 2/3 16bpp), b11:8 4bpp palette bank, b12 tiled |

State words are sticky (persist across packets) except tx/ty/deltas, which reset to defaults when absent.

## Pixel pipeline (per destination pixel, x inner loop)

1. `tx = x_tx >> 9`, `ty = x_ty >> 9`; clamp mode skips texels outside `[0,w)×[0,h)`, otherwise wrap (mask).
2. Tiled: `index = tex16(tile + ((ty>>3)·(w>>3) + (tx>>3))·2)`, skip if 0; texel offset `index·64 + (ty&7)·8 + (tx&7)`.
   Linear: `ty·w + tx`.
3. Texel → RGB565: 4bpp nibble (high nibble for even offsets) through `palette[bank·16 + n]`, 8bpp through the
   256-entry palette, 16bpp direct.
4. Skip if equal to the transparent colour (when b2), else optional shade (`c·shade/256` per 8-bit channel),
   optional alpha blend (`src·sf + dst·df >> 8`, factor selects 0x01 zero, 0x02 src colour, 0x04 src pixel, 0x08
   dst colour, 0x10 dst pixel, b5 invert), write RGB565.
5. Non-textured quads fill with `RGB565(shade colour)` (or blend it).

Palette: 256 dwords (RGB888) at `pal_offset·1024`, converted to RGB565 when a packet has b6 and the offset
changed since the last load (flip packets invalidate the cache).

Frame buffer addressing: `dest + ((x & 0x3ff) | (y & 0x1ff) << 10) · 2` — 1024 × 512 pixels, 2 KiB stride.

## Flipping

Banks: `B0 = 0`, `B1 = 0x100000` (or `0x400000`). Front = `display_bank ? B1 : B0`.
* Flip-async packet: draw target becomes `draw_select ? back : front`.
* Flip-sync packet: the engine stops until vblank.
* At vblank (`execute_flipping`, only if started and `flip_count != 0`): draw = `draw_select ? front : back`,
  display = front, clear flip-sync, `flip_count--`, `display_bank ^= 1`.

**Core rule (vr0_video_regs):** the vblank flip additionally waits until the renderer has *caught up* with the
display list -- stopped at the flip-sync packet, or idle with an empty queue. MAME processes each packet instantly
(one packet per 1100 clocks), so its list is always complete by vblank; the RTL renderer draws pixel by pixel and
can still be drawing at vblank in heavy frames. Flipping then (the first hardware build did) shows a half-drawn
buffer whose undrawn parts still hold the frame from two flips ago: moving sprites jitter back and forth and
partial sprites flash. With the rule a late frame is shown one vblank later instead, which is what the chip's
flip-sync mechanism exists for. `dbg_flip_defer` counts the deferred vblanks (core simulation).

**Renderer throughput:** the destination is written in 32-pixel segments; a finished segment is copied into a
write-back buffer in one clock and written to SDRAM from there while drawing continues in the next segment.
Measured with the renderer bench (attract, 2..7-clock memory latency): 2.42 -> 1.32 clocks per pixel; the
write-back itself (one SDRAM word per clock) is now the limit for fills.

## Crystal of Kings usage (attract, reference statistics)

35 K quads in 3600 frames: all textured quads are **8 bpp with transparency**; 12.9 K tiled, 397 scaled,
**0 rotated, 0 alpha-blended, 0 clamped**; 3.4 K shaded; 3.0 K fills (screen clears); one flip-sync per frame.
Palette (re)loads 25 K. Worst frame: 288 K textured pixels written, 336 K considered. Average frame: 72 K
textured + 65 K fill pixels.

## Display timing in the core (M17/M24)

| Quantity | MAME (screen) | Core | Source |
| --- | --- | --- | --- |
| Pixel clock | 14.31818 MHz x2 / (div+1) | clk_sys / (6*(div+1)/2) = 7.159 MHz for crysking | CRTTIM 0x8B |
| Total / visible pixels | HTOT+1 = 455 / HDISP+1 = 320 | same | HTOT 0x5C6 (b10 enable), HDISP 0x13F |
| Total / visible lines | VTOT/2+1+9 = 262 / VDISP = 240 | same | VTOT 0x9F9, VDISP 0xF0 |
| Frame rate | 59.94 Hz (7.159 MHz / 455 / 262 ... = 60.05 Hz) | 60.05 Hz | |
| HSYNC | not modelled | starts HTOT - (HSW+1) - (HBP+1) = pixel 361, 34 px (4.75 us) | HSWBP 0x213B (the 34-pixel field matches NTSC sync width; MAME names the bytes the other way round) |
| VSYNC | not modelled | 3 lines ending VBP+1 = 15 lines before the end of the frame (lines 244-246) | VSBP 0x0E |

The raster has its own reset (PLL lock only): while the board is held in reset (ROM download, OSD reset) it keeps
running the CRTC reset-default timing (the crysking geometry above), so a 15-kHz CRT stays locked and shows the
MiSTer loading screen. The geometry registers are applied at the next frame boundary (MAME re-times the screen at once; the difference is
invisible: the game programs the CRTC once during boot). The vblank interrupt (IRQ 24) and the frame-buffer flip
happen at the first line after the visible area, exactly as MAME's screen vblank callback. The hsync/vsync
placement is a MiSTer/CRT presentation choice derived from the CRTC porch registers; it does not affect the game.
The boot BIOS briefly programs 640x480 (831 x 617 total, 28.6 MHz pixel clock) before switching to 320x240, as the
real board does ("vertical line" boot screen at ~20 kHz in the PCB notes); MiSTer's scaler follows the change.
