// Command-line driver for the Crystal System reference model (research / golden data generation).
//
//   crystal_sim --bios BIOS --flash U1 [U2 U3] [options]
//     --frames N            run N frames (vblanks), default 600
//     --snap-every N        write display buffer PPM every N frames into --out
//     --snap-at F[,F...]    write display buffer PPM at specific frames
//     --out DIR             output directory (default .)
//     --pc-hist             print the top PC hotspots at the end
//     --trace FROM:COUNT    instruction trace (PC, opcode, regs) of COUNT insns starting at insn FROM
//     --io-log FILE         log non-RAM bus accesses (addr size data r/w @insn,frame)
//     --packets FILE        log every processed display-list packet (32 words)
//     --dma-log FILE        log DMA starts
//     --wav FILE            write stereo 16-bit audio
//     --input F:what:on/off  input event at frame F (what = coin1,coin2,start1,start2,test,service,
//                           up,down,left,right,b1,b2,b3,b4 for P1)
//     --pic289              PIO bit 29 as MAME 0.289 (no PIC device)
//     --dump-ram FRAME:FILE dump work RAM at frame
//     --stop-pc ADDR        stop when PC hits ADDR (prints state)
#include "crystal_ref.h"
#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <map>
#include <set>
#include <sstream>
#include <string>
#include <vector>

using namespace crystal;

static std::vector<uint8_t> read_file(const std::string &p)
{
    std::ifstream f(p, std::ios::binary);
    if (!f) { fprintf(stderr, "cannot read %s\n", p.c_str()); exit(2); }
    return std::vector<uint8_t>((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
}

static void write_ppm(const std::string &path, Board &b)
{
    uint32_t w = b.scr_hdisp, h = b.scr_vdisp;
    FILE *f = fopen(path.c_str(), "wb");
    if (!f) return;
    fprintf(f, "P6\n%u %u\n255\n", w, h);
    for (uint32_t y = 0; y < h; y++)
        for (uint32_t x = 0; x < w; x++) {
            uint32_t a = b.display_dest + (((x & 0x3ff) | ((y & 0x1ff) << 10)) << 1);
            uint16_t p = b.fb16(a);
            uint8_t rgb[3] = {uint8_t(((p >> 11) & 0x1f) << 3 | ((p >> 13) & 7)), uint8_t(((p >> 5) & 0x3f) << 2 | ((p >> 9) & 3)),
                              uint8_t((p & 0x1f) << 3 | ((p >> 2) & 7))};
            fwrite(rgb, 1, 3, f);
        }
    fclose(f);
}

struct WavOut {
    FILE *f = nullptr;
    uint32_t n = 0;
    void open(const std::string &p) {
        f = fopen(p.c_str(), "wb");
        uint8_t hdr[44] = {};
        fwrite(hdr, 1, 44, f);
    }
    void put(int16_t l, int16_t r) { if (f) { fwrite(&l, 2, 1, f); fwrite(&r, 2, 1, f); n++; } }
    void close() {
        if (!f) return;
        uint32_t rate = 44191, bytes = n * 4;
        auto w32 = [&](uint32_t v) { fwrite(&v, 4, 1, f); };
        auto w16 = [&](uint16_t v) { fwrite(&v, 2, 1, f); };
        fseek(f, 0, SEEK_SET);
        fwrite("RIFF", 1, 4, f); w32(36 + bytes); fwrite("WAVEfmt ", 1, 8, f); w32(16); w16(1); w16(2); w32(rate);
        w32(rate * 4); w16(4); w16(16); fwrite("data", 1, 4, f); w32(bytes);
        fclose(f);
    }
};

int main(int argc, char **argv)
{
    std::string bios_path, out = ".", trace_spec, io_log, pkt_log, dma_log, wav_path;
    std::vector<std::string> flash_paths;
    int frames = 600, snap_every = 0;
    std::set<int> snap_at;
    bool pc_hist = false, pic289 = false;
    std::multimap<int, std::string> input_events;
    std::map<int, std::string> dump_ram;
    long long stop_pc = -1;
    for (int i = 1; i < argc; i++) {
        std::string a = argv[i];
        auto next = [&]() { if (i + 1 >= argc) { fprintf(stderr, "missing value for %s\n", a.c_str()); exit(2); } return std::string(argv[++i]); };
        if (a == "--bios") bios_path = next();
        else if (a == "--flash") { while (i + 1 < argc && argv[i + 1][0] != '-') flash_paths.push_back(argv[++i]); }
        else if (a == "--frames") frames = atoi(next().c_str());
        else if (a == "--snap-every") snap_every = atoi(next().c_str());
        else if (a == "--snap-at") { std::stringstream ss(next()); std::string t; while (std::getline(ss, t, ',')) snap_at.insert(atoi(t.c_str())); }
        else if (a == "--out") out = next();
        else if (a == "--pc-hist") pc_hist = true;
        else if (a == "--trace") trace_spec = next();
        else if (a == "--io-log") io_log = next();
        else if (a == "--packets") pkt_log = next();
        else if (a == "--dma-log") dma_log = next();
        else if (a == "--wav") wav_path = next();
        else if (a == "--pic289") pic289 = true;
        else if (a == "--input") { std::string v = next(); input_events.emplace(atoi(v.c_str()), v.substr(v.find(':') + 1)); }
        else if (a == "--dump-ram") { std::string v = next(); dump_ram[atoi(v.c_str())] = v.substr(v.find(':') + 1); }
        else if (a == "--stop-pc") stop_pc = strtoll(next().c_str(), nullptr, 0);
        else { fprintf(stderr, "unknown option %s\n", a.c_str()); return 2; }
    }
    Board b;
    b.cfg.pic_master = !pic289;
    if (!b.load_bios(read_file(bios_path))) { fprintf(stderr, "bad bios\n"); return 2; }
    std::vector<uint8_t> flash;
    for (auto &p : flash_paths) { auto v = read_file(p); flash.insert(flash.end(), v.begin(), v.end()); }
    b.load_flash(flash);
    b.reset();

    FILE *fio = io_log.empty() ? nullptr : fopen(io_log.c_str(), "w");
    FILE *fpk = pkt_log.empty() ? nullptr : fopen(pkt_log.c_str(), "w");
    FILE *fdm = dma_log.empty() ? nullptr : fopen(dma_log.c_str(), "w");
    WavOut wav;
    if (!wav_path.empty()) wav.open(wav_path);
    if (fio) b.hooks.io_access = [&](uint32_t addr, int size, uint32_t data, bool wr) {
        fprintf(fio, "%c %08x %d %08x pc=%08x i=%llu f=%d\n", wr ? 'W' : 'R', addr, size, data, b.cpu.s.PPC,
                (unsigned long long)b.cpu.insn_count, b.frame);
    };
    if (fpk) b.hooks.packet = [&](uint32_t ptr, const uint16_t *p) {
        fprintf(fpk, "f=%d q=%04x", b.frame, ptr / 32);
        for (int i = 0; i < 32; i++) fprintf(fpk, " %04x", p[i]);
        fprintf(fpk, "\n");
    };
    if (fdm) b.hooks.dma_start = [&](int w, uint32_t s, uint32_t d, uint32_t c, uint32_t ctrl) {
        fprintf(fdm, "f=%d dma%d src=%08x dst=%08x cnt=%06x ctrl=%03x pc=%08x\n", b.frame, w, s, d, c, ctrl, b.cpu.s.PPC);
    };
    if (wav.f) b.hooks.sample = [&](int16_t l, int16_t r) { wav.put(l, r); };

    uint64_t trace_from = 0, trace_count = 0;
    if (!trace_spec.empty()) { trace_from = strtoull(trace_spec.c_str(), nullptr, 0); trace_count = strtoull(trace_spec.substr(trace_spec.find(':') + 1).c_str(), nullptr, 0); }

    std::map<uint32_t, uint64_t> hist;
    std::map<uint16_t, uint64_t> invalid_ops;
    b.cpu.on_invalid = [&](uint32_t pc, uint16_t op) {
        if (invalid_ops[op]++ < 4) fprintf(stderr, "INVALID opcode %04x at %08x (insn %llu frame %d)\n", op, pc, (unsigned long long)b.cpu.insn_count, b.frame);
    };
    int last_frame = -1;
    auto apply_input = [&](const std::string &e) {
        std::string what = e.substr(0, e.find(':'));
        bool on = e.find(":on") != std::string::npos;
        auto setbit = [&](uint8_t &r, int bit) { if (on) r &= ~(1 << bit); else r |= (1 << bit); };
        auto setbit32 = [&](uint32_t &r, int bit) { if (on) r &= ~(1u << bit); else r |= (1u << bit); };
        if (what == "coin1") { if (on && (b.in.system & 0x10)) b.coin_insert(0); setbit(b.in.system, 4); }
        else if (what == "coin2") { if (on && (b.in.system & 0x20)) b.coin_insert(1); setbit(b.in.system, 5); }
        else if (what == "start1") setbit(b.in.system, 0);
        else if (what == "start2") setbit(b.in.system, 1);
        else if (what == "service") setbit(b.in.system, 6);
        else if (what == "test") setbit(b.in.system, 7);
        else if (what == "b1") setbit32(b.in.p1p2, 0);
        else if (what == "b2") setbit32(b.in.p1p2, 2);
        else if (what == "b3") setbit32(b.in.p1p2, 4);
        else if (what == "b4") setbit32(b.in.p1p2, 6);
        else if (what == "up") setbit32(b.in.p1p2, 16);
        else if (what == "down") setbit32(b.in.p1p2, 18);
        else if (what == "left") setbit32(b.in.p1p2, 20);
        else if (what == "right") setbit32(b.in.p1p2, 22);
        else fprintf(stderr, "unknown input %s\n", what.c_str());
    };
    while (b.frame < frames) {
        if (b.frame != last_frame) {
            last_frame = b.frame;
            auto r = input_events.equal_range(b.frame);
            for (auto it = r.first; it != r.second; ++it) apply_input(it->second);
            if ((snap_every && b.frame % snap_every == 0) || snap_at.count(b.frame)) {
                char name[512];
                snprintf(name, sizeof name, "%s/frame_%05d.ppm", out.c_str(), b.frame);
                write_ppm(name, b);
            }
            auto d = dump_ram.find(b.frame);
            if (d != dump_ram.end()) {
                FILE *f = fopen(d->second.c_str(), "wb");
                fwrite(b.workram.data(), 1, b.workram.size(), f);
                fclose(f);
            }
        }
        uint64_t n = b.cpu.insn_count;
        if (trace_count && n >= trace_from && n < trace_from + trace_count) {
            auto &s = b.cpu.s;
            printf("%llu %08x %04x SR=%04x SP=%08x ER=%08x R=%08x %08x %08x %08x %08x %08x %08x %08x\n",
                   (unsigned long long)n, s.PC, b.fetch(s.PC), s.SR, s.SP, s.ER, s.R[0], s.R[1], s.R[2], s.R[3], s.R[4],
                   s.R[5], s.R[6], s.R[7]);
        }
        if (stop_pc >= 0 && b.cpu.s.PC == uint32_t(stop_pc)) {
            auto &s = b.cpu.s;
            printf("STOP at PC=%08x insn=%llu frame=%d SP=%08x R0=%08x R1=%08x R2=%08x R3=%08x\n", s.PC,
                   (unsigned long long)n, b.frame, s.SP, s.R[0], s.R[1], s.R[2], s.R[3]);
            break;
        }
        if (pc_hist) hist[b.cpu.s.PC]++;
        b.step_insn();
    }
    if (fio) fclose(fio);
    if (fpk) fclose(fpk);
    if (fdm) fclose(fdm);
    wav.close();

    printf("frames=%d insns=%llu ticks=%llu PC=%08x SR=%04x SP=%08x packets=%llu pixels=%llu invalid=%llu unmapped r/w=%llu/%llu uart_tx=%llu\n",
           b.frame, (unsigned long long)b.cpu.insn_count, (unsigned long long)b.now, b.cpu.s.PC, b.cpu.s.SR, b.cpu.s.SP,
           (unsigned long long)b.packets_done, (unsigned long long)b.pixels_drawn, (unsigned long long)b.cpu.invalid_count,
           (unsigned long long)b.unmapped_reads, (unsigned long long)b.unmapped_writes, (unsigned long long)b.uart_tx_count);
    for (auto &l : b.log) printf("log: %s\n", l.c_str());
    if (pc_hist) {
        std::vector<std::pair<uint64_t, uint32_t>> v;
        for (auto &h : hist) v.push_back({h.second, h.first});
        std::sort(v.rbegin(), v.rend());
        for (size_t i = 0; i < v.size() && i < 40; i++) printf("  pc %08x  %llu\n", v[i].second, (unsigned long long)v[i].first);
    }
    return 0;
}
