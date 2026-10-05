// BrezzaSoft Crystal System MiSTer core -- VRender0 video engine registers, command queue and flip control.
// Copyright (C) 2026 Kyle Lester. SPDX-License-Identifier: GPL-3.0-or-later
//
// Behaviour: MAME video/vrender0.cpp (c2334733), docs/VRENDER0_VIDEO.md. Registers at 0x03000000 are 16-bit
// handlers called per accessed 16-bit lane. The packet processor (vr0_render) is started with the packet's
// texture-RAM word address and reports when it is done and whether the packet was a flip.
module vr0_video_regs (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        io_sel,
    input  wire        io_we,
    input  wire [13:0] io_addr,        // dword index within 0x03000000-0x0300FFFF
    input  wire  [3:0] io_be,
    input  wire [31:0] io_wdata,
    output reg  [31:0] io_rdata,

    input  wire        vblank_start,   // one pulse at the vblank rising edge of a frame that raises the IRQ
    output wire        vblank_irq,     // request IRQ 24 (same pulse)

    // packet processor handshake
    output reg         pkt_start,      // pulse: process the packet at texture word address pkt_addr
    output reg  [16:0] pkt_addr,       // queue index * 32 (16-bit word address in texture RAM)
    input  wire        pkt_done,       // pulse: packet finished
    input  wire  [1:0] pkt_flip,       // with pkt_done: b0 sync flip, b1 async flip
    output wire [22:0] draw_dest,      // frame-RAM byte address of the draw buffer
    output wire [22:0] display_dest,   // frame-RAM byte address of the displayed buffer
    output wire  [1:0] dither_mode,
    input  wire [15:0] min_interval    // minimum clocks between packet starts (MAME: 1100)
);
    reg  [15:0] q_front;
    reg  [10:0] q_rear;
    reg         bank1_sel, draw_sel, r_reset, r_start, flip_sync;
    reg         disp_bank;
    reg   [1:0] dither;
    reg   [7:0] flip_cnt;
    reg  [22:0] draw_d, disp_d;
    reg         busy;
    reg  [15:0] gap;

    assign draw_dest    = draw_d;
    assign display_dest = disp_d;
    assign dither_mode  = dither;
    assign vblank_irq   = vblank_start;

    wire [22:0] B1    = bank1_sel ? 23'h400000 : 23'h100000;
    wire [22:0] front = disp_bank ? B1 : 23'd0;
    wire [22:0] back  = disp_bank ? 23'd0 : B1;

    wire [15:0] off_lo = {io_addr[13:0], 2'b00};      // byte offset of lane 0
    wire        wr = io_sel && io_we;

    // 16-bit register write (one lane)
    task automatic w16(input [15:0] off, input [15:0] d, input [1:0] m);
        case (off)
            16'h0080: q_front <= {m[1] ? d[15:8] : q_front[15:8], m[0] ? d[7:0] : q_front[7:0]};
            16'h008c: if (m[0]) begin
                draw_sel <= d[7];
                r_reset  <= d[3];
                r_start  <= d[2];
                dither   <= d[1:0];
                if (d[3]) begin q_front <= 16'd0; q_rear <= 11'd0; end
            end
            16'h0090: bank1_sel <= d[15];
            16'h00a6: if (m[0]) begin
                if (d[7:0] == 8'd1) flip_cnt <= flip_cnt + 8'd1;
                else if (d[7:0] == 8'd0) flip_cnt <= 8'd0;
            end
            default: ;
        endcase
    endtask
    function automatic [15:0] r16(input [15:0] off);
        case (off)
            16'h0080: return {5'd0, q_front[10:0]};
            16'h0082: return {5'd0, q_rear};
            16'h008c: return {8'd0, draw_sel, 3'd0, r_reset, r_start, dither};
            16'h008e: return {15'd0, disp_bank};
            16'h0090: return {bank1_sel, 15'd0};
            16'h00a6: return {8'd0, flip_cnt};
            default:  return 16'd0;
        endcase
    endfunction

    always @(posedge clk) begin
        pkt_start <= 1'b0;
        if (!rst_n) begin
            q_front <= 16'd0; q_rear <= 11'd0;
            bank1_sel <= 1'b0; draw_sel <= 1'b0; r_reset <= 1'b0; r_start <= 1'b0; flip_sync <= 1'b0;
            disp_bank <= 1'b0; dither <= 2'd0; flip_cnt <= 8'd0;
            draw_d <= 23'd0; disp_d <= 23'd0;
            busy <= 1'b0; gap <= 16'd0;
        end else begin
            if (gap != 16'd0) gap <= gap - 16'd1;

            // packet completion (MAME pipeline_cb after process_packet)
            if (busy && pkt_done) begin
                busy   <= 1'b0;
                q_rear <= q_rear + 11'd1;
                if (pkt_flip[0]) flip_sync <= 1'b1;
                if (pkt_flip[1]) draw_d <= draw_sel ? back : front;
            end
            // packet issue
            if (!busy && gap == 16'd0 && r_start && !flip_sync && (q_rear != q_front[10:0])) begin
                busy      <= 1'b1;
                pkt_start <= 1'b1;
                pkt_addr  <= {1'b0, q_rear, 5'd0};
                gap       <= min_interval;
            end

            // vblank flip (execute_flipping)
            if (vblank_start && r_start && flip_cnt != 8'd0) begin
                draw_d    <= draw_sel ? front : back;
                disp_d    <= front;
                flip_sync <= 1'b0;
                flip_cnt  <= flip_cnt - 8'd1;
                disp_bank <= !disp_bank;
            end

            if (wr) begin
                if (io_be[1:0] != 2'b00) w16(off_lo, io_wdata[15:0], io_be[1:0]);
                if (io_be[3:2] != 2'b00) w16(off_lo + 16'd2, io_wdata[31:16], io_be[3:2]);
            end
        end
    end

    always @(posedge clk)
        if (io_sel && !io_we)
            io_rdata <= {io_be[3:2] != 2'b00 ? r16(off_lo + 16'd2) : 16'd0, io_be[1:0] != 2'b00 ? r16(off_lo) : 16'd0};
endmodule
