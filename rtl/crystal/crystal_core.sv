// BrezzaSoft Crystal System MiSTer core -- core top: loader, board, memory system, scanout.
// Copyright (C) 2026 Kyle Lester. SPDX-License-Identifier: GPL-3.0-or-later
//
// docs/ARCHITECTURE.md. SDRAM clients (priority order): 0 scanout, 1 sound, 2 instruction cache, 3 CPU/DMA data,
// 4 renderer texture reads, 5 renderer frame reads, 6 renderer frame writes, 7 loader.
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
    input  wire        ioctl_upload,
    input  wire        ioctl_rd,
    output wire [15:0] ioctl_din,
    output wire        ioctl_upload_req,

    input  wire [31:0] joy0, joy1, joy2, joy3,
    input  wire        sw_test,
    input  wire        cpu_turbo,
    input  wire [64:0] rtc,

    input  wire [15:0] SDRAM_DQ_I,
    output wire [15:0] SDRAM_DQ_O,
    output wire        SDRAM_DQ_OE,
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
    output reg         hblank, vblank, hsync, vsync,

    output wire signed [15:0] audio_l,
    output wire signed [15:0] audio_r,

    output wire        rom_loading,
    output wire        cpu_running,

    // simulation / diagnostics
    output wire        dbg_retire,
    output wire [31:0] dbg_pc,
    output wire        dbg_illegal,
    output wire [15:0] dbg_underflows,
    output wire  [4:0] dbg_cpu_state,
    output wire [31:0] dbg_render_pixels,
    output wire        dbg_d_ack,
    output wire        dbg_d_we,
    output wire [31:0] dbg_d_addr,
    output wire  [3:0] dbg_d_be,
    output wire [31:0] dbg_d_data,
    output wire [15:0] dbg_opcode,
    output wire        dbg_took_irq,
    output wire [31:0] dbg_sr,
    output wire [31:0] dbg_sp,
    output wire [31:0] dbg_er,
    output wire [255:0] dbg_regs,
    output wire        dbg_vblank_start
);
    wire [31:0] dbg_d_wdata_w, dbg_d_rdata_w;
    assign dbg_d_data = dbg_d_we ? dbg_d_wdata_w : dbg_d_rdata_w;
    // ------------------------------------------------------------------ loader and reset
    wire        ld_busy, ld_loaded;
    wire  [7:0] game_id, dsw;
    wire  [3:0] flash_banks;
    wire        lf_req, lf_ack;
    wire [26:0] lf_addr;
    wire [63:0] lf_data;
    wire  [7:0] lf_be;
    wire        ls_req, ls_wnext, ls_done;
    wire [23:0] ls_addr;
    wire  [5:0] ls_len;
    wire [15:0] ls_wdata;

    crystal_loader loader (
        .clk(clk_sys), .pll_locked(pll_locked),
        .ioctl_download(ioctl_download), .ioctl_index(ioctl_index), .ioctl_wr(ioctl_wr), .ioctl_addr(ioctl_addr),
        .ioctl_dout(ioctl_dout), .ioctl_wait(ld_wait),
        .busy(ld_busy), .game_id(game_id), .flash_banks(flash_banks), .dsw(dsw), .loaded(ld_loaded),
        .f_req(lf_req), .f_addr(lf_addr), .f_data(lf_data), .f_be(lf_be), .f_ack(lf_ack),
        .s_req(ls_req), .s_addr(ls_addr), .s_len(ls_len), .s_wdata(ls_wdata), .s_wnext(ls_wnext), .s_done(ls_done)
    );
    assign rom_loading = ld_busy;
    wire ld_wait, nv_wait;
    assign ioctl_wait = ld_wait | nv_wait;

    reg [7:0] rst_cnt;
    reg       board_rst_n;
    always @(posedge clk_sys) begin
        if (!pll_locked || ld_busy || reset_request || !sd_ready) begin
            rst_cnt <= 8'd0;
            board_rst_n <= 1'b0;
        end else if (!(&rst_cnt)) rst_cnt <= rst_cnt + 8'd1;
        else board_rst_n <= 1'b1;
    end
    assign cpu_running = board_rst_n;

    // ------------------------------------------------------------------ inputs (MiSTer joystick -> MAME ports)
    // joystick bits: 0 right, 1 left, 2 down, 3 up, 4 B1, 5 B2, 6 B3, 7 B4, 8 start, 9 coin, 10 service
    function automatic [7:0] pl(input [31:0] j);   // {right,left,down,up,b4,b3,b2,b1} for one player, active high
        return {j[0], j[1], j[2], j[3], j[7], j[6], j[5], j[4]};
    endfunction
    wire [7:0] p1 = pl(joy0), p2 = pl(joy1), p3 = pl(joy2), p4 = pl(joy3);
    // P1_P2: b0 P1 B1, b1 P2 B1, b2 P1 B2, b3 P2 B2, b4 P1 B3, b5 P2 B3, b6 P1 B4, b7 P2 B4,
    //        b16 P1 up, b17 P2 up, b18 P1 down, b19 P2 down, b20 P1 left, b21 P2 left, b22 P1 right, b23 P2 right
    function automatic [31:0] pair(input [7:0] a, input [7:0] c);
        return ~{8'h00,
                 c[7], a[7], c[6], a[6], c[5], a[5], c[4], a[4],
                 8'h00,
                 c[3], a[3], c[2], a[2], c[1], a[1], c[0], a[0]};
    endfunction
    wire [31:0] in_p1p2 = pair(p1, p2);
    wire [31:0] in_p3p4 = pair(p3, p4);
    // SYSTEM: b0-3 start1-4, b4 coin1, b5 coin2, b6 service1, b7 test (all active low)
    wire  [7:0] in_system = ~{sw_test, joy0[10] | joy1[10], joy1[9], joy0[9], joy3[8], joy2[8], joy1[8], joy0[8]};

    // ------------------------------------------------------------------ board
    reg         rtc_load;
    wire  [9:0] g_hdisp, g_vdisp, g_vtot;
    wire        mi_req, mi_ack, md_req, md_we, md_ack;
    wire [27:0] mi_addr, md_addr, mi_pre_addr;
    wire [15:0] mi_data;
    wire        vt_req, vf_req, vw_req;
    wire [23:0] vt_addr, vf_addr, vw_addr;
    wire  [5:0] vt_len, vf_len, vw_len;
    wire [15:0] vw_wdata;
    wire  [1:0] vw_wbe;
    wire        ss_req;
    wire [23:0] ss_addr;
    wire  [5:0] ss_len;
    wire  [3:0] md_be;
    wire [31:0] md_wdata, md_rdata;
    wire [22:0] display_dest;
    wire        crt_blank;
    wire [9:0]  hcnt, vcnt;
    wire        hb0, vb0, hs0, vs0;

    crystal_board board (
        .clk(clk_sys), .rst_n(board_rst_n),
        .flash_banks(flash_banks), .cpu_credit_max(6'd32), .cpu_turbo(cpu_turbo), .render_interval(16'd1100),
        .in_p1p2(in_p1p2), .in_p3p4(in_p3p4), .in_system(in_system), .in_dsw(dsw),
        .coin_counter(), .lamps(),
        .rtc_load(rtc_load), .rtc_bcd(rtc[47:0]),
        .mi_req(mi_req), .mi_addr(mi_addr), .mi_pre_addr(mi_pre_addr), .mi_ack(mi_ack), .mi_data(mi_data),
        .md_req(md_req), .md_we(md_we), .md_addr(md_addr), .md_be(md_be), .md_wdata(md_wdata), .md_ack(md_ack), .md_rdata(md_rdata),
        .vt_req(vt_req), .vt_addr(vt_addr), .vt_len(vt_len), .vt_rvalid(c_rvalid[4]), .vt_done(c_done[4]),
        .vf_req(vf_req), .vf_addr(vf_addr), .vf_len(vf_len), .vf_rvalid(c_rvalid[5]), .vf_done(c_done[5]),
        .v_rdata(sd_rdata),
        .vw_req(vw_req), .vw_addr(vw_addr), .vw_len(vw_len), .vw_wdata(vw_wdata), .vw_wbe(vw_wbe),
        .vw_wnext(c_wnext[6]), .vw_done(c_done[6]),
        .tex_snoop(da_inv && dc_inv_addr[24:23] == 2'b01), .tex_snoop_addr(dc_inv_addr[24:1]),
        .ss_req(ss_req), .ss_addr(ss_addr), .ss_len(ss_len), .ss_rvalid(c_rvalid[1]), .ss_rdata(sd_rdata), .ss_done(c_done[1]),
        .audio_l(audio_l), .audio_r(audio_r),
        .dbg_render_pixels(dbg_render_pixels),
        .ce_pix(ce_pix), .hcnt(hcnt), .vcnt(vcnt), .hblank(hb0), .vblank(vb0), .hsync(hs0), .vsync(vs0),
        .display_dest(display_dest), .crt_blank(crt_blank),
        .geo_hdisp(g_hdisp), .geo_vdisp(g_vdisp), .geo_vtot(g_vtot),
        .dbg_retire(dbg_retire), .dbg_pc(dbg_pc), .dbg_opcode(dbg_opcode), .dbg_took_irq(dbg_took_irq),
        .dbg_illegal(dbg_illegal), .dbg_sr(dbg_sr), .dbg_sp(dbg_sp), .dbg_er(dbg_er), .dbg_regs(dbg_regs),
        .dbg_cpu_state(dbg_cpu_state), .dbg_io_ack(), .dbg_io_rdata(), .dbg_cpu_irq(), .dbg_irq_vector(),
        .dbg_vblank_start(dbg_vblank_start), .dbg_d_ack(dbg_d_ack), .dbg_d_we(dbg_d_we), .dbg_d_addr(dbg_d_addr), .dbg_d_be(dbg_d_be),
        .dbg_d_wdata(dbg_d_wdata_w), .dbg_d_rdata(dbg_d_rdata_w)
    );

    // RTC: load once when MiSTer's RTC becomes valid (rtc[64] toggles on every update)
    reg rtc64_q, rtc_seen;
    always @(posedge clk_sys) begin
        rtc64_q <= rtc[64];
        rtc_load <= 1'b0;
        if (!board_rst_n) rtc_seen <= 1'b0;
        else if (rtc[64] != rtc64_q && !rtc_seen) begin rtc_load <= 1'b1; rtc_seen <= 1'b1; end
    end

    // ------------------------------------------------------------------ memory system
    localparam integer NC = 8;
    wire [NC-1:0] c_req, c_we, c_wnext, c_rvalid, c_done;
    wire [NC*24-1:0] c_addr;
    wire [NC*6-1:0]  c_len;
    wire [NC*16-1:0] c_wdata;
    wire [NC*2-1:0]  c_wbe;
    wire [15:0]      sd_rdata;
    wire             sd_ready;

    // client 0: scanout
    wire        sc_req, sc_rvalid, sc_done;
    wire [23:0] sc_addr;
    wire  [5:0] sc_len;
    // client 2: instruction cache
    wire        ic_req;
    wire [23:0] ic_addr;
    wire  [5:0] ic_len;
    // client 3: CPU/DMA data (D-cache)
    wire        da_inv;
    wire        da_req, da_we;
    wire [23:0] da_addr;
    wire  [5:0] da_len;
    wire [15:0] da_wdata16;
    wire  [1:0] da_wbe2;

    assign c_req   = {ls_req, vw_req, vf_req, vt_req, da_req, ic_req, ss_req, sc_req};
    assign c_we    = {1'b1, 1'b1, 1'b0, 1'b0, da_we, 1'b0, 1'b0, 1'b0};
    assign c_addr  = {ls_addr, vw_addr, vf_addr, vt_addr, da_addr, ic_addr, ss_addr, sc_addr};
    assign c_len   = {ls_len, vw_len, vf_len, vt_len, da_len, ic_len, ss_len, sc_len};
    assign c_wdata = {ls_wdata, vw_wdata, 16'd0, 16'd0, da_wdata16, 16'd0, 16'd0, 16'd0};
    assign c_wbe   = {2'b11, vw_wbe, 2'b11, 2'b11, da_wbe2, 2'b11, 2'b11, 2'b11};
    assign ls_wnext = c_wnext[7];
    assign ls_done  = c_done[7];

    crystal_sdram #(.NC(NC)) sdram (
        .clk(clk_sys), .init(!pll_locked),
        .c_req(c_req), .c_we(c_we), .c_addr(c_addr), .c_len(c_len), .c_wdata(c_wdata), .c_wbe(c_wbe),
        .c_wnext(c_wnext), .c_rvalid(c_rvalid), .rdata(sd_rdata), .c_done(c_done), .ready(sd_ready),
        .dq_o(SDRAM_DQ_O), .dq_oe(SDRAM_DQ_OE), .dq_i(SDRAM_DQ_I), .sd_a(SDRAM_A), .sd_ba(SDRAM_BA), .sd_ncs(SDRAM_nCS),
        .sd_nras(SDRAM_nRAS), .sd_ncas(SDRAM_nCAS), .sd_nwe(SDRAM_nWE), .sd_cke(SDRAM_CKE)
    );
    assign {SDRAM_DQMH, SDRAM_DQML} = SDRAM_A[12:11];
`ifdef VERILATOR
    assign SDRAM_CLK = ~clk_sys;
`else
    altddio_out #(
        .extend_oe_disable("OFF"), .intended_device_family("Cyclone V"), .invert_output("OFF"),
        .lpm_hint("UNUSED"), .lpm_type("altddio_out"), .oe_reg("UNREGISTERED"), .power_up_high("OFF"), .width(1)
    ) sdramclk_ddr (
        .datain_h(1'b0), .datain_l(1'b1), .outclock(clk_sys), .dataout(SDRAM_CLK),
        .aclr(1'b0), .aset(1'b0), .oe(1'b1), .outclocken(1'b1), .sclr(1'b0), .sset(1'b0)
    );
`endif

    // ---- flash store (DDR3)
    wire        fr0_ack, fr1_ack;
    wire [31:0] fr0_data;
    wire [15:0] fr1_data;
    crystal_flash_ddr flash (
        .clk(clk_sys), .rst_n(pll_locked),
        .r0_req(md_req && md_addr[27] && !md_we), .r0_addr(md_addr[26:0]), .r0_ack(fr0_ack), .r0_data(fr0_data),
        .r1_req(mi_req && mi_addr[27]), .r1_addr(mi_addr[26:0]), .r1_ack(fr1_ack), .r1_data(fr1_data),
        .w_req(lf_req), .w_addr(lf_addr), .w_data(lf_data), .w_be(lf_be), .w_ack(lf_ack),
        .DDRAM_BUSY(DDRAM_BUSY), .DDRAM_BURSTCNT(DDRAM_BURSTCNT), .DDRAM_ADDR(DDRAM_ADDR), .DDRAM_DOUT(DDRAM_DOUT),
        .DDRAM_DOUT_READY(DDRAM_DOUT_READY), .DDRAM_RD(DDRAM_RD), .DDRAM_DIN(DDRAM_DIN), .DDRAM_BE(DDRAM_BE),
        .DDRAM_WE(DDRAM_WE)
    );

    // ---- instruction fetch: SDRAM through the I-cache, flash through the flash store
    wire        ic_ack;
    wire [15:0] ic_data;
    crystal_icache icache (
        .clk(clk_sys), .rst_n(board_rst_n),
        .req(mi_req && !mi_addr[27]), .addr(mi_addr[24:0]), .pre_addr(mi_pre_addr[24:0]), .ack(ic_ack), .data(ic_data),
        .inv(da_inv), .inv_addr(dc_inv_addr), .hold(wb_busy),
        .m_req(ic_req), .m_addr(ic_addr), .m_len(ic_len), .m_rvalid(c_rvalid[2]), .m_rdata(sd_rdata), .m_done(c_done[2])
    );
    assign mi_ack  = mi_addr[27] ? fr1_ack : ic_ack;
    assign mi_data = mi_addr[27] ? fr1_data : ic_data;

    // ---- data port: D-cache + posted writes (CPU/DMA)
    wire        dc_ack, wb_busy;
    wire [31:0] dc_rdata;
    wire [24:0] dc_inv_addr;
    crystal_dcache dcache (
        .clk(clk_sys), .rst_n(board_rst_n),
        .req(md_req && !md_addr[27] && !nv_sel), .we(md_we), .addr(md_addr[24:0]), .be(md_be), .wdata(md_wdata),
        .ack(dc_ack), .rdata(dc_rdata),
        .inv(da_inv), .inv_addr(dc_inv_addr), .wb_busy(wb_busy),
        .m_req(da_req), .m_we(da_we), .m_addr(da_addr), .m_len(da_len), .m_wdata(da_wdata16), .m_wbe(da_wbe2),
        .m_wnext(c_wnext[3]), .m_rvalid(c_rvalid[3]), .m_rdata(sd_rdata), .m_done(c_done[3])
    );
    // flash writes (outside the command dword, handled by the board) are ignored: ack immediately
    // NVRAM (block RAM, persistent through MiSTer): SDRAM-space alias 0x1820000-0x182FFFF
    wire        nv_sel = !md_addr[27] && md_addr[24:16] == 9'h182;
    wire        nv_ack;
    wire [31:0] nv_rdata;
    crystal_nvram nvram (
        .clk(clk_sys),
        .req(md_req && nv_sel), .we(md_we), .addr(md_addr[15:2]), .be(md_be), .wdata(md_wdata),
        .ack(nv_ack), .rdata(nv_rdata),
        .ioctl_download(ioctl_download), .ioctl_upload(ioctl_upload), .ioctl_index(ioctl_index), .ioctl_wr(ioctl_wr),
        .ioctl_rd(ioctl_rd), .ioctl_addr(ioctl_addr), .ioctl_dout(ioctl_dout), .ioctl_din(ioctl_din),
        .ioctl_wait(nv_wait), .upload_req(ioctl_upload_req)
    );
    assign md_ack   = md_addr[27] ? (md_we ? md_req : fr0_ack) : nv_sel ? nv_ack : dc_ack;
    assign md_rdata = md_addr[27] ? fr0_data : nv_sel ? nv_rdata : dc_rdata;

    // ------------------------------------------------------------------ scanout
    vr0_scanout scanout (
        .clk(clk_sys), .rst_n(board_rst_n),
        .ce_pix(ce_pix), .hcnt(hcnt), .vcnt(vcnt), .hblank(hb0), .vblank(vb0),
        .hdisp(g_hdisp), .vdisp(g_vdisp), .vtotal(g_vtot),
        .display_dest(display_dest), .blank(crt_blank || !board_rst_n),
        .r(r), .g(g), .b(b),
        .m_req(sc_req), .m_addr(sc_addr), .m_len(sc_len), .m_rvalid(c_rvalid[0]), .m_rdata(sd_rdata), .m_done(c_done[0]),
        .underflows(dbg_underflows)
    );
    // scanout pixels are one pixel late: delay the timing signals to match
    always @(posedge clk_sys) if (ce_pix) begin
        hblank <= hb0; vblank <= vb0; hsync <= hs0; vsync <= vs0;
    end

endmodule
