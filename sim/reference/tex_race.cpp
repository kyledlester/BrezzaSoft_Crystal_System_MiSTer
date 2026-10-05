// Analysis: does the game rewrite texture-RAM lines that the display list it has just submitted reads?
// (MAME renders each packet ~immediately; the RTL renderer may still be drawing that list when the CPU moves on.)
//   tex_race --frames N [--input F:what:on|off ...]   (ROMs from C:/Users/klest/Crystal_research/roms)
#include "crystal_ref.h"
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <map>
#include <string>
#include <vector>

static std::vector<uint8_t> rd(const std::string &p)
{
    std::ifstream f(p, std::ios::binary);
    if (!f) { fprintf(stderr, "cannot read %s\n", p.c_str()); exit(2); }
    return std::vector<uint8_t>((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
}

int main(int argc, char **argv)
{
    std::string rom = "C:/Users/klest/Crystal_research/roms";
    int frames = 600;
    std::multimap<int, std::string> inputs;
    for (int i = 1; i < argc; i++) {
        std::string a = argv[i];
        if (a == "--frames") frames = atoi(argv[++i]);
        else if (a == "--input") { std::string v = argv[++i]; inputs.emplace(atoi(v.c_str()), v.substr(v.find(':') + 1)); }
    }
    crystal::Board b;
    b.load_bios(rd(rom + "/mx27l1000.u14"));
    std::vector<uint8_t> fl;
    for (auto n : {"bcsv0004f01.u1", "bcsv0004f02.u2", "bcsv0004f03.u3"}) { auto v = rd(rom + "/" + n); fl.insert(fl.end(), v.begin(), v.end()); }
    b.load_flash(fl);
    b.reset();

    // list id: incremented when a flip packet is processed (each display list ends with one)
    int list_id = 0;
    std::vector<int> line_list(0x800000 / 32, -10);   // last list that read each 32-byte texture line
    b.hooks.packet = [&](uint32_t, const uint16_t *pk) { if (pk[0] & 0x81) list_id++; };
    b.hooks.tex_read = [&](uint32_t a) { line_list[(a & 0x7fffff) >> 5] = list_id; };
    std::map<int, uint64_t> hits, writes;       // per frame
    b.hooks.ram_write = [&](uint32_t addr, int size, uint32_t) {
        if (addr < 0x03800000 || addr >= 0x04000000) return;
        uint32_t l = (addr & 0x7fffff) >> 5;
        writes[b.frame]++;
        // the list submitted last (list_id - 1, its flip already processed) or the one being built read this line
        if (line_list[l] >= list_id - 1) hits[b.frame]++;
    };
    int last = -1;
    while (b.frame < frames) {
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
        }
        b.step_insn();
    }
    uint64_t th = 0, tw = 0; int fr_hit = 0;
    for (auto &kv : writes) tw += kv.second;
    for (auto &kv : hits) { th += kv.second; if (kv.second) fr_hit++; }
    printf("texture writes %llu, to lines read by the last submitted list %llu, in %d frames\n",
           (unsigned long long)tw, (unsigned long long)th, fr_hit);
    int shown = 0;
    int from = getenv("FROM") ? atoi(getenv("FROM")) : 0;
    for (auto &kv : hits) if (kv.second && kv.first >= from && shown++ < 40) printf("  frame %d: %llu of %llu writes\n", kv.first,
        (unsigned long long)kv.second, (unsigned long long)writes[kv.first]);
    return 0;
}
