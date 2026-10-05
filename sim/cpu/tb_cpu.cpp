// SE3208 differential test: RTL (rtl/cpu/se3208/se3208_cpu.sv, Verilator) vs the reference interpreter
// (sim/reference/se3208_ref.h) in lock-step.
//
//   tb_cpu [--seeds N] [--insns N] [--seed S] [--verbose]
//
// Each seed builds a deterministic pseudo-random 4 GiB memory (sparse overlay over a hash), a reset vector
// pointing at a random instruction stream biased towards decodable opcodes, then runs both models. After every
// RTL retire the reference executes one instruction with the same interrupt line level; the full architectural
// state (R0-R7, PC, SR, SP, ER) and the ordered list of memory writes must match, as must the illegal-opcode
// report. Memory latency (0-3 cycles) and the IRQ line/vector change randomly. Prints PASS/FAIL and the first
// mismatch with a disassembly-friendly context.
#include "Vse3208_cpu.h"
#include "verilated.h"
#include "../reference/se3208_ref.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <unordered_map>
#include <vector>

struct Mem {
    uint32_t seed;
    std::unordered_map<uint32_t, uint8_t> ov;
    uint8_t rd8(uint32_t a) const {
        auto it = ov.find(a);
        if (it != ov.end()) return it->second;
        uint32_t h = (a ^ seed) * 2654435761u;
        h ^= h >> 15;
        h *= 2246822519u;
        return uint8_t(h >> 24);
    }
    void wr8(uint32_t a, uint8_t v) { ov[a] = v; }
    uint32_t rd(uint32_t a, int size) const { uint32_t v = 0; for (int i = 0; i < size; i++) v |= uint32_t(rd8(a + i)) << (8 * i); return v; }
    void wr(uint32_t a, int size, uint32_t d) { for (int i = 0; i < size; i++) wr8(a + i, uint8_t(d >> (8 * i))); }
};

struct Wr { uint32_t addr; int size; uint32_t data; };

double sc_time_stamp() { return 0; }

static uint64_t rng_state;
static uint32_t rnd() { rng_state ^= rng_state << 13; rng_state ^= rng_state >> 7; rng_state ^= rng_state << 17; return uint32_t(rng_state); }

static uint16_t random_opcode()
{
    // bias: fewer far branches / stack-pointer clobbers so programs stay in RAM-like code longer
    uint32_t pick = rnd() % 1000;
    if (pick < 15) return uint16_t(0xE0AD);                     // SET 13 (ENI): exercise interrupts
    if (pick < 22) return uint16_t(0xE0AC);                     // SET 12 (AUT): vectored interrupts
    if (pick < 26) return uint16_t(0xE0BC);                     // CLR 12
    if (pick < 36) return uint16_t(0xE010 | (rnd() & 7));       // EXTS
    if (pick < 40) return uint16_t(0xE0C0 | (rnd() & 15));      // SWI
    for (;;) {
        uint16_t o = uint16_t(rnd());
        se3208::Op op = se3208::decode(o);
        uint32_t r = rnd() % 100;
        if (op == se3208::OP_INVALID && r < 95) continue;
        if ((op == se3208::OP_JR || op == se3208::OP_CALLR || op == se3208::OP_POP) && r < 70) continue;
        if (op == se3208::OP_LEATOSP && r < 50) continue;
        return o;
    }
}

int main(int argc, char **argv)
{
    Verilated::commandArgs(argc, argv);
    int seeds = 200, insns = 20000;
    long first_seed = 1;
    bool verbose = false;
    for (int i = 1; i < argc; i++) {
        std::string a = argv[i];
        if (a == "--seeds") seeds = atoi(argv[++i]);
        else if (a == "--insns") insns = atoi(argv[++i]);
        else if (a == "--seed") { first_seed = atol(argv[++i]); seeds = 1; }
        else if (a == "--verbose") verbose = true;
    }
    uint64_t total_insns = 0, total_irqs = 0, total_illegal = 0, total_writes = 0;
    uint64_t op_hist[se3208::OP_COUNT] = {};
    for (long seed = first_seed; seed < first_seed + seeds; seed++) {
        rng_state = 0x9E3779B97F4A7C15ull ^ (uint64_t(seed) * 0xD1B54A32D192ED03ull);
        Mem mem_rtl, mem_ref;
        mem_rtl.seed = mem_ref.seed = uint32_t(seed * 0x1234567);
        uint32_t code = 0x00001000 + (rnd() & 0xff0);
        // reset vector, code stream, and a code stream at every possible interrupt vector target region
        for (Mem *m : {&mem_rtl, &mem_ref}) m->wr(0, 4, code);
        std::vector<uint16_t> prog(4096);
        for (auto &w : prog) w = random_opcode();
        for (size_t i = 0; i < prog.size(); i++) { mem_rtl.wr(code + 2 * i, 2, prog[i]); mem_ref.wr(code + 2 * i, 2, prog[i]); }

        Vse3208_cpu *top = new Vse3208_cpu;
        se3208::Cpu ref;
        std::vector<Wr> wr_rtl, wr_ref;
        ref.bus.read = [&](uint32_t a, int s) { return mem_ref.rd(a, s); };
        ref.bus.write = [&](uint32_t a, int s, uint32_t d) { mem_ref.wr(a, s, d); wr_ref.push_back({a, s, d}); };
        ref.bus.fetch = [&](uint32_t a) { return uint16_t(mem_ref.rd(a & ~1u, 2)); };   // odd PC: bit 0 ignored (docs/SE3208.md)
        uint8_t irq_vec = 0;
        ref.bus.iack = [&]() { return irq_vec; };
        bool ref_illegal = false;
        ref.on_invalid = [&](uint32_t, uint16_t) { ref_illegal = true; };

        top->clk = 0;
        top->rst_n = 0;
        top->start_ok = 1;
        top->irq = 0;
        top->nmi = 0;
        top->irq_vector = 0;
        top->i_ack = 0;
        top->d_ack = 0;
        for (int i = 0; i < 4; i++) { top->clk = 1; top->eval(); top->clk = 0; top->eval(); }
        top->rst_n = 1;
        ref.reset();

        int i_lat = 0, d_lat = 0, i_wait = -1, d_wait = -1;
        bool irq_level = false;
        bool rtl_illegal = false;
        uint64_t cycles = 0;
        int retired = 0;
        bool fail = false;
        std::string why;
        while (retired < insns && !fail) {
            // memory responses (combinational, presented before the rising edge)
            top->i_ack = 0;
            top->d_ack = 0;
            if (top->i_req) {
                if (i_wait < 0) i_wait = i_lat = rnd() % 4;
                if (i_wait == 0) { top->i_ack = 1; top->i_data = uint16_t(mem_rtl.rd(top->i_addr, 2)); }
            }
            if (top->d_req) {
                if (d_wait < 0) d_wait = d_lat = rnd() % 4;
                if (d_wait == 0) {
                    top->d_ack = 1;
                    uint32_t a = top->d_addr & ~3u;
                    if (top->d_we) {
                        // lane-placed write with byte enables -> sized write as the CPU intended
                        int lo = -1, n = 0;
                        for (int b = 0; b < 4; b++) if (top->d_be & (1 << b)) { if (lo < 0) lo = b; n++; }
                        uint32_t data = (top->d_wdata >> (8 * lo)) & (n == 4 ? 0xffffffffu : ((1u << (8 * n)) - 1));
                        if (uint32_t(lo) != (top->d_addr & 3)) { fail = true; why = "byte enable / address mismatch"; }
                        mem_rtl.wr(a + lo, n, data);
                        wr_rtl.push_back({a + lo, n, data});
                    } else
                        top->d_rdata = mem_rtl.rd(a, 4);
                }
            }
            top->clk = 1;
            top->eval();
            if (top->i_ack && top->i_req == 0) {}
            if (i_wait >= 0) { if (top->i_ack) i_wait = -1; else i_wait--; }
            if (d_wait >= 0) { if (top->d_ack) d_wait = -1; else d_wait--; }
            // the ack is consumed on this edge; withdraw it
            top->clk = 0;
            top->eval();
            cycles++;
            if (top->illegal) rtl_illegal = true;
            if (top->retire) {
                ref_illegal = false;
                ref.irq_line = irq_level;
                ref.step();
                op_hist[ref.last_op]++;
                retired++;
                total_insns++;
                if (top->dbg_took_irq) total_irqs++;
                if (ref_illegal) total_illegal++;
                total_writes += wr_ref.size();
                auto &s = ref.s;
                char buf[512];
                bool regs_ok = true;
                for (int r = 0; r < 8; r++) if (top->dbg_regs[r] != s.R[r]) regs_ok = false;
                uint32_t rtl_pc_next = 0;   // next PC is visible as the PC register after retire
                (void)rtl_pc_next;
                if (!regs_ok || top->dbg_sr != s.SR || top->dbg_sp != s.SP || top->dbg_er != s.ER ||
                    top->dbg_pc != s.PPC || top->dbg_opcode != ref.last_opcode || bool(top->dbg_took_irq) != ref.last_took_irq || rtl_illegal != ref_illegal) {
                    fail = true;
                    snprintf(buf, sizeof buf, "state mismatch");
                    why = buf;
                }
                if (!fail) {
                    if (wr_rtl.size() != wr_ref.size()) { fail = true; why = "write count mismatch"; }
                    else for (size_t w = 0; w < wr_rtl.size(); w++)
                        if (wr_rtl[w].addr != wr_ref[w].addr || wr_rtl[w].size != wr_ref[w].size || wr_rtl[w].data != wr_ref[w].data) {
                            fail = true; why = "write mismatch"; break;
                        }
                }
                if (fail || verbose) {
                    printf("%s seed %ld insn %d: pc %08x op %04x (%s)%s\n", fail ? "FAIL" : "    ", seed, retired, s.PPC, ref.last_opcode,
                           se3208::op_name(ref.last_op), ref.last_took_irq ? " +IRQ" : "");
                }
                if (fail) {
                    printf("  why: %s\n", why.c_str());
                    printf("  %-4s %08x %08x\n", "PC", top->dbg_pc, s.PPC);
                    printf("  %-4s %08x %08x\n", "SR", top->dbg_sr, s.SR);
                    printf("  %-4s %08x %08x\n", "SP", top->dbg_sp, s.SP);
                    printf("  %-4s %08x %08x\n", "ER", top->dbg_er, s.ER);
                    for (int r = 0; r < 8; r++) printf("  R%d   %08x %08x%s\n", r, top->dbg_regs[r], s.R[r], top->dbg_regs[r] != s.R[r] ? "  <==" : "");
                    printf("  irq rtl %d ref %d  illegal rtl %d ref %d\n", top->dbg_took_irq, ref.last_took_irq, rtl_illegal, ref_illegal);
                    for (auto &w : wr_rtl) printf("  rtl W %08x %d %08x\n", w.addr, w.size, w.data);
                    for (auto &w : wr_ref) printf("  ref W %08x %d %08x\n", w.addr, w.size, w.data);
                }
                wr_rtl.clear();
                wr_ref.clear();
                rtl_illegal = false;
                // change the interrupt line between instructions
                if (rnd() % 64 == 0) irq_level = !irq_level;
                top->irq = irq_level;
                irq_vec = uint8_t(rnd() % 40);
                top->irq_vector = irq_vec;
            }
            if (cycles > uint64_t(insns) * 400 + 1000) { fail = true; why = "timeout"; printf("FAIL seed %ld: timeout (hung CPU)\n", seed); }
        }
        delete top;
        if (fail) {
            printf("CPU DIFFTEST: FAIL (seed %ld)\n", seed);
            return 1;
        }
    }
    printf("CPU DIFFTEST: PASS seeds=%d insns=%llu irqs=%llu illegal=%llu writes=%llu\n", seeds,
           (unsigned long long)total_insns, (unsigned long long)total_irqs, (unsigned long long)total_illegal,
           (unsigned long long)total_writes);
    printf("opcode coverage:");
    int missing = 0;
    for (int o = 0; o < se3208::OP_COUNT; o++) {
        if (!op_hist[o]) { printf(" MISSING:%s", se3208::op_name(se3208::Op(o))); missing++; }
    }
    printf(missing ? "\n" : " all %d opcodes exercised\n", int(se3208::OP_COUNT));
    return 0;
}
