// Behavioural x16 SDR SDRAM (8192 rows x 512 columns x 4 banks = 32 MiB) for Verilator benches.
//
// Call step() once per clk_sys cycle *after* the rising edge has been evaluated, with the controller's
// registered pin outputs. Pin timing as crystal_sdram.sv documents: the chip sees the command half a clock
// later (SDRAM_CLK = !clk); READ data of a command registered on edge e must be on dq_i before edge e+3.
// Every JEDEC timing rule the controller relies on is checked; violations are counted and the first ones are
// printed with the cycle number.
#pragma once
#include <cstdint>
#include <cstdio>
#include <vector>

struct SdramModel {
    std::vector<uint16_t> mem;
    bool open[4] = {};
    uint32_t row[4] = {};
    int64_t t_act[4], t_pre[4], t_wr[4], t_rd[4];
    int64_t t_act_any = -100, t_ref = -100, t_rd_any = -100, last_ref = 0, t_mrs = -100;
    int64_t cyc = 0;
    bool mode_set = false;
    uint64_t violations = 0, reads = 0, writes = 0, acts = 0, pres = 0, refs = 0;
    int64_t max_ref_gap = 0;
    // read pipeline: data to present on dq_i in a given cycle
    struct Pend { int64_t when; uint16_t data; };
    std::vector<Pend> pend;
    uint16_t dq_i = 0;
    bool dq_drive = false;    // chip drives the bus this cycle

    SdramModel() : mem(16u << 20, 0) {
        for (int b = 0; b < 4; b++) { t_act[b] = -100; t_pre[b] = -100; t_wr[b] = -100; t_rd[b] = -100; }
    }
    void viol(const char *what, int b = -1) {
        if (violations++ < 20) printf("SDRAM VIOLATION cycle %lld: %s (bank %d)\n", (long long)cyc, what, b);
    }
    // ncs, nras, ncas, nwe, ba, a, dqm (= {A12,A11}), dq_o, dq_oe as registered on this edge
    void step(int nras, int ncas, int nwe, int ba, uint32_t a, uint16_t dq_o, bool dq_oe) {
        int cmd = (nras << 2) | (ncas << 1) | nwe;
        if (cyc < 2) cmd = 0b111;   // ignore power-up register contents
        uint32_t dqm = (a >> 11) & 3;
        switch (cmd) {
        case 0b011:  // ACT
            if (open[ba]) viol("ACT to open bank", ba);
            if (cyc - t_pre[ba] < 2) viol("tRP", ba);
            if (cyc - t_act_any < 2) viol("tRRD", ba);
            if (cyc - t_act[ba] < 6) viol("tRC", ba);
            if (cyc - t_ref < 7) viol("tRFC (ACT)", ba);
            open[ba] = true; row[ba] = a & 0x1fff; t_act[ba] = cyc; t_act_any = cyc; acts++;
            break;
        case 0b010:  // PRE
            for (int b = 0; b < 4; b++) {
                if (!((a & 0x400) || b == ba)) continue;
                if (!open[b]) continue;
                if (cyc - t_act[b] < 4) viol("tRAS", b);
                if (cyc - t_wr[b] < 2) viol("tWR", b);
                if (cyc - t_rd[b] < 1) viol("READ->PRE", b);
                open[b] = false; t_pre[b] = cyc;
            }
            pres++;
            break;
        case 0b101: {  // READ
            if (!open[ba]) { viol("READ to closed bank", ba); break; }
            if (cyc - t_act[ba] < 2) viol("tRCD (READ)", ba);
            if (a & 0x400) viol("auto precharge not expected", ba);
            if (dqm) viol("DQM set on READ", ba);
            uint32_t w = (uint32_t(ba) << 22) | (row[ba] << 9) | (a & 0x1ff);
            pend.push_back({cyc + 2, mem[w]});   // on dq_i before edge cyc+3
            t_rd[ba] = cyc; t_rd_any = cyc; reads++;
            break;
        }
        case 0b100: {  // WRITE
            if (!open[ba]) { viol("WRITE to closed bank", ba); break; }
            if (cyc - t_act[ba] < 2) viol("tRCD (WRITE)", ba);
            if (!dq_oe) viol("WRITE without driving DQ", ba);
            if (cyc - t_rd_any < 4) viol("read->write bus turnaround", ba);
            uint32_t w = (uint32_t(ba) << 22) | (row[ba] << 9) | (a & 0x1ff);
            uint16_t v = mem[w];
            if (!(dqm & 1)) v = (v & 0xff00) | (dq_o & 0x00ff);
            if (!(dqm & 2)) v = (v & 0x00ff) | (dq_o & 0xff00);
            mem[w] = v;
            t_wr[ba] = cyc; writes++;
            break;
        }
        case 0b001:  // REF
            for (int b = 0; b < 4; b++) if (open[b]) viol("REF with an open bank", b);
            if (cyc - t_ref < 7) viol("tRFC (REF)");
            if (mode_set) { if (cyc - last_ref > max_ref_gap) max_ref_gap = cyc - last_ref; }
            last_ref = cyc; t_ref = cyc; refs++;
            break;
        case 0b000:  // MRS
            if ((a & 0x3ff) != 0x020) viol("unexpected mode register value");
            mode_set = true; t_mrs = cyc;
            break;
        default: break;
        }
        if (dq_oe && dq_drive) viol("bus contention (chip and FPGA drive DQ)");
        // present read data
        dq_drive = false;
        for (size_t i = 0; i < pend.size();) {
            if (pend[i].when == cyc) { dq_i = pend[i].data; dq_drive = true; pend.erase(pend.begin() + i); }
            else if (pend[i].when < cyc) pend.erase(pend.begin() + i);
            else i++;
        }
        cyc++;
    }
};
