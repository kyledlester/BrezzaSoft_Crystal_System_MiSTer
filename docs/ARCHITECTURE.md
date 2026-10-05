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
