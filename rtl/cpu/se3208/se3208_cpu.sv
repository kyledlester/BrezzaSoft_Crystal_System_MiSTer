// BrezzaSoft Crystal System MiSTer core -- ADChips SE3208 CPU.
// Copyright (C) 2026 Kyle Lester. SPDX-License-Identifier: GPL-3.0-or-later
//
// Behaviour: MAME se3208.cpp (c2334733) as documented in docs/SE3208.md, verified instruction by instruction
// against sim/reference/se3208_ref.h (sim/cpu). Multi-cycle implementation:
//
//   FETCH  -> DECODE -> EXEC -> [memory micro-sequence] -> DONE -> [interrupt entry] -> FETCH
//
// * Instruction port: 16-bit fetches (i_req/i_addr, i_ack/i_data), meant for an instruction cache.
// * Data port: one aligned 32-bit bus cycle per request with byte enables (d_be) and lane-placed data, exactly the
//   accesses MAME makes: aligned 8/16/32-bit accesses are single cycles, unaligned 16/32-bit accesses are split
//   into byte cycles in ascending address order. Request is held until d_ack (same-cycle ack allowed).
// * Pacing: a new instruction starts only when `start_ok` is high (credit counter outside, MAME timing = one
//   instruction per 6 clk_sys on average); `retire` pulses when an instruction (and its interrupt entry) is done.
// * Undecodable opcodes execute as NOPs like MAME but pulse `illegal` (simulation stops on it).
// * Interrupts: level `irq` checked after every instruction when SR.ENI; vector = 2, or `irq_vector` when SR.AUT
//   (sampled on the acknowledge cycle, `iack` pulses). `nmi` is edge-latched, vector 1.
module se3208_cpu (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        start_ok,

    output reg         i_req,
    output reg  [31:0] i_addr,
    input  wire        i_ack,
    input  wire [15:0] i_data,

    output reg         d_req,
    output reg         d_we,
    output reg  [31:0] d_addr,      // byte address of the access (aligned to its size)
    output reg   [3:0] d_be,
    output reg  [31:0] d_wdata,     // lane-placed
    input  wire        d_ack,
    input  wire [31:0] d_rdata,     // full dword, lanes extracted by the CPU

    input  wire        irq,
    input  wire        nmi,
    input  wire  [7:0] irq_vector,
    output reg         iack,

    output reg         retire,
    output reg         illegal,
    output reg  [31:0] dbg_pc,      // address of the instruction that retired
    output reg  [15:0] dbg_opcode,
    output reg         dbg_took_irq,
    output wire [31:0] dbg_sr,
    output wire [31:0] dbg_sp,
    output wire [31:0] dbg_er,
    output wire [255:0] dbg_regs
);
    // ------------------------------------------------------------------ architectural state
    reg [31:0] R [0:7];
    reg [31:0] PC, SR, SP, ER;

    localparam [31:0] F_C = 32'h0080, F_V = 32'h0010, F_S = 32'h0020, F_Z = 32'h0040,
                      F_M = 32'h0200, F_E = 32'h0800, F_AUT = 32'h1000, F_ENI = 32'h2000, F_NMI = 32'h4000;

    assign dbg_sr = SR;
    assign dbg_sp = SP;
    assign dbg_er = ER;
    genvar gi;
    generate for (gi = 0; gi < 8; gi++) begin : g_dbg
        assign dbg_regs[gi*32 +: 32] = R[gi];
    end endgenerate

    // ------------------------------------------------------------------ opcodes
    typedef enum logic [6:0] {
        O_INVALID, O_LDB, O_LDS, O_LD, O_LDBU, O_STB, O_STS, O_ST, O_LDSU,
        O_LERI, O_LDSP, O_STSP, O_PUSH, O_POP,
        O_ADDI, O_ADCI, O_SUBI, O_SBCI, O_ANDI, O_ORI, O_XORI, O_CMPI, O_TSTI, O_LEATOSP, O_LEAFROMSP,
        O_ADD, O_ADC, O_SUB, O_SBC, O_AND, O_OR, O_XOR, O_CMP, O_TST, O_MOV, O_NEG,
        O_BCC, O_CALL,
        O_LDI, O_LDBSP, O_LDSSP, O_LDBUSP, O_STBSP, O_STSSP, O_LDSUSP, O_LEASPTOSP,
        O_EXTB, O_EXTS, O_JR, O_CALLR, O_SET, O_CLR, O_SWI, O_HALT,
        O_ASR, O_LSR, O_ASL, O_MULS, O_MVTC, O_MVFC
    } op_t;

    function automatic op_t decode(input [15:0] o);
        op_t r;
        r = O_INVALID;
        case (o[15:14])
            2'd0: case (o[13:11])
                3'd0: r = O_LDB;  3'd1: r = O_LDS;  3'd2: r = O_LD;  3'd3: r = O_LDBU;
                3'd4: r = O_STB;  3'd5: r = O_STS;  3'd6: r = O_ST;  3'd7: r = O_LDSU;
            endcase
            2'd1: r = O_LERI;
            2'd2: case (o[13:11])
                3'd0: r = O_LDSP;
                3'd1: r = O_STSP;
                3'd2: r = O_PUSH;
                3'd3: r = O_POP;
                default: case (o[8:6])
                    3'd0: r = O_ADDI; 3'd1: r = O_ADCI; 3'd2: r = O_SUBI; 3'd3: r = O_SBCI;
                    3'd4: r = O_ANDI; 3'd5: r = O_ORI;  3'd6: r = O_XORI;
                    3'd7: case (o[2:0])
                        3'd0: r = O_CMPI; 3'd1: r = O_TSTI; 3'd2: r = O_LEATOSP; 3'd3: r = O_LEAFROMSP;
                        default: r = O_INVALID;
                    endcase
                endcase
            endcase
            2'd3: case (o[13:12])
                2'd0: case (o[8:6])
                    3'd0: r = O_ADD; 3'd1: r = O_ADC; 3'd2: r = O_SUB; 3'd3: r = O_SBC;
                    3'd4: r = O_AND; 3'd5: r = O_OR;  3'd6: r = O_XOR;
                    3'd7: case (o[2:0])
                        3'd0: r = O_CMP; 3'd1: r = O_TST; 3'd2: r = O_MOV; 3'd3: r = O_NEG;
                        default: r = O_INVALID;
                    endcase
                endcase
                2'd1: r = (o[11:8] == 4'hf) ? O_CALL : O_BCC;
                2'd2: begin
                    if (o[11]) r = O_LDI;
                    else if (o[10]) begin
                        case (o[9:7])
                            3'd0: r = O_LDBSP; 3'd1: r = O_LDSSP; 3'd3: r = O_LDBUSP;
                            3'd4: r = O_STBSP; 3'd5: r = O_STSSP; 3'd7: r = O_LDSUSP;
                            default: r = O_INVALID;
                        endcase
                    end else if (o[9]) r = O_LEASPTOSP;
                    else if (!o[8]) begin
                        case (o[7:4])
                            4'd0: r = O_EXTB;  4'd1: r = O_EXTS; 4'd8: r = O_JR;    4'd9: r = O_CALLR;
                            4'd10: r = O_SET;  4'd11: r = O_CLR; 4'd12: r = O_SWI;  4'd13: r = O_HALT;
                            default: r = O_INVALID;
                        endcase
                    end
                end
                2'd3: case (o[11:9])
                    3'd0, 3'd1, 3'd2, 3'd3: case (o[4:3])
                        2'd0: r = O_ASR; 2'd1: r = O_LSR; 2'd2: r = O_ASL; default: r = O_INVALID;
                    endcase
                    3'd4: r = O_MULS;
                    3'd6: r = o[3] ? O_MVFC : O_MVTC;
                    default: r = O_INVALID;
                endcase
            endcase
        endcase
        return r;
    endfunction

    // ------------------------------------------------------------------ control state
    typedef enum logic [4:0] {
        S_RESET0, S_RESET1, S_FETCH, S_FETCHW, S_DECODE, S_EXEC, S_MUL,
        S_MEM, S_MEMW, S_LOADWB, S_STACK, S_DONE, S_IRQ0, S_IRQ1, S_IRQ2, S_HALTED
    } st_t;
    st_t st;

    reg  [15:0] ir;
    op_t        op;
    reg  [31:0] npc;

    // memory micro-sequence
    reg  [31:0] m_addr;      // first byte address
    reg   [2:0] m_size;      // 1, 2, 4
    reg         m_we;
    reg  [31:0] m_wdata;     // value (not lane placed)
    reg   [1:0] m_idx;       // byte index within an unaligned split
    reg         m_split;
    reg  [31:0] m_rdata;     // assembled value
    reg   [4:0] m_ret;       // continuation selector
    reg         ld_signed;
    reg   [2:0] ld_rd;

    // stack sequences: PUSH/POP masks, CALL, SWI, IRQ entry
    reg  [10:0] stk_mask;
    reg   [3:0] stk_i;        // PUSH: 10 downto 0, POP: 0 to 10
    reg   [7:0] vec;

    localparam [4:0] RET_LOAD = 5'd0, RET_STORE = 5'd1, RET_PUSH = 5'd2, RET_POP = 5'd3, RET_CALL = 5'd4,
                     RET_SWI1 = 5'd5, RET_SWI2 = 5'd6, RET_VEC = 5'd7, RET_IRQ1 = 5'd8, RET_IRQ2 = 5'd9,
                     RET_RESET = 5'd10;

    reg nmi_d, nmi_pend;
    reg took_irq, is_nmi;
    reg [31:0] dbg_pc_hold;   // address of the instruction being executed (retire report after an interrupt entry)

    // decoded fields (EXEC)
    wire [2:0]  f_rd8   = ir[10:8];
    wire [2:0]  f_ri    = ir[7:5];
    wire [2:0]  f_s3    = ir[5:3];
    wire [2:0]  f_d0    = ir[2:0];
    wire [2:0]  f_s9    = ir[11:9];
    wire        e_set   = SR[11];

    function automatic [31:0] ext4(input [31:0] er, input [31:0] imm);
        return {er[27:0], imm[3:0]};
    endfunction
    function automatic [31:0] ext8(input [31:0] er, input [31:0] imm);
        return {er[23:0], imm[7:0]};
    endfunction

    // ---- ALU helpers
    function automatic [35:0] addc(input [31:0] a, input [31:0] b, input cin);  // {C,V,r}
        logic [32:0] s;
        logic c, v;
        s = {1'b0, a} + {1'b0, b} + {32'd0, cin};
        c = ((a[31] & b[31]) | (~s[31] & (a[31] | b[31])));
        v = ((a[31] ^ s[31]) & (b[31] ^ s[31]));
        return {2'b00, c, v, s[31:0]};
    endfunction
    function automatic [35:0] subc(input [31:0] a, input [31:0] b, input cin);   // a - b - cin
        logic [31:0] r;
        logic c, v;
        r = a - b - {31'd0, cin};
        c = ((b[31] & r[31]) | (~a[31] & (b[31] | r[31])));
        v = ((b[31] ^ a[31]) & (r[31] ^ a[31]));
        return {2'b00, c, v, r};
    endfunction

    // SR with Z/S/C/V replaced
    function automatic [31:0] arith_sr(input [31:0] sr, input [31:0] r, input c, input v);
        logic [31:0] n;
        n = sr & ~(F_Z | F_C | F_V | F_S);
        if (r == 32'd0) n = n | F_Z;
        if (r[31])      n = n | F_S;
        if (c)          n = n | F_C;
        if (v)          n = n | F_V;
        return n;
    endfunction
    function automatic [31:0] logic_sr(input [31:0] sr, input [31:0] r, input clr_e);
        logic [31:0] n;
        n = sr & ~(F_S | F_Z | (clr_e ? F_E : 32'd0));
        if (r == 32'd0) n = n | F_Z;
        if (r[31])      n = n | F_S;
        return n;
    endfunction

    // branch condition, MAME flag semantics
    function automatic logic cond(input [3:0] c, input [31:0] sr);
        logic s, v, z, cy;
        s = sr[5]; v = sr[4]; z = sr[6]; cy = sr[7];
        case (c)
            4'h0: return !v;          // JNV
            4'h1: return v;           // JV
            4'h2: return !s;          // JP
            4'h3: return s;           // JM
            4'h4: return !z;          // JNZ
            4'h5: return z;           // JZ
            4'h6: return !cy;         // JNC
            4'h7: return cy;          // JC
            4'h8: return !(z || (s ^ v)); // JGT
            4'h9: return s ^ v;       // JLT
            4'ha: return !(s ^ v);    // JGE
            4'hb: return z || (s ^ v);// JLE
            4'hc: return !(z || cy);  // JHI
            4'hd: return z || cy;     // JLS
            default: return 1'b1;     // JMP (CALL handled separately)
        endcase
    endfunction

    // shift unit (count 0..31), carry per docs/SE3208.md (count-1 / 32-count taken mod 32)
    function automatic [33:0] shifter(input [1:0] kind, input [31:0] val, input [4:0] by); // {c, unused, r}
        logic [31:0] r;
        logic c;
        logic [4:0] cb;
        case (kind)
            2'd0: begin r = $signed(val) >>> by; cb = by - 5'd1; c = val[cb]; end    // ASR
            2'd1: begin r = val >> by;           cb = by - 5'd1; c = val[cb]; end    // LSR
            default: begin r = val << by;        cb = 5'd0 - by; c = val[cb]; end    // ASL: 32-by mod 32
        endcase
        return {c, 1'b0, r};
    endfunction

    // multiplier: registered unsigned 32x32 product
    reg  [31:0] mul_a, mul_b;
    reg  [63:0] mul_p;
    always @(posedge clk) mul_p <= mul_a * mul_b;
    reg  [1:0]  mul_cnt;

    // lane helpers
    function automatic [3:0] be_of(input [1:0] a, input [2:0] size);
        case (size)
            3'd1: return 4'b0001 << a;
            3'd2: return a[1] ? 4'b1100 : 4'b0011;
            default: return 4'b1111;
        endcase
    endfunction

    // ------------------------------------------------------------------ main sequencer
    integer k;
    always @(posedge clk) begin
        retire  <= 1'b0;
        illegal <= 1'b0;
        iack    <= 1'b0;
        nmi_d   <= nmi;
        if (nmi && !nmi_d) nmi_pend <= 1'b1;

        if (!rst_n) begin
            for (k = 0; k < 8; k++) R[k] <= 32'd0;
            SP <= 32'd0; ER <= 32'd0; SR <= 32'd0; PC <= 32'd0;
            st <= S_RESET0;
            i_req <= 1'b0; d_req <= 1'b0; d_we <= 1'b0;
            nmi_pend <= 1'b0;
            took_irq <= 1'b0;
            is_nmi   <= 1'b0;
        end else begin
            case (st)
            // ---------------------------------------------------------- reset: PC = read32(0)
            S_RESET0: begin
                m_addr <= 32'd0; m_size <= 3'd4; m_we <= 1'b0; m_ret <= RET_RESET;
                st <= S_MEM;
            end

            // ---------------------------------------------------------- fetch
            S_FETCH: begin
                if (start_ok) begin
                    i_req  <= 1'b1;
                    i_addr <= {PC[31:1], 1'b0};
                    st     <= S_FETCHW;
                end
            end
            S_FETCHW: begin
                if (i_ack) begin
                    i_req <= 1'b0;
                    ir    <= i_data;
                    st    <= S_DECODE;
                end
            end
            S_DECODE: begin
                op       <= decode(ir);
                npc      <= PC + 32'd2;
                took_irq <= 1'b0;
                st       <= S_EXEC;
            end

            // ---------------------------------------------------------- execute
            S_EXEC: begin
                st <= S_DONE;
                case (op)
                O_INVALID: illegal <= 1'b1;

                // loads/stores with index register: off5 scaled by size, ext keeps the low 4 bits
                O_LDB, O_LDBU, O_STB, O_LDS, O_LDSU, O_STS, O_LD, O_ST: begin
                    logic [31:0] off, base;
                    logic [2:0] sz;
                    sz  = (op == O_LD || op == O_ST) ? 3'd4 : (op == O_LDS || op == O_LDSU || op == O_STS) ? 3'd2 : 3'd1;
                    off = (sz == 3'd4) ? {25'd0, ir[4:0], 2'b00} : (sz == 3'd2) ? {26'd0, ir[4:0], 1'b0} : {27'd0, ir[4:0]};
                    if (e_set) off = ext4(ER, off);
                    base = (f_ri == 3'd0) ? 32'd0 : R[f_ri];
                    m_addr  <= base + off;
                    m_size  <= sz;
                    m_we    <= (op == O_STB || op == O_STS || op == O_ST);
                    m_wdata <= R[f_rd8];
                    m_ret   <= (op == O_STB || op == O_STS || op == O_ST) ? RET_STORE : RET_LOAD;
                    ld_signed <= (op == O_LDB || op == O_LDS);
                    ld_rd   <= f_rd8;
                    SR      <= SR & ~F_E;
                    st      <= S_MEM;
                end
                O_LERI: begin
                    ER <= e_set ? {ER[17:0], ir[13:0]} : {{18{ir[13]}}, ir[13:0]};
                    SR <= SR | F_E;
                end
                O_LDSP, O_STSP: begin
                    logic [31:0] off;
                    off = {22'd0, ir[7:0], 2'b00};
                    if (e_set) off = ext4(ER, off);
                    m_addr  <= SP + off;
                    m_size  <= 3'd4;
                    m_we    <= (op == O_STSP);
                    m_wdata <= R[f_rd8];
                    m_ret   <= (op == O_STSP) ? RET_STORE : RET_LOAD;
                    ld_signed <= 1'b0;
                    ld_rd   <= f_rd8;
                    SR      <= SR & ~F_E;
                    st      <= S_MEM;
                end
                O_PUSH: begin
                    stk_mask <= ir[10:0];
                    stk_i    <= 4'd10;
                    st       <= S_STACK;
                end
                O_POP: begin
                    stk_mask <= ir[10:0];
                    stk_i    <= 4'd0;
                    st       <= S_STACK;
                end
                O_ADDI, O_ADCI, O_SUBI, O_SBCI, O_ANDI, O_ORI, O_XORI, O_CMPI, O_TSTI: begin
                    logic [31:0] imm, a, r;
                    logic [35:0] t;
                    imm = e_set ? ext4(ER, {28'd0, ir[12:9]}) : {{28{ir[12]}}, ir[12:9]};
                    a   = R[f_s3];
                    case (op)
                        O_ADDI: begin t = addc(a, imm, 1'b0);  R[f_d0] <= t[31:0]; SR <= arith_sr(SR, t[31:0], t[33], t[32]) & ~F_E; end
                        O_ADCI: begin t = addc(a, imm, SR[7]); R[f_d0] <= t[31:0]; SR <= arith_sr(SR, t[31:0], t[33], t[32]) & ~F_E; end
                        O_SUBI: begin t = subc(a, imm, 1'b0);  R[f_d0] <= t[31:0]; SR <= arith_sr(SR, t[31:0], t[33], t[32]) & ~F_E; end
                        O_SBCI: begin t = subc(a, imm, SR[7]); R[f_d0] <= t[31:0]; SR <= arith_sr(SR, t[31:0], t[33], t[32]) & ~F_E; end
                        O_CMPI: begin t = subc(a, imm, 1'b0);  SR <= arith_sr(SR, t[31:0], t[33], t[32]) & ~F_E; end
                        O_ANDI: begin r = a & imm; R[f_d0] <= r; SR <= logic_sr(SR, r, 1'b1); end
                        O_ORI:  begin r = a | imm; R[f_d0] <= r; SR <= logic_sr(SR, r, 1'b1); end
                        O_XORI: begin r = a ^ imm; R[f_d0] <= r; SR <= logic_sr(SR, r, 1'b1); end
                        default: begin r = a & imm; SR <= logic_sr(SR, r, 1'b1); end   // TSTI
                    endcase
                end
                O_LEATOSP, O_LEAFROMSP: begin
                    logic [31:0] off, base;
                    off = e_set ? ext4(ER, {28'd0, ir[12:9]}) : {{28{ir[12]}}, ir[12:9]};
                    if (op == O_LEATOSP) begin
                        base = (f_s3 == 3'd0) ? 32'd0 : R[f_s3];
                        SP <= (base + off) & ~32'd3;
                    end else
                        R[f_s3] <= SP + off;
                    SR <= SR & ~F_E;
                end
                O_LEASPTOSP: begin
                    logic [31:0] off;
                    off = e_set ? ext8(ER, {22'd0, ir[7:0], 2'b00}) : {{22{ir[7]}}, ir[7:0], 2'b00};
                    SP <= (SP + off) & ~32'd3;
                    SR <= SR & ~F_E;
                end
                O_ADD, O_ADC, O_SUB, O_SBC, O_CMP: begin
                    logic [35:0] t;
                    case (op)
                        O_ADD: t = addc(R[f_s3], R[f_s9], 1'b0);
                        O_ADC: t = addc(R[f_s3], R[f_s9], SR[7]);
                        O_SUB, O_CMP: t = subc(R[f_s3], R[f_s9], 1'b0);
                        default: t = subc(R[f_s3], R[f_s9], SR[7]);
                    endcase
                    if (op != O_CMP) R[f_d0] <= t[31:0];
                    SR <= arith_sr(SR, t[31:0], t[33], t[32]);
                end
                O_AND, O_OR, O_XOR, O_TST: begin
                    logic [31:0] r;
                    case (op)
                        O_OR:  r = R[f_s3] | R[f_s9];
                        O_XOR: r = R[f_s3] ^ R[f_s9];
                        default: r = R[f_s3] & R[f_s9];
                    endcase
                    if (op != O_TST) R[f_d0] <= r;
                    SR <= logic_sr(SR, r, 1'b0);
                end
                O_MOV: R[f_s9] <= R[f_s3];
                O_NEG: begin
                    logic [35:0] t;
                    t = subc(32'd0, R[f_s3], 1'b0);
                    R[f_s9] <= t[31:0];
                    SR <= arith_sr(SR, t[31:0], t[33], t[32]);
                end
                O_MULS: begin
                    mul_a   <= R[f_s3];
                    mul_b   <= R[ir[8:6]];
                    mul_cnt <= 2'd2;
                    st      <= S_MUL;
                end
                O_BCC: begin
                    logic [31:0] off;
                    off = e_set ? ext8(ER, {24'd0, ir[7:0]}) : {{24{ir[7]}}, ir[7:0]};
                    if (cond(ir[11:8], SR)) npc <= PC + 32'd2 + {off[30:0], 1'b0};
                    SR <= SR & ~F_E;
                end
                O_CALL: begin
                    logic [31:0] off;
                    off = e_set ? ext8(ER, {24'd0, ir[7:0]}) : {{24{ir[7]}}, ir[7:0]};
                    npc     <= PC + 32'd2 + {off[30:0], 1'b0};
                    SP      <= SP - 32'd4;
                    m_addr  <= SP - 32'd4;
                    m_size  <= 3'd4;
                    m_we    <= 1'b1;
                    m_wdata <= PC + 32'd2;
                    m_ret   <= RET_CALL;
                    SR      <= SR & ~F_E;
                    st      <= S_MEM;
                end
                O_LDI: begin
                    R[f_rd8] <= e_set ? ext4(ER, {24'd0, ir[7:0]}) : {{24{ir[7]}}, ir[7:0]};
                    SR <= SR & ~F_E;
                end
                O_LDBSP, O_LDBUSP, O_STBSP, O_LDSSP, O_LDSUSP, O_STSSP: begin
                    logic [31:0] off;
                    logic half;
                    half = (op == O_LDSSP || op == O_LDSUSP || op == O_STSSP);
                    off  = half ? {27'd0, ir[3:0], 1'b0} : {28'd0, ir[3:0]};
                    if (e_set) off = ext4(ER, off);
                    m_addr  <= SP + off;
                    m_size  <= half ? 3'd2 : 3'd1;
                    m_we    <= (op == O_STBSP || op == O_STSSP);
                    m_wdata <= R[ir[6:4]];
                    m_ret   <= (op == O_STBSP || op == O_STSSP) ? RET_STORE : RET_LOAD;
                    ld_signed <= (op == O_LDBSP || op == O_LDSSP);
                    ld_rd   <= ir[6:4];
                    SR      <= SR & ~F_E;
                    st      <= S_MEM;
                end
                O_EXTB, O_EXTS: begin
                    if (ir[3]) illegal <= 1'b1;
                    else begin
                        logic [31:0] r;
                        r = (op == O_EXTB) ? {{24{R[ir[2:0]][7]}}, R[ir[2:0]][7:0]} : {{16{R[ir[2:0]][15]}}, R[ir[2:0]][15:0]};
                        R[ir[2:0]] <= r;
                        SR <= logic_sr(SR, r, 1'b1);
                    end
                end
                O_JR: begin
                    if (ir[3]) illegal <= 1'b1;
                    else begin
                        npc <= R[ir[2:0]];
                        SR  <= SR & ~F_E;
                    end
                end
                O_CALLR: begin
                    if (ir[3]) illegal <= 1'b1;
                    else begin
                        npc     <= R[ir[2:0]];
                        SP      <= SP - 32'd4;
                        m_addr  <= SP - 32'd4;
                        m_size  <= 3'd4;
                        m_we    <= 1'b1;
                        m_wdata <= PC + 32'd2;
                        m_ret   <= RET_CALL;
                        SR      <= SR & ~F_E;
                        st      <= S_MEM;
                    end
                end
                O_SET: SR <= SR | (32'd1 << ir[3:0]);
                O_CLR: SR <= SR & ~(32'd1 << ir[3:0]);
                O_SWI: begin
                    if (SR[13]) begin
                        // push PC (of the SWI itself, as MAME), push SR, clear ENI/E/M, PC = vector 0x10+n
                        vec     <= {4'h1, ir[3:0]};
                        SP      <= SP - 32'd4;
                        m_addr  <= SP - 32'd4;
                        m_size  <= 3'd4;
                        m_we    <= 1'b1;
                        m_wdata <= PC;
                        m_ret   <= RET_SWI1;
                        st      <= S_MEM;
                    end
                end
                O_HALT, O_MVTC, O_MVFC: ;
                O_ASR, O_LSR, O_ASL: begin
                    logic [33:0] t;
                    logic [4:0] by;
                    logic [1:0] kind;
                    by   = ir[10] ? R[ir[7:5]][4:0] : ir[9:5];
                    kind = (op == O_ASR) ? 2'd0 : (op == O_LSR) ? 2'd1 : 2'd2;
                    t    = shifter(kind, R[f_d0], by);
                    R[f_d0] <= t[31:0];
                    SR <= arith_sr(SR, t[31:0], t[33], 1'b0) & ~F_E;
                end
                default: illegal <= 1'b1;
                endcase
            end

            S_MUL: begin
                if (mul_cnt != 2'd0) mul_cnt <= mul_cnt - 2'd1;
                else begin
                    R[f_d0] <= mul_p[31:0];
                    SR      <= (mul_p[63:32] != 32'd0) ? ((SR | F_V) & ~F_E) : (SR & ~(F_V | F_E));
                    st      <= S_DONE;
                end
            end

            // ---------------------------------------------------------- PUSH / POP register lists
            S_STACK: begin
                if (op == O_PUSH) begin
                    if (stk_mask[stk_i]) begin
                        logic [31:0] v;
                        case (stk_i)
                            4'd10: v = PC;
                            4'd9:  v = SR;
                            4'd8:  v = ER;
                            default: v = R[stk_i[2:0]];
                        endcase
                        SP      <= SP - 32'd4;
                        m_addr  <= SP - 32'd4;
                        m_size  <= 3'd4;
                        m_we    <= 1'b1;
                        m_wdata <= v;
                        m_ret   <= RET_PUSH;
                        st      <= S_MEM;
                    end else if (stk_i == 4'd0) st <= S_DONE;
                    else stk_i <= stk_i - 4'd1;
                end else begin
                    if (stk_mask[stk_i]) begin
                        m_addr <= SP;
                        m_size <= 3'd4;
                        m_we   <= 1'b0;
                        m_ret  <= RET_POP;
                        st     <= S_MEM;
                    end else if (stk_i == 4'd10) st <= S_DONE;
                    else stk_i <= stk_i + 4'd1;
                end
            end

            // ---------------------------------------------------------- memory micro-sequence
            S_MEM: begin
                logic aligned;
                aligned = (m_size == 3'd1) || (m_size == 3'd2 && !m_addr[0]) || (m_size == 3'd4 && m_addr[1:0] == 2'd0);
                m_split <= !aligned;
                m_idx   <= 2'd0;
                m_rdata <= 32'd0;
                d_req   <= 1'b1;
                d_we    <= m_we;
                if (aligned) begin
                    d_addr  <= m_addr;
                    d_be    <= be_of(m_addr[1:0], m_size);
                    d_wdata <= m_wdata << {m_addr[1:0], 3'b000};
                end else begin
                    d_addr  <= m_addr;
                    d_be    <= be_of(m_addr[1:0], 3'd1);
                    d_wdata <= {24'd0, m_wdata[7:0]} << {m_addr[1:0], 3'b000};
                end
                st <= S_MEMW;
            end
            S_MEMW: begin
                if (d_ack) begin
                    logic [31:0] lanes;
                    lanes = d_rdata >> {d_addr[1:0], 3'b000};
                    if (!m_split) begin
                        d_req <= 1'b0;
                        case (m_size)
                            3'd1: m_rdata <= {24'd0, lanes[7:0]};
                            3'd2: m_rdata <= {16'd0, lanes[15:0]};
                            default: m_rdata <= d_rdata;
                        endcase
                        st <= S_LOADWB;
                    end else begin
                        logic [31:0] acc;
                        logic [31:0] na;
                        acc = m_rdata | ({24'd0, lanes[7:0]} << {m_idx, 3'b000});
                        m_rdata <= acc;
                        if ({1'b0, m_idx} == m_size - 3'd1) begin
                            d_req <= 1'b0;
                            st    <= S_LOADWB;
                        end else begin
                            na = m_addr + {30'd0, m_idx} + 32'd1;
                            m_idx   <= m_idx + 2'd1;
                            d_addr  <= na;
                            d_be    <= be_of(na[1:0], 3'd1);
                            d_wdata <= {24'd0, m_wdata[{m_idx + 2'd1, 3'b000} +: 8]} << {na[1:0], 3'b000};
                        end
                    end
                end
            end
            // continuation after a memory access (m_rdata valid for reads)
            S_LOADWB: begin
                case (m_ret)
                RET_LOAD: begin
                    logic [31:0] v;
                    case (m_size)
                        3'd1: v = ld_signed ? {{24{m_rdata[7]}}, m_rdata[7:0]} : {24'd0, m_rdata[7:0]};
                        3'd2: v = ld_signed ? {{16{m_rdata[15]}}, m_rdata[15:0]} : {16'd0, m_rdata[15:0]};
                        default: v = m_rdata;
                    endcase
                    R[ld_rd] <= v;
                    st <= S_DONE;
                end
                RET_STORE, RET_CALL: st <= S_DONE;
                RET_PUSH: begin
                    if (stk_i == 4'd0) st <= S_DONE;
                    else begin stk_i <= stk_i - 4'd1; st <= S_STACK; end
                end
                RET_POP: begin
                    SP <= SP + 32'd4;
                    case (stk_i)
                        4'd10: npc <= m_rdata;
                        4'd9:  SR  <= m_rdata;
                        4'd8:  ER  <= m_rdata;
                        default: R[stk_i[2:0]] <= m_rdata;
                    endcase
                    if (stk_i == 4'd10) st <= S_DONE;
                    else begin stk_i <= stk_i + 4'd1; st <= S_STACK; end
                end
                RET_SWI1: begin   // PC pushed; push SR
                    SP      <= SP - 32'd4;
                    m_addr  <= SP - 32'd4;
                    m_wdata <= SR;
                    m_we    <= 1'b1;
                    m_ret   <= RET_SWI2;
                    st      <= S_MEM;
                end
                RET_SWI2, RET_IRQ2: begin   // SR pushed; clear flags, read vector
                    SR     <= SR & ~(F_ENI | F_E | F_M | ((m_ret == RET_IRQ2 && is_nmi) ? F_NMI : 32'd0));
                    m_addr <= {22'd0, vec, 2'b00};
                    m_size <= 3'd4;
                    m_we   <= 1'b0;
                    m_ret  <= RET_VEC;
                    st     <= S_MEM;
                end
                RET_VEC: begin
                    if (took_irq) begin
                        PC <= m_rdata;       // interrupt entry ends the instruction
                        st <= S_IRQ2;
                    end else begin
                        npc <= m_rdata;      // SWI: PC = vector (MAME: -2 then +2)
                        st  <= S_DONE;
                    end
                end
                RET_IRQ1: begin   // PC pushed; push SR
                    SP      <= SP - 32'd4;
                    m_addr  <= SP - 32'd4;
                    m_wdata <= SR;
                    m_we    <= 1'b1;
                    m_ret   <= RET_IRQ2;
                    st      <= S_MEM;
                end
                RET_RESET: begin
                    PC <= m_rdata;
                    st <= S_FETCH;
                end
                default: st <= S_DONE;
                endcase
            end

            // ---------------------------------------------------------- end of instruction, interrupt check
            S_DONE: begin
                PC <= npc;
                if (nmi_pend) begin
                    nmi_pend <= 1'b0;
                    took_irq <= 1'b1;
                    is_nmi   <= 1'b1;
                    vec      <= 8'd1;
                    st       <= S_IRQ0;
                end else if (irq && SR[13]) begin
                    took_irq <= 1'b1;
                    is_nmi   <= 1'b0;
                    vec      <= SR[12] ? irq_vector : 8'd2;
                    iack     <= SR[12];
                    st       <= S_IRQ0;
                end else begin
                    retire       <= 1'b1;
                    dbg_pc       <= PC;
                    dbg_opcode   <= ir;
                    dbg_took_irq <= 1'b0;
                    st           <= S_FETCH;
                end
            end
            S_IRQ0: begin   // push PC (next)
                SP      <= SP - 32'd4;
                m_addr  <= SP - 32'd4;
                m_size  <= 3'd4;
                m_we    <= 1'b1;
                m_wdata <= PC;
                m_ret   <= RET_IRQ1;
                st      <= S_MEM;
            end
            S_IRQ2: begin
                retire       <= 1'b1;
                dbg_pc       <= dbg_pc_hold;
                dbg_opcode   <= ir;
                dbg_took_irq <= 1'b1;
                st           <= S_FETCH;
            end
            default: st <= S_FETCH;
            endcase
        end
    end

    always @(posedge clk) if (st == S_DECODE) dbg_pc_hold <= PC;

endmodule
