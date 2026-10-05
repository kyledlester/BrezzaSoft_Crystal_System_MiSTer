// Crystal CRT Adjust bench: crystal_raster (CRTC reset-default timing) -> the core's one-pixel output alignment ->
// crystal_crt_adjust with the vendored crt_adjust, exactly as Crystal.sv wires them. Port of the owner's Namco NB-1
// sim/m17_crt_tb.sv (same checks, Crystal geometry: 455 x 262 at clk_sys/12, 320 x 240 active, HSync 34 px from
// pixel 361, VSync 3 lines from line 244).
// Copyright (C) 2026 Kyle Lester. SPDX-License-Identifier: GPL-3.0-or-later
//
// Source picture: pixel (x, y) of the 320 x 240 active area carries {y, x} (unique), black in blanking.
// For every setting (after the per-frame latch and a settling frame), on the stream that goes to arcade_video:
//   - HSync period 455 pixels (5,460 clk) and width 34 pixels on every line; VSync period 262 lines, width 3 lines;
//   - every active output line shows ONE source line, its pixels in order, each held a uniform time;
//   - all 240 lines, all 320 pixels, never on a sync; Off = the native stream on every clock.
//   Run: scripts/sim/crt_test.sh
`timescale 1ns/1ps
module tb_crt;
    reg clk = 1'b0;
    always #5.820 clk = ~clk;
    longint cyc = 0;
    always @(posedge clk) cyc <= cyc + 1;
    reg rst_n = 1'b0;
    initial begin repeat (4) @(posedge clk); rst_n = 1'b1; end
    wire ce_pix, hb0, vb0, hs0, vs0;
    wire [9:0] hcount, vcount;
    crystal_raster vt (.clk(clk), .rst_n(rst_n), .htotal(10'd455), .hdisp(10'd320), .hs_start(10'd361), .hs_end(10'd395),
        .vtotal(10'd262), .vdisp(10'd240), .vs_start(10'd244), .vs_end(10'd247), .div(6'd12),
        .ce_pix(ce_pix), .hcnt(hcount), .vcnt(vcount), .hblank(hb0), .vblank(vb0), .hsync(hs0), .vsync(vs0));
    // crystal_core: the scanout pixel and the timing signals are registered one pixel late
    reg hblank = 1'b1, vblank = 1'b1, hsync = 1'b0, vsync = 1'b0;
    reg [23:0] rgb = 24'd0;
    always @(posedge clk) if (ce_pix) begin
        hblank <= hb0; vblank <= vb0; hsync <= hs0; vsync <= vs0;
        rgb <= (!hb0 && !vb0) ? {vcount[7:0], 7'd0, hcount[8:0]} : 24'd0;
    end
    // Crystal.sv: frame_event = vblank rise; core: vb_next from the raster line counter
    reg vb_fe = 1'b0;
    always @(posedge clk) vb_fe <= vblank;
    wire frame_end = vblank && !vb_fe;
    wire line_end = ce_pix && hcount == 10'd454;

    reg on = 0, sd_off = 1; reg [4:0] hsz = 0; reg [3:0] hp = 0, vs = 0;
    wire ce_o, hb_o, vb_o, hs_o, vs_o, act; wire [23:0] rgb_o;
    wire signed [4:0] hsize_s; wire signed [3:0] hpos_s, vsh_s;
    crystal_crt_adjust dut (.clk_sys(clk), .ce_pix(ce_pix), .frame_event(frame_end),
        .osd_on(on), .osd_hsize(hsz), .osd_hpos(hp), .osd_vshift(vs), .sd_off(sd_off),
        .vb_next((vcount == 10'd261) ? 1'b0 : (vcount >= 10'd239)),
        .rgb_in(rgb), .hblank_in(hblank), .vblank_in(vblank), .hsync_in(hsync), .vsync_in(vsync),
        .ce_out(ce_o), .rgb_out(rgb_o), .hblank_out(hb_o), .vblank_out(vb_o), .hsync_out(hs_o), .vsync_out(vs_o),
        .active(act), .hsize_s(hsize_s), .hpos_s(hpos_s), .vsh_s(vsh_s));

    integer errors = 0, checks = 0;
    task automatic err(input string s); errors++; if (errors <= 40) $display("ERROR %s", s); endtask

    // upstream raster cadence (must never change): clk between line_end pulses / frame_end pulses
    longint le_last = 0, fe_last = 0;
    int le_bad = 0, fe_bad = 0, le_n = 0;
    always @(posedge clk) begin
        if (line_end) begin if (le_last != 0 && cyc - le_last != 5460) le_bad++; le_last = cyc; le_n++; end
        if (frame_end) begin if (fe_last != 0 && cyc - fe_last != 5460 * 262) fe_bad++; fe_last = cyc; end
    end
    // bypass: Off -> output == native stream every clock
    int byp_bad = 0;
    always @(posedge clk) if (!act && {ce_o, rgb_o, hb_o, vb_o, hs_o, vs_o} !== {ce_pix, rgb, hblank, vblank, hsync, vsync}) byp_bad++;

    // ---------------- per-line / per-frame measurement of the output stream (sampled at ce_o)
    bit meas = 0;
    longint hs_rise_t = 0, hs_prev_rise = 0, hs_fall_t = 0, vs_rise_t = 0;
    bit hs_d = 0, vs_d = 0;
    int hs_per_bad, hs_w_bad, vs_per_bad, vs_w_bad, line_bad, hold_bad, lines_vs, vs_w;
    int vis_min_y, lines_frame, lf_min, lf_max, exp_y, line_seq_bad, vs_overlap, vbp; bit fr_started, ln_in_vs;
    int vis_min, vis_max, bp_min, fp_min, first_src_line, hold_min, hold_max;
    // current line state
    int ln_cnt, ln_y, ln_lastx; longint ln_first_t, ln_last_t, px_t; bit ln_any, ln_order_bad;
    bit[23:0] px_cur; bit px_valid;
    int line_after_vs; bit seen_first;
    task automatic reset_meas();
        hs_per_bad = 0; hs_w_bad = 0; vs_per_bad = 0; vs_w_bad = 0; line_bad = 0; hold_bad = 0;
        vis_min = 999; vis_max = 0; bp_min = 999999; fp_min = 999999; first_src_line = -1;
        hold_min = 999; hold_max = 0; lines_vs = -1; vs_w = 0; ln_any = 0; seen_first = 0; px_valid = 0;
        lines_frame = 0; lf_min = 999; lf_max = 0; exp_y = 0; line_seq_bad = 0; vs_overlap = 0; fr_started = 0; vbp = -1;
    endtask
    task automatic end_line(input longint next_rise);
        if (!meas) return;
        if (ln_any) begin
            int bp, fp;
            if (ln_order_bad) line_bad++;
            if (ln_cnt < vis_min) begin vis_min = ln_cnt; vis_min_y = ln_y; end
            if (ln_cnt > vis_max) vis_max = ln_cnt;
            bp = int'((ln_first_t - hs_fall_t) / 12);
            fp = int'((next_rise - ln_last_t) / 12);
            if (bp < bp_min) bp_min = bp;
            if (fp < fp_min) fp_min = fp;
            if (!seen_first) begin first_src_line = ln_y; seen_first = 1; vbp = lines_vs; end
            lines_frame++;
            if (fr_started && ln_y != exp_y) line_seq_bad++;   // sequence checked once a VSync framed the window
            exp_y = ln_y + 1;
            if (ln_in_vs) vs_overlap++;
        end
        ln_any = 0; ln_cnt = 0; ln_order_bad = 0; px_valid = 0; ln_in_vs = 0;
    endtask
    always @(posedge clk) begin
        // HSync (on clk: the output registers change on ce_o edges)
        if (hs_o && !hs_d) begin
            end_line(cyc);
            if (meas && hs_prev_rise != 0 && cyc - hs_prev_rise != 5460) hs_per_bad++;
            hs_prev_rise = cyc; hs_rise_t = cyc;
            if (lines_vs >= 0) lines_vs++;
        end
        if (!hs_o && hs_d) begin
            hs_fall_t = cyc;
            // width: 34 pixels, the edges on the output pixel CE (NCO: within one read period)
            if (meas && (cyc - hs_rise_t < 34 * 12 - 16 || cyc - hs_rise_t > 34 * 12 + 16)) hs_w_bad++;
        end
        hs_d = hs_o;
        // VSync in clk: period 262 lines, width 3 lines (edges on the output pixel CE: within 2 pixels)
        if (vs_o && !vs_d) begin
            if (meas && vs_rise_t != 0 && (cyc - vs_rise_t) != 262 * 5460) vs_per_bad++;
            if (meas && fr_started) begin
                if (lines_frame < lf_min) lf_min = lines_frame;
                if (lines_frame > lf_max) lf_max = lines_frame;
            end
            fr_started = 1; lines_frame = 0; exp_y = 0;
            vs_rise_t = cyc; lines_vs = 0; seen_first = 0;
        end
        if (!vs_o && vs_d && meas && ((cyc - vs_rise_t) < 3 * 5460 - 24 || (cyc - vs_rise_t) > 3 * 5460 + 24)) vs_w_bad++;
        vs_d = vs_o;
        // content, sampled when the framework samples it (ce_o)
        if (ce_o && meas) begin
            if (!hb_o && !vb_o) begin
                bit [8:0] x; bit [7:0] y;
                y = rgb_o[23:16]; x = rgb_o[8:0];
                if (px_valid && rgb_o != px_cur) begin
                    // pixel changed: its hold time
                    int h; h = int'(cyc - px_t);
                    if (h < hold_min) hold_min = h;
                    if (h > hold_max) hold_max = h;
                end
                if (!px_valid || rgb_o != px_cur) begin px_t = cyc; px_cur = rgb_o; px_valid = 1; end
                if (!ln_any) begin
                    ln_any = 1; ln_y = y; ln_first_t = cyc; ln_cnt = 1; ln_lastx = x;
                    if (x != 0) ln_order_bad = 1;          // the left edge is never cropped
                end else if (x != ln_lastx) begin
                    if (y != ln_y || x != ln_lastx + 1) ln_order_bad = 1;
                    ln_lastx = x; ln_cnt++;
                end
                ln_last_t = cyc + 1;
                if (vs_o) ln_in_vs = 1;
            end
        end
    end

    task automatic run_setting(input bit o, input [4:0] hs, input [3:0] hpos, input [3:0] vsh, input bit sdo,
                               input string tag, input bit want_full);
        on = o; hsz = hs; hp = hpos; vs = vsh; sd_off = sdo;
        @(posedge frame_end); @(posedge frame_end);       // latched + one settling frame
        reset_meas(); meas = 1;
        @(posedge frame_end); @(posedge frame_end);
        meas = 0;
        checks++;
        if (hs_per_bad || hs_w_bad || vs_per_bad || vs_w_bad) err($sformatf("%s: sync changed (HS per %0d w %0d, VS per %0d w %0d)",
                                                                     tag, hs_per_bad, hs_w_bad, vs_per_bad, vs_w_bad));
        checks++; if (line_bad) err($sformatf("%s: %0d lines out of order / not one source line", tag, line_bad));
        checks++; if (vis_max == 0) err($sformatf("%s: no active video", tag));
        if (o && sdo) begin
            checks++;
            // hold time per pixel: floor/ceil of the read period (NCO), or exactly 12 when neutral
            if (hold_max - hold_min > 1 && hold_min != 999) err($sformatf("%s: pixel hold %0d..%0d clk", tag, hold_min, hold_max));
        end
        // every setting: the whole picture, in order, never on a sync
        checks++; if (lf_min != 240 || lf_max != 240) err($sformatf("%s: %0d..%0d lines per frame", tag, lf_min, lf_max));
        checks++; if (line_seq_bad) err($sformatf("%s: source lines out of sequence (%0d)", tag, line_seq_bad));
        checks++; if (vis_min != 320) err($sformatf("%s: %0d of 320 pixels on some line", tag, vis_min));
        checks++; if (bp_min < 0 || fp_min < 0) err($sformatf("%s: content on the HSync (BP %0d FP %0d)", tag, bp_min, fp_min));
        checks++; if (vs_overlap) err($sformatf("%s: %0d content lines during VSync", tag, vs_overlap));
        $display("  %-26s on %0d H-Size %3d H-Pos %4d V-Shift %3d | pixels %3d(y%0d)..%3d  BP %3d  FP %3d  hold %0d..%0d  lines %0d  VS->first line %0d",
                 tag, act, hsize_s, hpos_s * 6, vsh_s, vis_min, vis_min_y, vis_max, bp_min, fp_min,
                 hold_min == 999 ? 0 : hold_min, hold_max, lf_min, vbp);
    endtask

    function automatic [4:0] hidx(input int v);   // H-Size value -> OSD index
        hidx = (v >= 0) ? 5'(v) : 5'(v + 23);
    endfunction

    int nocrop_max;
    initial begin
        $display("Crystal native raster + CRT Adjust bench");
        repeat (3) @(posedge frame_end);
        run_setting(0, 0, 0, 0, 1, "native (Off)", 1);
        checks++; if (byp_bad) err($sformatf("bypass differs from the native stream on %0d clocks", byp_bad));
        run_setting(1, 0, 0, 0, 1, "On, neutral", 1);
        // every H-Size value at H-Position 0
        nocrop_max = -99;
        for (int v = -12; v <= 10; v++) begin
            run_setting(1, hidx(v), 0, 0, 1, $sformatf("H-Size %0d", v), 0);
            if (vis_min == 320 && v > nocrop_max) nocrop_max = v;
        end
        // every H-Position at H-Size 0, -12, +10
        for (int s = 0; s < 5; s++) begin
            int hv; hv = (s == 0) ? 0 : (s == 1) ? -12 : (s == 2) ? 10 : (s == 3) ? 5 : -6;
            for (int p = -8; p <= 7; p++) run_setting(1, hidx(hv), 4'(p), 0, 1, $sformatf("H-Size %0d H-Pos %0d", hv, p * 6), 0);
        end
        // every V-Shift
        for (int q = -8; q <= 7; q++) run_setting(1, 0, 0, 4'(q), 1, $sformatf("V-Shift %0d", q), 1);
        // corners
        for (int c = 0; c < 8; c++)
            run_setting(1, hidx(c[0] ? 10 : -12), c[1] ? 4'd7 : 4'd8, c[2] ? 4'd7 : 4'd8, 1, $sformatf("corner %0d", c), 0);
        // index 23..31 (unreachable from the OSD) = 0; scandoubler on = bypass
        run_setting(1, 5'd27, 0, 0, 1, "H-Size index 27", 1);
        checks++; if (hsize_s != 0) err("index 27 not decoded as 0");
        run_setting(1, hidx(8), 4'd3, 4'd2, 0, "On but scandoubler on", 1);
        checks++; if (act) err("adjust active with the scandoubler on");
        checks++; if (byp_bad) err($sformatf("bypass differs from the native stream on %0d clocks", byp_bad));
        checks++; if (le_bad || fe_bad) err($sformatf("upstream raster cadence changed (%0d lines, %0d frames)", le_bad, fe_bad));
        $display("  upstream raster: %0d lines, cadence constant (5,460 clk / line, 262 lines / frame)", le_n);
        $display("  H-Size no-crop limit at H-Position 0: +%0d", nocrop_max);
        $display("  %0d checks", checks);
        if (errors == 0) $display("PASS CRYSTAL CRT"); else $display("FAIL CRYSTAL CRT: %0d errors", errors);
        $finish;
    end
endmodule
