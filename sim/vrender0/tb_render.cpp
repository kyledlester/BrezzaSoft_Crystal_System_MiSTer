// Renderer differential test: rtl/vrender0/vr0_render.sv vs the reference model's process_packet, packet by
// packet, on the real Crystal of Kings display-list stream.
//
//   tb_render --rom DIR [--frames N] [--from-frame F] [--input F:what:on|off] [--verbose]
//
// The reference model (sim/reference) runs the game. Its CPU/DMA writes to texture and frame RAM are mirrored
// into the RTL's SDRAM image (and snooped into the RTL texture cache). Just before the reference processes a
// packet, the RTL renderer processes the same packet (same draw buffer) on the mirror; after the reference has
// processed it, the destination rectangle of the RTL frame RAM is compared with the reference frame RAM.
// Reports the first mismatching packet with its decoded fields, plus pixel/cycle statistics.
#include "Vvr0_render.h"
#include "verilated.h"
#include "../reference/crystal_ref.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <map>
#include <string>
#include <vector>

double sc_time_stamp() { return 0; }
static uint64_t rng = 0x9E3779B97F4A7C15ull;
static uint32_t rnd() { rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17; return uint32_t(rng); }

static std::vector<uint8_t> read_file(const std::string &p)
{
    std::ifstream f(p, std::ios::binary);
    if (!f) { fprintf(stderr, "cannot read %s\n", p.c_str()); exit(2); }
    return std::vector<uint8_t>((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
}

struct Port { int wait = -1; uint32_t addr = 0; int left = 0; bool active = false; bool done_pending = false; };

int main(int argc, char **argv)
{
    std::string rom = "C:/Users/klest/Crystal_research/roms";
    int frames = 600, from_frame = 0;
    bool verbose = false;
    std::multimap<int, std::string> inputs;
    for (int i = 1; i < argc; i++) {
        std::string a = argv[i];
        if (a == "--rom") rom = argv[++i];
        else if (a == "--frames") frames = atoi(argv[++i]);
        else if (a == "--from-frame") from_frame = atoi(argv[++i]);
        else if (a == "--verbose") verbose = true;
        else if (a == "--input") { std::string v = argv[++i]; inputs.emplace(atoi(v.c_str()), v.substr(v.find(':') + 1)); }
    }
    crystal::Board b;
    b.load_bios(read_file(rom + "/mx27l1000.u14"));
    std::vector<uint8_t> fl;
    for (auto n : {"bcsv0004f01.u1", "bcsv0004f02.u2", "bcsv0004f03.u3"}) { auto v = read_file(rom + "/" + n); fl.insert(fl.end(), v.begin(), v.end()); }
    b.load_flash(fl);
    b.reset();

    // RTL SDRAM image (word addressed): texture bank at 0x400000, frame bank at 0x800000
    std::vector<uint16_t> sd(16u << 20, 0);
    std::vector<uint32_t> snoops;
    b.hooks.ram_write = [&](uint32_t addr, int size, uint32_t data) {
        for (int i = 0; i < size; i++) {
            uint32_t a = addr + i;
            uint32_t w;
            if (a >= 0x03800000 && a < 0x04000000) w = 0x400000 + ((a & 0x7fffff) >> 1);
            else if (a >= 0x04000000 && a < 0x04800000) w = 0x800000 + ((a & 0x7fffff) >> 1);
            else continue;
            uint8_t v = uint8_t(data >> (8 * i));
            sd[w] = (a & 1) ? uint16_t((sd[w] & 0x00ff) | (v << 8)) : uint16_t((sd[w] & 0xff00) | v);
            if (w < 0x800000) snoops.push_back(w);
        }
    };

    Vvr0_render *t = new Vvr0_render;
    t->clk = 0; t->rst_n = 0; t->start = 0; t->snoop = 0;
    t->t_rvalid = t->f_rvalid = 0; t->t_done = t->f_done = t->w_done = 0; t->w_wnext = 0;
    for (int i = 0; i < 4; i++) { t->clk = 1; t->eval(); t->clk = 0; t->eval(); }
    t->rst_n = 1;
    uint64_t cyc = 0;
    Port pt, pf, pw;
    uint64_t packets = 0;

    auto tick = [&]() {
        // ---- memory service (one word per cycle per port after a random initial latency)
        t->t_rvalid = 0; t->t_done = 0; t->f_rvalid = 0; t->f_done = 0; t->w_wnext = 0;
        t->w_done = pw.done_pending;
        pw.done_pending = false;
        auto rd_port = [&](Port &p, bool req, uint32_t addr, int len, uint8_t &rvalid, uint16_t &rdata, uint8_t &done) {
            if (req && !p.active) { p.active = true; p.addr = addr; p.left = len; p.wait = 2 + rnd() % 6; }
            if (p.active) {
                if (p.wait > 0) p.wait--;
                else {
                    rvalid = 1; rdata = sd[p.addr & 0xffffff]; p.addr++;
                    if (--p.left == 0) { done = 1; p.active = false; }
                }
            }
        };
        rd_port(pt, t->t_req, t->t_addr, t->t_len, t->t_rvalid, t->t_rdata, t->t_done);
        rd_port(pf, t->f_req, t->f_addr, t->f_len, t->f_rvalid, t->f_rdata, t->f_done);
        if (t->w_req && !pw.active && !pw.done_pending && !t->w_done) {
            pw.active = true; pw.addr = t->w_addr; pw.left = t->w_len; pw.wait = 2 + rnd() % 6;
            static long wp = getenv("WPKT") ? atol(getenv("WPKT")) : -1;
            if ((long)packets == wp) printf("WB %06x (x %d y %d)\n", t->w_addr, t->w_addr & 0x3ff, (t->w_addr >> 10) & 0x1ff);
        }
        bool wn = false;
        if (pw.active) { if (pw.wait > 0) pw.wait--; else wn = true; }
        t->w_wnext = wn;
        t->eval();
        if (wn) {
            uint16_t d = t->w_wdata;
            static long watch = getenv("WADDR") ? strtol(getenv("WADDR"), nullptr, 16) : -1;
            if (watch >= 0 && (long)(pw.addr & 0xffffe0) == (watch & 0xffffe0))
                printf("W %06x %04x be %d (burst base %06x) packet %llu cyc %llu\n", pw.addr, d, t->w_wbe, t->w_addr,
                       (unsigned long long)packets, (unsigned long long)cyc);
            uint32_t a = pw.addr & 0xffffff;
            if (t->w_wbe & 1) sd[a] = (sd[a] & 0xff00) | (d & 0x00ff);
            if (t->w_wbe & 2) sd[a] = (sd[a] & 0x00ff) | (d & 0xff00);
            pw.addr++;
            if (--pw.left == 0) { pw.active = false; pw.done_pending = true; }
        }
        t->clk = 1; t->eval();
        t->clk = 0; t->eval();
        cyc++;
    };

    uint64_t quads = 0, fails = 0, rtl_cycles = 0;
    uint32_t cur_ptr = 0;
    uint32_t q_dx = 0, q_dy = 0, q_ex = 0, q_ey = 0, q_dest = 0;
    bool have = false;
    uint16_t pk[32];

    auto compare = [&]() {
        if (!have) return;
        have = false;
        if (q_ex < q_dx || q_ey < q_dy) return;
        int bad = 0;
        for (uint32_t y = q_dy; y <= q_ey && bad < 5; y++)
            for (uint32_t x = q_dx; x <= q_ex && bad < 5; x++) {
                uint32_t ba = q_dest + ((((x & 0x3ff) | ((y & 0x1ff) << 10))) << 1);
                uint16_t ref = b.fb16(ba);
                uint16_t rtl = sd[0x800000 + (ba >> 1)];
                if (ref != rtl) {
                    if (bad == 0) {
                        printf("MISMATCH packet %llu (frame %d, queue %u): p0=%04x dx=%u dy=%u ex=%u ey=%u dest=%06x\n",
                               (unsigned long long)packets, b.frame, cur_ptr / 32, pk[0], q_dx, q_dy, q_ex, q_ey, q_dest);
                        printf("  words:");
                        for (int i = 0; i < 32; i++) printf(" %04x", pk[i]);
                        printf("\n  state: tx=%x ty=%x dxx=%x dxy=%x dyx=%x dyy=%x fmt=%d tiled=%d w=%d h=%d font=%x tile=%x pal=%x bank=%d trans=%06x shade=%06x blend=%02x/%02x\n",
                               b.rs.tx, b.rs.ty, b.rs.txdx, b.rs.tydx, b.rs.txdy, b.rs.tydy, b.rs.pixel_format, b.rs.texture_mode,
                               b.rs.width, b.rs.height, b.rs.font_offset, b.rs.tile_offset, b.rs.pal_offset, b.rs.palette_bank,
                               b.rs.trans_color, b.rs.shade_color, b.rs.src_blend, b.rs.dst_blend);
                    }
                    printf("  (%u,%u) ref %04x rtl %04x\n", x, y, ref, rtl);
                    bad++;
                }
            }
        if (bad) fails++;
    };

    b.hooks.before_packet = [&](uint32_t ptr) {
        compare();   // the previous packet has been processed by the reference by now
        // texture-cache snoops for the CPU writes since the last packet
        for (uint32_t w : snoops) {
            t->snoop = 1; t->snoop_addr = w;
            t->clk = 1; t->eval(); t->clk = 0; t->eval(); cyc++;
        }
        t->snoop = 0;
        snoops.clear();
        if (b.frame < from_frame) return;
        for (int i = 0; i < 32; i++) pk[i] = b.tex16((ptr + i) << 1);
        cur_ptr = ptr;
        // run the RTL on the same packet
        t->start = 1;
        t->pkt_addr = ptr;
        t->draw_dest = b.draw_dest;
        uint64_t c0 = cyc;
        tick();
        t->start = 0;
        int guard = 0;
        while (!t->done) {
            tick();
            {
                static long wp = getenv("CTRACE") ? atol(getenv("CTRACE")) : -1;
                if ((long)packets == wp) {
                    uint32_t d = t->dbg;
                    uint32_t x = (d >> 1) & 0x3ff;
                    uint32_t y = (t->dbg3 >> 10) & 0x1ff;
                    if (y == 20 && x >= 50 && x < 140)
                        printf("C rst %d stall %d%d%d p5v %d seg_v %d in %d w_req %d x %u seg_base %06x seg_m %08x\n", d >> 28,
                               (d >> 26) & 1, (d >> 25) & 1, (d >> 24) & 1, (d >> 18) & 1, (d >> 17) & 1, (d >> 12) & 1,
                               (d >> 13) & 1, x, t->dbg3, t->dbg2);
                }
            }
            if (++guard > 5000000) {
                printf("RTL renderer hung on packet %llu p0=%04x dbg=%08x\n", (unsigned long long)packets, pk[0], t->dbg);
                printf("  t port: req %d addr %06x len %d active %d left %d wait %d\n", t->t_req, t->t_addr, t->t_len, pt.active, pt.left, pt.wait);
                printf("  words:");
                for (int i = 0; i < 32; i++) printf(" %04x", pk[i]);
                printf("\n");
                exit(1);
            }
        }
        rtl_cycles += cyc - c0;
        packets++;
        if (!(pk[0] & 0x81) && (pk[0] & 0x100)) {
            quads++;
            have = true;
            q_dx = pk[1] & 0x3ff; q_dy = pk[2] & 0x1ff; q_ex = pk[3] & 0x3ff; q_ey = pk[4] & 0x1ff; q_dest = b.draw_dest;
        }
        if (verbose) printf("packet %llu p0=%04x cycles %llu\n", (unsigned long long)packets, pk[0], (unsigned long long)(cyc - c0));
    };

    int last = -1;
    while (b.frame < frames && fails == 0) {
        if (b.frame != last) {
            last = b.frame;
            auto r = inputs.equal_range(b.frame);
            for (auto it = r.first; it != r.second; ++it) {
                std::string w = it->second.substr(0, it->second.find(':'));
                bool on = it->second.find(":on") != std::string::npos;
                auto setbit = [&](uint8_t &reg, int bit) { if (on) reg &= ~(1 << bit); else reg |= (1 << bit); };
                if (w == "coin1") { if (on) b.coin_insert(0); setbit(b.in.system, 4); }
                else if (w == "start1") setbit(b.in.system, 0);
            }
            if (b.frame % 300 == 0) { printf("frame %d packets %llu quads %llu rtl pixels %u cycles %llu\n", b.frame, (unsigned long long)packets, (unsigned long long)quads, t->stat_pixels, (unsigned long long)rtl_cycles); fflush(stdout); }
        }
        b.step_insn();
    }
    compare();
    printf("RENDER DIFFTEST: %s frames=%d packets=%llu quads=%llu rtl_pixels=%u rtl_cycles=%llu (%.2f cycles/pixel)\n",
           fails ? "FAIL" : "PASS", b.frame, (unsigned long long)packets, (unsigned long long)quads, t->stat_pixels,
           (unsigned long long)rtl_cycles, t->stat_pixels ? double(rtl_cycles) / t->stat_pixels : 0.0);
    delete t;
    return fails ? 1 : 0;
}
