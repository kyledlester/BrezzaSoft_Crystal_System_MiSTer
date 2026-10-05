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
| K11 | D | Renderer 4/16 bpp, rotation, clamp paths implemented but not exercised by the crysking packet stream | open |
| K12 | D | Odd PC fetches ignore bit 0 (MAME's unaligned word fetch behaviour depends on its memory system) | by design |
| K13 | D | Sound EnvVol kept as the 24-bit register image between samples (MAME keeps an s32) | open |
