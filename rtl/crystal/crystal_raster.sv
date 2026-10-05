// BrezzaSoft Crystal System MiSTer core -- programmable raster counter.
// Copyright (C) 2026 Kyle Lester. SPDX-License-Identifier: GPL-3.0-or-later
//
// One pixel per `div` clk_sys cycles. Counters start at the first visible pixel/line (0,0); blanking and sync
// are combinational decodes of the registered counters, all qualified to the same pixel. Timing values are
// sampled at the start of each frame so a CRTC reprogramming never produces a torn frame.
module crystal_raster (
    input  wire       clk,
    input  wire       rst_n,
    input  wire [9:0] htotal,     // pixels per line
    input  wire [9:0] hdisp,      // visible pixels
    input  wire [9:0] hs_start,   // first hsync pixel
    input  wire [9:0] hs_end,     // first pixel after hsync
    input  wire [9:0] vtotal,     // lines per frame
    input  wire [9:0] vdisp,      // visible lines
    input  wire [9:0] vs_start,
    input  wire [9:0] vs_end,
    input  wire [5:0] div,        // clk_sys cycles per pixel
    output reg        ce_pix,
    output reg  [9:0] hcnt,
    output reg  [9:0] vcnt,
    output wire       hblank,
    output wire       vblank,
    output wire       hsync,
    output wire       vsync
);
    reg [5:0] dcnt;
    reg [9:0] ht, hd, hss, hse, vt, vd, vss, vse;

    always @(posedge clk) begin
        if (!rst_n) begin
            dcnt   <= '0;
            ce_pix <= 1'b0;
            hcnt   <= '0;
            vcnt   <= '0;
            ht <= htotal; hd <= hdisp; hss <= hs_start; hse <= hs_end;
            vt <= vtotal; vd <= vdisp; vss <= vs_start; vse <= vs_end;
        end else begin
            ce_pix <= 1'b0;
            if (dcnt >= div - 6'd1) begin
                dcnt   <= '0;
                ce_pix <= 1'b1;
            end else begin
                dcnt <= dcnt + 6'd1;
            end
            if (ce_pix) begin
                if (hcnt >= ht - 10'd1) begin
                    hcnt <= '0;
                    if (vcnt >= vt - 10'd1) begin
                        vcnt <= '0;
                        ht <= htotal; hd <= hdisp; hss <= hs_start; hse <= hs_end;
                        vt <= vtotal; vd <= vdisp; vss <= vs_start; vse <= vs_end;
                    end else begin
                        vcnt <= vcnt + 10'd1;
                    end
                end else begin
                    hcnt <= hcnt + 10'd1;
                end
            end
        end
    end

    assign hblank = (hcnt >= hd);
    assign vblank = (vcnt >= vd);
    assign hsync  = (hcnt >= hss) && (hcnt < hse);
    assign vsync  = (vcnt >= vss) && (vcnt < vse);
endmodule
