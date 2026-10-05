// Board-level lock-step test (M5): rtl/crystal/crystal_board.sv (Verilator) vs the reference SE3208 with a
// private copy of every RAM/ROM of the Crystal System.
//
//   tb_board --stream DIR [--insns N] [--frames N] [--trace-from N] [--seed S] [--progress N]
//
// DIR holds index0.bin (MRA stream: flash banks then BIOS) produced by scripts/mra_stream.py. The crysking
// protection words are substituted as the core's loader does (docs/PROTECTION.md).
//
// Checks, per retired instruction: PC, opcode, R0-R7, SR, SP, ER, interrupt entry, and the ordered list of CPU
// data accesses (write/read, byte address, size, data). Reads of RAM/ROM/flash-array must return what the
// reference memory holds; reads of device registers (I/O, flash command dword) are taken from the RTL; interrupts
// are taken when the RTL takes them, with the RTL's vector. The device blocks themselves are verified by their
// own tests and by frame/audio comparisons.
#include "Vcrystal_board.h"
#include "verilated.h"
#include "../reference/se3208_ref.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <fstream>
#include <map>
#include <string>
#include <vector>

double sc_time_stamp() { return 0; }

static std::vector<uint8_t> read_file(const std::string &p)
{
    std::ifstream f(p, std::ios::binary);
    if (!f) { fprintf(stderr, "cannot read %s\n", p.c_str()); exit(2); }
    return std::vector<uint8_t>((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
}

struct Acc { bool we; uint32_t addr; int size; uint32_t data; };

static uint64_t rng = 88172645463325252ull;
static uint32_t rnd() { rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17; return uint32_t(rng); }

int main(int argc, char **argv)
{
    std::string stream_dir;
    uint64_t max_insns = 50000000ull, trace_from = UINT64_MAX, progress = 1000000;
    int max_frames = 1000000;
    int max_lat = 3;
    bool io_trace = false;
    for (int i = 1; i < argc; i++) {
        std::string a = argv[i];
        if (a == "--stream") stream_dir = argv[++i];
        else if (a == "--insns") max_insns = strtoull(argv[++i], nullptr, 0);
        else if (a == "--frames") max_frames = atoi(argv[++i]);
        else if (a == "--trace-from") trace_from = strtoull(argv[++i], nullptr, 0);
        else if (a == "--progress") progress = strtoull(argv[++i], nullptr, 0);
        else if (a == "--seed") rng ^= strtoull(argv[++i], nullptr, 0) * 0x9E3779B97F4A7C15ull;
        else if (a == "--max-lat") max_lat = atoi(argv[++i]);
        else if (a == "--io-trace") io_trace = true;
    }
    auto stream = read_file(stream_dir + "/index0.bin");
    size_t nbanks = (stream.size() - 0x20000) / 0x1000000;
    std::vector<uint8_t> flash(stream.begin(), stream.begin() + nbanks * 0x1000000);
    std::vector<uint8_t> bios(stream.begin() + nbanks * 0x1000000, stream.end());
    {   // protection overlay (as rtl/crystal/crystal_prot_overlay.sv)
        auto w16 = [&](uint32_t a, uint16_t v) { flash[a] = v & 0xff; flash[a + 1] = v >> 8; };
        w16(0x7bb6, 0xdf01); w16(0x7bb8, 0x9c00); w16(0x976a, 0x901c); w16(0x976c, 0x9001);
        w16(0x8096, 0x90fc); w16(0x8098, 0x9001); w16(0x8a52, 0x4000); w16(0x8a54, 0x403c);
    }

    // ---------------- RTL-side physical memories
    std::vector<uint8_t> sdram(32u << 20, 0);
    memcpy(&sdram[0x1800000], bios.data(), bios.size());
    auto phys_rd = [&](uint32_t p, int n) -> uint32_t {
        uint32_t v = 0;
        for (int i = 0; i < n; i++) {
            uint32_t a = p + i;
            uint8_t b = (a & 0x8000000) ? flash[(a & 0x7ffffff) % flash.size()] : sdram[a & 0x1ffffff];
            v |= uint32_t(b) << (8 * i);
        }
        return v;
    };

    // ---------------- reference-side memories (MAME map)
    std::vector<uint8_t> r_wram(0x800000, 0), r_tex(0x800000, 0), r_frame(0x800000, 0), r_nvram(0x10000, 0);
    uint32_t r_bank = 0;
    // returns pointer to RAM/ROM byte or nullptr for device space
    auto r_ptr = [&](uint32_t a, bool write) -> uint8_t * {
        if (a < 0x20000) return write ? nullptr : &bios[a];
        if (a >= 0x01400000 && a < 0x01410000) return &r_nvram[a & 0xffff];
        if (a >= 0x02000000 && a < 0x03000000) return &r_wram[a & 0x7fffff];
        if (a >= 0x03800000 && a < 0x04000000) return &r_tex[a & 0x7fffff];
        if (a >= 0x04000000 && a < 0x04800000) return &r_frame[a & 0x7fffff];
        if (a >= 0x05000000 && a < 0x06000000 && (a & ~3u) != 0x05000000 && !write) {
            if (r_bank < nbanks) return &flash[r_bank * 0x1000000 + (a & 0xffffff)];
            return nullptr;
        }
        return nullptr;
    };

    Vcrystal_board *top = new Vcrystal_board;
    top->flash_banks = uint8_t(nbanks);
    top->cpu_credit_max = 32;
    top->cpu_turbo = 0;
    top->render_interval = 1100;
    top->in_p1p2 = 0xffffffff;
    top->in_p3p4 = 0xffffffff;
    top->in_system = 0xff;
    top->in_dsw = 0xff;
    top->rtc_load = 0;
    top->rst_n = 0;
    top->clk = 0;
    for (int i = 0; i < 8; i++) { top->clk = 1; top->eval(); top->clk = 0; top->eval(); }
    top->rst_n = 1;

    se3208::Cpu ref;
    std::deque<Acc> rtl_acc;         // CPU data accesses observed in the RTL for the current instruction
    std::vector<Acc> ref_acc;
    bool mismatch = false;
    std::string why;
    uint8_t irq_vec_for_ref = 0;
    size_t rtl_pos = 0;             // index into the RTL access list while the reference executes
    std::vector<Acc> cur;           // RTL accesses of the instruction being replayed
    bool in_reset = true;

    // shadow of registers with plain read-back (MAME): value and the mask of bits that read back as written
    std::map<uint32_t, std::pair<uint32_t, uint32_t>> shadow;
    auto shadow_mask = [](uint32_t da) -> uint32_t {
        if (da == 0x01800c08) return 0xffffffff;                                      // INTEN
        if (da >= 0x01801400 && da < 0x01801420) return (da & 4) ? 0x0000ffff : 0xfffffffe; // TMCNT / TMCON (b0 self-clears)
        if (da == 0x01800804 || da == 0x01800808 || da == 0x01800814 || da == 0x01800818) return 0xffffffff;
        return 0;
    };
    ref.bus.read = [&](uint32_t a, int s) -> uint32_t {
        uint32_t v = 0;
        uint8_t *p = r_ptr(a, false);
        bool device = (p == nullptr);
        if (in_reset) { for (int i = 0; i < s; i++) v |= uint32_t(r_ptr(a + i, false)[0]) << (8 * i); return v; }
        if (!device) for (int i = 0; i < s; i++) v |= uint32_t(r_ptr(a + i, false)[0]) << (8 * i);
        if (rtl_pos >= cur.size()) { if (!mismatch) { mismatch = true; why = "reference made an extra read"; } return v; }
        const Acc &r = cur[rtl_pos++];
        if (r.we || r.addr != a || r.size != s) {
            if (!mismatch) { mismatch = true; char b[200]; snprintf(b, sizeof b, "access mismatch: ref R %08x/%d, rtl %c %08x/%d", a, s, r.we ? 'W' : 'R', r.addr, r.size); why = b; }
            return v;
        }
        if (device) {
            uint32_t da = a & ~3u, sm = shadow_mask(da);
            auto it = shadow.find(da);
            if (sm && it != shadow.end()) {
                uint32_t lane = (a & 3) * 8, m = (s == 4 ? 0xffffffffu : ((1u << (8 * s)) - 1));
                uint32_t chk = (sm & it->second.second) >> lane & m;
                uint32_t exp = (it->second.first >> lane) & m;
                if (((r.data ^ exp) & chk) && !mismatch) { mismatch = true; char b[200]; snprintf(b, sizeof b, "register read-back %08x/%d: rtl %08x expected %08x (mask %08x)", a, s, r.data, exp, chk); why = b; }
            }
            return r.data;
        }
        if (r.data != v && !mismatch) { mismatch = true; char b[200]; snprintf(b, sizeof b, "read data mismatch at %08x/%d: rtl %08x ref %08x", a, s, r.data, v); why = b; }
        return v;
    };
    ref.bus.write = [&](uint32_t a, int s, uint32_t d) {
        if (rtl_pos >= cur.size()) { if (!mismatch) { mismatch = true; why = "reference made an extra write"; } return; }
        const Acc &r = cur[rtl_pos++];
        if (!r.we || r.addr != a || r.size != s || r.data != d) {
            if (!mismatch) { mismatch = true; char b[200]; snprintf(b, sizeof b, "access mismatch: ref W %08x/%d=%08x, rtl %c %08x/%d=%08x", a, s, d, r.we ? 'W' : 'R', r.addr, r.size, r.data); why = b; }
        }
        {
            uint32_t da = a & ~3u;
            if (shadow_mask(da)) {
                uint32_t lane = (a & 3) * 8, m = (s == 4 ? 0xffffffffu : ((1u << (8 * s)) - 1)) << lane;
                auto &e = shadow[da];
                e.first = (e.first & ~m) | ((d << lane) & m);
                e.second |= m;
            }
        }
        uint8_t *p = r_ptr(a, true);
        if (p) for (int i = 0; i < s; i++) *r_ptr(a + i, true) = uint8_t(d >> (8 * i));
        if ((a & ~3u) == 0x01280000) r_bank = ((d << (8 * (a & 3))) >> 1) & 7;
    };
    ref.bus.fetch = [&](uint32_t a) -> uint16_t {
        a &= ~1u;
        uint8_t *p = r_ptr(a, false);
        return p ? uint16_t(p[0] | (r_ptr(a + 1, false)[0] << 8)) : 0;
    };
    ref.bus.iack = [&]() { return irq_vec_for_ref; };
    ref.reset();
    in_reset = false;
    // the reset vector read is a data access in the RTL; consume it below

    // ---------------- memory port servers
    struct Port { int wait = -1; } pi, pd;
    // renderer SDRAM clients (crystal_sdram protocol: rvalid per word, done with the last read word, writes
    // advance on wnext and complete with done one clock after the last word)
    struct CPort { bool active = false; uint32_t addr = 0; int left = 0, wait = 0; bool done_pending = false; } ct, cf, cw;
    auto sd_word = [&](uint32_t w) -> uint16_t { uint32_t b = (w << 1) & 0x1ffffff; return uint16_t(sdram[b] | (sdram[b + 1] << 8)); };
    uint64_t cycles = 0, insns = 0, frames = 0, irqs = 0;
    bool reset_read_seen = false;
    std::vector<Acc> pending;        // RTL accesses since the last retire
    while (!mismatch && insns < max_insns && frames < uint64_t(max_frames)) {
        // responses
        top->mi_ack = 0; top->md_ack = 0;
        top->vt_rvalid = 0; top->vt_done = 0; top->vf_rvalid = 0; top->vf_done = 0; top->vw_wnext = 0;
        top->vw_done = cw.done_pending; cw.done_pending = false;
        top->tex_snoop = 0;
        top->ss_rvalid = 0; top->ss_done = 0;
        {
            static int sw = -1;
            if (top->ss_req) {
                if (sw < 0) sw = 2;
                if (sw == 0) { top->ss_rvalid = 1; top->ss_done = 1; top->ss_rdata = sd_word(top->ss_addr); sw = -2; }
                else if (sw > 0) sw--;
            } else sw = -1;
        }
        {
            bool tr = false, fr = false;
            if (top->vt_req && !ct.active) { ct = {true, top->vt_addr, top->vt_len, int(1 + rnd() % 4), false}; }
            if (ct.active) { if (ct.wait > 0) ct.wait--; else { top->v_rdata = sd_word(ct.addr++); top->vt_rvalid = 1; tr = true; if (--ct.left == 0) { top->vt_done = 1; ct.active = false; } } }
            if (top->vf_req && !cf.active) { cf = {true, top->vf_addr, top->vf_len, int(1 + rnd() % 4), false}; }
            if (cf.active && !tr) { if (cf.wait > 0) cf.wait--; else { top->v_rdata = sd_word(cf.addr++); top->vf_rvalid = 1; if (--cf.left == 0) { top->vf_done = 1; cf.active = false; } } }
            (void)fr;
            if (top->vw_req && !cw.active && !top->vw_done) { cw = {true, top->vw_addr, top->vw_len, int(1 + rnd() % 4), false}; }
            if (cw.active) { if (cw.wait > 0) cw.wait--; else top->vw_wnext = 1; }
        }
        if (top->mi_req) { if (pi.wait < 0) pi.wait = rnd() % (max_lat + 1); if (pi.wait == 0) { top->mi_ack = 1; top->mi_data = uint16_t(phys_rd(top->mi_addr, 2)); } }
        if (top->md_req) {
            if (pd.wait < 0) pd.wait = rnd() % (max_lat + 1);
            if (pd.wait == 0) {
                top->md_ack = 1;
                uint32_t p = top->md_addr & ~3u;
                if (top->md_we) {
                    if ((p & 0x1800000) == 0x0800000) { top->tex_snoop = 1; top->tex_snoop_addr = (p >> 1) & 0xffffff; }
                    for (int b = 0; b < 4; b++) if (top->md_be & (1 << b)) {
                        uint32_t a = p + b;
                        if (!(a & 0x8000000)) sdram[a & 0x1ffffff] = uint8_t(top->md_wdata >> (8 * b));
                    }
                } else top->md_rdata = phys_rd(p, 4);
            }
        }
        top->eval();
        if (top->vw_wnext) {
            uint32_t b = (cw.addr << 1) & 0x1ffffff;
            if (top->vw_wbe & 1) sdram[b] = uint8_t(top->vw_wdata);
            if (top->vw_wbe & 2) sdram[b + 1] = uint8_t(top->vw_wdata >> 8);
            cw.addr++;
            if (--cw.left == 0) { cw.active = false; cw.done_pending = true; }
        }
        top->eval();
        // the CPU consumes a data acknowledge on the coming edge (it may be combinational): sample it now
        if (top->dbg_d_ack) {
            Acc a;
            a.we = top->dbg_d_we;
            int lo = -1, n = 0;
            for (int b = 0; b < 4; b++) if (top->dbg_d_be & (1 << b)) { if (lo < 0) lo = b; n++; }
            a.addr = (top->dbg_d_addr & ~3u) + lo;
            a.size = n;
            uint32_t m = n == 4 ? 0xffffffffu : ((1u << (8 * n)) - 1);
            a.data = ((a.we ? top->dbg_d_wdata : top->dbg_d_rdata) >> (8 * lo)) & m;
            if (!reset_read_seen) {
                reset_read_seen = true;   // PC = read32(0) at reset
                if (a.addr != 0 || a.size != 4 || a.data != ref.s.PC) { mismatch = true; why = "reset vector read"; }
            } else
                pending.push_back(a);
            if (io_trace && (a.addr >= 0x01200000 && a.addr < 0x02000000 || a.addr >= 0x03000000 && a.addr < 0x03010000 || a.addr >= 0x04800000 && a.addr < 0x05000000))
                printf("IO %c %08x/%d %08x  insn %llu frame %llu cyc %llu\n", a.we ? 'W' : 'R', a.addr, a.size, a.data, (unsigned long long)insns, (unsigned long long)frames, (unsigned long long)cycles);
        }
        top->clk = 1;
        top->eval();
        if (pi.wait >= 0) { if (top->mi_ack) pi.wait = -1; else pi.wait--; }
        if (pd.wait >= 0) { if (top->md_ack) pd.wait = -1; else pd.wait--; }

        top->clk = 0;
        top->eval();
        cycles++;

        if (top->dbg_vblank_start) {
            frames++;
            if (frames % 60 == 0) { printf("frame %llu insns %llu cycles %llu pc %08x irqs %llu\n", (unsigned long long)frames, (unsigned long long)insns, (unsigned long long)cycles, ref.s.PC, (unsigned long long)irqs); fflush(stdout); }
        }
        if (top->dbg_illegal) { mismatch = true; why = "RTL reports an illegal opcode"; }
        if (top->dbg_retire) {
            cur = pending;
            pending.clear();
            rtl_pos = 0;
            bool took = top->dbg_took_irq;
            if (took) {
                // the vector read is the last read of the entry sequence
                for (auto it = cur.rbegin(); it != cur.rend(); ++it) if (!it->we) { irq_vec_for_ref = uint8_t(it->addr / 4); break; }
                irqs++;
            }
            ref.irq_line = took;
            ref.step();
            insns++;
            auto &s = ref.s;
            bool regs_ok = true;
            for (int r = 0; r < 8; r++) if (top->dbg_regs[r] != s.R[r]) regs_ok = false;
            if (!mismatch && rtl_pos != cur.size()) { mismatch = true; why = "RTL made accesses the reference did not"; }
            if (!mismatch && (!regs_ok || top->dbg_sr != s.SR || top->dbg_sp != s.SP || top->dbg_er != s.ER ||
                top->dbg_pc != s.PPC || top->dbg_opcode != ref.last_opcode || took != ref.last_took_irq)) {
                mismatch = true; why = "architectural state mismatch";
            }
            if (insns >= trace_from || mismatch) {
                printf("%s %llu pc %08x op %04x %-9s SR=%04x SP=%08x R=%08x %08x %08x %08x %08x %08x %08x %08x%s\n",
                       mismatch ? "FAIL" : "    ", (unsigned long long)insns, s.PPC, ref.last_opcode, se3208::op_name(ref.last_op),
                       s.SR, s.SP, s.R[0], s.R[1], s.R[2], s.R[3], s.R[4], s.R[5], s.R[6], s.R[7], took ? " +IRQ" : "");
            }
            if (mismatch) {
                printf("  why: %s\n", why.c_str());
                printf("  rtl  PC %08x op %04x SR %08x SP %08x ER %08x took %d\n", top->dbg_pc, top->dbg_opcode, top->dbg_sr, top->dbg_sp, top->dbg_er, took);
                for (int r = 0; r < 8; r++) printf("  R%d rtl %08x ref %08x\n", r, top->dbg_regs[r], s.R[r]);
                for (auto &a : cur) printf("  rtl %c %08x/%d %08x\n", a.we ? 'W' : 'R', a.addr, a.size, a.data);
            }
            if (progress && insns % progress == 0) { printf("  %llu insns, frame %llu, pc %08x\n", (unsigned long long)insns, (unsigned long long)frames, s.PC); fflush(stdout); }
        }
    }
    if (mismatch) printf("  why: %s\n", why.c_str());
    printf("BOARD LOCKSTEP: %s insns=%llu frames=%llu cycles=%llu irqs=%llu final pc=%08x  (%.2f cycles/insn)\n",
           mismatch ? "FAIL" : "PASS", (unsigned long long)insns, (unsigned long long)frames, (unsigned long long)cycles,
           (unsigned long long)irqs, ref.s.PC, insns ? double(cycles) / insns : 0.0);
    delete top;
    return mismatch ? 1 : 0;
}
