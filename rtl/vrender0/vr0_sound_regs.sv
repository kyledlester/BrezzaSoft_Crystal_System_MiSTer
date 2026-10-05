// BrezzaSoft Crystal System MiSTer core -- VRender0 sound engine register file.
// Copyright (C) 2026 Kyle Lester. SPDX-License-Identifier: GPL-3.0-or-later
//
// Behaviour: MAME sound/vrender0.cpp (c2334733), docs/VRENDER0_AUDIO.md. 16-bit handlers per lane at
// 0x04800000. Channel parameters live in a 32 x 16-word RAM (512 x 16) so the sample engine can read them in
// its time slot; the engine writes back the dynamic fields (CurSAddr, EnvVol, EnvStage) through port B.
// Read-back follows MAME bit for bit, including the `>> 4` lane shift of the 32-bit masks (KNOWN_ISSUES K6).
module vr0_sound_regs (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        io_sel,
    input  wire        io_we,
    input  wire [9:0]  io_addr,        // dword index within 0x04800000-0x04800FFF
    input  wire  [3:0] io_be,
    input  wire [31:0] io_wdata,
    output wire [31:0] io_rdata,       // valid two clocks after io_sel (board B_IOR)

    // engine access to channel words (address = channel*16 + word)
    input  wire  [8:0] eng_addr,
    output wire [15:0] eng_rdata,
    input  wire        eng_we,
    input  wire [15:0] eng_wdata,

    output reg  [31:0] status,
    output reg  [31:0] note_on,
    output reg  [31:0] int_mask,
    output reg  [31:0] int_pend,
    input  wire [31:0] eng_status_clr,  // engine: voices that ended
    input  wire [31:0] eng_pend_set,    // engine: interrupt pending bits to set
    output reg  [4:0]  max_chan,
    output reg  [7:0]  chan_clk_num,
    output reg  [15:0] ctrl,
    output wire        irq_clear,       // pulse when int_pend becomes 0 by a CPU write (informational)
    output reg  [31:0] touched,         // CPU wrote CurSAddr/EnvVol words (0-3) of channel n
    input  wire [31:0] touch_clr
);
    // Channel registers: 32 channels x 16 words stored as the MAME channel_t::read() image, in block RAM:
    // even and odd words in separate RAMs (a dword-aligned CPU access touches one of each), each split into
    // byte lanes; port A = CPU, port B = sample engine (and the reset-time default fill).
    reg [15:0] rev_factor, buf_addr;
    reg [15:0] buf_size [0:3];

    // CPU-side channel word read-modify-write uses the stored read-back image; the stored image already
    // has the MAME read masks applied (see wfix()).
    function automatic [15:0] wfix(input [3:0] w, input [15:0] d);
        case (w)
            4'd3:  return 16'h6000 | (d & 16'h1fff);      // LD b12, EnvStage b11:8, EnvVol 23:16
            4'd5:  return d & 16'h7f00;                   // Modes
            4'd7, 4'd9: return d & 16'h7f3f;              // vol b14:8, loop 21:16
            4'd14, 4'd15: return d;                       // targets + rate b16
            default: return d;
        endcase
    endfunction

    wire [11:0] off_lo = {io_addr, 2'b00};
    wire        wr = io_sel && io_we;
    assign irq_clear = 1'b0;

    integer i;

    function automatic [15:0] creg_r(input [11:0] off);
        case (off)
            12'h404: return status[15:0];
            12'h406: return status[19:4];      // MAME: m_status >> 4
            12'h408: return note_on[15:0];
            12'h40a: return note_on[19:4];
            12'h410: return {8'd0, rev_factor[7:0]};
            12'h412: return {9'd0, buf_addr[6:0]};
            12'h420: return {4'd0, buf_size[0][11:0]};
            12'h422: return {4'd0, buf_size[1][11:0]};
            12'h440: return {4'd0, buf_size[2][11:0]};
            12'h442: return {4'd0, buf_size[3][11:0]};
            12'h480: return int_mask[15:0];
            12'h482: return int_mask[19:4];
            12'h500: return int_pend[15:0];
            12'h502: return int_pend[19:4];
            12'h600: return {3'd0, max_chan, chan_clk_num};
            12'h602: return ctrl;
            default: return 16'd0;
        endcase
    endfunction

    // CPU writes are applied one lane per cycle through this small queue so the channel RAM stays single-port
    reg        pend_hi;
    reg [15:0] pend_hi_d;
    reg [1:0]  pend_hi_m;
    reg [11:0] pend_hi_off;

    task automatic creg_w(input [11:0] off, input [15:0] d, input [1:0] m);
        logic [15:0] mm;
        mm = {{8{m[1]}}, {8{m[0]}}};
        case (off)
            12'h404, 12'h406: if (d[15]) status <= (status | (32'd1 << d[4:0])) & ~eng_status_clr;
                              else status <= status & ~(32'd1 << d[4:0]) & ~eng_status_clr;
            12'h408, 12'h40a: if (d[15]) note_on <= note_on | (32'd1 << d[4:0]);
                              else note_on <= note_on & ~(32'd1 << d[4:0]);
            12'h410: if (m[0]) rev_factor <= {8'd0, d[7:0]};
            12'h412: if (m[0]) buf_addr <= {9'd0, d[6:0]};
            12'h420: buf_size[0] <= (buf_size[0] & ~mm) | (d & 16'h0fff & mm);
            12'h422: buf_size[1] <= (buf_size[1] & ~mm) | (d & 16'h0fff & mm);
            12'h440: buf_size[2] <= (buf_size[2] & ~mm) | (d & 16'h0fff & mm);
            12'h442: buf_size[3] <= (buf_size[3] & ~mm) | (d & 16'h0fff & mm);
            12'h480: int_mask <= (int_mask & ~{16'd0, mm}) | {16'd0, d & mm};
            12'h482: int_mask <= (int_mask & ~({16'd0, mm} << 4)) | ({16'd0, d & mm} << 4);
            12'h500: int_pend <= (int_pend | eng_pend_set) & ~{16'd0, d & mm};
            12'h502: int_pend <= (int_pend | eng_pend_set) & ~({16'd0, d & mm} << 4);
            12'h600: begin
                if (m[0]) chan_clk_num <= d[7:0];
                if (m[1]) max_chan <= d[12:8];
            end
            12'h602: ctrl <= (ctrl & ~mm) | (d & mm);
            default: ;
        endcase
    endtask

    always @(posedge clk) begin
        if (!rst_n) begin
            status <= 32'd0; note_on <= 32'd0; int_mask <= 32'd0; int_pend <= 32'd0;
            max_chan <= 5'd0; chan_clk_num <= 8'd0; ctrl <= 16'd0;
            rev_factor <= 16'd0; buf_addr <= 16'd0;
            for (i = 0; i < 4; i++) buf_size[i] <= 16'd0;
            pend_hi <= 1'b0;
        end else begin
            // engine side effects (overridden below by a CPU write to the same register in this cycle)
            status   <= status & ~eng_status_clr;
            int_pend <= int_pend | eng_pend_set;
            if (pend_hi) begin
                pend_hi <= 1'b0;
                creg_w(pend_hi_off, pend_hi_d, pend_hi_m);
            end
            if (wr) begin
                if (io_be[1:0] != 2'b00 && off_lo >= 12'h400) creg_w(off_lo, io_wdata[15:0], io_be[1:0]);
                if (io_be[3:2] != 2'b00 && off_lo >= 12'h400) begin
                    pend_hi     <= 1'b1;
                    pend_hi_off <= off_lo + 12'd2;
                    pend_hi_d   <= io_wdata[31:16];
                    pend_hi_m   <= io_be[3:2];
                end
            end
        end
    end

    // ------------------------------------------------------------------ channel RAM (block RAM)
    // reset-time fill with MAME's channel_t defaults (word 3 = 0x7100: ld = 1, env_stage = 1)
    reg  [9:0] init_i;
    wire       init_busy = !init_i[9];
    always @(posedge clk) begin
        if (!rst_n) init_i <= 10'd0;
        else if (init_busy) init_i <= init_i + 10'd1;
    end
    wire        ch_wr  = wr && off_lo < 12'h400;
    wire  [7:0] a_pair = io_addr[7:0];                     // {channel, word[3:1]}
    wire [15:0] a_even = wfix({a_pair[2:0], 1'b0}, io_wdata[15:0]);
    wire [15:0] a_odd  = wfix({a_pair[2:0], 1'b1}, io_wdata[31:16]);
    wire  [8:0] b_word = init_busy ? init_i[8:0] : eng_addr;
    wire [15:0] b_data = init_busy ? ((init_i[3:0] == 4'd3) ? 16'h7100 : 16'h0000) : eng_wdata;
    wire        b_we   = init_busy || eng_we;
    wire [15:0] qa_even, qa_odd, qb_even, qb_odd;
    crystal_tdpram #(.AW(8), .DW(8)) r_el (.clk(clk),
        .a_we(ch_wr && io_be[0]), .a_addr(a_pair), .a_wdata(a_even[7:0]),  .a_rdata(qa_even[7:0]),
        .b_we(b_we && !b_word[0]), .b_addr(b_word[8:1]), .b_wdata(b_data[7:0]), .b_rdata(qb_even[7:0]));
    crystal_tdpram #(.AW(8), .DW(8)) r_eh (.clk(clk),
        .a_we(ch_wr && io_be[1]), .a_addr(a_pair), .a_wdata(a_even[15:8]), .a_rdata(qa_even[15:8]),
        .b_we(b_we && !b_word[0]), .b_addr(b_word[8:1]), .b_wdata(b_data[15:8]), .b_rdata(qb_even[15:8]));
    crystal_tdpram #(.AW(8), .DW(8)) r_ol (.clk(clk),
        .a_we(ch_wr && io_be[2]), .a_addr(a_pair), .a_wdata(a_odd[7:0]),   .a_rdata(qa_odd[7:0]),
        .b_we(b_we && b_word[0]), .b_addr(b_word[8:1]), .b_wdata(b_data[7:0]), .b_rdata(qb_odd[7:0]));
    crystal_tdpram #(.AW(8), .DW(8)) r_oh (.clk(clk),
        .a_we(ch_wr && io_be[3]), .a_addr(a_pair), .a_wdata(a_odd[15:8]),  .a_rdata(qa_odd[15:8]),
        .b_we(b_we && b_word[0]), .b_addr(b_word[8:1]), .b_wdata(b_data[15:8]), .b_rdata(qb_odd[15:8]));
    reg b_par;
    always @(posedge clk) b_par <= eng_addr[0];
    assign eng_rdata = b_par ? qb_odd : qb_even;

    // touched: CPU wrote CurSAddr/EnvVol (words 0-3) of a channel
    always @(posedge clk) begin
        logic [31:0] t;
        t = touched & ~touch_clr;
        if (ch_wr && off_lo[4:3] == 2'b00) t[off_lo[9:5]] = 1'b1;
        touched <= rst_n ? t : 32'd0;
    end

    // ------------------------------------------------------------------ CPU reads
    // channel words come straight from the RAM outputs (address presented while io_sel is high); the control
    // registers are registered at the same time
    reg        rd_ch;
    reg  [3:0] rd_be;
    reg [31:0] rd_ctl;
    always @(posedge clk) begin
        if (io_sel && !io_we) begin
            rd_ch  <= off_lo < 12'h400;
            rd_be  <= io_be;
            rd_ctl <= {creg_r(off_lo + 12'd2), creg_r(off_lo)};
        end
    end
    reg        rd_ch_q;
    reg  [3:0] rd_be_q;
    reg [31:0] rd_ctl_q, rd_ram_q;
    always @(posedge clk) begin
        rd_ch_q  <= rd_ch;
        rd_be_q  <= rd_be;
        rd_ctl_q <= rd_ctl;
    end
    wire [31:0] rd_v = rd_ch ? {qa_odd, qa_even} : rd_ctl;
    assign io_rdata = {rd_be[3:2] != 2'b00 ? rd_v[31:16] : 16'd0, rd_be[1:0] != 2'b00 ? rd_v[15:0] : 16'd0};
endmodule
