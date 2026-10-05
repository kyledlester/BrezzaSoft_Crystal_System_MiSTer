// BrezzaSoft Crystal System MiSTer core -- VRender0 wavetable sample engine.
// Copyright (C) 2026 Kyle Lester. SPDX-License-Identifier: GPL-3.0-or-later
//
// Behaviour: MAME sound/vrender0.cpp render_audio() (c2334733), docs/VRENDER0_AUDIO.md. One stereo sample every
// 1944 clk_sys (sound clock = VR0/2, / 972 = 44191 Hz). For channels 0..MaxChn with Status and RS set, in order:
// read the channel words (vr0_sound_regs channel RAM), fetch one sample from frame or texture RAM, decode
// (u-law table, 8-bit, 16-bit), advance CurSAddr by DSAddr*div>>16, loop or stop (stop clears Status, may raise
// IntPend / IRQ 2 and -- as MAME -- ends the channel loop for this sample), apply EnvVol and the envelope stages,
// mix with the 7-bit L/R volumes. Dynamic words written back: CurSAddr, EnvVol/EnvStage (a CPU write to those
// words while the channel is being processed wins).
// Known approximation: EnvVol is kept as the 24-bit register image between samples (MAME keeps an s32); only
// envelopes that overflow 24 bits differ (KNOWN_ISSUES K5). crysking uses no envelope.
module vr0_sound #(
    parameter EXT_TICK = 0               // 1: samples are started by `tick_in` (verification)
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        tick_in,

    // register file
    output reg   [8:0] eng_addr,
    input  wire [15:0] eng_rdata,
    output reg         eng_we,
    output reg  [15:0] eng_wdata,
    input  wire [31:0] status,
    input  wire [31:0] int_mask,
    input  wire [31:0] int_pend,
    input  wire  [4:0] max_chan,
    input  wire  [7:0] chan_clk_num,
    input  wire [15:0] ctrl,
    output reg  [31:0] eng_status_clr,
    output reg  [31:0] eng_pend_set,
    output reg         irq,               // pulse: request VRender0 IRQ 2
    input  wire [31:0] touched,           // CPU wrote CurSAddr/EnvVol words of channel n since touch_clr
    output reg  [31:0] touch_clr,

    // SDRAM client (one-word reads)
    output reg         m_req,
    output reg  [23:0] m_addr,
    output reg   [5:0] m_len,
    input  wire        m_rvalid,
    input  wire [15:0] m_rdata,
    input  wire        m_done,

    output reg signed [15:0] out_l,
    output reg signed [15:0] out_r,
    output reg         out_strobe
);
    localparam [10:0] SAMPLE_CLKS = 11'd1944;

    // u-law table (Evoga), MAME ulaw_to_16
    function automatic [15:0] ulaw(input [7:0] v);
        logic [15:0] t [0:255];
        t = '{
        16'h8000,16'h8400,16'h8800,16'h8c00,16'h9000,16'h9400,16'h9800,16'h9c00,16'ha000,16'ha400,16'ha800,16'hac00,16'hb000,16'hb400,16'hb800,16'hbc00,
        16'h4000,16'h4400,16'h4800,16'h4c00,16'h5000,16'h5400,16'h5800,16'h5c00,16'h6000,16'h6400,16'h6800,16'h6c00,16'h7000,16'h7400,16'h7800,16'h7c00,
        16'hc000,16'hc200,16'hc400,16'hc600,16'hc800,16'hca00,16'hcc00,16'hce00,16'hd000,16'hd200,16'hd400,16'hd600,16'hd800,16'hda00,16'hdc00,16'hde00,
        16'h2000,16'h2200,16'h2400,16'h2600,16'h2800,16'h2a00,16'h2c00,16'h2e00,16'h3000,16'h3200,16'h3400,16'h3600,16'h3800,16'h3a00,16'h3c00,16'h3e00,
        16'he000,16'he100,16'he200,16'he300,16'he400,16'he500,16'he600,16'he700,16'he800,16'he900,16'hea00,16'heb00,16'hec00,16'hed00,16'hee00,16'hef00,
        16'h1000,16'h1100,16'h1200,16'h1300,16'h1400,16'h1500,16'h1600,16'h1700,16'h1800,16'h1900,16'h1a00,16'h1b00,16'h1c00,16'h1d00,16'h1e00,16'h1f00,
        16'hf000,16'hf080,16'hf100,16'hf180,16'hf200,16'hf280,16'hf300,16'hf380,16'hf400,16'hf480,16'hf500,16'hf580,16'hf600,16'hf680,16'hf700,16'hf780,
        16'h0800,16'h0880,16'h0900,16'h0980,16'h0a00,16'h0a80,16'h0b00,16'h0b80,16'h0c00,16'h0c80,16'h0d00,16'h0d80,16'h0e00,16'h0e80,16'h0f00,16'h0f80,
        16'hf800,16'hf840,16'hf880,16'hf8c0,16'hf900,16'hf940,16'hf980,16'hf9c0,16'hfa00,16'hfa40,16'hfa80,16'hfac0,16'hfb00,16'hfb40,16'hfb80,16'hfbc0,
        16'h0400,16'h0440,16'h0480,16'h04c0,16'h0500,16'h0540,16'h0580,16'h05c0,16'h0600,16'h0640,16'h0680,16'h06c0,16'h0700,16'h0740,16'h0780,16'h07c0,
        16'hfc00,16'hfc20,16'hfc40,16'hfc60,16'hfc80,16'hfca0,16'hfcc0,16'hfce0,16'hfd00,16'hfd20,16'hfd40,16'hfd60,16'hfd80,16'hfda0,16'hfdc0,16'hfde0,
        16'h0200,16'h0220,16'h0240,16'h0260,16'h0280,16'h02a0,16'h02c0,16'h02e0,16'h0300,16'h0320,16'h0340,16'h0360,16'h0380,16'h03a0,16'h03c0,16'h03e0,
        16'hfe00,16'hfe10,16'hfe20,16'hfe30,16'hfe40,16'hfe50,16'hfe60,16'hfe70,16'hfe80,16'hfe90,16'hfea0,16'hfeb0,16'hfec0,16'hfed0,16'hfee0,16'hfef0,
        16'h0100,16'h0110,16'h0120,16'h0130,16'h0140,16'h0150,16'h0160,16'h0170,16'h0180,16'h0190,16'h01a0,16'h01b0,16'h01c0,16'h01d0,16'h01e0,16'h01f0,
        16'h0000,16'h0008,16'h0010,16'h0018,16'h0020,16'h0028,16'h0030,16'h0038,16'h0040,16'h0048,16'h0050,16'h0058,16'h0060,16'h0068,16'h0070,16'h0078,
        16'hff80,16'hff88,16'hff90,16'hff98,16'hffa0,16'hffa8,16'hffb0,16'hffb8,16'hffc0,16'hffc8,16'hffd0,16'hffd8,16'hffe0,16'hffe8,16'hfff0,16'hfff8};
        return t[v];
    endfunction

    typedef enum logic [3:0] { E_IDLE, E_DIV, E_CH, E_RD, E_FETCH, E_FWAIT, E_ADV, E_ENV, E_MIX, E_WB, E_OUT } est_t;
    est_t st;

    reg  [10:0] tick;
    reg         due;
    // divider: div = 0x1E8000 / (clk+1) (MAME ((30 << 16) | 0x8000) / (num + 1)), or 0x10000 when num == 0
    reg  [20:0] div, dq, dr_n;
    reg  [21:0] drem;
    reg   [4:0] dcnt;
    reg   [8:0] dden;

    reg   [4:0] ch;
    reg  [15:0] w [0:15];
    reg   [4:0] rd_i;
    reg         rd_pending;
    reg signed [31:0] acc_l, acc_r;
    reg signed [31:0] smp;
    reg  [31:0] cur;
    reg signed [31:0] env;
    reg   [3:0] stage;
    reg   [1:0] lvl;
    reg         env_ph;               // envelope level: 0 = rate product, 1 = add / target compare
    reg signed [31:0] rate_q;
    reg         ended;

    wire [7:0]  modes  = w[5][14:8];
    wire [21:0] lbegin = {w[7][5:0], w[6]};
    wire [21:0] lend   = {w[9][5:0], w[8]};
    wire  [6:0] lvol   = w[7][14:8];
    wire  [6:0] rvol   = w[9][14:8];
    wire        use_tex = modes[6] && ctrl[5];

    function automatic signed [31:0] sext24(input [23:0] v);
        return {{8{v[23]}}, v};
    endfunction
    function automatic signed [31:0] env_rate(input integer l);
        logic [16:0] r;
        case (l)
            0: r = {w[14][7], w[10]};
            1: r = {w[14][15], w[11]};
            2: r = {w[15][7], w[12]};
            default: r = {w[15][15], w[13]};
        endcase
        return {{15{r[16]}}, r};
    endfunction
    function automatic [6:0] env_target(input integer l);
        case (l)
            0: return w[14][6:0];
            1: return w[14][14:8];
            2: return w[15][6:0];
            default: return w[15][14:8];
        endcase
    endfunction

    always @(posedge clk) begin
        eng_we         <= 1'b0;
        eng_status_clr <= 32'd0;
        eng_pend_set   <= 32'd0;
        irq            <= 1'b0;
        touch_clr      <= 32'd0;
        out_strobe     <= 1'b0;
        if (!rst_n) begin
            st <= E_IDLE; tick <= 11'd0; due <= 1'b0; m_req <= 1'b0;
            out_l <= 16'sd0; out_r <= 16'sd0; div <= 21'h10000;
        end else begin
            if (EXT_TICK) begin
                if (tick_in) due <= 1'b1;
            end else if (tick == SAMPLE_CLKS - 1) begin tick <= 11'd0; due <= 1'b1; end
            else tick <= tick + 11'd1;

            case (st)
            E_IDLE: if (due && !(EXT_TICK && tick_in)) begin
                due <= 1'b0;
                acc_l <= 32'sd0; acc_r <= 32'sd0;
                // start the divider
                dden <= {1'b0, chan_clk_num} + 9'd1;
                drem <= 22'd0;
                dq   <= 21'd0;
                dcnt <= 5'd20;
                st   <= E_DIV;
            end
            E_DIV: begin
                // restoring division of 0x1E8000 (21 bits) by dden, one quotient bit per clock (MSB first)
                logic [21:0] r;
                logic [20:0] n;
                n = 21'h1E8000;
                r = {drem[20:0], n[dcnt]};
                if (r >= {13'd0, dden}) begin drem <= r - {13'd0, dden}; dq <= {dq[19:0], 1'b1}; end
                else begin drem <= r; dq <= {dq[19:0], 1'b0}; end
                if (dcnt == 5'd0) begin
                    st <= E_CH;
                    ch <= 5'd0;
                end else dcnt <= dcnt - 5'd1;
            end
            E_CH: begin
                if (ch == 5'd0 && dcnt == 5'd0) div <= (chan_clk_num != 8'd0) ? dq : 21'h10000;
                dcnt <= 5'd31;
                if (!(status[ch] && ctrl[15])) begin
                    if (ch == max_chan) st <= E_OUT;
                    else ch <= ch + 5'd1;
                end else begin
                    touch_clr[ch] <= 1'b1;
                    rd_i <= 5'd0;
                    rd_pending <= 1'b0;
                    eng_addr <= {ch, 4'd0};
                    st <= E_RD;
                end
            end
            E_RD: begin
                // read the 16 channel words (one per clock, data one clock later)
                if (rd_pending) w[rd_i[3:0] - 4'd1] <= eng_rdata;
                rd_pending <= 1'b1;
                if (rd_i == 5'd16) st <= E_FETCH;
                else begin
                    eng_addr <= {ch, rd_i[3:0] + 4'd1};
                    rd_i <= rd_i + 5'd1;
                end
            end
            E_FETCH: begin
                logic [22:0] ba;
                cur   <= {w[1], w[0]};
                env   <= sext24({w[3][7:0], w[2]});
                stage <= w[3][11:8];
                ba = {w[1], w[0]} >> 9;
                if (!modes[4] && !modes[5]) ba[0] = 1'b0;       // 16-bit samples: word aligned
                m_req  <= 1'b1;
                m_addr <= (use_tex ? 24'h400000 : 24'h800000) + {2'd0, ba[22:1]};
                m_len  <= 6'd1;
                st <= E_FWAIT;
            end
            E_FWAIT: begin
                if (m_rvalid) begin
                    logic [7:0] b;
                    logic [22:0] ba;
                    logic [15:0] u;
                    ba = cur >> 9;
                    b = ba[0] ? m_rdata[15:8] : m_rdata[7:0];
                    u = ulaw(b);
                    if (modes[4])      smp <= {{16{u[15]}}, u};
                    else if (modes[5]) smp <= {{16{b[7]}}, b, 8'd0};
                    else               smp <= {{16{m_rdata[15]}}, m_rdata};
                end
                if (m_done) begin m_req <= 1'b0; st <= E_ADV; end
            end
            E_ADV: begin
                // MAME: cur_saddr += (ds_addr * div) >> 16 in C int arithmetic (32-bit wrap, arithmetic shift)
                logic [36:0] stepw;
                logic signed [31:0] step;
                logic [31:0] nc;
                stepw = {21'd0, w[4]} * {16'd0, div};
                step = $signed(stepw[31:0]) >>> 16;
                nc = cur + step;
                ended <= 1'b0;
                if (nc >= {lend, 10'd0}) begin
                    if (modes[0]) cur <= (nc - {lend, 10'd0}) + {lbegin, 10'd0};
                    else begin
                        cur <= nc;
                        ended <= 1'b1;
                        eng_status_clr[ch] <= 1'b1;
                        if (int_mask != 32'hffffffff) begin
                            logic [31:0] np;
                            np = int_pend | (~int_mask & (32'd1 << ch));
                            eng_pend_set <= ~int_mask & (32'd1 << ch);
                            if (np != 32'd0 && np != int_pend) irq <= 1'b1;
                        end
                    end
                end else
                    cur <= nc;
                lvl <= 2'd0;
                env_ph <= 1'b0;
                st <= E_ENV;
            end
            E_ENV: begin
                if (ended) begin
                    // MAME: the voice ended -> 'break' out of the channel loop for this sample (cur written back)
                    st <= E_WB;
                end else begin
                    // volume (once) and the envelope stages, sequentially like MAME's level loop; each level
                    // takes two clocks (rate product, then add and target compare)
                    env_ph <= !env_ph;
                    if (!env_ph) begin
                        logic signed [63:0] p;
                        if (lvl == 2'd0) smp <= (smp * (env >>> 16)) >>> 8;
                        p = env_rate(lvl) * $signed({11'd0, div});
                        rate_q <= $signed(p[31:0]) >>> 16;
                    end else begin
                        if (modes[2] && stage[lvl]) begin
                            logic signed [31:0] ne;
                            ne = env + rate_q;
                            env <= ne;
                            if (rate_q > 0) begin
                                if (((ne >>> 16) & 32'h7f) >= {25'd0, env_target(lvl)}) stage <= stage << 1;
                            end else if (rate_q < 0) begin
                                if (((ne >>> 16) & 32'h7f) <= {25'd0, env_target(lvl)}) stage <= stage << 1;
                            end
                        end
                        if (lvl == 2'd3) st <= E_MIX;
                        lvl <= lvl + 2'd1;
                    end
                end
            end
            E_MIX: begin
                acc_l <= acc_l + ((smp * $signed({25'd0, lvol})) >>> 8);
                acc_r <= acc_r + ((smp * $signed({25'd0, rvol})) >>> 8);
                st <= E_WB;
            end
            E_WB: begin
                // write back CurSAddr (words 0,1) and EnvVol/EnvStage (words 2,3) unless the CPU touched them
                if (dcnt == 5'd31) begin
                    dcnt <= 5'd0;
                end else begin
                    if (!touched[ch]) begin
                        eng_we <= 1'b1;
                        eng_addr <= {ch, 2'b00, dcnt[1:0]};
                        case (dcnt[1:0])
                            2'd0: eng_wdata <= cur[15:0];
                            2'd1: eng_wdata <= cur[31:16];
                            2'd2: eng_wdata <= env[15:0];
                            default: eng_wdata <= {1'b0, 2'b11, w[3][12], stage, env[23:16]};
                        endcase
                    end
                    if (dcnt == 5'd3) begin
                        if (ended || ch == max_chan) st <= E_OUT;
                        else begin ch <= ch + 5'd1; st <= E_CH; end
                    end else dcnt <= dcnt + 5'd1;
                end
            end
            E_OUT: begin
                out_l <= (acc_l > 32'sd32767) ? 16'sd32767 : (acc_l < -32'sd32768) ? -16'sd32768 : acc_l[15:0];
                out_r <= (acc_r > 32'sd32767) ? 16'sd32767 : (acc_r < -32'sd32768) ? -16'sd32768 : acc_r[15:0];
                out_strobe <= 1'b1;
                st <= E_IDLE;
            end
            default: st <= E_IDLE;
            endcase
        end
    end
endmodule
