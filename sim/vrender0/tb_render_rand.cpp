// Randomised renderer test: random display-list packets exercising every feature of vr0_render (4/8/16 bpp,
// tiled/linear, clamp/wrap, scale/rotation deltas, every blend factor selection, shade, transparency, palette
// banks/reloads, fills with and without blending) on random texture/frame memory, compared pixel for pixel with
// the reference model's process_packet (crystal::Board).
//
//   tb_render_rand [--n N] [--seed S]
#include "Vvr0_render.h"
#include "verilated.h"
#include "../reference/crystal_ref.h"
#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>

double sc_time_stamp() { return 0; }
static uint64_t rng = 0x1234ABCD5678EF01ull;
static uint32_t rnd() { rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17; return uint32_t(rng); }

struct Port { bool active = false; uint32_t addr = 0; int left = 0, wait = 0; bool done_pending = false; };

int main(int argc, char **argv)
{
    int n = 3000;
    for (int i = 1; i < argc; i++) {
        std::string a = argv[i];
        if (a == "--n") n = atoi(argv[++i]);
        if (a == "--seed") rng ^= strtoull(argv[++i], nullptr, 0) * 0x9E3779B97F4A7C15ull;
    }
    crystal::Board b;
    b.reset();
    std::vector<uint16_t> sd(16u << 20, 0);
    Vvr0_render *t = new Vvr0_render;
    Port pt, pf, pw;
    auto tick = [&]() {
        t->t_rvalid = 0; t->t_done = 0; t->f_rvalid = 0; t->f_done = 0; t->w_wnext = 0;
        t->w_done = pw.done_pending; pw.done_pending = false;
        auto rd = [&](Port &p, bool req, uint32_t addr, int len, uint8_t &rv, uint16_t &rdat, uint8_t &dn) {
            if (req && !p.active) { p.active = true; p.addr = addr; p.left = len; p.wait = rnd() % 5; }
            if (p.active) { if (p.wait > 0) p.wait--; else { rv = 1; rdat = sd[p.addr & 0xffffff]; p.addr++; if (--p.left == 0) { dn = 1; p.active = false; } } }
        };
        rd(pt, t->t_req, t->t_addr, t->t_len, t->t_rvalid, t->t_rdata, t->t_done);
        rd(pf, t->f_req, t->f_addr, t->f_len, t->f_rvalid, t->f_rdata, t->f_done);
        if (t->w_req && !pw.active && !t->w_done) { pw.active = true; pw.addr = t->w_addr; pw.left = t->w_len; pw.wait = rnd() % 5; }
        bool wn = pw.active && pw.wait == 0;
        if (pw.active && pw.wait > 0) pw.wait--;
        t->w_wnext = wn;
        t->eval();
        if (wn) {
            uint32_t a = pw.addr & 0xffffff;
            if (t->w_wbe & 1) sd[a] = (sd[a] & 0xff00) | (t->w_wdata & 0xff);
            if (t->w_wbe & 2) sd[a] = (sd[a] & 0x00ff) | (t->w_wdata & 0xff00);
            pw.addr++;
            if (--pw.left == 0) { pw.active = false; pw.done_pending = true; }
        }
        t->clk = 1; t->eval(); t->clk = 0; t->eval();
    };
    t->rst_n = 0; t->start = 0; t->snoop = 0;
    for (int i = 0; i < 4; i++) tick();
    t->rst_n = 1;

    // random texture RAM (texture images, tile maps, palettes) in both models
    auto put_tex = [&](uint32_t byte, uint8_t v) {
        b.texram[byte & 0x7fffff] = v;
        uint32_t w = 0x400000 + ((byte & 0x7fffff) >> 1);
        sd[w] = (byte & 1) ? uint16_t((sd[w] & 0x00ff) | (v << 8)) : uint16_t((sd[w] & 0xff00) | v);
    };
    for (uint32_t a = 0x20000; a < 0x80000; a++) put_tex(a, uint8_t(rnd()));
    // tile maps: mostly small indices into the texture area (index * 64 bytes), some zero (skipped tiles)
    for (uint32_t a = 0x80000; a < 0x88000; a += 2) {
        uint16_t idx = (rnd() % 8 == 0) ? 0 : uint16_t(0x800 + rnd() % 0x1800);
        put_tex(a, idx & 0xff); put_tex(a + 1, idx >> 8);
    }
    // frame RAM: random background
    for (uint32_t w = 0; w < 0x200000; w++) { uint16_t v = uint16_t(rnd()); sd[0x800000 + w] = v; b.frameram[w * 2] = v & 0xff; b.frameram[w * 2 + 1] = v >> 8; }

    int fails = 0;
    uint64_t pixels = 0;
    for (int i = 0; i < n && !fails; i++) {
        uint16_t pk[32] = {};
        bool flip = rnd() % 40 == 0;
        uint16_t p0 = 0;
        if (flip) p0 = (rnd() & 1) ? 0x80 : 0x01;
        else {
            p0 = 0x100;                                  // draw
            if (rnd() % 8) p0 |= 0x08;                   // texture
            if (rnd() % 3 == 0) p0 |= 0x02;              // blend
            if (rnd() % 2) p0 |= 0x04;                   // transparency
            if (rnd() % 3 == 0) p0 |= 0x10;              // shade
            if (rnd() % 4 == 0) p0 |= 0x20;              // clamp
            if (rnd() % 3 == 0) p0 |= 0x40;              // palette load
            if (rnd() % 2) p0 |= 0x200;                  // tx/ty
            if (rnd() % 2) p0 |= 0x400;                  // deltas
            if (rnd() % 3 == 0) p0 |= 0x800;             // blend state
            if (rnd() % 3 == 0) p0 |= 0x1000;            // shade colour
            if (rnd() % 3 == 0) p0 |= 0x2000;            // transparent colour
            if (rnd() % 2 || i == 0) p0 |= 0x4000;       // texture state
        }
        pk[0] = p0;
        uint32_t dx = rnd() % 400, dy = rnd() % 260;
        pk[1] = uint16_t(dx); pk[2] = uint16_t(dy);
        pk[3] = uint16_t(dx + rnd() % 48); pk[4] = uint16_t(dy + rnd() % 40);
        auto r21 = [&]() { return uint32_t(rnd() & 0x1fffff); };
        auto small = [&](int scale) { int v = int(rnd() % (2 * scale)) - scale; return uint32_t(v) & 0x1fffff; };
        uint32_t tx = r21() & 0x1ffff, ty = r21() & 0x1ffff;
        pk[5] = tx & 0xffff; pk[6] = tx >> 16; pk[7] = ty & 0xffff; pk[8] = ty >> 16;
        uint32_t d[4] = {small(1024), small(512), small(512), small(1024)};
        if (rnd() % 2) { d[0] = 0x200 + small(64); d[1] = 0; d[2] = 0; d[3] = 0x200 + small(64); }
        for (int k = 0; k < 4; k++) { pk[9 + 2 * k] = d[k] & 0xffff; pk[10 + 2 * k] = d[k] >> 16; }
        static const uint8_t sel[] = {0x01, 0x02, 0x04, 0x08, 0x10, 0x00, 0x03};
        uint8_t sb = sel[rnd() % 7] | ((rnd() & 1) << 5), db = sel[rnd() % 7] | ((rnd() & 1) << 5);
        pk[17] = uint16_t(rnd()); pk[18] = uint16_t((rnd() & 0xff) | (sb << 8));
        pk[19] = uint16_t(rnd()); pk[20] = uint16_t((rnd() & 0xff) | (db << 8));
        pk[21] = uint16_t(rnd()); pk[22] = uint16_t(rnd() & 0xff);
        pk[23] = uint16_t(rnd()); pk[24] = uint16_t(rnd() & 0xff);
        pk[25] = uint16_t(0x80000 / 128 + rnd() % 32);         // tile map offset
        pk[26] = uint16_t(0x20000 / 128 + rnd() % 64);         // texture offset
        pk[27] = uint16_t((0x40000 / 1024 + rnd() % 64) << 3); // palette offset
        pk[28] = uint16_t((rnd() % 6) | ((rnd() % 6) << 3) | ((rnd() % 4) << 6) | ((rnd() % 16) << 8) | ((rnd() & 1) << 12));
        uint32_t ptr = (rnd() % 2048) * 32;
        for (int k = 0; k < 32; k++) { put_tex((ptr + k) * 2, pk[k] & 0xff); put_tex((ptr + k) * 2 + 1, pk[k] >> 8); }
        // tell the RTL caches about the texture writes (packet words)
        for (int k = 0; k < 32; k += 8) { t->snoop = 1; t->snoop_addr = 0x400000 + ptr + k; tick(); }
        t->snoop = 0;
        uint32_t dest = (rnd() & 1) ? 0x100000 : 0;
        b.draw_dest = dest;
        int rflip = b.process_packet(ptr);
        t->start = 1; t->pkt_addr = ptr; t->draw_dest = dest;
        tick();
        t->start = 0;
        int guard = 0;
        while (!t->done) { tick(); if (++guard > 2000000) { printf("hung on packet %d\n", i); return 1; } }
        if (((t->flip & 1) != 0) != ((rflip & 1) != 0) || ((t->flip & 2) != 0) != ((rflip & 0x80) != 0)) { printf("FAIL %d: flip %d vs %d\n", i, t->flip, rflip); fails++; }
        if (!flip && (p0 & 0x100)) {
            int bad = 0;
            for (uint32_t y = pk[2] & 0x1ff; y <= (pk[4] & 0x1ffu); y++)
                for (uint32_t x = pk[1] & 0x3ff; x <= (pk[3] & 0x3ffu); x++) {
                    uint32_t ba = dest + ((((x & 0x3ff) | ((y & 0x1ff) << 10))) << 1);
                    uint16_t rv = b.fb16(ba), tv = sd[0x800000 + (ba >> 1)];
                    pixels++;
                    if (rv != tv && bad++ < 3)
                        printf("FAIL packet %d p0=%04x fmt=%d tiled=%d w=%d h=%d blend=%02x/%02x (%u,%u) ref %04x rtl %04x\n", i, p0,
                               b.rs.pixel_format, b.rs.texture_mode, b.rs.width, b.rs.height, b.rs.src_blend, b.rs.dst_blend, x, y, rv, tv);
                }
            if (bad) {
                fails++;
                printf("  words:");
                for (int k = 0; k < 32; k++) printf(" %04x", pk[k]);
                printf("\n");
            }
        }
    }
    printf("RENDER RANDOM: %s packets=%d pixels=%llu\n", fails ? "FAIL" : "PASS", n, (unsigned long long)pixels);
    delete t;
    return fails ? 1 : 0;
}
