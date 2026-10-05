// BrezzaSoft Crystal System MiSTer core -- board top (M0 skeleton).
// Copyright (C) 2026 Kyle Lester. SPDX-License-Identifier: GPL-3.0-or-later
//
// M0: clock/reset plumbing, a fixed MAME-default raster (455 x 262 pixel clocks, 320 x 240 visible,
// pixel clock = clk_sys / 12 = 7.159 MHz, 60.05 Hz) with a test pattern, silent audio, idle SDRAM/DDR3.
// Later milestones replace the pattern with the VRender0 CRTC scanout.
module crystal_core (
    input  wire        clk_sys,
    input  wire        pll_locked,
    input  wire        reset_request,

    input  wire        ioctl_download,
    input  wire [15:0] ioctl_index,
    input  wire        ioctl_wr,
    input  wire [26:0] ioctl_addr,
    input  wire [15:0] ioctl_dout,
    output wire        ioctl_wait,

    input  wire [31:0] joy0, joy1, joy2, joy3,
    input  wire        sw_test,

    inout  wire [15:0] SDRAM_DQ,
    output wire [12:0] SDRAM_A,
    output wire        SDRAM_DQML,
    output wire        SDRAM_DQMH,
    output wire  [1:0] SDRAM_BA,
    output wire        SDRAM_nCS,
    output wire        SDRAM_nWE,
    output wire        SDRAM_nRAS,
    output wire        SDRAM_nCAS,
    output wire        SDRAM_CKE,
    output wire        SDRAM_CLK,

    input  wire        DDRAM_BUSY,
    output wire  [7:0] DDRAM_BURSTCNT,
    output wire [28:0] DDRAM_ADDR,
    input  wire [63:0] DDRAM_DOUT,
    input  wire        DDRAM_DOUT_READY,
    output wire        DDRAM_RD,
    output wire [63:0] DDRAM_DIN,
    output wire  [7:0] DDRAM_BE,
    output wire        DDRAM_WE,

    output wire        ce_pix,
    output wire  [7:0] r, g, b,
    output wire        hblank, vblank, hsync, vsync,

    output wire signed [15:0] audio_l,
    output wire signed [15:0] audio_r,

    output wire        rom_loading,
    output wire        cpu_running
);

    // ---------------------------------------------------------------- reset
    reg [15:0] rst_cnt = '0;
    reg        rst_n   = 1'b0;
    always @(posedge clk_sys) begin
        if (!pll_locked || reset_request || ioctl_download) begin
            rst_cnt <= '0;
            rst_n   <= 1'b0;
        end else if (!(&rst_cnt)) begin
            rst_cnt <= rst_cnt + 16'd1;
        end else begin
            rst_n <= 1'b1;
        end
    end

    // ---------------------------------------------------------------- raster (MAME default)
    wire [9:0] hcnt;
    wire [9:0] vcnt;
    crystal_raster raster (
        .clk(clk_sys), .rst_n(rst_n),
        .htotal(10'd455), .hdisp(10'd320), .hs_start(10'd336), .hs_end(10'd370),
        .vtotal(10'd262), .vdisp(10'd240), .vs_start(10'd244), .vs_end(10'd247),
        .div(4'd12),
        .ce_pix(ce_pix), .hcnt(hcnt), .vcnt(vcnt),
        .hblank(hblank), .vblank(vblank), .hsync(hsync), .vsync(vsync)
    );

    // ---------------------------------------------------------------- M0 test pattern
    wire border = (hcnt == 10'd0) || (hcnt == 10'd319) || (vcnt == 10'd0) || (vcnt == 10'd239);
    assign r = border ? 8'hff : {hcnt[7:3], 3'b000};
    assign g = border ? 8'hff : {vcnt[7:3], 3'b000};
    assign b = border ? 8'hff : {hcnt[8], vcnt[8], 6'b0} | (sw_test ? 8'h3f : 8'h00);

    assign audio_l = 16'sd0;
    assign audio_r = 16'sd0;
    assign ioctl_wait = 1'b0;
    assign rom_loading = ioctl_download;
    assign cpu_running = 1'b0;

    // ---------------------------------------------------------------- idle external memories
    assign SDRAM_DQ   = 16'hzzzz;
    assign SDRAM_A    = 13'd0;
    assign SDRAM_DQML = 1'b1;
    assign SDRAM_DQMH = 1'b1;
    assign SDRAM_BA   = 2'd0;
    assign SDRAM_nCS  = 1'b1;
    assign SDRAM_nWE  = 1'b1;
    assign SDRAM_nRAS = 1'b1;
    assign SDRAM_nCAS = 1'b1;
    assign SDRAM_CKE  = 1'b0;
    assign SDRAM_CLK  = 1'b0;

    assign DDRAM_BURSTCNT = 8'd1;
    assign DDRAM_ADDR     = 29'd0;
    assign DDRAM_RD       = 1'b0;
    assign DDRAM_DIN      = 64'd0;
    assign DDRAM_BE       = 8'hff;
    assign DDRAM_WE       = 1'b0;

endmodule
