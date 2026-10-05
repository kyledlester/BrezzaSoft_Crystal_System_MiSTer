# Core architecture

## Board being implemented

Crystal System main PCB AMG0110B/D: MagicEyes VRenderZERO SoC (SE3208 CPU + interrupt controller, 4 timers, 2 DMA,
UARTs, PIO, CRTC, 2D renderer, 32-voice wavetable), 3 × HY57V651620 SDRAM (work / texture / frame, 8 MiB each),
MX27L1000 BIOS, 32 KiB battery SRAM, DS1302 RTC, 14.31818 MHz crystal. Cartridge: up to 8 × Intel 28F128J3A flash
(16 MiB each) + protection PIC.

## Clocking

One fabric clock, `clk_sys = 85.909080 MHz` (6 × 14.31818 MHz = the VRender0 clock). All other rates are clock
enables or counters derived from it:

| Function | Rate | Derivation |
| --- | --- | --- |
| SE3208 | 14.318 M instructions/s average | one instruction credit per 6 clk_sys (MAME master: 3 cycles @ 42.95 MHz) |
| Timers, DMA, render pacing | VR0 clock | clk_sys |
| Pixel clock | 14.318 MHz [×2] / (div+1) | 6·(div+1) [/2] clk_sys per pixel (crysking: 12 → 7.159 MHz) |
| Sound | 44191 Hz | one sample per 1944 clk_sys |
| SDRAM | 85.909 MHz, CL2 | clk_sys |
| DDR3 port | clk_sys | `DDRAM_CLK = clk_sys` |

## Block diagram

```
 HPS (ioctl) ──► crystal_loader ──► prot_overlay (crysking only) ──► DDR3 flash store
                        └──────────────────────────────────────────► SDRAM bank 3 (BIOS)

            ┌──────────────┐  bus  ┌────────────────────────────┐
            │  se3208_cpu  │──────►│ crystal_bus (address decode)│──► inputs / coin / lamps / bank latch
            │ +I$ +credit  │◄──────│                            │──► vr0_sys (INTC, timers, DMA, PIO, CRTC regs)
            └──────────────┘       │                            │──► vr0_video regs / vr0_sound regs
                     ▲ irq/iack    └────────────┬───────────────┘
                     │                          │ memory requests
           vr0_intc ◄┘     ┌────────────────────▼──────────────────────────┐
                           │ crystal_mem: SDRAM scheduler (4 banks, open    │◄── vr0_scanout (line buffers)
                           │ rows) + DDR3 flash reader                      │◄── vr0_render (packet fetch,
                           └───────────────────────────────────────────────┘     texel/tile reads, fb RMW)
                                                                              ◄── vr0_sound (voice buffers)
```

## Memory clients (rtl/crystal/crystal_core.sv)

| SDRAM client (priority) | Block | Traffic |
| --- | --- | --- |
| 0 | `vr0_scanout` | 32-word bursts, one display line ahead (line buffer 2 x 1024 x 16) |
| 1 | `vr0_sound` | one word per active voice per 44.19 kHz sample |
| 2 | `crystal_icache` (8 KiB, banks 0/3) | 8-word line fills, uncached single words elsewhere |
| 3 | `crystal_dcache` (8 KiB write-through, banks 0/3) + 8-entry posted-write FIFO | line fills, posted/synchronous writes |
| 4 | `vr0_render` texture reads | 32-word packets, 32-word palette bursts, 16-word cache lines |
| 5 | `vr0_render` frame reads | 32-word segments (alpha blending only) |
| 6 | `vr0_render` frame writes | 32-word masked segment write-backs |
| 7 | `crystal_loader` | BIOS words, RAM clear bursts (reset only) |

Flash (DDR3) has two read ports (CPU data, instruction fetch), each with a 64-byte line buffer, and the loader's
write port. Coherency rules: only the CPU/DMA port writes banks 0/3 (cached); CPU/DMA writes to texture RAM
invalidate the renderer's texture caches (snoop); writes to texture/frame RAM are never posted, so a display list
or sample is in SDRAM before the CPU can start the engine through an I/O register; I-cache fills wait for posted
writes.

## Verification status

| Layer | Bench | Result |
| --- | --- | --- |
| CPU | `scripts/sim/cpu_difftest.sh` | 10 M random instructions identical |
| Board (CPU, decode, devices) | `scripts/sim/board_lockstep.sh` | 120 M instructions / 740 frames identical |
| SDRAM controller | `scripts/sim/sdram_stress.sh` | 0 timing violations, data checked |
| Renderer | `scripts/sim/render_difftest.sh` | 886 M pixels / 177 K packets identical (attract + gameplay) |
| Audio | `scripts/sim/audio_difftest.sh` | 4.78 M samples identical |
| Full core | `scripts/sim/core_sim.sh` | real download, DDR3 image check, video capture |

## Repository layout

| Path | Content |
| --- | --- |
| `Crystal.sv` | MiSTer `emu` top: hps_io, PLL, video/audio glue |
| `rtl/cpu/se3208/` | SE3208 CPU (generic) |
| `rtl/vrender0/` | VRender0 SoC blocks (generic): system/intc/timers/DMA/CRTC, video engine, sound engine |
| `rtl/memory/` | SDRAM controller/scheduler, DDR3 flash reader, caches |
| `rtl/crystal/` | Crystal System board: address decode, inputs, flash banking, DS1302, loader, game-specific overlay |
| `rtl/mister/` | PLL and MiSTer-specific glue |
| `sim/reference/` | MAME-derived C++ reference model (executable specification) |
| `sim/cpu/`, `sim/vrender0/`, `sim/integration/` | Verilator benches |
| `scripts/` | build, MRA stream, research and comparison tools |
| `mra/` | MRA files |
| `docs/` | specifications and evidence |

## Generic vs. game-specific

Everything in `rtl/cpu` and `rtl/vrender0` is driven only by register values. Game knowledge lives in the MRA
board record (game id, flash bank count) and in `rtl/crystal/crystal_prot_overlay.sv`.

## Verification strategy

1. **CPU**: RTL vs `se3208_ref.h` in lock-step on random and directed programs (register/flag/memory state after
   every instruction), then real-BIOS lock-step with the reference board model supplying I/O read data.
2. **Board**: RTL board in Verilator vs the reference model: first divergence in (PC, opcode, address, data).
3. **Video**: three independent layers — packet stream (CPU side), frame RAM contents after each frame
   (renderer), scanout pixels (display) — each compared with the reference.
4. **Audio**: per-voice register state and per-sample output vs reference.
