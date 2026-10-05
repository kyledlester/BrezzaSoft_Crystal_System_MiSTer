// BrezzaSoft Crystal System MiSTer core -- open-row, multi-client SDRAM controller (x16, CL2, BL1).
// Copyright (C) 2026 Kyle Lester. SPDX-License-Identifier: GPL-3.0-or-later
//
// Design (docs/SDRAM_BANDWIDTH.md):
// * Burst length 1: every READ/WRITE moves one 16-bit word, so consecutive column commands to open rows stream
//   at one word per clock and a "burst" is just a run of column commands. With BL1 the read DQM latency only
//   concerns the READ cycle itself, whose A[12:11] are always 0 -- so the controller is also correct on boards
//   that tie DQM to A[12:11] (the core drives {DQMH,DQML} = A[12:11], as the author's NB-1/NB-2 controllers).
// * Rows stay open (no auto-precharge). Each bank remembers its row; a client that activated a row or issued a
//   column command and still has words left owns the bank, so others cannot precharge it under its feet.
// * Each cycle the highest-priority client (index 0 first) that can issue *any* command (column, PRE or ACT)
//   gets the command slot, so clients on different banks overlap their ACT/PRE/column phases.
// * Timing closure: everything the selection needs is a register. Per-bank "timing satisfied" flags are computed
//   from the next counter values; per-client row-hit / row-miss / owner flags are recomputed every clock from the
//   current state and are only trusted when `fresh` (nothing that could change them happened in the previous
//   clock: no ACT/PRE/REF on that bank, no new request or row-crossing column for that client). A stale flag
//   just delays a command by one clock; it can never issue a wrong one.
// * Pin timing exactly as the vendored/NB-2 controllers: commands registered on clk (dedicated output
//   registers); SDRAM_CLK = clk inverted (altddio_out, outside); the word of a READ registered on edge e is sampled
//   from DQ on edge e+3 and presented (rvalid) on edge e+4.
// Timing at 85.909 MHz (11.64 ns): tRCD 2, tRP 2, tRAS 4, tRC 6, tRRD 2, tWR 2, tRFC 7, CL 2; read->write bus
// turnaround 4 clocks; refresh every REFRESH_CYCLES (64 ms / 8192 rows).
module crystal_sdram #(
    parameter integer NC = 6,                    // clients (<= 8)
    parameter [9:0] REFRESH_CYCLES = 10'd650,
    parameter [15:0] STARTUP_CYCLES = 16'd10000  // >= 100 us
) (
    input  wire              clk,
    input  wire              init,              // synchronous (re)initialisation

    // clients: request level held until done; parameters are sampled when accepted
    input  wire [NC-1:0]     c_req,
    input  wire [NC-1:0]     c_we,
    input  wire [NC*24-1:0]  c_addr,            // word address [24:1] of the first word
    input  wire [NC*6-1:0]   c_len,             // words, 1..32
    input  wire [NC*16-1:0]  c_wdata,           // current write word (advance on c_wnext)
    input  wire [NC*2-1:0]   c_wbe,             // current write byte enables ([1] = DQ15..8)
    output wire [NC-1:0]     c_wnext,           // the current write word is issued on this edge (advance)
    output reg  [NC-1:0]     c_rvalid,          // a read word for this client is on rdata
    output reg  [15:0]       rdata,
    output reg  [NC-1:0]     c_done,            // pulse: request completed (last write issued / last read word delivered)

    output reg               ready,

    // SDRAM pins (DQ split for the tri-state at the top)
    output reg  [15:0]       dq_o,
    output reg               dq_oe,
    input  wire [15:0]       dq_i,
    output reg  [12:0]       sd_a,
    output reg   [1:0]       sd_ba,
    output wire              sd_ncs,
    output reg               sd_nras,
    output reg               sd_ncas,
    output reg               sd_nwe,
    output wire              sd_cke
);
    localparam [2:0] CMD_NOP = 3'b111, CMD_ACT = 3'b011, CMD_RD = 3'b101, CMD_WR = 3'b100,
                     CMD_PRE = 3'b010, CMD_REF = 3'b001, CMD_MRS = 3'b000;
    localparam integer T_RCD = 2, T_RP = 2, T_RAS = 4, T_RC = 6, T_RRD = 2, T_WR = 2, T_RFC = 7, T_RW = 4;
    // mode: write burst = programmed (BL1), CL2, sequential, BL1
    localparam [12:0] MODE = 13'b000_0_00_010_0_000;

    assign sd_ncs = 1'b0;
    assign sd_cke = 1'b1;

    // ------------------------------------------------------------------ bank state
    reg        b_open [0:3];
    reg [12:0] b_row  [0:3];
    reg  [3:0] b_tact [0:3];     // clocks since ACT (saturating)
    reg  [3:0] b_tpre [0:3];     // clocks since PRE
    reg  [3:0] b_twr  [0:3];     // clocks since WRITE
    reg  [3:0] b_trd  [0:3];     // clocks since READ
    reg        b_own_v[0:3];
    reg  [2:0] b_own  [0:3];
    reg  [3:0] t_act_any, t_rd_any;
    // registered timing flags (true when the rule is satisfied in the current clock)
    reg  [3:0] f_rcd, f_ras, f_rc, f_rp, f_wr, f_rd1;
    reg        f_rrd, f_rw;
    reg  [3:0] b_cmd_last;       // bank received ACT/PRE in the previous clock

    // ------------------------------------------------------------------ client state
    reg  [NC-1:0] cl_act;        // accepted, words remain to issue
    reg  [NC-1:0] cl_we;
    reg  [23:0]   cl_addr [0:NC-1];
    reg   [5:0]   cl_left [0:NC-1];   // words left to issue
    reg   [5:0]   cl_rpend[0:NC-1];   // read words still to come back
    // registered per-client flags (valid when cl_fresh)
    reg  [NC-1:0] cl_hit, cl_miss, cl_closed, cl_owner_ok, cl_fresh;

    // read return pipeline: client id per stage (valid bit + id)
    reg  [3:0] rp_v;
    reg  [2:0] rp_c [0:3];
    reg [15:0] dq_q;

    // ------------------------------------------------------------------ init / refresh
    reg [15:0] init_cnt;
    reg [10:0] ref_cnt;
    reg        ref_pend;
    reg  [3:0] ref_wait;
    reg        ref_cmd_last;     // PREA/REF in the previous clock

    integer i, c;
    localparam [3:0] SAT = 4'd15;

    // ------------------------------------------------------------------ candidate selection (combinational, shallow)
    reg        sel_v;
    reg  [2:0] sel_c;
    reg  [2:0] sel_cmd;
    reg        any_open, prea_ok;

    always @* begin
        sel_v = 1'b0; sel_c = 3'd0; sel_cmd = CMD_NOP;
        any_open = 1'b0;
        prea_ok  = 1'b1;
        for (i = 0; i < 4; i++) begin
            if (b_open[i]) any_open = 1'b1;
            if (b_open[i] && !(f_ras[i] && f_wr[i] && f_rd1[i])) prea_ok = 1'b0;
        end
        for (c = NC - 1; c >= 0; c--) begin
            logic [1:0] bk;
            logic ok_col, ok_pre, ok_act;
            bk = cl_addr[c][23:22];
            ok_col = cl_hit[c] && f_rcd[bk] && (cl_we[c] ? f_rw : 1'b1);
            ok_pre = cl_miss[c] && f_ras[bk] && f_wr[bk] && f_rd1[bk];
            ok_act = cl_closed[c] && f_rp[bk] && f_rrd && f_rc[bk];
            if (cl_act[c] && cl_fresh[c] && cl_owner_ok[c] && (ok_col || ok_pre || ok_act)) begin
                sel_v = 1'b1; sel_c = c[2:0];
                sel_cmd = ok_col ? (cl_we[c] ? CMD_WR : CMD_RD) : (ok_pre ? CMD_PRE : CMD_ACT);
            end
        end
    end

    wire issue    = ready && !init && !ref_pend && ref_wait == 4'd0 && sel_v;
    wire issue_wr = issue && sel_cmd == CMD_WR;
    assign c_wnext = issue_wr ? (NC'(1) << sel_c) : '0;

    wire [1:0]  s_bank = cl_addr[sel_c][23:22];
    wire [12:0] s_row  = cl_addr[sel_c][21:9];
    wire [8:0]  s_col  = cl_addr[sel_c][8:0];

    always @(posedge clk) begin
        logic [2:0] cmd;
        logic [3:0] bcmd;
        logic       refcmd;
        cmd      = CMD_NOP;
        bcmd     = 4'd0;
        refcmd   = 1'b0;
        dq_oe    <= 1'b0;
        c_rvalid <= '0;
        c_done   <= '0;
        dq_q     <= dq_i;

        // timers (saturating) and the registered "rule satisfied" flags for the next clock
        for (i = 0; i < 4; i++) begin
            if (b_tact[i] != SAT) b_tact[i] <= b_tact[i] + 4'd1;
            if (b_tpre[i] != SAT) b_tpre[i] <= b_tpre[i] + 4'd1;
            if (b_twr[i]  != SAT) b_twr[i]  <= b_twr[i]  + 4'd1;
            if (b_trd[i]  != SAT) b_trd[i]  <= b_trd[i]  + 4'd1;
            f_rcd[i] <= b_tact[i] + 4'd1 >= T_RCD || b_tact[i] == SAT;
            f_ras[i] <= b_tact[i] + 4'd1 >= T_RAS || b_tact[i] == SAT;
            f_rc[i]  <= b_tact[i] + 4'd1 >= T_RC  || b_tact[i] == SAT;
            f_rp[i]  <= b_tpre[i] + 4'd1 >= T_RP  || b_tpre[i] == SAT;
            f_wr[i]  <= b_twr[i]  + 4'd1 >= T_WR  || b_twr[i]  == SAT;
            f_rd1[i] <= 1'b1;
        end
        if (t_act_any != SAT) t_act_any <= t_act_any + 4'd1;
        if (t_rd_any  != SAT) t_rd_any  <= t_rd_any  + 4'd1;
        f_rrd <= t_act_any + 4'd1 >= T_RRD || t_act_any == SAT;
        f_rw  <= t_rd_any  + 4'd1 >= T_RW  || t_rd_any  == SAT;

        // read return
        rp_v <= {rp_v[2:0], 1'b0};
        for (i = 3; i > 0; i--) rp_c[i] <= rp_c[i-1];
        if (rp_v[3]) begin
            rdata <= dq_q;
            c_rvalid[rp_c[3]] <= 1'b1;
            cl_rpend[rp_c[3]] <= cl_rpend[rp_c[3]] - 6'd1;
            if (cl_rpend[rp_c[3]] == 6'd1 && cl_left[rp_c[3]] == 6'd0) c_done[rp_c[3]] <= 1'b1;
        end

        // per-client flags from the current state (trusted next clock if fresh)
        for (c = 0; c < NC; c++) begin
            logic [1:0] bk;
            logic [12:0] rw;
            bk = cl_addr[c][23:22];
            rw = cl_addr[c][21:9];
            cl_hit[c]      <= b_open[bk] && b_row[bk] == rw;
            cl_miss[c]     <= b_open[bk] && b_row[bk] != rw;
            cl_closed[c]   <= !b_open[bk];
            cl_owner_ok[c] <= !b_own_v[bk] || b_own[bk] == c[2:0];
        end
        cl_fresh <= {NC{1'b1}};

        if (init) begin
            ready <= 1'b0;
            init_cnt <= 16'd0;
            cl_act <= '0;
            rp_v <= 4'd0;
            ref_pend <= 1'b0;
            ref_cnt <= 11'd0;
            ref_wait <= 4'd0;
            for (i = 0; i < 4; i++) begin
                b_open[i] <= 1'b0; b_own_v[i] <= 1'b0;
                b_tact[i] <= SAT; b_tpre[i] <= SAT; b_twr[i] <= SAT; b_trd[i] <= SAT;
            end
            t_act_any <= SAT; t_rd_any <= SAT;
            for (i = 0; i < NC; i++) begin cl_left[i] <= 6'd0; cl_rpend[i] <= 6'd0; end
            cl_fresh <= '0;
        end else if (!ready) begin
            // power-up: wait, PREA, 2 x REF, MRS
            init_cnt <= init_cnt + 16'd1;
            if (init_cnt == STARTUP_CYCLES) begin cmd = CMD_PRE; sd_a <= 13'h0400; end
            if (init_cnt == STARTUP_CYCLES + 4)  cmd = CMD_REF;
            if (init_cnt == STARTUP_CYCLES + 14) cmd = CMD_REF;
            if (init_cnt == STARTUP_CYCLES + 24) begin cmd = CMD_MRS; sd_a <= MODE; sd_ba <= 2'b00; end
            if (init_cnt == STARTUP_CYCLES + 30) ready <= 1'b1;
            cl_fresh <= '0;
        end else begin
            // ---------------- accept new requests (their flags are stale for one clock)
            for (i = 0; i < NC; i++) begin
                if (c_req[i] && !cl_act[i] && cl_rpend[i] == 6'd0 && !c_done[i]) begin
                    cl_act[i]   <= 1'b1;
                    cl_we[i]    <= c_we[i];
                    cl_addr[i]  <= c_addr[i*24 +: 24];
                    cl_left[i]  <= c_len[i*6 +: 6];
                    cl_rpend[i] <= c_we[i] ? 6'd0 : c_len[i*6 +: 6];
                    cl_fresh[i] <= 1'b0;
                end
            end

            // ---------------- refresh
            ref_cnt <= ref_cnt + 11'd1;
            if (ref_cnt >= {1'b0, REFRESH_CYCLES}) ref_pend <= 1'b1;
            if (ref_wait != 4'd0) ref_wait <= ref_wait - 4'd1;

            if (ref_pend) begin
                if (ref_wait == 4'd0) begin
                    if (any_open) begin
                        if (prea_ok) begin
                            cmd = CMD_PRE;
                            sd_a <= 13'h0400;     // all banks
                            for (i = 0; i < 4; i++) begin
                                if (b_open[i]) b_tpre[i] <= 4'd0;
                                b_open[i] <= 1'b0;
                            end
                            ref_wait <= T_RP - 1;
                            refcmd = 1'b1;
                        end
                    end else begin
                        cmd = CMD_REF;
                        ref_pend <= 1'b0;
                        ref_cnt <= 11'd0;
                        ref_wait <= T_RFC - 1;
                        for (i = 0; i < 4; i++) b_tact[i] <= 4'd0;   // tRC-like wait before the next ACT
                        refcmd = 1'b1;
                    end
                end
            end else if (issue) begin
                sd_ba <= s_bank;
                case (sel_cmd)
                CMD_ACT: begin
                    cmd = CMD_ACT;
                    sd_a <= s_row;
                    b_open[s_bank] <= 1'b1;
                    b_row[s_bank]  <= s_row;
                    b_tact[s_bank] <= 4'd0;
                    t_act_any      <= 4'd0;
                    f_rcd[s_bank]  <= 1'b0;
                    f_ras[s_bank]  <= 1'b0;
                    f_rc[s_bank]   <= 1'b0;
                    f_rrd          <= 1'b0;
                    b_own_v[s_bank] <= 1'b1;
                    b_own[s_bank]   <= sel_c;
                    bcmd[s_bank] = 1'b1;
                end
                CMD_PRE: begin
                    cmd = CMD_PRE;
                    sd_a <= 13'h0000;
                    b_open[s_bank] <= 1'b0;
                    b_tpre[s_bank] <= 4'd0;
                    f_rp[s_bank]   <= 1'b0;
                    bcmd[s_bank] = 1'b1;
                end
                default: begin   // READ / WRITE
                    cmd = sel_cmd;
                    b_own_v[s_bank] <= (cl_left[sel_c] != 6'd1);
                    b_own[s_bank]   <= sel_c;
                    if (sel_cmd == CMD_WR) begin
                        sd_a   <= {~c_wbe[sel_c*2 +: 2], 2'b00, s_col};   // A12:11 = DQM (high = masked)
                        dq_o   <= c_wdata[sel_c*16 +: 16];
                        dq_oe  <= 1'b1;
                        b_twr[s_bank] <= 4'd0;
                        f_wr[s_bank]  <= 1'b0;
                        if (cl_left[sel_c] == 6'd1) c_done[sel_c] <= 1'b1;
                    end else begin
                        sd_a <= {4'b0000, s_col};
                        b_trd[s_bank] <= 4'd0;
                        t_rd_any <= 4'd0;
                        f_rw     <= 1'b0;
                        rp_v[0] <= 1'b1;
                        rp_c[0] <= sel_c;
                    end
                    cl_addr[sel_c] <= cl_addr[sel_c] + 24'd1;
                    cl_left[sel_c] <= cl_left[sel_c] - 6'd1;
                    if (cl_left[sel_c] == 6'd1) cl_act[sel_c] <= 1'b0;
                    // ownership of this bank may change: the *other* clients on it are stale next clock
                    for (c = 0; c < NC; c++)
                        if (c[2:0] != sel_c && cl_addr[c][23:22] == s_bank) cl_fresh[c] <= 1'b0;
                    if (s_col == 9'h1ff) cl_fresh[sel_c] <= 1'b0;   // next word is in another row
                end
                endcase
            end
            // flags of clients on a bank whose state changed are stale next clock
            for (c = 0; c < NC; c++)
                if (bcmd[cl_addr[c][23:22]] || refcmd) cl_fresh[c] <= 1'b0;
        end
        {sd_nras, sd_ncas, sd_nwe} <= cmd;
    end
endmodule
