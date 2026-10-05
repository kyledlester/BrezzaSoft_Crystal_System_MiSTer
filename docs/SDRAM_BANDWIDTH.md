# External memory architecture and bandwidth

## Capacity

| Logical memory | Size | Placement |
| --- | --- | --- |
| Cartridge flash (crysking: 3 × 16 MiB, up to 8 banks) | 48 MiB | **DDR3** (HPS, f2sdram port), byte `0x32000000 + offset`, read-only after load |
| Work RAM | 8 MiB | **SDRAM bank 0** |
| Texture RAM | 8 MiB | **SDRAM bank 1** |
| Frame RAM | 8 MiB | **SDRAM bank 2** |
| BIOS (128 KiB), NVRAM (64 KiB), spare | | **SDRAM bank 3** |

32 MiB SDRAM (the smallest MiSTer module) is therefore sufficient; larger modules work identically. Each logical
memory owns one internal SDRAM bank (8 MiB = one bank of a 256 Mbit x16 device: 8192 rows × 512 columns × 16 bit),
so the controller can keep one open row per client class and interleave commands between them without precharge
conflicts. The original board also had one 16-bit SDRAM chip per memory (3 × HY57V651620).

## Measured demand (reference model, crysking)

From `crystal_sim --stats` (attract 3600 frames + gameplay to frame 6000). Per frame at 60.05 Hz:

| Client | Average | Worst frame | Pattern |
| --- | --- | --- | --- |
| CPU instruction fetch | 238 K 16-bit fetches | same | work RAM, loops → I-cache |
| CPU data | 30 K reads + 23 K writes | ~ | mostly work RAM, word/dword |
| Renderer texels (8 bpp) | 67-83 K | 351 K considered | sequential in x (2 texels / word) |
| Renderer tile indices | 43-48 K | ~ | 1 per 8 pixels per line |
| Renderer frame writes | 56-72 K textured + 65-69 K fill | 309 K textured + 77 K fill | horizontal runs, masked |
| Renderer frame reads (alpha blend) | 6 K | ~30 K (est.) | horizontal runs |
| Display scanout | 76.8 K | 76.8 K | 320-pixel lines |
| Sound | ≤ 32 voices × 44.1 kHz | crysking: ~1-4 voices in play | per-voice sequential |
| Flash (DDR3) | 1.1 K CPU reads | loading phases | sequential copies |

## Cycle budget at clk_sys = 85.909 MHz (1.43 M SDRAM cycles per frame)

Assumptions for the open-row controller (CL2, tRCD 2, tRP 2, tRC 7 at 86 MHz): a column access to an open row
costs 1 command cycle; row misses cost ~6 cycles; bursts of 4-8 words in the renderer and caches.

| Client | Worst-frame cycles | Share |
| --- | --- | --- |
| CPU fetch (8 KiB I-cache, 16-byte lines, ~97 % hit → 7 K fills × 10 cyc) | 70 K | 5 % |
| CPU data (uncached reads ~10 cyc, posted writes ~2 cyc) | 350 K | 24 % |
| Renderer (texel 0.5 + frame write 1.1 + tile 0.15 per pixel, fill 1.1) | 650 K | 45 % |
| Scanout (line bursts) | 85 K | 6 % |
| Sound (8-byte voice buffers) | 15 K | 1 % |
| Refresh (8192 rows / 64 ms) | 20 K | 1.5 % |
| **Total** | **~1.19 M** | **~83 %** |

The worst frame is a short peak (the renderer is allowed to spill into the next frame exactly like the real
engine, whose queue simply drains later); the average frame is ~35 %. Margins come from: a small CPU data cache
(cuts the largest CPU term), larger renderer bursts, and bank parallelism (the cost model above serialises banks).

## Arbitration (priority, highest first)

1. **Display scanout** — line buffer (2 lines × 1024 px in BRAM) refilled during the previous line; never starves
   (needs < 6 % of cycles, requested 1+ line ahead).
2. **Sound** — one 4-word buffer per voice, refilled when half empty; tiny demand, latency-critical.
3. **Refresh** — scheduled into idle cycles, forced when overdue.
4. **CPU** — instruction-cache line fills and data accesses; the CPU is paced, so latency matters more than
   throughput.
5. **Renderer** — texel/tile reads and frame read-modify-writes through FIFOs; takes all remaining cycles.
6. **DMA** — one unit per 4 clocks at most (MAME timing), shares the CPU port.
7. **ROM loader** — only while the core is held in reset.

Rows: each client class sticks to its own bank, so the scheduler picks the highest-priority ready request whose
bank row is open (or that can be opened without closing a row another pending request needs).

## Stress test (M11)

`sim/memory/` replays per-frame access streams extracted from the reference model (worst frame + gameplay
average) through the RTL controller + client models and reports per-client bandwidth, latency histograms, display
FIFO minimum fill and any underflow. Acceptance: zero scanout underflow and zero sound underrun under the worst
recorded frame, renderer completion time per frame reported.

## Alternatives kept in reserve

* Visible frame-buffer windows (2 × 320 × 240 × 16) in BRAM (≈ 240 M10K) — removes scanout and renderer frame
  traffic from SDRAM if measurement shows the budget is not met.
* Texture RAM in DDR3 behind a texture cache.
