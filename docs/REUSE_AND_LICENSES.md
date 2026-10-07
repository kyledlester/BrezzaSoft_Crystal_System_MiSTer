# Reused material and licenses

The core as a whole is GPL-3.0-or-later (`LICENSE`), like the author's other MiSTer cores.

| Material | Source | Revision | License | Files | Modifications |
| --- | --- | --- | --- | --- | --- |
| MiSTer framework | MiSTer-devel Template_MiSTer `sys/` via the author's Namco NB-2 core (`Namco_NB2_MiSTer`, commit `bef86c831b88ca2da171453d9b9a75487688e15e`, which imported it unchanged from the NB-1 public release) | as imported | GPL-2.0+/GPL-3.0 (`LICENSE.MiSTer`) | `sys/*` | none |
| Build/release scripts | author's NB-2 core | `bef86c8` | GPL-3.0+ | `scripts/release_rbf.tcl` | revision name |
| CRT Adjust | [rmonic79/MiSTer-CRT-Adjust](https://github.com/rmonic79/MiSTer-CRT-Adjust) by Umberto Parisi (rmonic79) with Andrea Bogazzi (@asturur); OSD integration ported from the author's NB-1 core (`nb1_crt_adjust.sv`) | | GPL-3.0+ | `rtl/vendor/crt_adjust.sv`, glue in `rtl/crystal/crystal_crt_adjust.sv` | none to `crt_adjust.sv`; glue is original |
| PLL module structure | author's NB-1 core `nb1_pll.sv` | | GPL-3.0+ | `rtl/mister/crystal_pll.sv` | frequency, names |
| MAME (behavioural specification, transcribed C++) | mamedev/mame | `c233473382353a00fb2d8b00d98c197cee910854` | BSD-3-Clause (these files) | `sim/reference/se3208_ref.h`, `crystal_ref.{h,cpp}` derived from `se3208.cpp` (ElSemi), `crystal.cpp` (ElSemi, Angelo Salese), `machine/vrender0.cpp`, `video/vrender0.cpp`, `sound/vrender0.cpp` (Angelo Salese, ElSemi), `ds1302.cpp` (Curt Coder) | restructured into a deterministic standalone model; copyright notices kept in file headers |
| MAME PIC16x8x core (behavioural specification) | mamedev/mame `src/devices/cpu/pic16x8x/pic16x8x.cpp` (Tony La Porta, Grull Osgo, Dirk Best) | `c233473382353a00fb2d8b00d98c197cee910854` | BSD-3-Clause | `sim/reference/pic16_ref.h` (port), `rtl/crystal/crystal_pic16.sv` (implementation of the same behaviour) | restructured; copyright notice kept in the header |
| ADChips SE3208 quick reference card | adc.co.kr `se3208_quick_ref_060424.pdf` | 2006 | reference only, not redistributed | — | — |

The RTL (SE3208 CPU, VRender0 blocks, memory system) is original work written for this project from the
behaviour documented in `docs/`; no existing HDL implementation of the SE3208 or VRender0 was found (searches:
GitHub, MiSTer/JT cores lists, web; only MAME and the ADChips card exist).

No ROM, BIOS, flash image, extracted asset or trace is part of the repository or the RBF.
