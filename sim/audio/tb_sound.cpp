// Audio differential test: rtl/vrender0/vr0_sound_regs.sv + vr0_sound.sv vs the reference model's sound engine.
//
//   tb_sound [--rom DIR] [--frames N] [--input F:what:on|off] [--wav FILE]
//
// The reference model runs the game. Its writes to the sound registers are replayed into the RTL register file
// as they happen, its RAM writes are mirrored into the RTL sample memory, and every time the reference renders
// an output sample the RTL engine renders one too (external tick). Left/right samples and the Status register
// are compared sample by sample; the first mismatch is reported with the channel registers.
#include "Vvr0_sound_top.h"
#include "verilated.h"
#include "../reference/crystal_ref.h"
#include <cstdio>
#include <cstdlib>
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

int main(int argc, char **argv)
{
    std::string rom = "C:/Users/klest/Crystal_research/roms", wav;
    int frames = 6000;
    std::multimap<int, std::string> inputs;
    for (int i = 1; i < argc; i++) {
        std::string a = argv[i];
        if (a == "--rom") rom = argv[++i];
        else if (a == "--frames") frames = atoi(argv[++i]);
        else if (a == "--wav") wav = argv[++i];
        else if (a == "--input") { std::string v = argv[++i]; inputs.emplace(atoi(v.c_str()), v.substr(v.find(':') + 1)); }
    }
    crystal::Board b;
    b.load_bios(read_file(rom + "/mx27l1000.u14"));
    std::vector<uint8_t> fl;
    for (auto n : {"bcsv0004f01.u1", "bcsv0004f02.u2", "bcsv0004f03.u3"}) { auto v = read_file(rom + "/" + n); fl.insert(fl.end(), v.begin(), v.end()); }
    b.load_flash(fl);
    b.reset();

    std::vector<uint16_t> sd(16u << 20, 0);   // SDRAM word image (texture 0x400000, frame 0x800000)
    Vvr0_sound_top *t = new Vvr0_sound_top;
    uint64_t cyc = 0;
    int m_wait = -1;
    auto tick = [&]() {
        t->m_rvalid = 0; t->m_done = 0;
        if (t->m_req) {
            if (m_wait < 0) m_wait = 3;
            if (m_wait == 0) { t->m_rvalid = 1; t->m_done = 1; t->m_rdata = sd[t->m_addr & 0xffffff]; m_wait = -2; }
            else if (m_wait > 0) m_wait--;
        } else m_wait = -1;
        t->clk = 1; t->eval(); t->clk = 0; t->eval(); cyc++;
    };
    t->rst_n = 0; t->io_sel = 0; t->tick = 0;
    for (int i = 0; i < 4; i++) tick();
    t->rst_n = 1;

    b.hooks.ram_write = [&](uint32_t addr, int size, uint32_t data) {
        for (int i = 0; i < size; i++) {
            uint32_t a = addr + i, w;
            if (a >= 0x03800000 && a < 0x04000000) w = 0x400000 + ((a & 0x7fffff) >> 1);
            else if (a >= 0x04000000 && a < 0x04800000) w = 0x800000 + ((a & 0x7fffff) >> 1);
            else continue;
            uint8_t v = uint8_t(data >> (8 * i));
            sd[w] = (a & 1) ? uint16_t((sd[w] & 0x00ff) | (v << 8)) : uint16_t((sd[w] & 0xff00) | v);
        }
    };
    // the renderer writes frame RAM without going through write(): mirror it at every packet boundary is too
    // costly, so samples are assumed not to live in drawn areas (crysking keeps them in frame RAM above 0x200000)
    uint64_t reg_writes = 0;
    b.hooks.io_access = [&](uint32_t addr, int size, uint32_t data, bool wr) {
        if (!wr || addr < 0x04800000 || addr >= 0x04801000) return;
        uint32_t sh = (addr & 3) * 8;
        uint32_t m = size == 4 ? 0xf : size == 2 ? (0x3u << (addr & 3)) : (0x1u << (addr & 3));
        t->io_sel = 1; t->io_we = 1; t->io_addr = (addr & 0xfff) >> 2; t->io_be = m; t->io_wdata = data << sh;
        tick();
        t->io_sel = 0; t->io_we = 0;
        tick(); tick();
        reg_writes++;
    };
    uint64_t samples = 0, nonzero = 0, fails = 0;
    FILE *fw = wav.empty() ? nullptr : fopen(wav.c_str(), "wb");
    if (fw) { uint8_t h[44] = {}; fwrite(h, 1, 44, fw); }
    b.hooks.sample = [&](int16_t l, int16_t r) {
        if (fails) return;
        t->tick = 1; tick(); t->tick = 0;
        int guard = 0;
        while (!t->out_strobe) { tick(); if (++guard > 5000) { printf("RTL sound engine hung\n"); exit(1); } }
        samples++;
        if (l || r) nonzero++;
        if (fw) { int16_t s2[2] = {t->out_l, t->out_r}; fwrite(s2, 2, 2, fw); }
        if ((int16_t)t->out_l != l || (int16_t)t->out_r != r || t->status != b.snd_status) {
            fails++;
            printf("MISMATCH sample %llu (frame %d): ref %d %d status %08x | rtl %d %d status %08x\n", (unsigned long long)samples,
                   b.frame, l, r, b.snd_status, (int16_t)t->out_l, (int16_t)t->out_r, t->status);
            for (int c = 0; c <= b.snd_max_chan; c++)
                if (b.snd_status & (1u << c) || ((b.snd_status ^ t->status) & (1u << c)))
                    printf("  ch%d cur %08x ds %04x modes %02x lb %06x le %06x vol %d/%d env %08x\n", c, b.ch[c].cur_saddr,
                           b.ch[c].ds_addr, b.ch[c].modes, b.ch[c].loop_begin, b.ch[c].loop_end, b.ch[c].l_chn_vol,
                           b.ch[c].r_chn_vol, b.ch[c].env_vol);
        }
    };
    int last = -1;
    while (b.frame < frames && !fails) {
        if (b.frame != last) {
            last = b.frame;
            auto rr = inputs.equal_range(b.frame);
            for (auto it = rr.first; it != rr.second; ++it) {
                std::string w = it->second.substr(0, it->second.find(':'));
                bool on = it->second.find(":on") != std::string::npos;
                auto setbit = [&](uint8_t &reg, int bit) { if (on) reg &= ~(1 << bit); else reg |= (1 << bit); };
                if (w == "coin1") { if (on) b.coin_insert(0); setbit(b.in.system, 4); }
                else if (w == "start1") setbit(b.in.system, 0);
                else if (w == "b1") { if (on) b.in.p1p2 &= ~1u; else b.in.p1p2 |= 1u; }
            }
            if (b.frame % 600 == 0) { printf("frame %d samples %llu nonzero %llu reg writes %llu\n", b.frame, (unsigned long long)samples, (unsigned long long)nonzero, (unsigned long long)reg_writes); fflush(stdout); }
        }
        b.step_insn();
    }
    if (fw) {
        uint32_t rate = 44191, bytes = uint32_t(samples * 4);
        auto w32 = [&](uint32_t v) { fwrite(&v, 4, 1, fw); };
        auto w16 = [&](uint16_t v) { fwrite(&v, 2, 1, fw); };
        fseek(fw, 0, SEEK_SET);
        fwrite("RIFF", 1, 4, fw); w32(36 + bytes); fwrite("WAVEfmt ", 1, 8, fw); w32(16); w16(1); w16(2); w32(rate);
        w32(rate * 4); w16(4); w16(16); fwrite("data", 1, 4, fw); w32(bytes);
        fclose(fw);
    }
    printf("AUDIO DIFFTEST: %s frames=%d samples=%llu nonzero=%llu reg_writes=%llu\n", fails ? "FAIL" : "PASS", b.frame,
           (unsigned long long)samples, (unsigned long long)nonzero, (unsigned long long)reg_writes);
    delete t;
    return fails ? 1 : 0;
}
