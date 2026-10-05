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
    output reg  [31:0] io_rdata,

    // engine access to channel words (address = channel*16 + word)
    input  wire  [8:0] eng_addr,
    output reg  [15:0] eng_rdata,
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
    // channel RAM, 16-bit words, MAME channel_t::read layout stored as the read-back value
    reg [15:0] chram [0:511];
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

    reg  [15:0] rd_lo, rd_hi;
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
                if (pend_hi_off < 12'h400) ;   // channel words handled in the RAM process
                else creg_w(pend_hi_off, pend_hi_d, pend_hi_m);
            end
            if (wr) begin
                if (io_be[1:0] != 2'b00 && off_lo >= 12'h400) creg_w(off_lo, io_wdata[15:0], io_be[1:0]);
                if (io_be[3:2] != 2'b00) begin
                    pend_hi     <= 1'b1;
                    pend_hi_off <= off_lo + 12'd2;
                    pend_hi_d   <= io_wdata[31:16];
                    pend_hi_m   <= io_be[3:2];
                end
            end
        end
    end

    // channel RAM: CPU writes (lane 0 now, lane 1 next cycle), engine port
    always @(posedge clk) begin
        logic [31:0] t;
        t = touched & ~touch_clr;
        if (wr && io_be[1:0] != 2'b00 && off_lo < 12'h400 && off_lo[4:3] == 2'b00) t[off_lo[9:5]] = 1'b1;
        if (pend_hi && pend_hi_off < 12'h400 && pend_hi_off[4:3] == 2'b00) t[pend_hi_off[9:5]] = 1'b1;
        touched <= rst_n ? t : 32'd0;
    end
    always @(posedge clk) begin
        if (wr && io_be[1:0] != 2'b00 && off_lo < 12'h400) begin
            logic [8:0] a;
            logic [15:0] mm, nv;
            a  = off_lo[9:1];
            mm = {{8{io_be[1]}}, {8{io_be[0]}}};
            nv = (chram[a] & ~mm) | (io_wdata[15:0] & mm);
            chram[a] <= wfix(a[3:0], nv);
        end else if (pend_hi && pend_hi_off < 12'h400) begin
            logic [8:0] a;
            logic [15:0] mm, nv;
            a  = pend_hi_off[9:1];
            mm = {{8{pend_hi_m[1]}}, {8{pend_hi_m[0]}}};
            nv = (chram[a] & ~mm) | (pend_hi_d & mm);
            chram[a] <= wfix(a[3:0], nv);
        end else if (eng_we)
            chram[eng_addr] <= eng_wdata;
        eng_rdata <= chram[eng_addr];
    end

    initial for (i = 0; i < 512; i++) chram[i] = (i % 16 == 3) ? 16'h7100 : 16'h0000;   // MAME defaults: ld = 1, env_stage = 1

    // CPU reads (registered)
    always @(posedge clk) begin
        if (io_sel && !io_we) begin
            rd_lo = (off_lo < 12'h400) ? chram[off_lo[9:1]] : creg_r(off_lo);
            rd_hi = (off_lo < 12'h400) ? chram[off_lo[9:1] + 9'd1] : creg_r(off_lo + 12'd2);
            io_rdata <= {io_be[3:2] != 2'b00 ? rd_hi : 16'd0, io_be[1:0] != 2'b00 ? rd_lo : 16'd0};
        end
    end
endmodule
