# Compare full-core frames (tb_core --snap-at, core_NNNNN.ppm) with reference-model frames (crystal_sim --snap-at,
# frame_NNNNN.ppm) of the same scripted sequence (e.g. the How-to-Play demo after the same coin/start inputs).
# The two timelines differ by a constant frame offset while the game runs at 60 fps; it is found by exact
# matching, then every core frame is compared (RGB565 domain) with the reference frame at that offset.
#   python scripts/sim/frame_compare.py CORE_DIR REF_DIR [--offsets LO HI]
import os, sys
import numpy as np
from PIL import Image

def load(path):
    a = np.asarray(Image.open(path).convert('RGB'), dtype=np.uint16)
    return ((a[..., 0] >> 3) << 11) | ((a[..., 1] >> 2) << 5) | (a[..., 2] >> 3)   # RGB565

def frames(d, prefix):
    out = {}
    for n in os.listdir(d):
        if n.startswith(prefix) and n.endswith('.ppm'):
            out[int(n[len(prefix):-4])] = os.path.join(d, n)
    return out

core_dir, ref_dir = sys.argv[1], sys.argv[2]
lo, hi = 2700, 3000
if '--offsets' in sys.argv:
    i = sys.argv.index('--offsets'); lo, hi = int(sys.argv[i + 1]), int(sys.argv[i + 2])
core = frames(core_dir, 'core_')
ref = frames(ref_dir, 'frame_')
cache = {}
def px(path):
    if path not in cache: cache[path] = load(path)
    return cache[path]
def diff(a, b):
    return int(np.count_nonzero(px(a) != px(b)))

# offset: the one with the most exactly matching frames over a sample of core frames
ck = sorted(core)
sample = ck[len(ck) // 3: len(ck) // 3 + 12]
best = None
for off in range(lo, hi + 1):
    m = sum(1 for c in sample if c + off in ref and diff(core[c], ref[c + off]) == 0)
    if m and (best is None or m > best[1]): best = (off, m)
if best is None:
    # no exact match anywhere: report the closest
    sc = []
    for off in range(lo, hi + 1):
        d = [diff(core[c], ref[c + off]) for c in sample if c + off in ref]
        if d: sc.append((sum(d) / len(d), off))
    sc.sort()
    print('no exact match; closest offsets (mean differing pixels, offset):', sc[:5])
    best = (sc[0][1], 0)
off = best[0]
print('frame offset core -> reference: %d (%d of %d sample frames exact)' % (off, best[1], len(sample)))
bad = 0; total = 0
for c in ck:
    if c + off not in ref: continue
    total += 1
    d = diff(core[c], ref[c + off])
    if d:
        bad += 1
        # neighbouring reference frames: does the core frame equal an earlier/later one (dropped / held frame)?
        near = [k for k in (-2, -1, 1, 2) if c + off + k in ref and diff(core[c], ref[c + off + k]) == 0]
        print('  core %d vs ref %d: %d pixels differ%s' % (c, c + off, d, ('  (= ref %+d)' % near[0]) if near else ''))
print('FRAMES: %d compared, %d identical, %d differ' % (total, total - bad, bad))
