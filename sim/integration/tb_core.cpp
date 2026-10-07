// Full-core simulation: rtl/crystal/crystal_core.sv with the SDRAM chip model, a DDR3 (Avalon-MM) model and the
// real MRA download through the ioctl interface.
//
//   tb_core --stream DIR [--frames N] [--snap-every N] [--snap-at F,F] [--out DIR] [--input F:what:on|off]
//
// Captures the core's video output (r,g,b with ce_pix/hblank/vblank) into PPM frames -- the scanout layer as
// MiSTer would see it -- and reports CPU progress, SDRAM timing violations, scanout underflows and illegal
// opcodes.
#include "Vcrystal_core.h"
#include "verilated.h"
#include "../memory/sdram_model.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <algorithm>
#include <deque>
#include <fstream>
#include <map>
#include <set>
#include <sstream>
#include <string>
#include <vector>

double sc_time_stamp() { return 0; }
static uint64_t rng = 0x2545F4914F6CDD1Dull;
static uint32_t rnd() { rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17; return uint32_t(rng); }

static std::vector<uint8_t> read_file(const std::string &p)
{
    std::ifstream f(p, std::ios::binary);
    if (!f) { fprintf(stderr, "cannot read %s\n", p.c_str()); exit(2); }
    return std::vector<uint8_t>((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
}

struct Ddr3 {
    static constexpr uint64_t BASE_W = 0x32000000ull / 8;
    std::vector<uint64_t> mem = std::vector<uint64_t>(128u << 20 >> 3, 0);   // 128 MiB window
    struct Burst { uint64_t start; uint64_t addr; int n; };
    std::deque<Burst> q;
    int beat = 0;
    uint64_t reads = 0, writes = 0;
    void step(Vcrystal_core *t, uint64_t cyc) {
        t->DDRAM_DOUT_READY = 0;
        bool busy = (rnd() % 8) == 0;
        if (!q.empty() && q.front().start <= cyc) {
            Burst &b = q.front();
            if (rnd() % 6) {   // occasional gaps between beats
                uint64_t w = b.addr - BASE_W + beat;
                t->DDRAM_DOUT = w < mem.size() ? mem[w] : 0;
                t->DDRAM_DOUT_READY = 1;
                if (++beat == b.n) { q.pop_front(); beat = 0; }
            }
        }
        t->DDRAM_BUSY = busy;
        (void)writes;
    }
    // Avalon: a command is accepted on an edge where RD/WE is asserted and BUSY is low; sample before the edge
    struct Cmd { bool rd, we; uint64_t addr, din; int n; uint8_t be; } pre;
    void sample(Vcrystal_core *t) {
        pre = {bool(t->DDRAM_RD), bool(t->DDRAM_WE), t->DDRAM_ADDR, t->DDRAM_DIN, t->DDRAM_BURSTCNT, t->DDRAM_BE};
    }
    void accept(uint64_t cyc, bool busy_seen) {
        if (busy_seen) return;
        if (pre.rd) { q.push_back({cyc + 18 + rnd() % 12, pre.addr, pre.n}); reads++; }
        if (pre.we) {
            uint64_t w = pre.addr - BASE_W;
            if (w < mem.size()) {
                uint64_t m = 0;
                for (int b = 0; b < 8; b++) if (pre.be & (1 << b)) m |= 0xffull << (8 * b);
                mem[w] = (mem[w] & ~m) | (pre.din & m);
            }
            writes++;
        }
    }
};

int main(int argc, char **argv)
{
    std::string stream_dir = "C:/Users/klest/Crystal_research/stream", out = ".";
    int frames = 120, snap_every = 0;
    std::set<int> snap_at;
    std::multimap<int, std::string> inputs;
    bool turbo = false, flip = false;
    int dump_tex_frame = -1; std::string dump_tex_file;
    int line_w = 320;                     // active pixels per line (320; Top Blade V 360)
    int dsw = -1;                         // >= 0: send the DIP switches on index 254 after the ROM download (as MiSTer)
    std::string wav;
    for (int i = 1; i < argc; i++) {
        std::string a = argv[i];
        auto nx = [&]() { return std::string(argv[++i]); };
        if (a == "--stream") stream_dir = nx();
        else if (a == "--frames") frames = atoi(nx().c_str());
        else if (a == "--snap-every") snap_every = atoi(nx().c_str());
        else if (a == "--snap-at") { std::stringstream ss(nx()); std::string t; while (std::getline(ss, t, ',')) snap_at.insert(atoi(t.c_str())); }
        else if (a == "--out") out = nx();
        else if (a == "--input") { std::string v = nx(); inputs.emplace(atoi(v.c_str()), v.substr(v.find(':') + 1)); }
        else if (a == "--turbo") turbo = true;
        else if (a == "--flip") flip = true;
        else if (a == "--dump-tex") { std::string v = nx(); dump_tex_frame = atoi(v.c_str()); dump_tex_file = v.substr(v.find(':') + 1); }
        else if (a == "--dsw") dsw = (int)strtol(nx().c_str(), nullptr, 16);
        else if (a == "--wav") wav = nx();
    }
    FILE *fw = wav.empty() ? nullptr : fopen(wav.c_str(), "wb");
    if (fw) { uint8_t h[44] = {}; fwrite(h, 1, 44, fw); }
    uint64_t wav_samples = 0, wav_nonzero = 0;
    // flash words the protection overlay replaces (crysking: game id 1, evosocc: game id 2), 16-byte granules
    auto is_prot = [](uint32_t off) {
        static const uint32_t w[] = {0x7bb0, 0x9760, 0x8090, 0x8a50,                                   // crysking
                                     0x2973880, 0x2973890, 0x2971050, 0x2971060, 0x2978030, 0x2974ed0}; // evosocc
        for (uint32_t x : w) if ((off >> 4) == (x >> 4)) return true;
        return false;
    };
    // optional protection PIC firmware stream (index 3: Top Blade V, Office Yeoin Cheonha)
    std::vector<uint8_t> s3;
    { std::ifstream f3(stream_dir + "/index3.bin", std::ios::binary);
      if (f3) s3.assign((std::istreambuf_iterator<char>(f3)), std::istreambuf_iterator<char>()); }
    auto s0 = read_file(stream_dir + "/index0.bin");
    auto s1 = read_file(stream_dir + "/index1.bin");

    Vcrystal_core *t = new Vcrystal_core;
    SdramModel sd;
    // ---- texture-write monitor: every CPU/DMA write to texture RAM (board bus) must reach the SDRAM unchanged and
    //      in order (through crystal_texq and the D-cache)
    struct HW { uint32_t w; uint16_t d; uint8_t lanes; };
    std::deque<HW> tex_exp;
    uint64_t tex_ok = 0, tex_bad = 0, flash_rd_ok = 0, flash_rd_bad = 0;
    struct TR { uint64_t cyc; char k; uint32_t w; uint32_t d; uint8_t m; };
    std::deque<TR> ring;
    auto ring_add = [&](TR r) { ring.push_back(r); if (ring.size() > 160) ring.pop_front(); };
    bool ring_dumped = false;
    bool mon_on = false;
    uint64_t bus_wait[5][2] = {}, bus_cnt[5][2] = {};
    uint64_t trw[4] = {};
    uint64_t texrd_ok = 0, texrd_bad = 0;
    uint64_t hash_hit[7] = {};
    static uint32_t sh_tag[2][4096]; static uint8_t sh_mask[2][4096]; uint64_t sh_srv[2] = {};
    for (int k = 0; k < 2; k++) for (int i = 0; i < 4096; i++) sh_tag[k][i] = ~0u;
    uint64_t texrd_pend = 0, texrd_free = 0; std::map<uint32_t, uint64_t> texrd_hist;
    int *cur_frame = nullptr; uint64_t *cur_cyc = nullptr;                  // after the board left reset (the loader clears the RAM before)
    sd.on_write = [&](uint32_t w, uint16_t d, uint8_t lanes) {
        if (!mon_on || w < 0x400000 || w >= 0x800000) return;
        { static int tf = getenv("TEXTRACE") ? atoi(getenv("TEXTRACE")) : -1;
          if (tf >= 0 && *cur_frame >= tf && *cur_frame <= tf + 2 && w >= 0x424400 && w < 0x424440)
              printf("  SDRAM W %06x %04x lanes %x cyc %llu\n", w, d, lanes, (unsigned long long)*cur_cyc); }
        if (tex_exp.empty()) { if (tex_bad++ < 10) printf("TEXWRITE unexpected word %06x %04x lanes %x\n", w, d, lanes); return; }
        ring_add({*cur_cyc, 'S', w, d, lanes});
        HW e = tex_exp.front(); tex_exp.pop_front();
        uint16_t m = (lanes & 1 ? 0x00ff : 0) | (lanes & 2 ? 0xff00 : 0);
        if (e.w != w || e.lanes != lanes || ((e.d ^ d) & m)) {
            if (!ring_dumped) { ring_dumped = true;
                for (auto &r : ring) printf("  %c %06x %08x m%x cyc %llu\n", r.k, r.w, r.d, r.m, (unsigned long long)r.cyc); }
            if (tex_bad++ < 10) printf("TEXWRITE MISMATCH: expected %06x %04x lanes %x, SDRAM got %06x %04x lanes %x\n", e.w, e.d, e.lanes, w, d, lanes);
        } else tex_ok++;
    };
    Ddr3 ddr;
    t->clk_sys = 0;
    t->pll_locked = 0;
    t->reset_request = 0;
    t->ioctl_download = 0;
    t->ioctl_wr = 0;
    t->joy0 = t->joy1 = t->joy2 = t->joy3 = 0;
    t->sw_test = 0;
    t->cpu_turbo = turbo;
    t->osd_flip = flip;
    t->DDRAM_BUSY = 0;
    t->DDRAM_DOUT_READY = 0;
    uint64_t cyc = 0;

    auto tick = [&]() {
        ddr.step(t, cyc);
        t->eval();
        bool busy_seen = t->DDRAM_BUSY;
        ddr.sample(t);
        t->SDRAM_DQ_I = sd.dq_i;
        t->clk_sys = 1;
        t->eval();
        sd.step(t->SDRAM_nRAS, t->SDRAM_nCAS, t->SDRAM_nWE, t->SDRAM_BA, t->SDRAM_A, t->SDRAM_DQ_O, t->SDRAM_DQ_OE);
        ddr.accept(cyc, busy_seen);
        t->clk_sys = 0;
        t->eval();
        cyc++;
    };
    for (int i = 0; i < 20; i++) tick();
    t->pll_locked = 1;

    // ---- download: index 1 then index 0 (hps_io WIDE: 16-bit words, byte addresses)
    auto download = [&](int index, const std::vector<uint8_t> &d) {
        t->ioctl_index = index;
        t->ioctl_download = 1;
        for (int i = 0; i < 4; i++) tick();
        for (size_t a = 0; a < d.size(); a += 2) {
            while (t->ioctl_wait) tick();
            t->ioctl_addr = uint32_t(a);
            t->ioctl_dout = uint16_t(d[a] | (a + 1 < d.size() ? d[a + 1] << 8 : 0));
            t->ioctl_wr = 1;
            tick();
            t->ioctl_wr = 0;
            tick();
            if ((a & 0x3fffff) == 0 && index == 0) { printf("  download %zu MiB\n", a >> 20); fflush(stdout); }
        }
        for (int i = 0; i < 4; i++) tick();
        t->ioctl_download = 0;
        tick();
    };
    // wait for SDRAM init
    for (int i = 0; i < 12000; i++) tick();
    download(1, s1);
    if (!s3.empty()) { download(3, s3); printf("PIC firmware sent on index 3: %zu bytes\n", s3.size()); }
    download(0, s0);
    if (dsw >= 0) {
        std::vector<uint8_t> d(8, 0);
        d[0] = uint8_t(dsw);
        download(254, d);
        printf("DIP switches sent on index 254: %02x\n", dsw);
    }
    printf("download done at cycle %llu, ddr writes %llu\n", (unsigned long long)cyc, (unsigned long long)ddr.writes);
    // verify the flash store image (protection words included) against the stream
    {
        size_t nb = (s0.size() - 0x20000) / 0x1000000, bad = 0;
        for (size_t w = 0; w < nb * 0x1000000 / 8; w++) {
            uint64_t v = 0;
            for (int b = 0; b < 8; b++) v |= uint64_t(s0[w * 8 + b]) << (8 * b);
            if (ddr.mem[w] != v) {
                uint32_t off = uint32_t(w * 8);
                bool prot = is_prot(off);
                if (!prot && bad++ < 4) printf("  flash store mismatch at %08x\n", off);
            }
        }
        printf("flash store check: %s\n", bad ? "FAIL" : "PASS (only the 8 protection words differ)");
    }

    // ---- run frames, capture video
    std::vector<uint32_t> img(1024 * 512, 0);
    int frame = 0, x = 0, y = 0;
    cur_frame = &frame; cur_cyc = &cyc;
    bool vb_q = true, hb_q = true;
    uint64_t retired = 0, illegal = 0, last_report = 0;
    uint64_t st_hist[32] = {};
    static const char *st_names[] = {"RESET0","RESET1","FETCH","FETCHW","DECODE","EXEC","MUL","MEM","MEMW","LOADWB","STACK","DONE","IRQ0","IRQ1","IRQ2","HALTED"};
    while (frame < frames) {
        tick();
        if (t->dbg_retire) retired++;
        {
            // every CPU flash-array read must return the ROM bytes of the selected bank
            static uint32_t bankreg = 0;
            static int flash_bad = 0;
            if (t->dbg_d_ack && t->dbg_d_we && (t->dbg_d_addr & ~3u) == 0x01280000) bankreg = (t->dbg_d_data >> 1) & 7;
            if (t->dbg_d_ack && !t->dbg_d_we && t->dbg_d_addr >= 0x05000004 && t->dbg_d_addr < 0x06000000 && bankreg < (s0.size() - 0x20000) / 0x1000000) {
                uint32_t off = bankreg * 0x1000000 + (t->dbg_d_addr & 0xfffffc);
                uint32_t exp = s0[off] | s0[off + 1] << 8 | s0[off + 2] << 16 | uint32_t(s0[off + 3]) << 24;
                for (int k = 0; k < 4; k++) if (!((t->dbg_d_be >> k) & 1)) exp &= ~(0xffu << (8 * k));
                uint32_t got = t->dbg_d_data;
                for (int k = 0; k < 4; k++) if (!((t->dbg_d_be >> k) & 1)) got &= ~(0xffu << (8 * k));
                bool prot = is_prot(off);
                if (got != exp && !prot && flash_bad++ < 10)
                    printf("FLASH READ MISMATCH bank %u off %07x be %x got %08x expected %08x cycle %llu frame %d\n", bankreg, off, t->dbg_d_be, got, exp, (unsigned long long)cyc, frame);
            }
        }
        {
            static FILE *wf = getenv("WDUMP") ? fopen(getenv("WDUMP"), "w") : nullptr;
            static bool all = getenv("WDUMP_ALL") != nullptr;
            if (wf && t->dbg_d_ack && (t->dbg_d_we || all))
                fprintf(wf, "%c %08x %x %08x\n", t->dbg_d_we ? 'W' : 'R', t->dbg_d_addr, t->dbg_d_be, t->dbg_d_data);
        }
        {
            static int io_from = getenv("IOTRACE_FROM") ? atoi(getenv("IOTRACE_FROM")) : -1;
            static int io_to = getenv("IOTRACE_TO") ? atoi(getenv("IOTRACE_TO")) : -1;
            if (io_from >= 0 && frame >= io_from && frame <= io_to && t->dbg_d_ack) {
                uint32_t a = t->dbg_d_addr;
                if ((a >= 0x01200000 && a < 0x02000000) || (a >= 0x03000000 && a < 0x03010000) || (a >= 0x04800000 && a < 0x05000000) || (a & ~3u) == 0x05000000)
                    printf("IO %c %08x be %x %08x frame %d cyc %llu\n", t->dbg_d_we ? 'W' : 'R', a, t->dbg_d_be, t->dbg_d_data, frame, (unsigned long long)cyc);
            }
        }
        st_hist[t->dbg_cpu_state & 31]++;
        if (t->cpu_running) mon_on = true;
        if (t->dbg_m_req && !t->dbg_m_ack && mon_on) {
            uint32_t pa = t->dbg_m_addr;
            int reg = (pa & 0x8000000) ? 0 : 1 + int((pa >> 23) & 3);            // 0 flash, 1 work, 2 tex, 3 frame, 4 bios/nvram
            bus_wait[reg][t->dbg_m_we ? 1 : 0]++;
            if (reg == 2 && !t->dbg_m_we) {   // texture read waiting: why?
                if (t->dbg_tq_state & 2) trw[0]++;            // blocked by a queued write to its block
                else if (t->dbg_tq_state & 4) trw[1]++;       // the queue is writing to the D-cache
                else if (!t->dbg_dc_idle) trw[2]++;           // D-cache busy (its own transaction / write FIFO)
                else trw[3]++;
            }
        }
        static bool m_req_q = false; static uint32_t m_addr_q = 0;
        bool m_start = t->dbg_m_req && (!m_req_q || t->dbg_m_addr != m_addr_q);
        m_req_q = t->dbg_m_req && !t->dbg_m_ack; m_addr_q = t->dbg_m_addr;
        if (m_start && mon_on && !t->dbg_m_we && !(t->dbg_m_addr & 0x8000000) && ((t->dbg_m_addr >> 23) & 3) == 1) {
            // texture read: is any write to the same dword still on its way to the SDRAM?
            uint32_t w = (t->dbg_m_addr & 0x1fffffc) >> 1;
            bool pend = false;
            for (auto &e : tex_exp) if ((e.w & ~1u) == w) { pend = true; break; }
            (pend ? texrd_pend : texrd_free)++;
            {   // would a hashed per-bucket pending check block this read? (texq design study)
                auto fold = [](uint32_t v, int b) { uint32_t r = 0; while (v) { r ^= v & ((1u << b) - 1); v >>= b; } return r; };
                uint32_t ra = w << 1; bool hit[7] = {};
                for (auto &e : tex_exp) {
                    uint32_t wa = e.w << 1;
                    hit[0] |= ((wa >> 6) & 127) == ((ra >> 6) & 127);
                    hit[1] |= ((wa >> 6) & 1023) == ((ra >> 6) & 1023);
                    hit[2] |= ((wa >> 4) & 1023) == ((ra >> 4) & 1023);
                    hit[3] |= fold(wa >> 6, 7) == fold(ra >> 6, 7);
                    hit[4] |= fold(wa >> 4, 10) == fold(ra >> 4, 10);
                    hit[5] |= (wa >> 6) == (ra >> 6);
                    hit[6] |= (wa >> 11) == (ra >> 11);
                }
                for (int k = 0; k < 7; k++) hash_hit[k] += hit[k];
                if (hit[5]) {   // blocked: could a direct-mapped shadow of queued writes answer it?
                    uint32_t dw = ra >> 2;
                    for (int k = 0; k < 2; k++) {
                        uint32_t i = dw & (k ? 4095 : 1023);
                        if (sh_tag[k][i] == dw && (sh_mask[k][i] & t->dbg_m_be) == t->dbg_m_be) sh_srv[k]++;
                    }
                }
            }
            texrd_hist[(t->dbg_m_addr >> 12) & 0x7ff]++;
        }
        if (t->dbg_m_ack && mon_on && !t->dbg_m_we && !(t->dbg_m_addr & 0x8000000) && ((t->dbg_m_addr >> 23) & 3) == 1) {
            // texture read data: the SDRAM contents with the still-queued writes applied in order
            uint32_t w0 = (t->dbg_m_addr & 0x1fffffc) >> 1, exp = 0;
            for (int h = 0; h < 2; h++) {
                uint16_t v = sd.mem[w0 + h];
                for (auto &e : tex_exp) if (e.w == w0 + h) {
                    if (e.lanes & 1) v = (v & 0xff00) | (e.d & 0x00ff);
                    if (e.lanes & 2) v = (v & 0x00ff) | (e.d & 0xff00);
                }
                exp |= uint32_t(v) << (16 * h);
            }
            uint32_t m = 0; for (int b = 0; b < 4; b++) if (t->dbg_m_be >> b & 1) m |= 0xffu << (8 * b);
            if ((t->dbg_m_rdata & m) != (exp & m)) { if (texrd_bad++ < 10) printf("TEXREAD %07x be %x got %08x want %08x\n", t->dbg_m_addr, t->dbg_m_be, t->dbg_m_rdata, exp); }
            else texrd_ok++;
        }
        if (t->dbg_m_ack && mon_on) { uint32_t pa = t->dbg_m_addr; int reg = (pa & 0x8000000) ? 0 : 1 + int((pa >> 23) & 3); bus_cnt[reg][t->dbg_m_we ? 1 : 0]++; }
        if (t->dbg_m_ack) {
            uint32_t pa = t->dbg_m_addr;
            if (t->dbg_m_we && !(pa & 0x8000000) && ((pa >> 23) & 3) == 1) {
                uint32_t w = (pa & 0x1fffffc) >> 1;
                uint8_t be = t->dbg_m_be;
                { static int tf = getenv("TEXTRACE") ? atoi(getenv("TEXTRACE")) : -1;
                  if (tf >= 0 && frame >= tf && frame <= tf + 2 && w >= 0x424400 && w < 0x424440)
                      printf("  BUS W %06x be %x data %08x cyc %llu\n", w, be, t->dbg_m_wdata, (unsigned long long)cyc); }
                ring_add({cyc, 'B', w, t->dbg_m_wdata, be});
                ring_add({cyc, t->dbg_m_req ? 'r' : '!', pa, 0, 0});
                for (int k = 0; k < 2; k++) {
                    uint32_t dw = pa >> 2 & 0x7fffff, i = dw & (k ? 4095 : 1023);
                    if (sh_tag[k][i] == dw) sh_mask[k][i] |= be; else { sh_tag[k][i] = dw; sh_mask[k][i] = be; }
                }
                if (be & 3)  tex_exp.push_back({w,     uint16_t(t->dbg_m_wdata),       uint8_t(be & 3)});
                if (be & 12) tex_exp.push_back({w + 1, uint16_t(t->dbg_m_wdata >> 16), uint8_t((be >> 2) & 3)});
            }
            if (!t->dbg_m_we && (pa & 0x8000000)) {
                uint32_t off = pa & 0x7fffffc;
                if (off + 3 < s0.size() - 0x20000 && !is_prot(off)) {
                    uint32_t exp = s0[off] | s0[off + 1] << 8 | s0[off + 2] << 16 | uint32_t(s0[off + 3]) << 24;
                    if (exp == t->dbg_m_rdata) flash_rd_ok++;
                    else if (flash_rd_bad++ < 10) printf("FLASH(bus) READ MISMATCH off %07x got %08x expected %08x frame %d\n", off, t->dbg_m_rdata, exp, frame);
                }
            }
        }
        {
            static unsigned last_defer = 0;
            if (t->dbg_flip_defer != last_defer) {
                last_defer = t->dbg_flip_defer;
                uint32_t s = t->dbg_defer_state;
                printf("DEFER %u frame %d: flip_sync %u busy %u flip_cnt %u q_rear %03x q_front %03x\n", last_defer, frame,
                       s >> 31, (s >> 30) & 1, (s >> 22) & 3, (s >> 11) & 0x7ff, s & 0x7ff);
            }
        }
        if (fw && cyc % 1944 == 0) {   // one output sample per 1944 clk_sys (44.19 kHz)
            int16_t s2[2] = {(int16_t)t->audio_l, (int16_t)t->audio_r};
            fwrite(s2, 2, 2, fw);
            wav_samples++;
            if (s2[0] || s2[1]) wav_nonzero++;
        }
        if (t->dbg_illegal) { if (illegal++ < 4) printf("ILLEGAL opcode at pc %08x\n", t->dbg_pc); }
        if (t->ce_pix) {
            if (!t->hblank && !t->vblank) {
                if (x < 1024 && y < 512) img[y * 1024 + x] = (t->r << 16) | (t->g << 8) | t->b;
                x++;
            }
            if (t->hblank && !hb_q) { if (!t->vblank && x > 0) line_w = x; x = 0; if (!t->vblank) y++; }
            if (t->vblank && !vb_q) {
                // frame complete
                if ((snap_every && frame % snap_every == 0) || snap_at.count(frame)) {
                    char name[512];
                    snprintf(name, sizeof name, "%s/core_%05d.ppm", out.c_str(), frame);
                    FILE *f = fopen(name, "wb");
                    fprintf(f, "P6\n%d 240\n255\n", line_w);
                    for (int yy = 0; yy < 240; yy++) for (int xx = 0; xx < line_w; xx++) {
                        uint32_t p = img[yy * 1024 + xx];
                        uint8_t c[3] = {uint8_t(p >> 16), uint8_t(p >> 8), uint8_t(p)};
                        fwrite(c, 1, 3, f);
                    }
                    fclose(f);
                }
                frame++;
                y = 0;
                if (frame == dump_tex_frame) {   // texture RAM (SDRAM bank 1 = words 0x400000-0x7fffff), bytes LE
                    FILE *f = fopen(dump_tex_file.c_str(), "wb");
                    for (uint32_t w = 0x400000; w < 0x800000; w++) { uint16_t v = sd.mem[w]; fputc(v & 0xff, f); fputc(v >> 8, f); }
                    fclose(f);
                    printf("texture RAM dumped at frame %d\n", frame);
                }
                auto r = inputs.equal_range(frame);
                for (auto it = r.first; it != r.second; ++it) {
                    std::string w = it->second.substr(0, it->second.find(':'));
                    bool on = it->second.find(":on") != std::string::npos;
                    int bit = w == "coin1" ? 9 : w == "start1" ? 8 : w == "b1" ? 4 : w == "b2" ? 5 : w == "b3" ? 6 :
                              w == "up" ? 3 : w == "down" ? 2 : w == "left" ? 1 : w == "right" ? 0 : -1;
                    if (bit >= 0) t->joy0 = on ? (t->joy0 | (1u << bit)) : (t->joy0 & ~(1u << bit));
                }
                if (frame % 30 == 0 || frame - last_report >= 30) {
                    last_report = frame;
                    printf("frame %d cycle %llu retired %llu pc %08x underflows %u sdram_viol %llu flip_defer %u texq_max %u\n", frame,
                           (unsigned long long)cyc, (unsigned long long)retired, t->dbg_pc, t->dbg_underflows,
                           (unsigned long long)sd.violations, (unsigned)t->dbg_flip_defer, (unsigned)t->dbg_texq_max);
                    fflush(stdout);
                }
            }
            hb_q = t->hblank;
            vb_q = t->vblank;
        }
    }
    if (fw) {
        uint32_t rate = 44191, bytes = uint32_t(wav_samples * 4);
        auto w32 = [&](uint32_t v) { fwrite(&v, 4, 1, fw); };
        auto w16 = [&](uint16_t v) { fwrite(&v, 2, 1, fw); };
        fseek(fw, 0, SEEK_SET);
        fwrite("RIFF", 1, 4, fw); w32(36 + bytes); fwrite("WAVEfmt ", 1, 8, fw); w32(16); w16(1); w16(2); w32(rate);
        w32(rate * 4); w16(4); w16(16); fwrite("data", 1, 4, fw); w32(bytes);
        fclose(fw);
        printf("audio: %llu samples, %llu nonzero\n",(unsigned long long)wav_samples, (unsigned long long)wav_nonzero);
    }
    printf("bus monitors: flash reads %llu ok / %llu bad, texture writes %llu ok / %llu bad (%zu still queued)\n",
           (unsigned long long)flash_rd_ok, (unsigned long long)flash_rd_bad, (unsigned long long)tex_ok,
           (unsigned long long)tex_bad, tex_exp.size());
    {
        const char *rn[5] = {"flash", "work RAM", "texture", "frame", "BIOS/NVRAM"};
        printf("texture reads: %llu to a dword with a write still queued, %llu to others; busiest 4 KiB pages:", (unsigned long long)texrd_pend, (unsigned long long)texrd_free);
        { std::vector<std::pair<uint64_t, uint32_t>> v; for (auto &kv : texrd_hist) v.push_back({kv.second, kv.first});
          std::sort(v.rbegin(), v.rend()); for (size_t i = 0; i < v.size() && i < 6; i++) printf(" %05x000:%llu", v[i].second, (unsigned long long)v[i].first); }
        printf("\n");
        printf("texq hash study (reads blocked): 64B%%128 %llu, 64B%%1024 %llu, 16B%%1024 %llu, 64B fold7 %llu, 16B fold10 %llu, 64B exact %llu, 2KB line exact %llu\n",
               (unsigned long long)hash_hit[0], (unsigned long long)hash_hit[1], (unsigned long long)hash_hit[2], (unsigned long long)hash_hit[3],
               (unsigned long long)hash_hit[4], (unsigned long long)hash_hit[5], (unsigned long long)hash_hit[6]);
        printf("texq shadow study: of %llu blocked reads, a 1K-dword shadow serves %llu, a 4K-dword shadow %llu\n",
               (unsigned long long)hash_hit[5], (unsigned long long)sh_srv[0], (unsigned long long)sh_srv[1]);
        printf("texture read wait cycles: blocked by queued write %llu, queue writing %llu, D-cache busy %llu, other %llu\n",
               (unsigned long long)trw[0], (unsigned long long)trw[1], (unsigned long long)trw[2], (unsigned long long)trw[3]);
        printf("bus profile (accesses / wait cycles):");
        for (int r = 0; r < 5; r++) printf(" %s rd %llu/%llu wr %llu/%llu;", rn[r], (unsigned long long)bus_cnt[r][0],
                                            (unsigned long long)bus_wait[r][0], (unsigned long long)bus_cnt[r][1], (unsigned long long)bus_wait[r][1]);
        printf("\n");
    }
    printf("texture read data: %llu ok / %llu bad\n", (unsigned long long)texrd_ok, (unsigned long long)texrd_bad);
    bool ok = sd.violations == 0 && illegal == 0 && flash_rd_bad == 0 && tex_bad == 0 && texrd_bad == 0;
    {
        uint64_t tot = 0;
        for (int i = 0; i < 16; i++) tot += st_hist[i];
        printf("CPU state profile (cycles after download):");
        for (int i = 0; i < 16; i++) if (st_hist[i]) printf(" %s %.1f%%", st_names[i], 100.0 * st_hist[i] / tot);
        printf("\n");
    }
    printf("CORE SIM: %s frames=%d cycles=%llu retired=%llu (%.2f cycles/insn) pc=%08x underflows=%u sdram_violations=%llu ddr_reads=%llu\n",
           ok ? "PASS" : "FAIL", frame, (unsigned long long)cyc, (unsigned long long)retired,
           retired ? double(cyc) / retired : 0.0, t->dbg_pc, t->dbg_underflows, (unsigned long long)sd.violations,
           (unsigned long long)ddr.reads);
    delete t;
    return ok ? 0 : 1;
}
