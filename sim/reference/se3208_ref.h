// SE3208 reference model for the Crystal System MiSTer core verification.
//
// Derived from MAME src/devices/cpu/se3208/se3208.cpp (license: BSD-3-Clause, copyright-holders: ElSemi),
// MAME commit c233473382353a00fb2d8b00d98c197cee910854. Restructured as a header-only interpreter with
// pluggable bus callbacks so the same code is the oracle for the RTL CPU differential tests and the core of the
// whole-board reference model. Instruction semantics are kept exactly as MAME, including the documented
// corner cases (see docs/SE3208.md):
//   * extended operands keep only the low 4 (or 8) bits of the scaled immediate;
//   * shift-by-zero carry follows x86 shift-count masking (BIT(val, 32 - 0) == BIT(val, 0) and
//     BIT(val, -1) == BIT(val, 31)) because MAME's BIT() compiles to a native shift;
//   * MULS is an unsigned 32x32 multiply (u32 operands promoted to int64);
//   * register-form ALU ops, MOV, NEG, PUSH, POP, SET, CLR, HALT, MVTC, MVFC do not clear the E flag.
// Unlike MAME, an undecodable opcode is reported (invalid_op callback / counter) instead of being a silent NOP.
//
// Copyright (C) 2026 Kyle Lester for the restructuring. Original copyright ElSemi. BSD-3-Clause.
#pragma once
#include <cstdint>
#include <functional>

namespace se3208 {

enum : uint32_t {
    FLAG_C   = 0x0080,
    FLAG_V   = 0x0010,
    FLAG_S   = 0x0020,
    FLAG_Z   = 0x0040,
    FLAG_M   = 0x0200,
    FLAG_E   = 0x0800,
    FLAG_AUT = 0x1000,
    FLAG_ENI = 0x2000,
    FLAG_NMI = 0x4000
};

enum Op : uint8_t {
    OP_INVALID = 0,
    OP_LDB, OP_LDS, OP_LD, OP_LDBU, OP_STB, OP_STS, OP_ST, OP_LDSU,
    OP_LERI, OP_LDSP, OP_STSP, OP_PUSH, OP_POP,
    OP_ADDI, OP_ADCI, OP_SUBI, OP_SBCI, OP_ANDI, OP_ORI, OP_XORI, OP_CMPI, OP_TSTI, OP_LEATOSP, OP_LEAFROMSP,
    OP_ADD, OP_ADC, OP_SUB, OP_SBC, OP_AND, OP_OR, OP_XOR, OP_CMP, OP_TST, OP_MOV, OP_NEG,
    OP_JNV, OP_JV, OP_JP, OP_JM, OP_JNZ, OP_JZ, OP_JNC, OP_JC, OP_JGT, OP_JLT, OP_JGE, OP_JLE, OP_JHI, OP_JLS,
    OP_JMP, OP_CALL,
    OP_LDI, OP_LDBSP, OP_LDSSP, OP_LDBUSP, OP_STBSP, OP_STSSP, OP_LDSUSP, OP_LEASPTOSP,
    OP_EXTB, OP_EXTS, OP_JR, OP_CALLR, OP_SET, OP_CLR, OP_SWI, OP_HALT,
    OP_ASR, OP_LSR, OP_ASL, OP_MULS, OP_MVTC, OP_MVFC,
    OP_COUNT
};

inline const char *op_name(Op o) {
    static const char *n[] = {
        "INVALID", "LDB", "LDS", "LD", "LDBU", "STB", "STS", "ST", "LDSU",
        "LERI", "LDSP", "STSP", "PUSH", "POP",
        "ADDI", "ADCI", "SUBI", "SBCI", "ANDI", "ORI", "XORI", "CMPI", "TSTI", "LEATOSP", "LEAFROMSP",
        "ADD", "ADC", "SUB", "SBC", "AND", "OR", "XOR", "CMP", "TST", "MOV", "NEG",
        "JNV", "JV", "JP", "JM", "JNZ", "JZ", "JNC", "JC", "JGT", "JLT", "JGE", "JLE", "JHI", "JLS",
        "JMP", "CALL",
        "LDI", "LDBSP", "LDSSP", "LDBUSP", "STBSP", "STSSP", "LDSUSP", "LEASPTOSP",
        "EXTB", "EXTS", "JR", "CALLR", "SET", "CLR", "SWI", "HALT",
        "ASR", "LSR", "ASL", "MULS", "MVTC", "MVFC"};
    return o < OP_COUNT ? n[o] : "?";
}

// Decoder: exact transcription of se3208_device::decode_op.
inline Op decode(uint16_t opcode) {
    auto B = [&](int pos, int len) { return (opcode >> pos) & ((1u << len) - 1); };
    switch (B(14, 2)) {
    case 0: {
        static const Op t[8] = {OP_LDB, OP_LDS, OP_LD, OP_LDBU, OP_STB, OP_STS, OP_ST, OP_LDSU};
        return t[B(11, 3)];
    }
    case 1:
        return OP_LERI;
    case 2:
        switch (B(11, 3)) {
        case 0: return OP_LDSP;
        case 1: return OP_STSP;
        case 2: return OP_PUSH;
        case 3: return OP_POP;
        default:
            switch (B(6, 3)) {
            case 0: return OP_ADDI;
            case 1: return OP_ADCI;
            case 2: return OP_SUBI;
            case 3: return OP_SBCI;
            case 4: return OP_ANDI;
            case 5: return OP_ORI;
            case 6: return OP_XORI;
            case 7:
                switch (B(0, 3)) {
                case 0: return OP_CMPI;
                case 1: return OP_TSTI;
                case 2: return OP_LEATOSP;
                case 3: return OP_LEAFROMSP;
                }
                break;
            }
            break;
        }
        break;
    case 3:
        switch (B(12, 2)) {
        case 0:
            switch (B(6, 3)) {
            case 0: return OP_ADD;
            case 1: return OP_ADC;
            case 2: return OP_SUB;
            case 3: return OP_SBC;
            case 4: return OP_AND;
            case 5: return OP_OR;
            case 6: return OP_XOR;
            case 7:
                switch (B(0, 3)) {
                case 0: return OP_CMP;
                case 1: return OP_TST;
                case 2: return OP_MOV;
                case 3: return OP_NEG;
                }
                break;
            }
            break;
        case 1: {
            static const Op t[16] = {OP_JNV, OP_JV, OP_JP, OP_JM, OP_JNZ, OP_JZ, OP_JNC, OP_JC,
                                     OP_JGT, OP_JLT, OP_JGE, OP_JLE, OP_JHI, OP_JLS, OP_JMP, OP_CALL};
            return t[B(8, 4)];
        }
        case 2:
            if (B(11, 1))
                return OP_LDI;
            if (B(10, 1)) {
                switch (B(7, 3)) {
                case 0: return OP_LDBSP;
                case 1: return OP_LDSSP;
                case 3: return OP_LDBUSP;
                case 4: return OP_STBSP;
                case 5: return OP_STSSP;
                case 7: return OP_LDSUSP;
                }
            } else if (B(9, 1)) {
                return OP_LEASPTOSP;
            } else if (!B(8, 1)) {
                switch (B(4, 4)) {
                case 0: return OP_EXTB;
                case 1: return OP_EXTS;
                case 8: return OP_JR;
                case 9: return OP_CALLR;
                case 10: return OP_SET;
                case 11: return OP_CLR;
                case 12: return OP_SWI;
                case 13: return OP_HALT;
                }
            }
            break;
        case 3:
            switch (B(9, 3)) {
            case 0: case 1: case 2: case 3:
                switch (B(3, 2)) {
                case 0: return OP_ASR;
                case 1: return OP_LSR;
                case 2: return OP_ASL;
                }
                break;
            case 4: return OP_MULS;
            case 6: return B(3, 1) ? OP_MVFC : OP_MVTC;
            }
            break;
        }
        break;
    }
    return OP_INVALID;
}

// Byte-addressed little-endian bus. Size is 1, 2 or 4 bytes; addresses passed with size 2 are 2-aligned and
// with size 4 are 4-aligned (the CPU splits unaligned accesses into byte accesses exactly like MAME).
struct Bus {
    std::function<uint32_t(uint32_t addr, int size)> read;
    std::function<void(uint32_t addr, int size, uint32_t data)> write;
    std::function<uint16_t(uint32_t addr)> fetch;   // instruction fetch (PC is 2-aligned)
    std::function<uint8_t()> iack;                  // interrupt acknowledge vector (AUT mode)
};

struct State {
    uint32_t R[8] = {};
    uint32_t PC = 0, SR = 0, SP = 0, ER = 0, PPC = 0;
};

class Cpu {
public:
    State s;
    Bus bus;
    bool irq_line = false;
    bool nmi_line = false;
    uint64_t insn_count = 0;
    uint64_t invalid_count = 0;
    uint16_t last_opcode = 0;
    Op last_op = OP_INVALID;
    bool last_took_irq = false;
    uint8_t last_irq_vector = 0;
    std::function<void(uint32_t pc, uint16_t opcode)> on_invalid;

    void reset() {
        for (auto &r : s.R) r = 0;
        s.SP = 0;
        s.ER = 0;
        s.PPC = 0;
        s.PC = read32(0);
        s.SR = 0;
        irq_line = false;
        nmi_line = false;
    }

    // Executes one instruction and then the interrupt check, exactly as one iteration of execute_run().
    void step() {
        uint16_t opcode = bus.fetch(s.PC);
        s.PPC = s.PC;
        last_opcode = opcode;
        last_op = decode(opcode);
        exec(last_op, opcode);
        s.PC += 2;
        last_took_irq = false;
        if (nmi_line) {
            nmi_execute();
            nmi_line = false;
        } else if (irq_line && test(FLAG_ENI)) {
            interrupt_execute();
        }
        insn_count++;
    }

    // Helpers exposed for the RTL harness
    static uint32_t sext(uint32_t v, int bits) { uint32_t m = 1u << (bits - 1); v &= (1u << bits) - 1; return (v ^ m) - m; }

private:
    bool test(uint32_t f) const { return (s.SR & f) != 0; }
    void setf(uint32_t f) { s.SR |= f; }
    void clrf(uint32_t f) { s.SR &= ~f; }

    uint8_t read8(uint32_t a) { return (uint8_t)bus.read(a, 1); }
    uint16_t read16(uint32_t a) {
        if (a & 1)
            return (uint16_t)(read8(a) | (read8(a + 1) << 8));
        return (uint16_t)bus.read(a, 2);
    }
    uint32_t read32(uint32_t a) {
        if ((a & 3) == 0)
            return bus.read(a, 4);
        return read8(a) | (read8(a + 1) << 8) | (read8(a + 2) << 16) | ((uint32_t)read8(a + 3) << 24);
    }
    void write8(uint32_t a, uint8_t d) { bus.write(a, 1, d); }
    void write16(uint32_t a, uint16_t d) {
        if (a & 1) {
            write8(a, d & 0xff);
            write8(a + 1, (d >> 8) & 0xff);
        } else
            bus.write(a, 2, d);
    }
    void write32(uint32_t a, uint32_t d) {
        if ((a & 3) == 0)
            bus.write(a, 4, d);
        else {
            write8(a, d & 0xff);
            write8(a + 1, (d >> 8) & 0xff);
            write8(a + 2, (d >> 16) & 0xff);
            write8(a + 3, (d >> 24) & 0xff);
        }
    }

    // x86 semantics of MAME's BIT(u32 x, n) = (x >> n) & 1 with a runtime count (count masked to 5 bits).
    static uint32_t xbit(uint32_t x, int n) { return (x >> (n & 31)) & 1; }

    uint32_t add_f(uint32_t a, uint32_t b) {
        uint32_t r = a + b;
        clrf(FLAG_Z | FLAG_C | FLAG_V | FLAG_S);
        if (!r) setf(FLAG_Z);
        if (r & 0x80000000) setf(FLAG_S);
        if ((((a & b) | (~r & (a | b))) >> 31) & 1) setf(FLAG_C);
        if ((((a ^ r) & (b ^ r)) >> 31) & 1) setf(FLAG_V);
        return r;
    }
    uint32_t sub_f(uint32_t a, uint32_t b) {
        uint32_t r = a - b;
        clrf(FLAG_Z | FLAG_C | FLAG_V | FLAG_S);
        if (!r) setf(FLAG_Z);
        if (r & 0x80000000) setf(FLAG_S);
        if ((((b & r) | (~a & (b | r))) >> 31) & 1) setf(FLAG_C);
        if ((((b ^ a) & (r ^ a)) >> 31) & 1) setf(FLAG_V);
        return r;
    }
    uint32_t adc_f(uint32_t a, uint32_t b) {
        uint32_t c = test(FLAG_C) ? 1 : 0;
        uint32_t r = a + b + c;
        clrf(FLAG_Z | FLAG_C | FLAG_V | FLAG_S);
        if (!r) setf(FLAG_Z);
        if (r & 0x80000000) setf(FLAG_S);
        if ((((a & b) | (~r & (a | b))) >> 31) & 1) setf(FLAG_C);
        if ((((a ^ r) & (b ^ r)) >> 31) & 1) setf(FLAG_V);
        return r;
    }
    uint32_t sbc_f(uint32_t a, uint32_t b) {
        uint32_t c = test(FLAG_C) ? 1 : 0;
        uint32_t r = a - b - c;
        clrf(FLAG_Z | FLAG_C | FLAG_V | FLAG_S);
        if (!r) setf(FLAG_Z);
        if (r & 0x80000000) setf(FLAG_S);
        if ((((b & r) | (~a & (b | r))) >> 31) & 1) setf(FLAG_C);
        if ((((b ^ a) & (r ^ a)) >> 31) & 1) setf(FLAG_V);
        return r;
    }
    uint32_t mul_f(uint32_t a, uint32_t b) {
        int64_t r = int64_t(a) * int64_t(b);   // u32 -> int64 zero-extends: unsigned product
        clrf(FLAG_V);
        if (r >> 32) setf(FLAG_V);
        return uint32_t(r);
    }
    uint32_t asr_f(uint32_t val, uint32_t by) {
        int32_t v = int32_t(val);
        v >>= (by & 31);
        clrf(FLAG_Z | FLAG_C | FLAG_V | FLAG_S);
        if (!v) setf(FLAG_Z);
        if (v & 0x80000000) setf(FLAG_S);
        if (xbit(val, int(by) - 1)) setf(FLAG_C);
        return uint32_t(v);
    }
    uint32_t lsr_f(uint32_t val, uint32_t by) {
        uint32_t v = val >> (by & 31);
        clrf(FLAG_Z | FLAG_C | FLAG_V | FLAG_S);
        if (!v) setf(FLAG_Z);
        if (v & 0x80000000) setf(FLAG_S);
        if (xbit(val, int(by) - 1)) setf(FLAG_C);
        return v;
    }
    uint32_t asl_f(uint32_t val, uint32_t by) {
        uint32_t v = val << (by & 31);
        clrf(FLAG_Z | FLAG_C | FLAG_V | FLAG_S);
        if (!v) setf(FLAG_Z);
        if (v & 0x80000000) setf(FLAG_S);
        if (xbit(val, 32 - int(by))) setf(FLAG_C);
        return v;
    }
    void logic_f(uint32_t r, bool clr_e) {
        clrf(FLAG_S | FLAG_Z | (clr_e ? FLAG_E : 0));
        if (!r) setf(FLAG_Z);
        if (r & 0x80000000) setf(FLAG_S);
    }

    uint32_t idx(uint32_t i) { return i ? s.R[i] : 0; }
    uint32_t ext(uint32_t imm, int shift) { return (s.ER << shift) | (imm & ((1u << shift) - 1)); }

    void push_val(uint32_t v) { s.SP -= 4; write32(s.SP, v); }
    uint32_t pop_val() { uint32_t v = read32(s.SP); s.SP += 4; return v; }

    void take_vector(uint8_t v) { s.PC = read32(4u * v); }

    void nmi_execute() {
        push_val(s.PC);
        push_val(s.SR);
        clrf(FLAG_NMI | FLAG_ENI | FLAG_E | FLAG_M);
        take_vector(1);
        last_took_irq = true;
        last_irq_vector = 1;
    }
    void interrupt_execute() {
        if (!test(FLAG_ENI)) return;
        push_val(s.PC);
        push_val(s.SR);
        clrf(FLAG_ENI | FLAG_E | FLAG_M);
        uint8_t v = test(FLAG_AUT) ? bus.iack() : 2;
        last_took_irq = true;
        last_irq_vector = v;
        take_vector(v);
    }

    // Conditional/unconditional relative branch offset (bits 0-7, extended by ER<<8).
    uint32_t br_off(uint16_t op) {
        uint32_t o = op & 0xff;
        o = test(FLAG_E) ? ext(o, 8) : uint32_t(int32_t(int8_t(o)));
        return o << 1;
    }
    void branch(uint16_t op, bool cond) {
        uint32_t o = br_off(op);
        if (cond) s.PC += o;
        clrf(FLAG_E);
    }

    void exec(Op o, uint16_t op) {
        auto B = [&](int pos, int len) { return (uint32_t)(op >> pos) & ((1u << len) - 1); };
        bool fs = test(FLAG_S), fv = test(FLAG_V), fz = test(FLAG_Z), fc = test(FLAG_C);
        switch (o) {
        case OP_INVALID:
            invalid_count++;
            if (on_invalid) on_invalid(s.PC, op);
            break;
        // ---- loads/stores with index register
        case OP_LDB: case OP_LDBU: case OP_STB:
        case OP_LDS: case OP_LDSU: case OP_STS:
        case OP_LD: case OP_ST: {
            uint32_t off = B(0, 5);
            uint32_t base = idx(B(5, 3));
            uint32_t rd = B(8, 3);
            if (o == OP_LDS || o == OP_LDSU || o == OP_STS) off <<= 1;
            if (o == OP_LD || o == OP_ST) off <<= 2;
            if (test(FLAG_E)) off = ext(off, 4);
            uint32_t a = base + off;
            switch (o) {
            case OP_LDB: s.R[rd] = uint32_t(int32_t(int8_t(read8(a)))); break;
            case OP_LDBU: s.R[rd] = read8(a); break;
            case OP_STB: write8(a, s.R[rd] & 0xff); break;
            case OP_LDS: s.R[rd] = uint32_t(int32_t(int16_t(read16(a)))); break;
            case OP_LDSU: s.R[rd] = read16(a); break;
            case OP_STS: write16(a, s.R[rd] & 0xffff); break;
            case OP_LD: s.R[rd] = read32(a); break;
            case OP_ST: write32(a, s.R[rd]); break;
            default: break;
            }
            clrf(FLAG_E);
            break;
        }
        case OP_LERI: {
            uint32_t imm = B(0, 14);
            if (test(FLAG_E)) s.ER = (s.ER << 14) | imm;
            else s.ER = sext(imm, 14);
            setf(FLAG_E);
            break;
        }
        case OP_LDSP: case OP_STSP: {
            uint32_t off = B(0, 8) << 2;
            uint32_t rd = B(8, 3);
            if (test(FLAG_E)) off = ext(off, 4);
            uint32_t a = s.SP + off;
            if (o == OP_LDSP) s.R[rd] = read32(a);
            else write32(a, s.R[rd]);
            clrf(FLAG_E);
            break;
        }
        case OP_PUSH: {
            uint32_t set = B(0, 11);
            if (set & (1 << 10)) push_val(s.PC);
            if (set & (1 << 9)) push_val(s.SR);
            if (set & (1 << 8)) push_val(s.ER);
            for (int r = 7; r >= 0; r--)
                if (set & (1 << r)) push_val(s.R[r]);
            break;
        }
        case OP_POP: {
            uint32_t set = B(0, 11);
            for (int r = 0; r < 8; r++)
                if (set & (1 << r)) s.R[r] = pop_val();
            if (set & (1 << 8)) s.ER = pop_val();
            if (set & (1 << 9)) s.SR = pop_val();
            if (set & (1 << 10)) s.PC = pop_val() - 2;
            break;
        }
        // ---- immediate ALU (imm4 at bits 9-12, src 3-5, dst 0-2)
        case OP_ADDI: case OP_ADCI: case OP_SUBI: case OP_SBCI: case OP_ANDI: case OP_ORI: case OP_XORI:
        case OP_CMPI: case OP_TSTI: {
            uint32_t imm = B(9, 4);
            imm = test(FLAG_E) ? ext(imm, 4) : sext(imm, 4);
            uint32_t a = s.R[B(3, 3)];
            uint32_t d = B(0, 3);
            switch (o) {
            case OP_ADDI: s.R[d] = add_f(a, imm); clrf(FLAG_E); break;
            case OP_ADCI: s.R[d] = adc_f(a, imm); clrf(FLAG_E); break;
            case OP_SUBI: s.R[d] = sub_f(a, imm); clrf(FLAG_E); break;
            case OP_SBCI: s.R[d] = sbc_f(a, imm); clrf(FLAG_E); break;
            case OP_ANDI: s.R[d] = a & imm; logic_f(s.R[d], true); break;
            case OP_ORI: s.R[d] = a | imm; logic_f(s.R[d], true); break;
            case OP_XORI: s.R[d] = a ^ imm; logic_f(s.R[d], true); break;
            case OP_CMPI: sub_f(a, imm); clrf(FLAG_E); break;
            case OP_TSTI: logic_f(a & imm, true); break;
            default: break;
            }
            break;
        }
        case OP_LEATOSP: {
            uint32_t off = B(9, 4);
            uint32_t base = idx(B(3, 3));
            off = test(FLAG_E) ? ext(off, 4) : sext(off, 4);
            s.SP = (base + off) & ~3u;
            clrf(FLAG_E);
            break;
        }
        case OP_LEAFROMSP: {
            uint32_t off = B(9, 4);
            off = test(FLAG_E) ? ext(off, 4) : sext(off, 4);
            s.R[B(3, 3)] = s.SP + off;
            clrf(FLAG_E);
            break;
        }
        case OP_LEASPTOSP: {
            uint32_t off = B(0, 8) << 2;
            off = test(FLAG_E) ? ext(off, 8) : sext(off, 10);
            s.SP = (s.SP + off) & ~3u;
            clrf(FLAG_E);
            break;
        }
        // ---- register ALU (src2 9-11, src1 3-5, dst 0-2); E flag untouched
        case OP_ADD: s.R[B(0, 3)] = add_f(s.R[B(3, 3)], s.R[B(9, 3)]); break;
        case OP_ADC: s.R[B(0, 3)] = adc_f(s.R[B(3, 3)], s.R[B(9, 3)]); break;
        case OP_SUB: s.R[B(0, 3)] = sub_f(s.R[B(3, 3)], s.R[B(9, 3)]); break;
        case OP_SBC: s.R[B(0, 3)] = sbc_f(s.R[B(3, 3)], s.R[B(9, 3)]); break;
        case OP_AND: s.R[B(0, 3)] = s.R[B(3, 3)] & s.R[B(9, 3)]; logic_f(s.R[B(0, 3)], false); break;
        case OP_OR: s.R[B(0, 3)] = s.R[B(3, 3)] | s.R[B(9, 3)]; logic_f(s.R[B(0, 3)], false); break;
        case OP_XOR: s.R[B(0, 3)] = s.R[B(3, 3)] ^ s.R[B(9, 3)]; logic_f(s.R[B(0, 3)], false); break;
        case OP_CMP: sub_f(s.R[B(3, 3)], s.R[B(9, 3)]); break;
        case OP_TST: logic_f(s.R[B(3, 3)] & s.R[B(9, 3)], false); break;
        case OP_MOV: s.R[B(9, 3)] = s.R[B(3, 3)]; break;
        case OP_NEG: s.R[B(9, 3)] = sub_f(0, s.R[B(3, 3)]); break;
        case OP_MULS: s.R[B(0, 3)] = mul_f(s.R[B(3, 3)], s.R[B(6, 3)]); clrf(FLAG_E); break;
        // ---- branches
        case OP_JNV: branch(op, !fv); break;
        case OP_JV: branch(op, fv); break;
        case OP_JP: branch(op, !fs); break;
        case OP_JM: branch(op, fs); break;
        case OP_JNZ: branch(op, !fz); break;
        case OP_JZ: branch(op, fz); break;
        case OP_JNC: branch(op, !fc); break;
        case OP_JC: branch(op, fc); break;
        case OP_JGT: branch(op, !(fz || (fs ^ fv))); break;
        case OP_JLT: branch(op, fs ^ fv); break;
        case OP_JGE: branch(op, !(fs ^ fv)); break;
        case OP_JLE: branch(op, fz || (fs ^ fv)); break;
        case OP_JHI: branch(op, !(fz || fc)); break;
        case OP_JLS: branch(op, fz || fc); break;
        case OP_JMP: branch(op, true); break;
        case OP_CALL: {
            uint32_t off = br_off(op);
            push_val(s.PC + 2);
            s.PC += off;
            clrf(FLAG_E);
            break;
        }
        // ---- misc
        case OP_LDI: {
            uint32_t imm = B(0, 8);
            imm = test(FLAG_E) ? ext(imm, 4) : uint32_t(int32_t(int8_t(imm)));
            s.R[B(8, 3)] = imm;
            clrf(FLAG_E);
            break;
        }
        case OP_LDBSP: case OP_LDBUSP: case OP_STBSP:
        case OP_LDSSP: case OP_LDSUSP: case OP_STSSP: {
            uint32_t off = B(0, 4);
            uint32_t rd = B(4, 3);
            if (o == OP_LDSSP || o == OP_LDSUSP || o == OP_STSSP) off <<= 1;
            if (test(FLAG_E)) off = ext(off, 4);
            uint32_t a = s.SP + off;
            switch (o) {
            case OP_LDBSP: s.R[rd] = uint32_t(int32_t(int8_t(read8(a)))); break;
            case OP_LDBUSP: s.R[rd] = read8(a); break;
            case OP_STBSP: write8(a, s.R[rd] & 0xff); break;
            case OP_LDSSP: s.R[rd] = uint32_t(int32_t(int16_t(read16(a)))); break;
            case OP_LDSUSP: s.R[rd] = read16(a); break;
            case OP_STSSP: write16(a, s.R[rd] & 0xffff); break;
            default: break;
            }
            clrf(FLAG_E);
            break;
        }
        case OP_EXTB: case OP_EXTS: {
            uint32_t d = B(0, 4);
            if (d > 7) { invalid_count++; if (on_invalid) on_invalid(s.PC, op); break; }
            s.R[d] = (o == OP_EXTB) ? uint32_t(int32_t(int8_t(s.R[d]))) : uint32_t(int32_t(int16_t(s.R[d])));
            logic_f(s.R[d], true);
            break;
        }
        case OP_JR: case OP_CALLR: {
            uint32_t r = B(0, 4);
            if (r > 7) { invalid_count++; if (on_invalid) on_invalid(s.PC, op); break; }
            if (o == OP_CALLR) push_val(s.PC + 2);
            s.PC = s.R[r] - 2;
            clrf(FLAG_E);
            break;
        }
        case OP_SET: s.SR |= (1u << B(0, 4)); break;
        case OP_CLR: s.SR &= ~(1u << B(0, 4)); break;
        case OP_SWI:
            if (!test(FLAG_ENI)) break;
            push_val(s.PC);
            push_val(s.SR);
            clrf(FLAG_ENI | FLAG_E | FLAG_M);
            take_vector(uint8_t(B(0, 4) + 0x10));
            s.PC -= 2;
            break;
        case OP_HALT: break;
        case OP_MVTC: case OP_MVFC: break;
        case OP_ASR: case OP_LSR: case OP_ASL: {
            uint32_t d = B(0, 3);
            uint32_t by = B(10, 1) ? (s.R[B(5, 3)] & 0x1f) : B(5, 5);
            if (o == OP_ASR) s.R[d] = asr_f(s.R[d], by);
            else if (o == OP_LSR) s.R[d] = lsr_f(s.R[d], by);
            else s.R[d] = asl_f(s.R[d], by);
            clrf(FLAG_E);
            break;
        }
        default:
            break;
        }
    }
};

} // namespace se3208
