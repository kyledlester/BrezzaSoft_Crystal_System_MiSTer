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
    bool turbo = false;
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
        else if (a == "--dsw") dsw = (int)strtol(nx().c_str(), nullptr, 16);
        else if (a == "--wav") wav = nx();
    }
    FILE *fw = wav.empty() ? nullptr : fopen(wav.c_str(), "wb");
    if (fw) { uint8_t h[44] = {}; fwrite(h, 1, 44, fw); }
    uint64_t wav_samples = 0, wav_nonzero = 0;
    auto s0 = read_file(stream_dir + "/index0.bin");
    auto s1 = read_file(stream_dir + "/index1.bin");

    Vcrystal_core *t = new Vcrystal_core;
    SdramModel sd;
    Ddr3 ddr;
    t->clk_sys = 0;
    t->pll_locked = 0;
    t->reset_request = 0;
    t->ioctl_download = 0;
    t->ioctl_wr = 0;
    t->joy0 = t->joy1 = t->joy2 = t->joy3 = 0;
    t->sw_test = 0;
    t->cpu_turbo = turbo;
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
                bool prot = (off >> 4) == (0x7bb0 >> 4) || (off >> 4) == (0x9760 >> 4) || (off >> 4) == (0x8090 >> 4) || (off >> 4) == (0x8a50 >> 4);
                if (!prot && bad++ < 4) printf("  flash store mismatch at %08x\n", off);
            }
        }
        printf("flash store check: %s\n", bad ? "FAIL" : "PASS (only the 8 protection words differ)");
    }

    // ---- run frames, capture video
    std::vector<uint32_t> img(1024 * 512, 0);
    int frame = 0, x = 0, y = 0;
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
            if (t->dbg_d_ack && !t->dbg_d_we && t->dbg_d_addr >= 0x05000004 && t->dbg_d_addr < 0x06000000 && bankreg < 3) {
                uint32_t off = bankreg * 0x1000000 + (t->dbg_d_addr & 0xfffffc);
                uint32_t exp = s0[off] | s0[off + 1] << 8 | s0[off + 2] << 16 | uint32_t(s0[off + 3]) << 24;
                for (int k = 0; k < 4; k++) if (!((t->dbg_d_be >> k) & 1)) exp &= ~(0xffu << (8 * k));
                uint32_t got = t->dbg_d_data;
                for (int k = 0; k < 4; k++) if (!((t->dbg_d_be >> k) & 1)) got &= ~(0xffu << (8 * k));
                bool prot = (off >> 4) == (0x7bb0 >> 4) || (off >> 4) == (0x9760 >> 4) || (off >> 4) == (0x8090 >> 4) || (off >> 4) == (0x8a50 >> 4);
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
            if (t->hblank && !hb_q) { x = 0; if (!t->vblank) y++; }
            if (t->vblank && !vb_q) {
                // frame complete
                if ((snap_every && frame % snap_every == 0) || snap_at.count(frame)) {
                    char name[512];
                    snprintf(name, sizeof name, "%s/core_%05d.ppm", out.c_str(), frame);
                    FILE *f = fopen(name, "wb");
                    fprintf(f, "P6\n320 240\n255\n");
                    for (int yy = 0; yy < 240; yy++) for (int xx = 0; xx < 320; xx++) {
                        uint32_t p = img[yy * 1024 + xx];
                        uint8_t c[3] = {uint8_t(p >> 16), uint8_t(p >> 8), uint8_t(p)};
                        fwrite(c, 1, 3, f);
                    }
                    fclose(f);
                }
                frame++;
                y = 0;
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
    bool ok = sd.violations == 0 && illegal == 0;
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
