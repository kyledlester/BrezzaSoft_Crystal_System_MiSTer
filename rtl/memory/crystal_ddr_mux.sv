// BrezzaSoft Crystal System MiSTer core -- DDR3 port shared by the flash store and screen_rotate.
// Copyright (C) 2026 Kyle Lester. SPDX-License-Identifier: GPL-3.0-or-later
//
// The flash store (crystal_flash_ddr: 8-beat read bursts, loader writes) owns the DDR3 port in normal use. The
// framework's screen_rotate (Orientation Rotate CW / CCW, HDMI only) writes one 32-bit pixel per pixel clock
// into its framebuffer at 0x24000000 as single-beat writes and never looks at DDRAM_BUSY. Its writes are
// queued here (FIFO) and issued between flash commands: the flash store sees BUSY while a queued write is on
// the bus, so its own commands simply wait one or a few clocks, and flash commands go first whenever both
// are ready. Read data (only the flash store reads) passes straight through: writes return nothing.
// Rate: one pixel per 12 clk_sys at most; the queue drains much faster than it fills. A full queue drops the
// pixel (counted; it would only blemish one HDMI frame).
module crystal_ddr_mux #(
    parameter integer AW = 9
) (
    input  wire        clk,

    // flash store (master 0)
    input  wire  [7:0] f_burstcnt,
    input  wire [28:0] f_addr,
    input  wire [63:0] f_din,
    input  wire  [7:0] f_be,
    input  wire        f_we,
    input  wire        f_rd,
    output wire        f_busy,

    // screen_rotate (master 1: single-beat writes, no wait)
    input  wire [28:0] r_addr,
    input  wire [63:0] r_din,
    input  wire  [7:0] r_be,
    input  wire        r_we,

    // DDR3 port
    input  wire        DDRAM_BUSY,
    output wire  [7:0] DDRAM_BURSTCNT,
    output wire [28:0] DDRAM_ADDR,
    output wire [63:0] DDRAM_DIN,
    output wire  [7:0] DDRAM_BE,
    output wire        DDRAM_WE,
    output wire        DDRAM_RD,

    output reg  [15:0] drops
);
    // entry: {addr[28:0], half (be = F0), data[31:0]} -- screen_rotate duplicates its pixel in both halves
    localparam integer EW = 29 + 1 + 32;
    reg  [AW-1:0] wr_ptr = '0, rd_ptr = '0;
    reg  [AW:0]   cnt = '0;
    reg  [1:0]    settle = 2'd0;
    reg           own = 1'b0;                 // the queue's write is on the bus
    wire [EW-1:0] head;
    initial drops = 16'd0;

    wire push = r_we && cnt < (1 << AW);
    crystal_sdpram #(.AW(AW), .DW(EW)) q (
        .clk(clk), .we(push), .waddr(wr_ptr), .wdata({r_addr, r_be[4], r_be[4] ? r_din[63:32] : r_din[31:0]}),
        .raddr(rd_ptr), .rdata(head)
    );
    wire head_ok = cnt != 0 && settle == 2'd0;
    wire f_cmd   = f_we || f_rd;
    wire pop     = own && !DDRAM_BUSY;

    assign f_busy         = DDRAM_BUSY || own;
    assign DDRAM_BURSTCNT = own ? 8'd1 : f_burstcnt;
    assign DDRAM_ADDR     = own ? head[61:33] : f_addr;
    assign DDRAM_DIN      = own ? {head[31:0], head[31:0]} : f_din;
    assign DDRAM_BE       = own ? (head[32] ? 8'hF0 : 8'h0F) : f_be;
    assign DDRAM_WE       = own ? 1'b1 : f_we;
    assign DDRAM_RD       = own ? 1'b0 : f_rd;

    always @(posedge clk) begin
        if (push) wr_ptr <= wr_ptr + 1'b1;
        if (pop)  rd_ptr <= rd_ptr + 1'b1;
        cnt <= cnt + (push ? 1'b1 : 1'b0) - (pop ? 1'b1 : 1'b0);
        if (r_we && !push) drops <= drops + 16'd1;
        if (pop || (push && wr_ptr == rd_ptr)) settle <= 2'd2;
        else if (settle != 2'd0) settle <= settle - 2'd1;
        // take the bus only between flash commands; give it back after each write if the flash store waits
        if (!own && !f_cmd && head_ok) own <= 1'b1;
        else if (pop) own <= 1'b0;
    end
endmodule
