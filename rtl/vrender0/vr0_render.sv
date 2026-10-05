// BrezzaSoft Crystal System MiSTer core -- VRender0 display-list packet processor and 2D renderer.
// Copyright (C) 2026 Kyle Lester. SPDX-License-Identifier: GPL-3.0-or-later
//
// Behaviour: MAME video/vrender0.cpp process_packet / draw_quad / draw_quad_fill / do_alpha / do_shade
// (c2334733), docs/VRENDER0_VIDEO.md. Generic VRender0 logic, no game knowledge.
//
// Structure
//   1. packet: 32 words read from texture RAM (burst), flip packets answered immediately
//   2. render state latch (MAME sticky / default rules) and palette load (256 RGB888 dwords -> RGB565 with
//      MAME's collision nudge)
//   3. pixel pipeline, one pixel per clock when the caches hit:
//        P0 coordinates (x, y, tx, ty accumulators, MAME 32-bit wrapping arithmetic, clamp test)
//        P1 tile-map word lookup (texture cache port A), linear offset
//        P2 texel word lookup (texture cache port B)
//        P3 texel extract + palette read
//        P4 transparency, shade
//        P5 alpha blend against the destination and store into the 32-pixel frame segment
//      A cache miss stalls the pipeline; the texture cache (128 x 16 words, direct mapped) is filled by 16-word
//      SDRAM bursts and snooped by CPU/DMA writes to texture RAM.
//   4. frame segment: the 32-pixel aligned run of the destination row being drawn; flushed as one masked
//      burst when the pipeline leaves it (and read first when the quad blends).
// Memory: all addresses are SDRAM word addresses (texture RAM base 0x400000, frame RAM base 0x800000).
module vr0_render (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        start,
    input  wire [16:0] pkt_addr,          // texture-RAM word address of the packet
    input  wire [22:0] draw_dest,         // frame-RAM byte address of the draw buffer
    output reg         done,
    output reg   [1:0] flip,              // with done: b0 sync, b1 async

    // texture RAM reads (SDRAM client)
    output reg         t_req,
    output reg  [23:0] t_addr,
    output reg   [5:0] t_len,
    input  wire        t_rvalid,
    input  wire [15:0] t_rdata,
    input  wire        t_done,

    // frame RAM reads (SDRAM client)
    output reg         f_req,
    output reg  [23:0] f_addr,
    output reg   [5:0] f_len,
    input  wire        f_rvalid,
    input  wire [15:0] f_rdata,
    input  wire        f_done,

    // frame RAM writes (SDRAM client)
    output reg         w_req,
    output reg  [23:0] w_addr,
    output reg   [5:0] w_len,
    output wire [15:0] w_wdata,
    output wire  [1:0] w_wbe,
    input  wire        w_wnext,
    input  wire        w_done,

    // texture RAM write snoop (CPU/DMA), SDRAM word address
    input  wire        snoop,
    input  wire [23:0] snoop_addr,

    // statistics
    output reg  [31:0] stat_pixels,
    output reg  [31:0] stat_busy_cycles,
    output wire [31:0] dbg,
    output wire [31:0] dbg2,
    output wire [23:0] dbg3
);
    assign dbg2 = seg_m;
    assign dbg3 = seg_base;
    localparam [23:0] TEX_BASE = 24'h400000, FB_BASE = 24'h800000;
    localparam [15:0] NOTRANS = 16'hecda;

    // ------------------------------------------------------------------ packet + state
    reg [15:0] pkt [0:31];
    reg  [4:0] pk_i;

    reg [31:0] rs_tx, rs_ty, rs_txdx, rs_tydx, rs_txdy, rs_tydy;
    reg [23:0] rs_src_col, rs_dst_col, rs_shade, rs_trans;
    reg  [5:0] rs_src_blend, rs_dst_blend;
    reg [15:0] rs_tile_off, rs_font_off;
    reg [12:0] rs_pal_off;
    reg  [3:0] rs_pal_bank;
    reg        rs_tiled;
    reg  [1:0] rs_fmt;
    reg  [2:0] rs_wlog, rs_hlog;        // width = 8 << wlog
    reg [13:0] last_pal;
    reg        last_pal_v;

    // palette RAM (RGB565)
    (* ramstyle = "M10K" *) reg [15:0] pal [0:255];
    reg        pal_we;
    reg  [7:0] pal_wa;
    reg [15:0] pal_wd;
    reg  [7:0] pal_ra;
    reg [15:0] pal_q;
    always @(posedge clk) begin
        if (pal_we) pal[pal_wa] <= pal_wd;
        pal_q <= pal[pal_ra];
    end

    function automatic [15:0] rgb32to16(input [23:0] c);
        return {c[23:19], c[15:10], c[7:3]};
    endfunction
    function automatic [7:0] x5(input [4:0] v); return {v, v[4:2]}; endfunction
    function automatic [7:0] x6(input [5:0] v); return {v, v[5:4]}; endfunction

    // ------------------------------------------------------------------ texture cache
    // Two direct-mapped caches so tile-map words and texels never evict each other:
    //   tile cache  (P1):  64 lines x 16 words, index tile_wa[9:4],  tag tile_wa[21:10]
    //   texel cache (P2): 128 lines x 16 words, index word[10:4],    tag word[21:11]
    (* ramstyle = "M10K" *) reg [15:0] tt_data [0:1023];
    reg [11:0] tt_tag [0:63];
    reg [63:0] tt_val;
    (* ramstyle = "M10K" *) reg [15:0] tc_data [0:2047];
    reg [10:0] tc_tag [0:127];
    reg [127:0] tc_val;
    reg   [9:0] tca_a;
    reg  [10:0] tcb_a;
    reg  [15:0] tca_q, tcb_q;
    reg         tc_we;
    reg  [10:0] tc_wa;
    reg  [15:0] tc_wd;
    reg         fill_tt;              // the fill in progress targets the tile cache
    always @(posedge clk) begin
        if (tc_we && fill_tt) tt_data[tc_wa[9:0]] <= tc_wd;
        tca_q <= tt_data[tca_a];
    end
    always @(posedge clk) begin
        if (tc_we && !fill_tt) tc_data[tc_wa] <= tc_wd;
        tcb_q <= tc_data[tcb_a];
    end

    // ------------------------------------------------------------------ frame segment (32 pixels)
    reg [15:0] seg [0:31];
    reg [31:0] seg_m;                 // pixels written
    reg [23:0] seg_base;              // SDRAM word address of pixel 0 of the segment
    reg        seg_v;                 // segment holds a valid window
    reg        seg_loaded;            // destination pixels read (blend quads)
    reg  [4:0] fl_i;                  // blend read (destination load) index
    // write-back buffer: a finished segment is copied here in one clock and written to SDRAM from here while
    // the pipeline already draws into the next segment (double buffering)
    reg [15:0] wbuf [0:31];
    reg [31:0] wbuf_m;
    reg  [4:0] wb_i;
    assign w_wdata = wbuf[wb_i];
    assign w_wbe   = wbuf_m[wb_i] ? 2'b11 : 2'b00;
    task automatic seg_to_wbuf;
        for (int k = 0; k < 32; k++) wbuf[k] <= seg[k];
        wbuf_m <= seg_m;
        w_req  <= 1'b1;
        w_addr <= seg_base;
        w_len  <= 6'd32;
        wb_i   <= 5'd0;
    endtask

    // ------------------------------------------------------------------ quad parameters (latched per packet)
    reg  [9:0] q_dx, q_endx;
    reg  [8:0] q_dy, q_endy;
    reg        q_tex, q_blend, q_shade, q_trans, q_clamp, q_fill_alpha;
    reg [15:0] q_transc;              // RGB565 transparent colour or NOTRANS
    reg [22:0] q_dest;
    reg [22:0] q_texaddr, q_tile;     // byte addresses in texture RAM
    reg [23:0] q_shadec;
    reg [15:0] q_fillc;

    // ------------------------------------------------------------------ sequencer
    typedef enum logic [3:0] {
        R_IDLE, R_PKT, R_DECODE, R_PAL, R_PALW, R_QUAD, R_FLUSH, R_FLUSHW, R_LOAD, R_LOADW, R_FILL, R_DONE
    } rst_t;
    rst_t rst;

    // palette load
    reg  [8:0] pl_i;                  // word index 0..511
    reg [15:0] pl_lo;

    // texture fill
    reg [21:0] fill_wa;               // texture word address of the line being filled
    reg  [3:0] fill_i;
    reg        filling;
    reg  [1:0] fill_fin;              // clocks until the last written word is readable
    reg        fill_dirty;            // snooped while filling
    reg        snoop_q;               // texture write snoop, registered
    reg [21:4] snoop_a;

    // ------------------------------------------------------------------ pixel pipeline registers
    // P0 generator
    reg        g_run;
    reg  [9:0] g_x;
    reg  [8:0] g_y;
    reg [31:0] g_rtx, g_rty;          // row start accumulators
    reg [31:0] g_tx, g_ty;            // current
    // stage valid / payload
    reg        p1_v, p2_v, p3_v, p4_v, p5_v;
    reg  [9:0] p1_x, p2_x, p3_x, p4_x, p5_x;
    reg  [8:0] p1_y, p2_y, p3_y, p4_y, p5_y;
    reg [21:0] p1_tx, p1_ty;          // texel coordinates (after >> 9, 23 bits, masked later)
    reg        p1_skip, p2_skip, p3_skip, p4_skip, p5_skip;
    reg [21:0] p2_off;                // texel offset (linear) or {ty&7, tx&7} for tiled
    reg  [5:0] p2_sub;
    reg        p2_tiled_wait;
    reg [21:0] p3_word;               // texel word address (texture word space)
    reg  [1:0] p3_lane;               // byte / nibble select
    reg [15:0] p4_tex16;              // 16bpp texel (P4)
    reg [15:0] p5_col;
    reg [23:0] p5_fb;                 // frame word address of the P5 pixel (registered on P4 -> P5)
    // P6 (destination read registered, blend products) and P7 (sum, clamp, segment write) never stall: they
    // only carry pixels that P5 already committed to the current segment.
    reg        p6_v, p7_v;
    reg  [4:0] p6_idx, p7_idx;
    reg        p6_blend, p7_blend;
    reg [15:0] p6_src, p6_dst, p7_col;
    reg [16:0] p7_pa [0:2], p7_pb [0:2];
    reg  [7:0] p4_pidx;               // palette index used for the P4 read (re-read while stalled)
    reg  [5:0] p2_tile_line_q;
    reg  [6:0] p3_line_q;
    reg  [3:0] p2_tile_w_q, p3_w_q;

    wire [9:0] maskw = (10'd8 << rs_wlog) - 10'd1;
    wire [9:0] maskh = (10'd8 << rs_hlog) - 10'd1;

    // stall: a stage cannot advance when the next one is blocked
    wire p1_miss, p2_miss;
    wire seg_hold;                    // P5 cannot accept (segment switch in progress)
    wire p5_hazard;                   // P5 blend pixel whose destination is still being written by P6/P7
    wire p2_wait;                     // P2W tag copy is being refreshed after a texel tag/valid write
    wire stall = p1_miss || p2_miss || p2_wait || seg_hold || p5_hazard;

    // ---- RAM output hold: the RAM outputs belong to the pixels one stage further on. On the first clock of a
    //      stall they are captured and the captured values are used until the pipeline advances, so a cache
    //      fill (which may rewrite the very line an older pixel read) cannot change them.
    reg         stall_q;
    reg  [15:0] tca_h, tcb_h, pal_h;
    wire [15:0] tca_e = stall_q ? tca_h : tca_q;
    wire [15:0] tcb_e = stall_q ? tcb_h : tcb_q;
    wire [15:0] pal_e = stall_q ? pal_h : pal_q;
    always @(posedge clk) begin
        stall_q <= stall && rst == R_FILL;
        if (stall && !stall_q) begin tca_h <= tca_q; tcb_h <= tcb_q; pal_h <= pal_q; end
    end

    // ---- P1: tile lookup (port A) ----------------------------------------------------------------
    // tile word address (texture word space): tile/2 + (ty>>3)*(w>>3) + (tx>>3)
    // (computed on P0 -> P1 so the tag lookup starts from a register)
    reg  [21:0] p1_tile_wa;
    function automatic [21:0] tile_wa_of(input [21:0] tx, input [21:0] ty);
        logic [21:0] tx_m, ty_m;
        tx_m = {12'd0, tx[9:0] & maskw};
        ty_m = {12'd0, ty[9:0] & maskh};
        return q_tile[22:1] + ((ty_m >> 3) << (rs_wlog)) + (tx_m >> 3);
    endfunction
    wire [5:0]  p1_line = p1_tile_wa[9:4];
    wire        p1_need_tile = p1_v && !p1_skip && q_tex && rs_tiled;
    assign p1_miss = p1_need_tile && !(tt_val[p1_line] && tt_tag[p1_line] == p1_tile_wa[21:10]);

    // ---- P2: texel lookup (port B) ---------------------------------------------------------------
    // tiled: index from port A data (tca_q, read in P1 -> available in P2)
    reg  [21:0] p2_word;
    reg   [1:0] p2_lane;
    reg         p2_skip_eff;
    always @* begin
        logic [22:0] off, b;
        p2_skip_eff = p2_skip;
        if (rs_tiled) begin
            off = {1'b0, tca_e, 6'd0} + {17'd0, p2_sub};
            if (q_tex && tca_e == 16'd0) p2_skip_eff = 1'b1;
        end else
            off = {1'b0, p2_off};
        case (rs_fmt)
            2'd0: begin b = q_texaddr + (off >> 1); p2_word = b[22:1]; p2_lane = {b[0], off[0]}; end   // 4bpp
            2'd1: begin b = q_texaddr + off;        p2_word = b[22:1]; p2_lane = {b[0], 1'b0}; end     // 8bpp
            default: begin b = q_texaddr + (off << 1); p2_word = b[22:1]; p2_lane = 2'b00; end         // 16bpp
        endcase
    end
    // ---- P2W: texel tag check + texel read (address registered from P2)
    reg         p2w_v, p2w_skip;
    reg   [9:0] p2w_x;
    reg   [8:0] p2w_y;
    reg  [21:0] p2w_word;
    reg   [1:0] p2w_lane;
    wire [6:0]  p2_line = p2w_word[10:4];
    // The tag entry of the P2W pixel is looked up one clock early and registered (timing): both the entry for
    // the pixel entering P2W (p2_word) and for the one held there (p2w_word) are read, the stall picks. A write to
    // the texel tags/valid bits makes the copy stale for one clock (the pixel waits while it is re-read).
    reg  [10:0] p2w_tt;
    reg         p2w_tv, p2w_stale;
    wire [6:0]  p2_line_in = p2_word[10:4];
    wire        p2w_hit = p2w_tv && p2w_tt == p2w_word[21:11];
    wire        p2w_need = p2w_v && !p2w_skip && q_tex;
    assign p2_wait = p2w_need && p2w_stale;
    assign p2_miss = p2w_need && !p2w_stale && !p2w_hit;
    wire tc_fill_start = rst == R_FILL && !filling && p2_miss && !t_req;
    wire tc_fill_end   = rst == R_FILL && filling && fill_fin == 2'd1 && !fill_tt;
    always @(posedge clk) begin
        if (!stall || rst != R_FILL) begin
            p2w_tt <= tc_tag[p2_line_in];
            p2w_tv <= tc_val[p2_line_in];
        end else begin
            p2w_tt <= tc_tag[p2_line];
            p2w_tv <= tc_val[p2_line];
        end
        p2w_stale <= !rst_n || tc_fill_start || tc_fill_end || snoop_q;
    end

    // ---- P3: texel extract -> palette index; P4: colour ----------------------------------------
    reg  [7:0] p3_pidx;
    always @* begin
        logic [7:0] byte_v;
        byte_v = p3_lane[1] ? tcb_e[15:8] : tcb_e[7:0];
        if (rs_fmt == 2'd0)        // 4bpp: even texel offset -> high nibble; 16-entry bank
            p3_pidx = {rs_pal_bank, p3_lane[0] ? byte_v[3:0] : byte_v[7:4]};
        else
            p3_pidx = byte_v;
    end
    wire [15:0] p4_col = rs_fmt[1] ? p4_tex16 : pal_e;

    // ---- frame segment ownership ----------------------------------------------------------------
    wire [23:0] p4_fbword = FB_BASE + {1'b0, q_dest[22:1]} + {5'd0, p4_y, 10'd0} + {14'd0, p4_x};
    wire [23:0] p5_fbword = p5_fb;
    wire        p5_in_seg = seg_v && (p5_fbword[23:5] == seg_base[23:5]);
    wire        p67_busy  = p6_v || p7_v;
    assign p5_hazard = p5_v && !p5_skip && q_blend_any &&
                       ((p6_v && p6_idx == p5_fb[4:0]) || (p7_v && p7_idx == p5_fb[4:0]));
    assign seg_hold = p5_v && !p5_skip && !(p5_in_seg && (!q_blend_any || seg_loaded));
    wire q_blend_any = q_tex ? q_blend : q_fill_alpha;

    // ---- blend math (combinational on P5) -------------------------------------------------------
    function automatic [8:0] fsel(input [5:0] sel, input [23:0] scol, input [23:0] dcol,
                                  input [7:0] sc, input [7:0] dc, input integer ch);
        logic [8:0] m;
        case (sel[4:0])
            5'h02: m = {1'b0, scol[ch*8 +: 8]};
            5'h04: m = {1'b0, sc};
            5'h08: m = {1'b0, dcol[ch*8 +: 8]};
            5'h10: m = {1'b0, dc};
            default: m = 9'd0;
        endcase
        if (sel[5]) m = 9'h100 - m;
        return m;
    endfunction
    function automatic [15:0] do_shade(input [15:0] src, input [23:0] sh);
        logic [15:0] r, g, b;
        r = x5(src[15:11]) * sh[23:16];
        g = x6(src[10:5])  * sh[15:8];
        b = x5(src[4:0])   * sh[7:0];
        return {r[15:11], g[15:10], b[15:11]};
    endfunction

    // P6: blend products (MAME: (s * fsel(src) + d * fsel(dst)) >> 8 per channel, saturated)
    logic [16:0] p6_pa [0:2], p6_pb [0:2];
    always @* begin
        logic [7:0] sv [0:2], dv [0:2];
        sv[2] = x5(p6_src[15:11]); sv[1] = x6(p6_src[10:5]); sv[0] = x5(p6_src[4:0]);
        dv[2] = x5(p6_dst[15:11]); dv[1] = x6(p6_dst[10:5]); dv[0] = x5(p6_dst[4:0]);
        for (int ch = 0; ch < 3; ch++) begin
            p6_pa[ch] = sv[ch] * fsel(rs_src_blend, rs_src_col, rs_dst_col, sv[ch], dv[ch], ch);
            p6_pb[ch] = dv[ch] * fsel(rs_dst_blend, rs_src_col, rs_dst_col, sv[ch], dv[ch], ch);
        end
    end
    // P7: sum and saturate
    logic [15:0] p7_out;
    always @* begin
        logic [16:0] acc;
        logic [7:0] o [0:2];
        for (int ch = 0; ch < 3; ch++) begin
            acc = p7_pa[ch] + p7_pb[ch];
            o[ch] = (acc[16:8] > 9'd255) ? 8'd255 : acc[15:8];
        end
        p7_out = p7_blend ? {o[2][7:3], o[1][7:2], o[0][7:3]} : p7_col;
    end

    assign dbg = {rst, filling, p1_miss, p2_miss, seg_hold, g_run, p1_v, p2_v, p3_v, p4_v, p5_v, seg_v, seg_loaded,
                  t_req, f_req, w_req, p5_in_seg, q_blend_any, p5_x, 1'b0};
    // simulation-only visibility
    wire [31:0] dbg_seg_m = seg_m;
    wire [23:0] dbg_seg_base = seg_base;
    wire [8:0]  dbg_p5_y = p5_y;

    // ------------------------------------------------------------------ main sequencer
    integer i;
    always @(posedge clk) begin
        done   <= 1'b0;
        pal_we <= 1'b0;
        tc_we  <= 1'b0;
        if (rst != R_IDLE) stat_busy_cycles <= stat_busy_cycles + 32'd1;

        // texture cache snoop (CPU/DMA writes to texture RAM), one clock after the write was issued (the
        // write itself reaches SDRAM later: texture-RAM writes are synchronous in the D-cache)
        snoop_q <= snoop && snoop_addr[23:22] == 2'b01;
        snoop_a <= snoop_addr[21:4];
        if (snoop_q) begin
            if (tc_tag[snoop_a[10:4]] == snoop_a[21:11]) tc_val[snoop_a[10:4]] <= 1'b0;
            if (tt_tag[snoop_a[9:4]] == snoop_a[21:10]) tt_val[snoop_a[9:4]] <= 1'b0;
            if (filling && snoop_a == fill_wa[21:4]) fill_dirty <= 1'b1;
        end

        if (!rst_n) begin
            rst <= R_IDLE;
            t_req <= 1'b0; f_req <= 1'b0; w_req <= 1'b0;
            tc_val <= 128'd0;
            tt_val <= 64'd0;
            last_pal_v <= 1'b0;
            filling <= 1'b0;
            seg_v <= 1'b0; seg_m <= 32'd0; seg_loaded <= 1'b0;
            g_run <= 1'b0;
            p1_v <= 1'b0; p2_v <= 1'b0; p2w_v <= 1'b0; p3_v <= 1'b0; p4_v <= 1'b0; p5_v <= 1'b0; p6_v <= 1'b0; p7_v <= 1'b0;
            stat_pixels <= 32'd0; stat_busy_cycles <= 32'd0;
            rs_tx <= 0; rs_ty <= 0; rs_txdx <= 32'h200; rs_tydx <= 0; rs_txdy <= 0; rs_tydy <= 32'h200;
            rs_src_col <= 0; rs_dst_col <= 0; rs_shade <= 0; rs_trans <= 0; rs_src_blend <= 0; rs_dst_blend <= 0;
            rs_tile_off <= 0; rs_font_off <= 0; rs_pal_off <= 0; rs_pal_bank <= 0; rs_tiled <= 0; rs_fmt <= 0;
            rs_wlog <= 0; rs_hlog <= 0;
        end else begin
            case (rst)
            // ---------------------------------------------------------- packet fetch
            R_IDLE: if (start) begin
                t_req  <= 1'b1;
                t_addr <= TEX_BASE + {7'd0, pkt_addr};
                t_len  <= 6'd32;
                pk_i   <= 5'd0;
                q_dest <= draw_dest;
                rst    <= R_PKT;
            end
            R_PKT: begin
                if (t_rvalid) begin pkt[pk_i] <= t_rdata; pk_i <= pk_i + 5'd1; end
                if (t_done) begin t_req <= 1'b0; rst <= R_DECODE; end
            end
            R_DECODE: begin
                logic [15:0] p0;
                p0 = pkt[0];
                if (p0[0] || p0[7]) begin
                    flip <= {p0[7], p0[0]};
                    last_pal_v <= 1'b0;
                    done <= 1'b1;
                    rst  <= R_IDLE;
                end else begin
                    flip <= 2'b00;
                    // render state (MAME process_packet)
                    if (p0[9]) begin
                        rs_tx <= {11'd0, pkt[6][4:0], pkt[5]};
                        rs_ty <= {11'd0, pkt[8][4:0], pkt[7]};
                    end else begin rs_tx <= 32'd0; rs_ty <= 32'd0; end
                    if (p0[10]) begin
                        rs_txdx <= {11'd0, pkt[10][4:0], pkt[9]};
                        rs_tydx <= {11'd0, pkt[12][4:0], pkt[11]};
                        rs_txdy <= {11'd0, pkt[14][4:0], pkt[13]};
                        rs_tydy <= {11'd0, pkt[16][4:0], pkt[15]};
                    end else begin
                        rs_txdx <= 32'h200; rs_tydx <= 32'd0; rs_txdy <= 32'd0; rs_tydy <= 32'h200;
                    end
                    if (p0[11]) begin
                        rs_src_col   <= {pkt[18][7:0], pkt[17]};
                        rs_src_blend <= pkt[18][13:8];
                        rs_dst_col   <= {pkt[20][7:0], pkt[19]};
                        rs_dst_blend <= pkt[20][13:8];
                    end
                    if (p0[12]) rs_shade <= {pkt[22][7:0], pkt[21]};
                    if (p0[13]) rs_trans <= {pkt[24][7:0], pkt[23]};
                    if (p0[14]) begin
                        rs_tile_off <= pkt[25];
                        rs_font_off <= pkt[26];
                        rs_pal_off  <= pkt[27][15:3];
                        rs_pal_bank <= pkt[28][11:8];
                        rs_tiled    <= pkt[28][12];
                        rs_fmt      <= pkt[28][7:6];
                        rs_wlog     <= pkt[28][2:0];
                        rs_hlog     <= pkt[28][5:3];
                    end
                    rst <= R_PAL;
                end
            end
            // ---------------------------------------------------------- palette load (state now latched)
            R_PAL: begin
                if (pkt[0][6] && !(last_pal_v && last_pal == {1'b0, rs_pal_off})) begin
                    t_req  <= 1'b1;
                    t_addr <= TEX_BASE + {2'd0, rs_pal_off, 9'd0};
                    t_len  <= 6'd32;
                    pl_i   <= 9'd0;
                    rst    <= R_PALW;
                end else
                    rst <= R_QUAD;
                // quad parameters
                q_dx   <= pkt[1][9:0];
                q_dy   <= pkt[2][8:0];
                q_endx <= pkt[3][9:0];
                q_endy <= pkt[4][8:0];
                q_tex  <= pkt[0][3];
                q_blend <= pkt[0][1];
                q_shade <= pkt[0][4];
                q_trans <= pkt[0][2];
                q_clamp <= pkt[0][5];
                q_texaddr <= {rs_font_off, 7'd0};
                q_tile    <= {rs_tile_off, 7'd0};
            end
            R_PALW: begin
                if (t_rvalid) begin
                    pl_i <= pl_i + 9'd1;
                    if (!pl_i[0]) pl_lo <= t_rdata;
                    else begin
                        logic [23:0] p;
                        logic [15:0] v, tr;
                        p  = {t_rdata[7:0], pl_lo};
                        v  = rgb32to16(p);
                        tr = rgb32to16(rs_trans);
                        if ((v == tr && {t_rdata, pl_lo} != {8'd0, rs_trans}) || v == NOTRANS)
                            v = (v[4:0] != 5'h1f) ? v + 16'd1 : v - 16'd1;
                        pal_we <= 1'b1;
                        pal_wa <= pl_i[8:1];
                        pal_wd <= v;
                    end
                end
                if (t_done) begin
                    t_req <= 1'b0;
                    if (pl_i == 9'd511 + (t_rvalid ? 9'd0 : 9'd1) || pl_i + (t_rvalid ? 9'd1 : 9'd0) == 9'd0) begin
                        last_pal   <= {1'b0, rs_pal_off};
                        last_pal_v <= 1'b1;
                        rst <= R_QUAD;
                    end else begin
                        t_req  <= 1'b1;
                        t_addr <= TEX_BASE + {2'd0, rs_pal_off, 9'd0} + {15'd0, pl_i + (t_rvalid ? 9'd1 : 9'd0)};
                        t_len  <= 6'd32;
                    end
                end
            end
            // ---------------------------------------------------------- draw
            R_QUAD: begin
                if (!pkt[0][8] || q_endx < q_dx || q_endy < q_dy) begin
                    done <= 1'b1;
                    rst  <= R_IDLE;
                end else begin
                    q_transc     <= q_trans ? rgb32to16(rs_trans) : NOTRANS;
                    q_shadec     <= q_shade ? rs_shade : 24'hffffff;
                    q_fillc      <= rgb32to16(q_shade ? rs_shade : 24'hffffff);
                    q_fill_alpha <= q_blend && (rs_src_blend != 6'd0);
                    g_run <= 1'b1;
                    g_x   <= q_dx;
                    g_y   <= q_dy;
                    g_rtx <= rs_tx;  g_rty <= rs_ty;
                    g_tx  <= rs_tx;  g_ty  <= rs_ty;
                    rst   <= R_FILL;
                end
            end
            R_FILL: begin
                // pipeline runs (below); finished when the generator is done and the pipe is empty
                if (!g_run && !p1_v && !p2_v && !p2w_v && !p3_v && !p4_v && !p5_v && !p67_busy && !filling) begin
                    rst <= R_FLUSH;
                end
            end
            R_FLUSH: begin
                // the last segment goes to the write-back buffer once it is free; the packet is done when
                // every write-back has completed
                if (!w_req) begin
                    if (seg_v && seg_m != 32'd0) seg_to_wbuf();
                    seg_v <= 1'b0;
                    seg_m <= 32'd0;
                    rst   <= R_FLUSHW;
                end
            end
            R_FLUSHW: begin
                if (!w_req) begin
                    done <= 1'b1;
                    rst  <= R_IDLE;
                end
            end
            default: rst <= R_IDLE;
            endcase

            // ---- segment write-back progress (any state)
            if (w_req) begin
                if (w_wnext) wb_i <= wb_i + 5'd1;
                if (w_done) w_req <= 1'b0;
            end

            // ============================================================== pixel pipeline (R_FILL)
            if (rst == R_FILL) begin
                // ---- texture cache fills (P2 miss first: it is the older pixel)
                if (!filling && (p2_miss || p1_miss) && !t_req) begin
                    logic [21:0] wa;
                    wa = p2_miss ? p2w_word : p1_tile_wa;
                    filling   <= 1'b1;
                    fill_fin  <= 2'd0;
                    fill_dirty <= snoop_q && snoop_a == wa[21:4];
                    fill_wa   <= wa;
                    fill_tt   <= !p2_miss;
                    fill_i    <= 4'd0;
                    if (p2_miss) tc_val[wa[10:4]] <= 1'b0; else tt_val[wa[9:4]] <= 1'b0;
                    t_req  <= 1'b1;
                    t_addr <= TEX_BASE + {2'd0, wa[21:4], 4'd0};
                    t_len  <= 6'd16;
                end
                if (filling) begin
                    if (t_rvalid) begin
                        tc_we  <= 1'b1;
                        tc_wa  <= fill_tt ? {1'b0, fill_wa[9:4], fill_i} : {fill_wa[10:4], fill_i};
                        tc_wd  <= t_rdata;
                        fill_i <= fill_i + 4'd1;
                    end
                    if (t_done) begin
                        t_req    <= 1'b0;
                        fill_fin <= 2'd3;
                    end
                    if (fill_fin != 2'd0) begin
                        fill_fin <= fill_fin - 2'd1;
                        if (fill_fin == 2'd1) begin
                            filling <= 1'b0;
                            // a snoop of this line in the completing clock counts as well
                            if (fill_tt) begin
                                tt_tag[fill_wa[9:4]] <= fill_wa[21:10];
                                tt_val[fill_wa[9:4]] <= !fill_dirty && !(snoop_q && snoop_a == fill_wa[21:4]);
                            end else begin
                                tc_tag[fill_wa[10:4]] <= fill_wa[21:11];
                                tc_val[fill_wa[10:4]] <= !fill_dirty && !(snoop_q && snoop_a == fill_wa[21:4]);
                            end
                        end
                    end
                end

                // ---- segment management for P5
                // a pixel outside the current segment: hand the segment to the write-back buffer (when free) and
                // open the new one in the same clock
                if (p5_v && !p5_skip && !p5_in_seg && !f_req && !p67_busy && !(seg_v && seg_m != 32'd0 && w_req)) begin
                    if (seg_v && seg_m != 32'd0) seg_to_wbuf();
                    seg_v      <= 1'b1;
                    seg_base   <= {p5_fbword[23:5], 5'd0};
                    seg_m      <= 32'd0;
                    seg_loaded <= 1'b0;
                end
                // destination load for blending; not while that same segment is still being written back
                if (p5_v && !p5_skip && p5_in_seg && q_blend_any && !seg_loaded && !f_req && !p67_busy &&
                    !(w_req && w_addr[23:5] == seg_base[23:5])) begin
                    f_req  <= 1'b1;
                    f_addr <= seg_base;
                    f_len  <= 6'd32;
                    fl_i   <= 5'd0;
                end
                if (f_req) begin
                    if (f_rvalid) begin
                        if (!seg_m[fl_i]) seg[fl_i] <= f_rdata;
                        fl_i <= fl_i + 5'd1;
                    end
                    if (f_done) begin f_req <= 1'b0; seg_loaded <= 1'b1; end
                end

                // ---- P7: segment write; P6 -> P7
                if (p7_v) begin
                    seg[p7_idx]   <= p7_out;
                    seg_m[p7_idx] <= 1'b1;
                end
                p7_v <= p6_v; p7_idx <= p6_idx; p7_blend <= p6_blend; p7_col <= p6_src;
                for (int ch = 0; ch < 3; ch++) begin p7_pa[ch] <= p6_pa[ch]; p7_pb[ch] <= p6_pb[ch]; end
                // ---- P5 -> P6: shade + destination read. The data registers load every clock (no stall enable,
                //      so the shade multipliers need no clock enable); p6_v says whether they hold a pixel.
                p6_v     <= 1'b0;
                p6_idx   <= p5_fb[4:0];
                p6_blend <= q_blend_any;
                p6_src   <= (q_tex && q_shade) ? do_shade(p5_col, q_shadec) : p5_col;
                p6_dst   <= seg[p5_fb[4:0]];
                if (!stall) begin
                    if (p5_v && !p5_skip) begin
                        p6_v <= 1'b1;
                        stat_pixels <= stat_pixels + 32'd1;
                    end
                    // ---- P4 -> P5: transparency (on the unshaded texel colour, shade is applied in P5 -> P6)
                    p5_v <= p4_v; p5_x <= p4_x; p5_y <= p4_y; p5_fb <= p4_fbword;
                    if (q_tex) begin
                        p5_skip <= p4_skip || (p4_col == q_transc);
                        p5_col  <= p4_col;
                    end else begin
                        p5_skip <= p4_skip;
                        p5_col  <= q_fillc;
                    end
                    // ---- P3 -> P4: texel extract / palette (palette RAM read with p3_pidx this cycle)
                    p4_v <= p3_v; p4_x <= p3_x; p4_y <= p3_y; p4_skip <= p3_skip;
                    p4_tex16 <= tcb_e;
                    p4_pidx  <= p3_pidx;
                    // ---- P2W -> P3
                    p3_v <= p2w_v; p3_x <= p2w_x; p3_y <= p2w_y; p3_skip <= p2w_skip;
                    p3_word <= p2w_word; p3_lane <= p2w_lane;
                    // ---- P2 -> P2W
                    p2w_v <= p2_v; p2w_x <= p2_x; p2w_y <= p2_y; p2w_skip <= p2_skip_eff;
                    p2w_word <= p2_word; p2w_lane <= p2_lane;
                    // ---- P1 -> P2
                    p2_v <= p1_v; p2_x <= p1_x; p2_y <= p1_y; p2_skip <= p1_skip;
                    p2_sub <= {p1_ty[2:0] & maskh[2:0], p1_tx[2:0] & maskw[2:0]};
                    p2_off <= ({12'd0, p1_ty[9:0] & maskh} << rs_wlog << 3) + {12'd0, p1_tx[9:0] & maskw};
                    // ---- P0 -> P1: generator
                    p1_v <= g_run;
                    if (g_run) begin
                        logic [21:0] tx, ty;
                        tx = g_tx[30:9];
                        ty = g_ty[30:9];
                        p1_x <= g_x; p1_y <= g_y;
                        p1_tx <= tx; p1_ty <= ty;
                        p1_tile_wa <= tile_wa_of(tx, ty);
                        p1_skip <= q_tex && q_clamp && ({g_tx[31], tx} > {13'd0, maskw} || {g_ty[31], ty} > {13'd0, maskh});
                        if (g_x == q_endx) begin
                            if (g_y == q_endy) g_run <= 1'b0;
                            g_x   <= q_dx;
                            g_y   <= g_y + 9'd1;
                            g_rtx <= g_rtx + rs_txdy;
                            g_rty <= g_rty + rs_tydy;
                            g_tx  <= g_rtx + rs_txdy;
                            g_ty  <= g_rty + rs_tydy;
                        end else begin
                            g_x  <= g_x + 10'd1;
                            g_tx <= g_tx + rs_txdx;
                            g_ty <= g_ty + rs_tydx;
                        end
                    end
                end
            end
        end
    end

    // ---- cache / palette read addresses. Each RAM output belongs to the pixel one stage further on; while
    //      the pipeline is stalled the same addresses are re-read so the outputs stay with their pixels.
    always @* begin
        tca_a  = {p1_line, p1_tile_wa[3:0]};
        tcb_a  = {p2_line, p2w_word[3:0]};
        pal_ra = p3_pidx;
    end
    always @(posedge clk) if (!stall || rst != R_FILL) begin
        p2_tile_line_q <= p1_line; p2_tile_w_q <= p1_tile_wa[3:0];
        p3_line_q <= p2_line; p3_w_q <= p2w_word[3:0];
    end
endmodule
