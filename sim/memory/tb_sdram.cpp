// crystal_sdram stress test: 6 clients issue random read/write bursts (1-16 words) to private row ranges
// that share banks (bank conflicts, row misses, bank interleaving), plus a streaming client. Every read is
// checked against a per-client shadow; the chip model checks JEDEC timing. Reports PASS/FAIL, violations,
// throughput (words per cycle) and per-client average latency.
#include "Vcrystal_sdram.h"
#include "verilated.h"
#include "sdram_model.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>
#include <string>
#include <vector>

double sc_time_stamp() { return 0; }
static uint64_t rng = 0x123456789abcdefull;
static uint32_t rnd() { rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17; return uint32_t(rng); }

constexpr int NC = 6;

struct Client {
    bool busy = false, we = false;
    uint32_t addr = 0;       // word address [24:1] -> bits 23:0
    int len = 0, idx = 0, got = 0;
    std::vector<uint16_t> wdata, exp;
    std::vector<uint8_t> wbe;
    std::map<uint32_t, uint16_t> shadow;
    uint64_t done = 0, words = 0, lat_sum = 0, started = 0;
    int row_base = 0, bank = 0;
};

int main(int argc, char **argv)
{
    uint64_t cycles_max = 2000000;
    int stream = 1;
    for (int i = 1; i < argc; i++) {
        std::string a = argv[i];
        if (a == "--cycles") cycles_max = strtoull(argv[++i], nullptr, 0);
        if (a == "--seed") rng ^= strtoull(argv[++i], nullptr, 0) * 0x9E3779B97F4A7C15ull;
    }
    Vcrystal_sdram *t = new Vcrystal_sdram;
    SdramModel chip;
    Client cl[NC];
    for (int c = 0; c < NC; c++) { cl[c].bank = c & 3; cl[c].row_base = c * 1000; }
    t->init = 1;
    t->clk = 0;
    for (int i = 0; i < 4; i++) { t->clk = 1; t->eval(); t->clk = 0; t->eval(); }
    t->init = 0;
    bool fail = false;
    uint64_t cyc = 0, words_total = 0, ready_at = 0;
    while (cyc < cycles_max && !fail) {
        // drive clients
        if (t->ready && !ready_at) ready_at = cyc;
        for (int c = 0; c < NC; c++) {
            Client &k = cl[c];
            if (!k.busy && t->ready && (rnd() % 4 == 0 || (c == 0 && stream))) {
                k.busy = true;
                k.we = (c == 0) ? false : (rnd() & 1);
                k.len = 1 + rnd() % 16;
                uint32_t row = k.row_base + rnd() % (c == 0 ? 4 : 50);
                uint32_t col = rnd() % (512 - k.len);
                k.addr = (uint32_t(k.bank) << 22) | (row << 9) | col;
                k.idx = 0; k.got = 0;
                k.wdata.resize(k.len); k.wbe.resize(k.len); k.exp.resize(k.len);
                for (int w = 0; w < k.len; w++) {
                    k.wdata[w] = uint16_t(rnd()); k.wbe[w] = uint8_t(1 + rnd() % 3);
                    auto it = k.shadow.find(k.addr + w);
                    k.exp[w] = it == k.shadow.end() ? 0 : it->second;
                }
                k.started = cyc;
            }
            t->c_req = (t->c_req & ~(1u << c)) | (uint32_t(k.busy) << c);
            t->c_we = (t->c_we & ~(1u << c)) | (uint32_t(k.we) << c);
            t->c_addr[c * 24 / 32] = 0;  // filled below
        }
        // pack wide ports (c_addr 6x24 = 144 bits, c_wdata 96 bits)
        {
            uint32_t aw[5] = {}, dw[3] = {};
            uint64_t lw = 0, bw = 0;
            for (int c = 0; c < NC; c++) {
                uint64_t a = cl[c].addr + uint64_t(cl[c].idx);
                for (int b = 0; b < 24; b++) if ((a >> b) & 1) aw[(c * 24 + b) / 32] |= 1u << ((c * 24 + b) % 32);
                uint16_t d = cl[c].idx < cl[c].len ? cl[c].wdata[cl[c].idx] : 0;
                for (int b = 0; b < 16; b++) if ((d >> b) & 1) dw[(c * 16 + b) / 32] |= 1u << ((c * 16 + b) % 32);
                lw |= uint64_t(cl[c].len & 63) << (6 * c);
                bw |= uint64_t(cl[c].idx < cl[c].len ? cl[c].wbe[cl[c].idx] : 0) << (2 * c);
            }
            // the controller samples c_addr only at accept (idx == 0), so the current-word address is fine
            for (int i = 0; i < 5; i++) t->c_addr[i] = aw[i];
            for (int i = 0; i < 3; i++) t->c_wdata[i] = dw[i];
            t->c_len = lw;
            t->c_wbe = uint16_t(bw);
        }
        t->dq_i = chip.dq_i;
        // write-advance is combinational: sample before the edge
        uint32_t wnext = t->c_wnext;
        t->clk = 1;
        t->eval();
        for (int c = 0; c < NC; c++) if (wnext & (1u << c)) {
            Client &k = cl[c];
            uint32_t a = k.addr + k.idx;
            uint16_t old = k.shadow.count(a) ? k.shadow[a] : 0, d = k.wdata[k.idx];
            if (!(k.wbe[k.idx] & 1)) d = (d & 0xff00) | (old & 0x00ff);
            if (!(k.wbe[k.idx] & 2)) d = (d & 0x00ff) | (old & 0xff00);
            k.shadow[a] = d;
            k.idx++;
            words_total++;
        }
        chip.step(t->sd_nras, t->sd_ncas, t->sd_nwe, t->sd_ba, t->sd_a, t->dq_o, t->dq_oe);
        for (int c = 0; c < NC; c++) {
            Client &k = cl[c];
            if (t->c_rvalid & (1u << c)) {
                if (k.we || k.got >= k.len) { printf("FAIL: unexpected read data for client %d\n", c); fail = true; }
                else if (t->rdata != k.exp[k.got]) {
                    printf("FAIL: client %d word %d addr %06x read %04x expected %04x (cycle %llu)\n", c, k.got, k.addr + k.got, t->rdata, k.exp[k.got], (unsigned long long)cyc);
                    fail = true;
                }
                k.got++;
                words_total++;
            }
            if (t->c_done & (1u << c)) {
                if (k.we ? k.idx != k.len : k.got != k.len) { printf("FAIL: client %d done early\n", c); fail = true; }
                k.busy = false; k.done++; k.words += k.len; k.lat_sum += cyc - k.started;
                k.idx = 0;
            }
        }
        t->clk = 0;
        t->eval();
        cyc++;
    }
    if (chip.violations) fail = true;
    if (chip.max_ref_gap > 700) { printf("FAIL: refresh gap %lld cycles\n", (long long)chip.max_ref_gap); fail = true; }
    uint64_t busy = cyc - ready_at;
    printf("SDRAM STRESS: %s cycles=%llu words=%llu (%.3f words/cycle) reads=%llu writes=%llu acts=%llu pres=%llu refs=%llu max_ref_gap=%lld violations=%llu\n",
           fail ? "FAIL" : "PASS", (unsigned long long)cyc, (unsigned long long)words_total, busy ? double(words_total) / busy : 0.0,
           (unsigned long long)chip.reads, (unsigned long long)chip.writes, (unsigned long long)chip.acts, (unsigned long long)chip.pres,
           (unsigned long long)chip.refs, (long long)chip.max_ref_gap, (unsigned long long)chip.violations);
    for (int c = 0; c < NC; c++)
        printf("  client %d: requests %llu words %llu avg latency %.1f cycles\n", c, (unsigned long long)cl[c].done,
               (unsigned long long)cl[c].words, cl[c].done ? double(cl[c].lat_sum) / cl[c].done : 0.0);
    delete t;
    return fail ? 1 : 0;
}
