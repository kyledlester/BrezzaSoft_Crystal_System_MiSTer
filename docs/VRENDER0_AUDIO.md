# VRender0 sound engine

Source: MAME `sound/vrender0.cpp` (c2334733). Registers at `0x04800000`, 16-bit handlers (a 32-bit access calls
two handlers). MAME header TODO: envelope and interrupt behaviour unverified; reverb, ping-pong, sustain and most
control bits not implemented; sample rate unverified.

## Registers

| Offset | Register |
| --- | --- |
| `000-3FF` | 32 channels × 32 bytes (below) |
| `404/406` | Status (W: b15 on/off, b4:0 channel; R: 32-bit mask >> 0/4 — MAME shift quirk) |
| `408/40A` | NoteOn (same format) |
| `410` | RevFactor, `412` reverb buffer start (b6:0), `420/422/440/442` buffer sizes |
| `480/482` | IntMask, `500/502` IntPend (W: clear bits) |
| `600` | b12:8 MaxChn (channels 0..MaxChn processed), b7:0 ChnClkNum |
| `602` | b15 RS run, b5 TM texture memory select, b4 reverb, b2:0 waits |

Channel (word offsets): `0/2` CurSAddr (32 bit, 9 fractional bits → byte address `>> 9`), `4/6` EnvVol (24-bit
signed, b14:8 of word 6 EnvStage, b12 loop direction), `8` DSAddr (pitch step), `A` Modes (b14:8: b0 loop, b1 sustain,
b2 envelope, b3 ping-pong, b4 µ-law, b5 8-bit, b6 texture memory), `C/E` LoopBegin (22 bit) + LChnVol (7 bit),
`10/12` LoopEnd + RChnVol, `14-1A` EnvRate0-3, `1C/1E` EnvTargets + EnvRate b16.

## Sample generation (MAME)

Rate: sound clock (VR0/2) / 972 = 44191 Hz. Per sample, for channels 0..MaxChn with Status bit and RS set:
read the sample at `CurSAddr >> 9` (16-bit aligned for 16-bit mode) from frame memory, or texture memory when the
channel's Modes b6 **and** control TM are set; µ-law through the Evoga table; 8-bit `<< 8`.
`CurSAddr += DSAddr · div >> 16` with `div = (30.5·65536) / (ChnClkNum + 1)` (1.0 if ChnClkNum = 0); at
`LoopEnd << 10` loop to `LoopBegin << 10` or stop (clear Status, raise IntPend/IRQ 2 if unmasked; MAME then skips
the remaining channels for that sample). Volume: `sample · (EnvVol >> 16) >> 8`, then `· L/RChnVol >> 8`, summed and
clamped to 16 bits.

## Crystal of Kings usage

Attract (first 3600 frames): MaxChn 31, ChnClkNum 29 (`div` = 1.0167), RS set, **no voice played** (the attract
mode is silent in the reference model as in MAME). Gameplay usage is captured in M20.
