// BrezzaSoft Crystal System MiSTer core -- VRender0 frame-buffer scanout.
// Copyright (C) 2026 Kyle Lester. SPDX-License-Identifier: GPL-3.0-or-later
//
// MAME screen_update: pixel (x,y) = frame RAM word at display_dest + ((x & 0x3ff) | (y & 0x1ff) << 10) * 2,
// RGB565 expanded with MAME's pal5bit/pal6bit (bit replication). Each visible line is fetched into one half of
// a 2 x 1024 line buffer during the previous line (bursts of 32 words from SDRAM bank 2, highest client
// priority), so the display never waits on memory. CRTMOD b9 (blank) outputs black.
// flip (OSD Orientation "Flipped"): the picture turned 180 degrees on the native raster -- display line y is
// fetched from line vdisp-1-y and each line is read out right to left. It reaches the 15-kHz output and HDMI
// alike, with no added latency; a change takes effect at the next frame.
module vr0_scanout (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        ce_pix,
    input  wire  [9:0] hcnt,
    input  wire  [9:0] vcnt,
    input  wire        hblank,
    input  wire        vblank,
    input  wire  [9:0] hdisp,
    input  wire  [9:0] vdisp,
    input  wire  [9:0] vtotal,
    input  wire [22:0] display_dest,  // frame RAM byte address
    input  wire        blank,
    input  wire        flip,

    output reg   [7:0] r,
    output reg   [7:0] g,
    output reg   [7:0] b,

    // SDRAM client (reads, frame RAM = SDRAM byte 0x1000000)
    output reg         m_req,
    output reg  [23:0] m_addr,
    output reg   [5:0] m_len,
    input  wire        m_rvalid,
    input  wire [15:0] m_rdata,
    input  wire        m_done,

    output reg  [15:0] underflows       // lines whose fetch had not completed when displayed (diagnostic)
);
    (* ramstyle = "M10K" *) reg [15:0] lb [0:2047];
    reg  [9:0] fetch_y;
    reg        fetch_buf;
    reg  [9:0] fetch_x;        // words requested so far
    reg  [9:0] wr_x;           // words received
    reg        fetching;
    reg  [9:0] line_done_y;
    reg        line_done_v;
    reg  [9:0] vcnt_q;
    reg [15:0] px;
    reg        f_flip, d_flip;   // latched for the fetch of a frame's first line / for its display

    // which line to fetch: the next visible line (vcnt + 1, wrapping to 0 at the end of the frame)
    wire [9:0] next_y = (vcnt + 10'd1 >= vtotal) ? 10'd0 : vcnt + 10'd1;

    always @(posedge clk) begin
        if (!rst_n) begin
            m_req <= 1'b0; fetching <= 1'b0; vcnt_q <= 10'h3ff; underflows <= 16'd0; line_done_v <= 1'b0;
        end else begin
            vcnt_q <= vcnt;
            // start fetching the next line at the beginning of each line
            if (vcnt != vcnt_q && next_y < vdisp) begin
                if (fetching) underflows <= underflows + 16'd1;
                fetching  <= 1'b1;
                if (next_y == 10'd0) f_flip <= flip;
                fetch_y   <= ((next_y == 10'd0) ? flip : f_flip) ? vdisp - 10'd1 - next_y : next_y;
                fetch_buf <= next_y[0];
                fetch_x   <= 10'd0;
                wr_x      <= 10'd0;
                m_req     <= 1'b0;
            end else if (fetching) begin
                if (!m_req && fetch_x < hdisp) begin
                    logic [23:0] wa;
                    wa = 24'h800000 + {2'b00, display_dest[22:1]} + {4'd0, fetch_y[8:0], 10'd0} + {14'd0, fetch_x};
                    m_req   <= 1'b1;
                    m_addr  <= wa;
                    m_len   <= (hdisp - fetch_x >= 10'd32) ? 6'd32 : (hdisp - fetch_x);
                end
                if (m_done) begin
                    m_req   <= 1'b0;
                    fetch_x <= fetch_x + {4'd0, m_len};
                end
                if (m_rvalid) begin
                    lb[{fetch_buf, wr_x}] <= m_rdata;
                    wr_x <= wr_x + 10'd1;
                    if (wr_x + 10'd1 == hdisp) begin fetching <= 1'b0; line_done_y <= fetch_y; end
                end
            end
        end
    end

    // pixel output (one clock of read latency; hcnt is stable for a whole pixel)
    always @(posedge clk) begin
        if (vcnt == 10'd0 && vcnt_q != 10'd0) d_flip <= f_flip;
        px <= lb[{vcnt[0], d_flip ? hdisp - 10'd1 - hcnt : hcnt}];
        if (ce_pix) begin
            if (hblank || vblank || blank) begin
                r <= 8'd0; g <= 8'd0; b <= 8'd0;
            end else begin
                r <= {px[15:11], px[15:13]};
                g <= {px[10:5], px[10:9]};
                b <= {px[4:0], px[4:2]};
            end
        end
    end
endmodule
