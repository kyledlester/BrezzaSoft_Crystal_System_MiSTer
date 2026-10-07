// BrezzaSoft Crystal System MiSTer core -- VRender0 system block (base 0x01800000).
// Copyright (C) 2026 Kyle Lester. SPDX-License-Identifier: GPL-3.0-or-later
//
// Interrupt controller, 4 timers, 2 DMA channels, UART register stub, PIO latch, CRTC registers + raster.
// Behaviour: MAME machine/vrender0.cpp (c2334733), docs/VRENDER0_SYSTEM.md. Generic: no board knowledge.
//
// Register port: dword offset `io_addr` (byte offset >> 2 within the 16 KiB block), byte enables `io_be`,
// lane-placed `io_wdata`; read data is registered (valid the cycle after io_sel).
module vr0_sys (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        soc_ce,           // VRender0 clock enable (1 = clk_sys; Top Blade V: 95 of 102 clocks)

    input  wire        io_sel,
    input  wire        io_we,
    input  wire [11:0] io_addr,
    input  wire  [3:0] io_be,
    input  wire [31:0] io_wdata,
    output reg  [31:0] io_rdata,

    input  wire [31:0] irq_req,        // one-cycle request pulses from outside (vblank, sound, coins, ...)
    output wire        cpu_irq,
    output wire  [7:0] irq_vector,

    // DMA bus master (aligned accesses, same protocol as the CPU data port)
    output reg         dma_req,
    output reg         dma_we,
    output reg  [31:0] dma_addr,
    output reg   [3:0] dma_be,
    output reg  [31:0] dma_wdata,
    input  wire        dma_ack,
    input  wire [31:0] dma_rdata,

    // PIO
    output reg  [31:0] pio_ldat,       // latched output register
    output reg         pio_wr,         // pulse: PIOLDAT written (board samples pio_wdata_raw)
    output reg  [31:0] pio_wdata_raw,  // the written data as MAME passes it (unaccessed lanes 0)
    input  wire [31:0] pio_edat,       // external pin levels

    // raster (from the board video timing) and CRTC geometry (to it)
    input  wire  [9:0] hpos,
    input  wire  [9:0] vpos,
    input  wire        frame_odd,
    output reg   [9:0] geo_htot,
    output reg   [9:0] geo_vtot,
    output reg   [9:0] geo_hdisp,
    output reg   [9:0] geo_vdisp,
    output reg   [4:0] geo_tpp,        // clk_sys per pixel
    output reg   [7:0] geo_hsw,        // HSWBP[15:8]+1 (sync width, see docs)
    output reg   [7:0] geo_hbp,        // HSWBP[7:0]+1
    output reg   [7:0] geo_vbp,        // VSBP[7:0]+1
    output wire        crt_blank,      // CRTMOD b9
    output wire        crt_interlace,
    output wire        vblank_irq_active  // this frame raises the vblank interrupt (interlace field select)
);
    // ------------------------------------------------------------------ helpers
    function automatic [31:0] merge(input [31:0] old, input [31:0] d, input [3:0] be);
        return {be[3] ? d[31:24] : old[31:24], be[2] ? d[23:16] : old[23:16],
                be[1] ? d[15:8] : old[15:8], be[0] ? d[7:0] : old[7:0]};
    endfunction
    wire [31:0] bemask = {{8{io_be[3]}}, {8{io_be[2]}}, {8{io_be[1]}}, {8{io_be[0]}}};
    wire        wr = io_sel && io_we;
    wire [13:0] off = {io_addr, 2'b00};

    // ------------------------------------------------------------------ interrupt controller
    reg  [31:0] inten, intst;
    reg   [2:0] int_high;
    wire [31:0] req_all;
    reg  [31:0] req_int;          // internal sources this cycle (timers, DMA)
    assign req_all = irq_req | req_int;
    assign cpu_irq = (intst != 32'd0);

    reg [4:0] lowest;
    integer b;
    always @* begin
        lowest = 5'd0;
        for (b = 31; b >= 0; b--) if (intst[b]) lowest = b[4:0];
    end
    assign irq_vector = {int_high, lowest};

    // ------------------------------------------------------------------ timers
    reg  [31:0] tm_con [0:3];
    reg  [15:0] tm_cnt [0:3];
    reg  [25:0] tm_left[0:3];
    // period 2*(prescale+1)*(count+1), registered (timing). A start loads the counter two clocks after the
    // TimerControl write (tm_st1 -> tm_st2), with the count compensated so the expiry clock is unchanged.
    // Auto-reload uses the period of the previous clock.
    reg  [25:0] tm_per [0:3];
    reg   [3:0] tm_st1, tm_st2;
    reg   [3:0] tm_run;
    function automatic [4:0] tirq(input integer t);
        case (t)
            0: return 5'd0;
            1: return 5'd1;
            2: return 5'd9;
            default: return 5'd10;
        endcase
    endfunction

    function automatic [25:0] tperiod(input [31:0] con, input [15:0] cnt);
        return ({18'd0, con[15:8]} + 26'd1) * ({10'd0, cnt} + 26'd1) * 26'd2;
    endfunction

    // ------------------------------------------------------------------ DMA
    reg  [15:0] dma_ctrl [0:1];
    reg  [31:0] dma_src  [0:1];
    reg  [31:0] dma_dst  [0:1];
    reg  [23:0] dma_cnt  [0:1];
    reg   [2:0] dma_wait [0:1];   // clocks until the next unit may start
    reg         dma_ch;           // channel owning the bus sequence
    reg   [1:0] dma_ph;           // 0 idle, 1 read, 2 write
    reg  [31:0] dma_buf;

    function automatic signed [3:0] dstep(input [15:0] c, input integer hold, input integer dir);
        logic [3:0] amt;
        if (c[hold]) return 4'sd0;
        amt = c[1] ? 4'd4 : (c[0] ? 4'd2 : 4'd1);
        return c[dir] ? -$signed(amt) : $signed(amt);
    endfunction
    function automatic [3:0] dbe(input [1:0] a, input [1:0] w);
        if (w[1]) return 4'b1111;
        if (w[0]) return a[1] ? 4'b1100 : 4'b0011;
        return 4'b0001 << a;
    endfunction

    // ------------------------------------------------------------------ UART stub, light pen
    reg [31:0] uart_ucon [0:1];
    reg [31:0] uart_ubdr [0:1];
    reg  [1:0] lightc;

    // ------------------------------------------------------------------ CRTC
    reg  [31:0] crtc [0:13];   // 0x00..0x34
    reg         crtc_dirty;
    assign crt_blank     = crtc[0][9];
    assign crt_interlace = !crtc[12][0];
    assign vblank_irq_active = !crt_interlace || (frame_odd ^ crtc[0][3]);

    function automatic [31:0] crtc_wmask(input [3:0] idx);
        case (idx)
            4'd0:  return 32'h000003ff;
            4'd1:  return 32'h00003fff;
            4'd2:  return 32'h0000ffff;
            4'd3:  return 32'h000003ff;
            4'd4:  return 32'h000001ff;
            4'd5:  return 32'h00007f3f;
            4'd6:  return 32'h000000ff;
            4'd7:  return 32'h000001ff;
            4'd8:  return 32'h00001fff;
            4'd9:  return 32'h00000fff;
            4'd10: return 32'h000003ff;
            4'd11: return 32'h00007fff;
            4'd12: return 32'h00007fff;
            default: return 32'h00000000;
        endcase
    endfunction

    // ------------------------------------------------------------------ main
    integer i;
    always @(posedge clk) begin
        req_int <= 32'd0;
        pio_wr  <= 1'b0;
        if (!rst_n) begin
            inten <= 32'd0; intst <= 32'd0; int_high <= 3'd0;
            for (i = 0; i < 4; i++) begin tm_con[i] <= 32'h0000ff00; tm_run[i] <= 1'b0; tm_cnt[i] <= 16'd0; tm_left[i] <= 26'd0; end
            tm_st1 <= 4'd0; tm_st2 <= 4'd0;
            for (i = 0; i < 2; i++) begin dma_ctrl[i] <= 16'd0; dma_wait[i] <= 3'd0; dma_src[i] <= 32'd0; dma_dst[i] <= 32'd0; dma_cnt[i] <= 24'd0; end
            dma_ph <= 2'd0; dma_req <= 1'b0;
            for (i = 0; i < 14; i++) crtc[i] <= 32'd0;
            crtc[1] <= 32'h0000002a;
            crtc_dirty <= 1'b0;
            uart_ucon[0] <= 32'd1; uart_ucon[1] <= 32'd1; uart_ubdr[0] <= 32'd1; uart_ubdr[1] <= 32'd1;
            lightc <= 2'd0;
            pio_ldat <= 32'd0;
            geo_htot <= 10'd455; geo_vtot <= 10'd262; geo_hdisp <= 10'd320; geo_vdisp <= 10'd240; geo_tpp <= 5'd12;
            geo_hsw <= 8'd34; geo_hbp <= 8'd60; geo_vbp <= 8'd15;
        end else begin
            // ---------------- timers (VRender0 clocks)
            if (soc_ce) begin
            tm_st1 <= 4'd0;
            tm_st2 <= tm_st1;
            for (i = 0; i < 4; i++) begin
                logic [25:0] left;
                tm_per[i] <= tperiod(tm_con[i], tm_cnt[i]);
                // counter value before this clock: after a start it would be period - 1 by now
                left = tm_st2[i] ? tm_per[i] - 26'd1 : tm_left[i];
                if (tm_run[i] && !tm_st1[i]) begin
                    if (left <= 26'd1) begin
                        if (tm_con[i][1]) tm_left[i] <= tm_per[i];
                        else begin tm_run[i] <= 1'b0; tm_con[i][0] <= 1'b0; end
                        req_int[tirq(i)] <= 1'b1;
                    end else
                        tm_left[i] <= left - 26'd1;
                end
            end
            end

            // ---------------- interrupt latch (masked requests are dropped, as MAME)
            intst <= intst | (req_all & inten);

            // ---------------- DMA engine (one unit at a time, channel 0 first)
            if (soc_ce) for (i = 0; i < 2; i++) if (dma_wait[i] != 3'd0) dma_wait[i] <= dma_wait[i] - 3'd1;
            case (dma_ph)
            2'd0: begin
                if (dma_ctrl[0][10] && dma_wait[0] == 3'd0) begin
                    if (dma_cnt[0] == 24'd0) begin dma_ctrl[0][10] <= 1'b0; req_int[7] <= 1'b1; end
                    else begin
                        dma_ch <= 1'b0; dma_ph <= 2'd1; dma_req <= 1'b1; dma_we <= 1'b0;
                        dma_addr <= {dma_src[0][31:2], dma_ctrl[0][1] ? 2'b00 : {dma_src[0][1], dma_ctrl[0][0] ? 1'b0 : dma_src[0][0]}};
                        dma_be <= dbe(dma_src[0][1:0], dma_ctrl[0][1:0]);
                        dma_wait[0] <= 3'd4;
                    end
                end else if (dma_ctrl[1][10] && dma_wait[1] == 3'd0) begin
                    if (dma_cnt[1] == 24'd0) begin dma_ctrl[1][10] <= 1'b0; req_int[8] <= 1'b1; end
                    else begin
                        dma_ch <= 1'b1; dma_ph <= 2'd1; dma_req <= 1'b1; dma_we <= 1'b0;
                        dma_addr <= {dma_src[1][31:2], dma_ctrl[1][1] ? 2'b00 : {dma_src[1][1], dma_ctrl[1][0] ? 1'b0 : dma_src[1][0]}};
                        dma_be <= dbe(dma_src[1][1:0], dma_ctrl[1][1:0]);
                        dma_wait[1] <= 3'd4;
                    end
                end
            end
            2'd1: if (dma_ack) begin
                // move the read lanes to the destination lanes
                logic [31:0] v, d;
                logic [1:0] sa, da;
                logic [15:0] c;
                c  = dma_ctrl[dma_ch];
                sa = c[1] ? 2'b00 : (c[0] ? {dma_src[dma_ch][1], 1'b0} : dma_src[dma_ch][1:0]);
                da = c[1] ? 2'b00 : (c[0] ? {dma_dst[dma_ch][1], 1'b0} : dma_dst[dma_ch][1:0]);
                v  = dma_rdata >> {sa, 3'b000};
                d  = v << {da, 3'b000};
                dma_we    <= 1'b1;
                dma_addr  <= {dma_dst[dma_ch][31:2], da};
                dma_be    <= dbe(dma_dst[dma_ch][1:0], c[1:0]);
                dma_wdata <= d;
                dma_ph    <= 2'd2;
            end
            2'd2: if (dma_ack) begin
                logic [15:0] c;
                logic [3:0] ss, ds;
                c = dma_ctrl[dma_ch];
                dma_req <= 1'b0;
                dma_we  <= 1'b0;
                ss = dstep(c, 5, 4);
                ds = dstep(c, 3, 2);
                dma_src[dma_ch] <= dma_src[dma_ch] + {{28{ss[3]}}, ss};
                dma_dst[dma_ch] <= dma_dst[dma_ch] + {{28{ds[3]}}, ds};
                dma_cnt[dma_ch] <= dma_cnt[dma_ch] - 24'd1;
                dma_ph <= 2'd0;
            end
            default: dma_ph <= 2'd0;
            endcase

            // ---------------- CRTC derived geometry (MAME crtc_update), one cycle after a changing write
            if (crtc_dirty) begin
                logic [10:0] hdisp, vdisp, htot, vtot;
                logic [7:0] hbp, hsw, hsfp, vbp;
                logic ok;
                logic [5:0] tpp;
                crtc_dirty <= 1'b0;
                ok    = 1'b1;
                hdisp = {1'b0, crtc[3][9:0]} + 11'd1;
                vdisp = {2'b0, crtc[7][8:0]};
                if (crtc[7][8:0] == 9'd0) ok = 1'b0;
                if (crt_interlace) vdisp = vdisp << 1;
                htot  = {1'b0, crtc[8][9:0]} + 11'd1;
                vtot  = crtc[9][10:0];
                hbp   = crtc[2][15:8];
                hsw   = crtc[2][7:0];
                hsfp  = crtc[4][7:0];
                vbp   = crtc[2][7:0];
                if (htot <= 11'd1 || htot <= hdisp) begin
                    if (hbp == 8'd0 && hsw == 8'd0 && hsfp == 8'd0) ok = 1'b0;
                    else begin
                        htot = hdisp + {3'd0, hbp} + {3'd0, hsw} + {3'd0, hsfp} + 11'd3;
                        crtc[8] <= {22'd0, htot[9:0] - 10'd1};
                    end
                end
                if (ok && vtot == 11'd0) begin
                    if (vbp == 8'd0) ok = 1'b0;
                    else begin
                        vtot = vdisp + {3'd0, vbp} + 11'd1;
                        crtc[9] <= {21'd0, vtot - 11'd1};
                    end
                end
                if (!crtc[1][3]) ok = 1'b0;   // external VCLK: MAME fatalerror; keep the previous geometry
                tpp = 6'd6 * ({3'd0, crtc[1][2:0]} + 6'd1);
                if (crtc[1][7]) tpp = tpp >> 1;
                if (!crt_interlace) vtot = (vtot >> 1) + 11'd1;
                vtot = vtot + 11'd9;
                if (ok) begin
                    geo_htot  <= htot[9:0];
                    geo_vtot  <= vtot[9:0];
                    geo_hdisp <= hdisp[9:0];
                    geo_vdisp <= vdisp[9:0];
                    geo_tpp   <= tpp[4:0];
                    geo_hsw   <= crtc[2][15:8] + 8'd1;
                    geo_hbp   <= crtc[2][7:0] + 8'd1;
                    geo_vbp   <= crtc[6][7:0] + 8'd1;
                end
            end

            // ---------------- register writes
            if (wr) begin
                case (off)
                14'h0800, 14'h0810: begin
                    logic ch;
                    logic [15:0] nc;
                    ch = off[4];
                    if (io_be[1:0] != 2'b00) begin
                        nc = merge({16'd0, dma_ctrl[ch]}, io_wdata, io_be);
                        if (!dma_ctrl[ch][10] && nc[10]) dma_wait[ch] <= 3'd2;   // first unit 2 clocks later
                        dma_ctrl[ch] <= nc;
                    end
                end
                14'h0804: dma_src[0] <= merge(dma_src[0], io_wdata, io_be);
                14'h0808: dma_dst[0] <= merge(dma_dst[0], io_wdata, io_be);
                14'h080c: dma_cnt[0] <= merge({8'd0, dma_cnt[0]}, io_wdata, io_be);
                14'h0814: dma_src[1] <= merge(dma_src[1], io_wdata, io_be);
                14'h0818: dma_dst[1] <= merge(dma_dst[1], io_wdata, io_be);
                14'h081c: dma_cnt[1] <= merge({8'd0, dma_cnt[1]}, io_wdata, io_be);
                14'h0c04: begin
                    logic [31:0] cl;
                    cl = 32'd0;
                    if (io_be[0]) cl = 32'd1 << io_wdata[4:0];
                    intst <= (intst | (req_all & inten)) & ~cl;
                    if (io_be[1]) int_high <= io_wdata[10:8];
                end
                14'h0c08: begin
                    logic [31:0] ne;
                    ne = merge(inten, io_wdata, io_be);
                    inten <= ne;
                    intst <= (intst | (req_all & inten)) & ne;
                end
                14'h1000: uart_ucon[0] <= merge(uart_ucon[0], io_wdata, io_be);
                14'h1020: uart_ucon[1] <= merge(uart_ucon[1], io_wdata, io_be);
                14'h1010: uart_ubdr[0] <= merge(uart_ubdr[0], io_wdata, io_be);
                14'h1030: uart_ubdr[1] <= merge(uart_ubdr[1], io_wdata, io_be);
                14'h1400, 14'h1408, 14'h1410, 14'h1418: begin
                    logic [1:0] t;
                    logic [31:0] nc;
                    t  = off[4:3];
                    nc = merge(tm_con[t], io_wdata, io_be);
                    tm_con[t] <= nc;
                    if (nc[0] != tm_con[t][0]) begin
                        if (nc[0]) begin tm_run[t] <= 1'b1; tm_st1[t] <= 1'b1; end
                        else tm_run[t] <= 1'b0;
                    end
                end
                14'h1404, 14'h140c, 14'h1414, 14'h141c: begin
                    logic [1:0] t;
                    t = off[4:3];
                    tm_cnt[t] <= merge({16'd0, tm_cnt[t]}, io_wdata, {2'b00, io_be[1:0]});
                end
                14'h2004: begin
                    pio_ldat      <= merge(pio_ldat, io_wdata, io_be);
                    pio_wdata_raw <= io_wdata & bemask;
                    pio_wr        <= 1'b1;
                end
                14'h3448: if (io_be[0]) lightc <= io_wdata[1:0];
                default: begin
                    if (off >= 14'h3400 && off < 14'h3438) begin
                        logic [3:0] idx;
                        logic [31:0] m, nv;
                        logic skip;
                        idx  = off[5:2];
                        m    = crtc_wmask(idx) & bemask;
                        skip = (crtc[0][8] && idx != 4'd0 && idx < 4'd10);
                        if (idx == 4'd8 && !io_wdata[10]) skip = 1'b1;
                        if (idx == 4'd9 && !io_wdata[11]) skip = 1'b1;
                        if (idx == 4'd13) skip = 1'b1;   // TCOL: not stored by MAME
                        nv = (crtc[idx] & ~m) | (io_wdata & m);
                        if (!skip) begin
                            crtc[idx] <= nv;
                            if (nv != crtc[idx]) crtc_dirty <= 1'b1;
                        end
                    end
                end
                endcase
            end
        end
    end

    // ------------------------------------------------------------------ register reads (registered)
    always @(posedge clk) begin
        if (io_sel && !io_we) begin
            case (off)
            14'h0000: io_rdata <= 32'h00000a00;
            14'h0004: io_rdata <= 32'h00000041;
            14'h0800: io_rdata <= {16'd0, dma_ctrl[0]};
            14'h0804: io_rdata <= dma_src[0];
            14'h0808: io_rdata <= dma_dst[0];
            14'h080c: io_rdata <= {8'd0, dma_cnt[0]};
            14'h0810: io_rdata <= {16'd0, dma_ctrl[1]};
            14'h0814: io_rdata <= dma_src[1];
            14'h0818: io_rdata <= dma_dst[1];
            14'h081c: io_rdata <= {8'd0, dma_cnt[1]};
            14'h0c04: io_rdata <= {21'd0, int_high, 8'd0};
            14'h0c08: io_rdata <= inten;
            14'h0c0c: io_rdata <= intst;
            14'h1000: io_rdata <= uart_ucon[0];
            14'h1020: io_rdata <= uart_ucon[1];
            14'h1010: io_rdata <= uart_ubdr[0];
            14'h1030: io_rdata <= uart_ubdr[1];
            14'h1400: io_rdata <= tm_con[0];
            14'h1408: io_rdata <= tm_con[1];
            14'h1410: io_rdata <= tm_con[2];
            14'h1418: io_rdata <= tm_con[3];
            14'h1404: io_rdata <= {16'd0, tm_cnt[0]};
            14'h140c: io_rdata <= {16'd0, tm_cnt[1]};
            14'h1414: io_rdata <= {16'd0, tm_cnt[2]};
            14'h141c: io_rdata <= {16'd0, tm_cnt[3]};
            14'h2004: io_rdata <= pio_ldat;
            14'h2008: io_rdata <= pio_edat;
            14'h3448: io_rdata <= {30'd0, lightc};
            default: begin
                if (off == 14'h3400) begin
                    logic [10:0] hd, vd;
                    logic [31:0] r;
                    hd = {1'b0, crtc[3][9:0]} + 11'd1;
                    vd = {2'b0, crtc[7][8:0]} + 11'd1;
                    if (crt_interlace) vd = vd << 1;
                    r = {22'd0, crtc[0][9:0]};
                    if ({1'b0, vpos} <= vd) r[14] = 1'b1;
                    if ({1'b0, hpos} <= hd && {1'b0, vpos} <= vd) r[13] = 1'b1;
                    if ({1'b0, hpos} <= hd) r[15] = 1'b1;
                    io_rdata <= r;
                end else if (off > 14'h3400 && off < 14'h3438)
                    io_rdata <= crtc[off[5:2]];
                else
                    io_rdata <= 32'd0;
            end
            endcase
        end
    end
endmodule
