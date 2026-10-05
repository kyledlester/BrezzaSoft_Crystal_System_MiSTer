# Known issues and open questions

Category: A blocks BIOS, B blocks game, C blocks graphics/playability, D accuracy only.

| ID | Cat | Issue | Status |
| --- | --- | --- | --- |
| K1 | D | Real PIC protection not emulated (PIC undumped); MAME-compatible word substitution used | by design, docs/PROTECTION.md |
| K2 | D | SE3208 real per-instruction timing unknown; MAME master's flat 3 cycles used | open |
| K3 | D | Render-engine real throughput unknown (MAME: 1 packet / 1100 clocks) | open |
| K4 | D | Masked interrupt requests are dropped (MAME), real HW may latch them | as MAME |
| K5 | D | Sound: envelope/interrupt unverified, reverb/ping-pong/sustain unimplemented, sample rate unverified (MAME) | as MAME |
| K6 | D | Sound register read-back shift quirk (`>> 4` instead of `>> 16`) and early-exit on voice end in MAME | reference model reproduces; RTL decision pending trace evidence (crysking never reads them in attract) |
| K7 | D | Dither modes not emulated (MAME), palette nudging artefact | RTL omits the nudging unless needed |
| K8 | D | DS1302 starts at a fixed date in the reference model | RTL will use MiSTer RTC |
| K9 | D | MAME test-menu reset workaround (`patchreset`) not implemented | revisit in M23 |
| K10 | D | DMA unused by crysking; covered by scripts/sim/dma_test.sh (400 random transfers vs MAME-master algorithm) | closed |
| K11 | D | Renderer paths unused by crysking (4/16 bpp, rotation, clamp, all blend selections) covered by scripts/sim/render_random.sh: 25,000 random packets / 12.1M pixels identical | closed |
| K12 | D | Odd PC fetches ignore bit 0 (MAME's unaligned word fetch behaviour depends on its memory system) | by design |
| K13 | D | Sound EnvVol kept as the 24-bit register image between samples (MAME keeps an s32) | open |
| K14 | D | Timer auto-reload uses the period registered one clock earlier: a TimerControl/TimerCount write in the single clock before an expiry is applied one period late (timing closure; starts are exact) | by design |
| K15 | D | Texture-RAM write snoop reaches the renderer's texture caches one clock after the CPU write is issued (the write itself reaches SDRAM later; fills starting in that clock are marked dirty) | by design |
| K16 | U | Not yet run on hardware: SDRAM board timing, DDR3 latency, HDMI/analog output, audio level and input mapping are simulation-only so far | HARDWARE_TEST_1 |
