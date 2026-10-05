// BrezzaSoft Crystal System MiSTer core -- Crystal System board (everything except the external memories).
// Copyright (C) 2026 Kyle Lester. SPDX-License-Identifier: GPL-3.0-or-later
//
// SE3208 + VRender0 blocks + board glue (crystal.cpp main_map), with memory traffic leaving through abstract
// ports that carry *physical* addresses (docs/SDRAM_BANDWIDTH.md):
//   phys[27]   = 0: SDRAM byte address phys[24:0]  (bank0 work RAM, bank1 texture RAM, bank2 frame RAM,
//                    bank3: BIOS at 0x1800000, NVRAM at 0x1820000)
//   phys[27]   = 1: cartridge flash byte offset phys[26:0] (bank * 16 MiB + offset), DDR3 store
// Port protocol: req held until ack (ack may come the same cycle), read data valid with ack.
module crystal_board (
    input  wire        clk,
    input  wire        rst_n,

    // configuration (MRA board record / OSD)
    input  wire  [3:0] flash_banks,       // populated 16 MiB flash banks
    input  wire  [5:0] cpu_credit_max,    // pacing burst limit (instructions)
    input  wire        cpu_turbo,         // ignore pacing (diagnostic)
    input  wire [15:0] render_interval,   // minimum clocks between display-list packets

    // inputs (active low, MAME port layout)
    input  wire [31:0] in_p1p2,
    input  wire [31:0] in_p3p4,
    input  wire  [7:0] in_system,
    input  wire  [7:0] in_dsw,
    output reg   [1:0] coin_counter,
    output reg  [15:0] lamps,

    // RTC seed
    input  wire        rtc_load,
    input  wire [47:0] rtc_bcd,

    // memory port I: instruction fetch (16-bit)
    output wire        mi_req,
    output wire [27:0] mi_addr,
    output wire [27:0] mi_pre_addr,
    input  wire        mi_ack,
    input  wire [15:0] mi_data,

    // memory port D: CPU/DMA data (32-bit, byte enables, lane-placed)
    output wire        md_req,
    output wire        md_we,
    output wire [27:0] md_addr,           // dword aligned
    output wire  [3:0] md_be,
    output wire [31:0] md_wdata,
    input  wire        md_ack,
    input  wire [31:0] md_rdata,

    // video engine SDRAM clients (word addresses, crystal_sdram client protocol)
    output wire        vt_req,
    output wire [23:0] vt_addr,
    output wire  [5:0] vt_len,
    input  wire        vt_rvalid,
    input  wire        vt_done,
    output wire        vf_req,
    output wire [23:0] vf_addr,
    output wire  [5:0] vf_len,
    input  wire        vf_rvalid,
    input  wire        vf_done,
    input  wire [15:0] v_rdata,
    output wire        vw_req,
    output wire [23:0] vw_addr,
    output wire  [5:0] vw_len,
    output wire [15:0] vw_wdata,
    output wire  [1:0] vw_wbe,
    input  wire        vw_wnext,
    input  wire        vw_done,
    // sound engine SDRAM client and output
    output wire        ss_req,
    output wire [23:0] ss_addr,
    output wire  [5:0] ss_len,
    input  wire        ss_rvalid,
    input  wire [15:0] ss_rdata,
    input  wire        ss_done,
    output wire signed [15:0] audio_l,
    output wire signed [15:0] audio_r,
    input  wire        tex_snoop,        // CPU/DMA write to texture RAM (SDRAM word address)
    input  wire [23:0] tex_snoop_addr,
    output wire [31:0] dbg_render_pixels,

    // video timing / scanout control
    output wire        ce_pix,
    output wire  [9:0] hcnt,
    output wire  [9:0] vcnt,
    output wire        hblank,
    output wire        vblank,
    output wire        hsync,
    output wire        vsync,
    output wire [22:0] display_dest,
    output wire        crt_blank,
    output wire  [9:0] geo_hdisp,
    output wire  [9:0] geo_vdisp,
    output wire  [9:0] geo_vtot,

    // debug
    output wire        dbg_retire,
    output wire [31:0] dbg_pc,
    output wire [15:0] dbg_opcode,
    output wire        dbg_took_irq,
    output wire        dbg_illegal,
    output wire [31:0] dbg_sr,
    output wire [31:0] dbg_sp,
    output wire [31:0] dbg_er,
    output wire [255:0] dbg_regs,
    output wire  [4:0] dbg_cpu_state,
    output wire        dbg_io_ack,        // a non-memory data access completed (value in dbg_io_rdata)
    output wire [31:0] dbg_io_rdata,
    output wire        dbg_cpu_irq,
    output wire  [7:0] dbg_irq_vector,
    output wire        dbg_vblank_start,
    output wire        dbg_d_ack,         // CPU data access completed
    output wire        dbg_d_we,
    output wire [31:0] dbg_d_addr,
    output wire  [3:0] dbg_d_be,
    output wire [31:0] dbg_d_wdata,
    output wire [31:0] dbg_d_rdata
);
    // ------------------------------------------------------------------ CPU and pacing
    wire        i_req, d_req, d_we, retire, iack, istart;
    wire [31:0] i_addr, d_addr, d_wdata, d_rdata, i_pre_addr;
    wire [15:0] i_data;
    wire  [3:0] d_be;
    wire        d_ack, i_ack;
    wire        cpu_irq;
    wire  [7:0] irq_vector;
    reg   [6:0] credit;
    reg   [2:0] pace;

    always @(posedge clk) begin
        if (!rst_n) begin
            credit <= 7'd1;
            pace   <= 3'd0;
        end else begin
            logic inc;
            inc  = (pace == 3'd5);
            pace <= inc ? 3'd0 : pace + 3'd1;
            case ({inc && credit < {1'b0, cpu_credit_max}, istart})
                2'b10: credit <= credit + 7'd1;
                2'b01: credit <= credit - 7'd1;
                default: ;
            endcase
        end
    end

    se3208_cpu cpu (
        .clk(clk), .rst_n(rst_n), .start_ok(cpu_turbo || credit != 7'd0),
        .i_req(i_req), .i_addr(i_addr), .i_pre_addr(i_pre_addr), .i_ack(i_ack), .i_data(i_data),
        .d_req(d_req), .d_we(d_we), .d_addr(d_addr), .d_be(d_be), .d_wdata(d_wdata), .d_ack(d_ack), .d_rdata(d_rdata),
        .irq(cpu_irq), .nmi(1'b0), .irq_vector(irq_vector), .iack(iack),
        .retire(retire), .start(istart), .illegal(dbg_illegal), .dbg_pc(dbg_pc), .dbg_opcode(dbg_opcode), .dbg_took_irq(dbg_took_irq),
        .dbg_sr(dbg_sr), .dbg_sp(dbg_sp), .dbg_er(dbg_er), .dbg_regs(dbg_regs), .dbg_state(dbg_cpu_state)
    );
    assign dbg_retire     = retire;
    assign dbg_d_ack      = d_ack;
    assign dbg_d_we       = d_we;
    assign dbg_d_addr     = d_addr;
    assign dbg_d_be       = d_be;
    assign dbg_d_wdata    = d_wdata;
    assign dbg_d_rdata    = d_rdata;
    assign dbg_cpu_irq    = cpu_irq;
    assign dbg_irq_vector = irq_vector;

    // ------------------------------------------------------------------ physical address map
    reg  [2:0] bank;
    reg [31:0] flashcmd;

    // returns {valid, phys}
    function automatic [28:0] phys_of(input [31:0] a, input [2:0] bk, input [3:0] nb);
        if (a < 32'h00020000)                          return {1'b1, 28'h1800000 | {11'd0, a[16:0]}};
        if (a >= 32'h01400000 && a < 32'h01410000)     return {1'b1, 28'h1820000 | {12'd0, a[15:0]}};
        if (a >= 32'h02000000 && a < 32'h03000000)     return {1'b1, 28'h0000000 | {5'd0, a[22:0]}};
        if (a >= 32'h03800000 && a < 32'h04000000)     return {1'b1, 28'h0800000 | {5'd0, a[22:0]}};
        if (a >= 32'h04000000 && a < 32'h04800000)     return {1'b1, 28'h1000000 | {5'd0, a[22:0]}};
        if (a >= 32'h05000000 && a < 32'h06000000 && {1'b0, bk} < nb)
                                                       return {1'b1, 1'b1, bk, a[23:0]};
        return 29'd0;
    endfunction

    // instruction fetches: memory regions only (unmapped/I-O fetches read 0)
    wire [28:0] i_phys = phys_of(i_addr, bank, flash_banks);
    wire        i_erased = (i_addr >= 32'h05000000 && i_addr < 32'h06000000 && !i_phys[28]);
    wire [28:0] i_pre_phys = phys_of(i_pre_addr, bank, flash_banks);
    assign mi_pre_addr = i_pre_phys[27:0];
    assign mi_req  = i_req && i_phys[28];
    assign mi_addr = i_phys[27:0];
    assign i_ack   = i_req && (i_phys[28] ? mi_ack : 1'b1);
    assign i_data  = i_phys[28] ? mi_data : (i_erased ? 16'hffff : 16'h0000);

    // ------------------------------------------------------------------ data bus: CPU / DMA arbitration
    wire        dma_req, dma_we;
    wire [31:0] dma_addr, dma_wdata;
    wire  [3:0] dma_be;
    reg         grant_dma;
    reg   [2:0] bs;                 // bus state
    localparam B_IDLE = 3'd0, B_MEM = 3'd1, B_IO = 3'd2, B_IOR = 3'd3, B_DONE = 3'd4, B_IOW = 3'd5;
    reg         b_we;
    reg  [31:0] b_addr, b_wdata, b_rdata;
    reg   [3:0] b_be;
    reg         b_ack;              // one-cycle completion pulse to the owning master
    reg         b_owner_dma;

    // registered bus path (I/O, flash command register, DMA) and a direct CPU path for memory regions
    reg         mdr_req, mdr_we;
    reg  [27:0] mdr_addr;
    reg   [3:0] mdr_be;
    reg  [31:0] mdr_wdata;
    wire [28:0] d_phys    = phys_of(d_addr, bank, flash_banks);
    wire        d_direct  = (bs == B_IDLE) && d_req && !dma_req && d_phys[28] && d_addr[31:2] != 30'h01400000;
    assign md_req   = d_direct ? 1'b1 : mdr_req;
    assign md_we    = d_direct ? (d_we && (d_addr >= 32'h00020000) && !(d_addr >= 32'h05000000 && d_addr < 32'h06000000)) : mdr_we;
    assign md_addr  = d_direct ? {d_phys[27:2], 2'b00} : mdr_addr;
    assign md_be    = d_direct ? d_be : mdr_be;
    assign md_wdata = d_direct ? d_wdata : mdr_wdata;
    assign d_ack   = d_direct ? md_ack : (b_ack && !b_owner_dma);
    assign d_rdata = d_direct ? md_rdata : b_rdata;
    wire   dma_ack = b_ack && b_owner_dma;
    reg    b_isio;
    assign dbg_io_ack   = b_ack && !b_owner_dma && b_isio;
    assign dbg_io_rdata = b_rdata;

    // io targets
    reg         sys_sel, vid_sel, snd_sel;
    wire [31:0] sys_rdata, vid_rdata, snd_rdata;
    reg  [1:0]  io_kind;            // 0 none/board, 1 sys, 2 video, 3 sound
    reg  [31:0] board_rdata;

    wire        lane_req = (grant_dma ? dma_req : d_req);

    always @(posedge clk) begin
        b_ack   <= 1'b0;
        sys_sel <= 1'b0; vid_sel <= 1'b0; snd_sel <= 1'b0;
        if (!rst_n) begin
            bs <= B_IDLE; mdr_req <= 1'b0; grant_dma <= 1'b0;
            bank <= 3'd0; flashcmd <= 32'hff; coin_counter <= 2'd0; lamps <= 16'd0;
        end else begin
            case (bs)
            B_IDLE: begin
                // pick a master: DMA if requesting and the CPU is not, or alternate
                logic use_dma;
                use_dma = dma_req && (!d_req || !grant_dma);
                if ((d_req || dma_req) && !d_direct) begin
                    logic [31:0] a;
                    logic [28:0] p;
                    grant_dma   <= use_dma;
                    b_owner_dma <= use_dma;
                    a       = use_dma ? dma_addr : d_addr;
                    b_addr  <= a;
                    b_we    <= use_dma ? dma_we : d_we;
                    b_be    <= use_dma ? dma_be : d_be;
                    b_wdata <= use_dma ? dma_wdata : d_wdata;
                    p = phys_of(a, bank, flash_banks);
                    b_isio <= 1'b0;
                    if (a[31:2] == 30'h01400000) begin       // 0x05000000: flash command / ID dword
                        b_isio <= 1'b1;
                        bs <= B_IO;
                    end else if (p[28]) begin
                        mdr_req   <= 1'b1;
                        mdr_we    <= (use_dma ? dma_we : d_we) && (a >= 32'h00020000) && !(a >= 32'h05000000 && a < 32'h06000000);
                        mdr_addr  <= {p[27:2], 2'b00};
                        mdr_be    <= use_dma ? dma_be : d_be;
                        mdr_wdata <= use_dma ? dma_wdata : d_wdata;
                        bs <= B_MEM;
                    end else begin
                        b_isio <= 1'b1;
                        bs <= B_IO;
                    end
                end
            end
            B_MEM: begin
                if (md_ack) begin
                    mdr_req <= 1'b0;
                    // erased/unpopulated flash and ROM writes are handled by phys_of / md_we
                    b_rdata <= md_rdata;
                    b_ack   <= 1'b1;
                    bs      <= B_DONE;
                end
            end
            B_IO: begin
                // issue the register access (one cycle), board registers handled here
                logic [31:0] a, d;
                a = b_addr;
                d = b_wdata;
                io_kind <= 2'd0;
                board_rdata <= 32'd0;
                if (a >= 32'h01800000 && a < 32'h01804000) begin sys_sel <= 1'b1; io_kind <= 2'd1; end
                else if (a >= 32'h03000000 && a < 32'h03010000) begin vid_sel <= 1'b1; io_kind <= 2'd2; end
                else if (a >= 32'h04800000 && a < 32'h04801000) begin snd_sel <= 1'b1; io_kind <= 2'd3; end
                else if (a[31:2] == 30'h00480000) begin               // 0x01200000
                    board_rdata <= in_p1p2;
                    if (b_we && b_be[0]) coin_counter <= d[1:0];
                end
                else if (a[31:2] == 30'h00480001) board_rdata <= in_p3p4;
                else if (a[31:2] == 30'h00480002) board_rdata <= {8'hff, in_system, 8'hff, in_dsw};
                else if (a[31:2] == 30'h004a0000) begin             // 0x01280000 bank select
                    if (b_we) bank <= d[3:1];
                end
                else if (a[31:2] == 30'h004c8000) begin             // 0x01320000 lamps (byte lanes 0 and 2)
                    if (b_we && b_be[0]) lamps[7:0]  <= d[7:0];
                    if (b_we && b_be[2]) lamps[15:8] <= d[23:16];
                end
                else if (a[31:2] == 30'h01400000) begin             // 0x05000000 flash command register
                    if (b_we) flashcmd <= d;
                    else begin
                        if (flashcmd[7:0] == 8'hff) begin
                            if ({1'b0, bank} < flash_banks) begin
                                // array read of the bank's first dword
                                mdr_req  <= 1'b1;
                                mdr_we   <= 1'b0;
                                mdr_addr <= {1'b1, bank, 24'd0};
                                mdr_be   <= 4'hf;
                                bs       <= B_MEM;
                            end else board_rdata <= 32'hffffffff;
                        end else if (flashcmd[7:0] == 8'h90)
                            board_rdata <= ({1'b0, bank} < flash_banks) ? 32'h00180089 : 32'hffffffff;
                        else
                            board_rdata <= 32'd0;
                    end
                end
                else if (a >= 32'h05000000 && a < 32'h06000000) board_rdata <= 32'hffffffff;   // erased bank
                if (!(a[31:2] == 30'h01400000 && !b_we && flashcmd[7:0] == 8'hff && {1'b0, bank} < flash_banks))
                    bs <= B_IOW;
            end
            B_IOW: bs <= B_IOR;      // register blocks see *_sel this cycle and register their read data
            B_IOR: begin
                case (io_kind)
                    2'd1: b_rdata <= sys_rdata;
                    2'd2: b_rdata <= vid_rdata;
                    2'd3: b_rdata <= snd_rdata;
                    default: b_rdata <= board_rdata;
                endcase
                b_ack <= 1'b1;
                bs    <= B_DONE;
            end
            B_DONE: bs <= B_IDLE;    // masters drop req on ack; one idle cycle before the next decode
            default: bs <= B_IDLE;
            endcase
        end
    end

    // lane-select read data for byte/word reads of the erased flash etc. is done by the CPU
    wire [11:0] io_dw  = b_addr[13:2];

    // ------------------------------------------------------------------ PIO / DS1302
    wire [31:0] pio_ldat, pio_wraw;
    wire        pio_wr;
    wire        rtc_io;
    crystal_ds1302 rtc (
        .clk(clk), .rst_n(rst_n), .ce(pio_wraw[24]), .sclk(pio_wraw[25]), .io_in(pio_wraw[28]), .sample(pio_wr),
        .io_out(rtc_io), .rtc_load(rtc_load), .rtc_bcd(rtc_bcd)
    );
    // MAME master: PIC data line (b29) = !written b29 (undumped PIC never drives it)
    reg pic_data;
    always @(posedge clk) if (!rst_n) pic_data <= 1'b1; else if (pio_wr) pic_data <= !pio_wraw[29];
    wire [31:0] pio_edat = {2'b00, pic_data, rtc_io, 28'd0};

    // ------------------------------------------------------------------ raster and vblank
    wire [9:0]  g_htot, g_vtot, g_hdisp, g_vdisp;
    wire [4:0]  g_tpp;
    wire [7:0]  g_hsw, g_hbp, g_vbp;
    wire        vb_irq_active;
    assign geo_hdisp = g_hdisp;
    assign geo_vdisp = g_vdisp;
    assign geo_vtot  = g_vtot;
    reg         frame_odd;
    reg         vb_q;
    wire [9:0]  hs_start = g_htot - {2'b0, g_hbp} - {2'b0, g_hsw};
    wire [9:0]  hs_end   = g_htot - {2'b0, g_hbp};
    wire [9:0]  vs_end   = g_vtot - {2'b0, g_vbp};
    wire [9:0]  vs_start = vs_end - 10'd3;
    crystal_raster raster (
        .clk(clk), .rst_n(rst_n),
        .htotal(g_htot), .hdisp(g_hdisp), .hs_start(hs_start), .hs_end(hs_end),
        .vtotal(g_vtot), .vdisp(g_vdisp), .vs_start(vs_start), .vs_end(vs_end),
        .div(g_tpp == 5'd0 ? 6'd12 : {1'b0, g_tpp}),
        .ce_pix(ce_pix), .hcnt(hcnt), .vcnt(vcnt), .hblank(hblank), .vblank(vblank), .hsync(hsync), .vsync(vsync)
    );
    always @(posedge clk) begin
        vb_q <= vblank;
        if (!rst_n) frame_odd <= 1'b0;
        else if (vblank && !vb_q) frame_odd <= !frame_odd;
    end
    wire vblank_start = vblank && !vb_q && vb_irq_active;
    assign dbg_vblank_start = vblank && !vb_q;

    // ------------------------------------------------------------------ VRender0 system block
    wire [31:0] irq_req;
    reg         coin1_q, coin2_q;
    always @(posedge clk) begin coin1_q <= in_system[4]; coin2_q <= in_system[5]; end
    wire        vid_vblank_irq;
    wire snd_irq;
    assign irq_req = (32'd1 << 24) & {32{vid_vblank_irq}}
                   | (32'd1 << 2)  & {32{snd_irq}}
                   | (32'd1 << 12) & {32{coin1_q && !in_system[4]}}   // coin 1 pressed (active low)
                   | (32'd1 << 19) & {32{coin2_q && !in_system[5]}};

    vr0_sys sys (
        .clk(clk), .rst_n(rst_n),
        .io_sel(sys_sel), .io_we(b_we), .io_addr(io_dw), .io_be(b_be), .io_wdata(b_wdata), .io_rdata(sys_rdata),
        .irq_req(irq_req), .cpu_irq(cpu_irq), .irq_vector(irq_vector),
        .dma_req(dma_req), .dma_we(dma_we), .dma_addr(dma_addr), .dma_be(dma_be), .dma_wdata(dma_wdata),
        .dma_ack(dma_ack), .dma_rdata(b_rdata),
        .pio_ldat(pio_ldat), .pio_wr(pio_wr), .pio_wdata_raw(pio_wraw), .pio_edat(pio_edat),
        .hpos(hcnt), .vpos(vcnt), .frame_odd(frame_odd),
        .geo_htot(g_htot), .geo_vtot(g_vtot), .geo_hdisp(g_hdisp), .geo_vdisp(g_vdisp), .geo_tpp(g_tpp),
        .geo_hsw(g_hsw), .geo_hbp(g_hbp), .geo_vbp(g_vbp),
        .crt_blank(crt_blank), .crt_interlace(), .vblank_irq_active(vb_irq_active)
    );

    // ------------------------------------------------------------------ video engine
    wire        pkt_start, pkt_done;
    wire [16:0] pkt_addr;
    wire  [1:0] pkt_flip;
    wire [22:0] draw_dest;
    vr0_video_regs vregs (
        .clk(clk), .rst_n(rst_n),
        .io_sel(vid_sel), .io_we(b_we), .io_addr(b_addr[15:2]), .io_be(b_be), .io_wdata(b_wdata), .io_rdata(vid_rdata),
        .vblank_start(vblank_start), .vblank_irq(vid_vblank_irq),
        .pkt_start(pkt_start), .pkt_addr(pkt_addr), .pkt_done(pkt_done), .pkt_flip(pkt_flip),
        .draw_dest(draw_dest), .display_dest(display_dest), .dither_mode(), .min_interval(render_interval)
    );

    vr0_render render (
        .clk(clk), .rst_n(rst_n),
        .start(pkt_start), .pkt_addr(pkt_addr), .draw_dest(draw_dest), .done(pkt_done), .flip(pkt_flip),
        .t_req(vt_req), .t_addr(vt_addr), .t_len(vt_len), .t_rvalid(vt_rvalid), .t_rdata(v_rdata), .t_done(vt_done),
        .f_req(vf_req), .f_addr(vf_addr), .f_len(vf_len), .f_rvalid(vf_rvalid), .f_rdata(v_rdata), .f_done(vf_done),
        .w_req(vw_req), .w_addr(vw_addr), .w_len(vw_len), .w_wdata(vw_wdata), .w_wbe(vw_wbe), .w_wnext(vw_wnext),
        .w_done(vw_done),
        .snoop(tex_snoop), .snoop_addr(tex_snoop_addr),
        .stat_pixels(dbg_render_pixels), .stat_busy_cycles(), .dbg(), .dbg2(), .dbg3()
    );

    // ------------------------------------------------------------------ sound engine registers
    wire [8:0]  s_eng_addr;
    wire [15:0] s_eng_rdata, s_eng_wdata;
    wire        s_eng_we;
    wire [31:0] s_status, s_int_mask, s_int_pend, s_st_clr, s_pend_set, s_touched, s_touch_clr;
    wire [4:0]  s_max_chan;
    wire [7:0]  s_clk_num;
    wire [15:0] s_ctrl;
    vr0_sound_regs sregs (
        .clk(clk), .rst_n(rst_n),
        .io_sel(snd_sel), .io_we(b_we), .io_addr(b_addr[11:2]), .io_be(b_be), .io_wdata(b_wdata), .io_rdata(snd_rdata),
        .eng_addr(s_eng_addr), .eng_rdata(s_eng_rdata), .eng_we(s_eng_we), .eng_wdata(s_eng_wdata),
        .status(s_status), .note_on(), .int_mask(s_int_mask), .int_pend(s_int_pend), .eng_status_clr(s_st_clr),
        .eng_pend_set(s_pend_set), .max_chan(s_max_chan), .chan_clk_num(s_clk_num), .ctrl(s_ctrl), .irq_clear(),
        .touched(s_touched), .touch_clr(s_touch_clr)
    );
    vr0_sound sound (
        .clk(clk), .rst_n(rst_n), .tick_in(1'b0),
        .eng_addr(s_eng_addr), .eng_rdata(s_eng_rdata), .eng_we(s_eng_we), .eng_wdata(s_eng_wdata),
        .status(s_status), .int_mask(s_int_mask), .int_pend(s_int_pend), .max_chan(s_max_chan),
        .chan_clk_num(s_clk_num), .ctrl(s_ctrl), .eng_status_clr(s_st_clr), .eng_pend_set(s_pend_set),
        .irq(snd_irq), .touched(s_touched), .touch_clr(s_touch_clr),
        .m_req(ss_req), .m_addr(ss_addr), .m_len(ss_len), .m_rvalid(ss_rvalid), .m_rdata(ss_rdata), .m_done(ss_done),
        .out_l(audio_l), .out_r(audio_r), .out_strobe()
    );
endmodule
