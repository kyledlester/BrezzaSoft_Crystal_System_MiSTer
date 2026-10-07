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
| K16 | U | Hardware test 1 (owner, 128 MB SDRAM, 15-kHz CRT): boot, attract, coin/start, gameplay, controls and sound work; findings fixed in the next build: CRT lost sync during the loading screen, sprite jitter / flashing lines (K17); HDMI not yet checked | partly closed |
| K17 | D | Frame flips wait for the renderer to reach the frame's flip-sync packet (MAME flips at vblank regardless, its renderer being instantaneous); a frame the renderer cannot finish in time is shown one frame later. Fixes the first hardware build's sprite jitter / flashing lines | by design |
| K18 | D | The BIOS boot briefly programs 640x480 (about 31 kHz) before the 320x240 game mode, as the real board; a 15-kHz CRT may roll for that moment after the loading screen | as hardware |
| K19 | D | Texture-RAM writes are ordered behind the display list submitted before them (crystal_texq), reproducing MAME's effectively instantaneous rendering; CPU reads of texture RAM wait while writes are pending | by design |
| K20 | B | Hardware test 2: booted into the BIOS set-up menu (DSW:8 Test seen On). The loader dropped the DIP switch transfer (index 254) when it arrived during the post-download RAM clear, so whether MiSTer's DIP values applied depended on timing; the MRA's switch page (page_id 1) also collided with the new CRT Adjust OSD page and there was no DIP menu. Fixed: index 254 accepted in any state, standard `DIP` OSD menu, no page_id. Simulated: DSW 0x7F reproduces the set-up menu, 0xFF boots the game | fixed |
| K21 | D | PIC16: watchdog, T0CKI counting and the F628A Timer1/Timer2/USART/CCP are not implemented (MAME has them as plain registers too; both firmwares have the watchdog disabled). The PIC EEPROM is reloaded from the MRA at every start (MAME saves it as NVRAM; neither firmware's behaviour depends on a saved copy as far as seen) | as MAME / open |
| K22 | D | Top Blade V: VRender0/CPU at 80.013 / 40.007 MHz as MAME's topbladv machine (the game programs its PLL); realised as a 95/102 clock enable, the screen keeps the crystal timing. Coins are one-frame impulses (MAME PORT_IMPULSE) | as MAME |
| K23 | D | Office Yeoin Cheonha: MAME notes that start 2 only skips attract items and that a 3-player mode is unconfirmed; the core uses MAME's input layout | as MAME |
