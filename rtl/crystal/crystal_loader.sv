// BrezzaSoft Crystal System MiSTer core -- ROM loader and SDRAM initialisation.
// Copyright (C) 2026 Kyle Lester. SPDX-License-Identifier: GPL-3.0-or-later
//
// MRA streams (docs/ROM_LAYOUT.md), hps_io WIDE=1 (16-bit words, byte addresses):
//   index 1   board record "CRYS", version, game id, flash banks
//   index 254 DIP switches (MRA <switches>), byte 0 = DSW
//   index 3   protection PIC firmware (MAME image, 16-bit words) -> crystal_pic16 (Top Blade V, Office Yeoin)
//   index 0   flash banks 0..n-1 (16 MiB each) -> DDR3 flash store, then the 128 KiB BIOS -> SDRAM 0x1800000
// After the index-0 download the work/texture/frame RAM banks and the NVRAM area are cleared to 0 (MAME's RAM
// default) before the board is released (`busy` low).
module crystal_loader (
    input  wire        clk,
    input  wire        pll_locked,

    input  wire        ioctl_download,
    input  wire [15:0] ioctl_index,
    input  wire        ioctl_wr,
    input  wire [26:0] ioctl_addr,
    input  wire [15:0] ioctl_dout,
    output reg         ioctl_wait,

    output reg         busy,           // hold the board in reset
    output reg   [7:0] game_id,
    output reg   [3:0] flash_banks,
    output reg   [7:0] dsw,
    output reg         loaded,         // a ROM stream has been loaded since power-up
    output wire        pic_we,         // PIC firmware word
    output wire [13:0] pic_addr,
    output wire [15:0] pic_data,

    // DDR3 flash store writes
    output reg         f_req,
    output reg  [26:0] f_addr,
    output reg  [63:0] f_data,
    output reg   [7:0] f_be,
    input  wire        f_ack,

    // SDRAM client (writes)
    output reg         s_req,
    output reg  [23:0] s_addr,         // word address
    output reg   [5:0] s_len,
    output reg  [15:0] s_wdata,
    input  wire        s_wnext,
    input  wire        s_done
);
    reg        dl_q;
    reg [63:0] acc;
    reg  [7:0] acc_be;
    reg  [1:0] st;                 // 0 idle/receive, 1 wait flash, 2 wait sdram word, 3 clear
    reg [23:0] clr_addr;
    reg [15:0] rec [0:7];

    assign pic_we   = ioctl_download && ioctl_wr && ioctl_index == 16'd3;
    assign pic_addr = ioctl_addr[14:1];
    assign pic_data = ioctl_dout;

    wire [26:0] bios_base = {flash_banks, 24'd0};
    wire        is_flash  = ioctl_addr < bios_base;

    wire [15:0] ov_dout;
    wire        ov_hit;
    crystal_prot_overlay overlay (
        .game_id(game_id), .flash_off(ioctl_addr), .din(ioctl_dout), .dout(ov_dout), .hit(ov_hit)
    );

    always @(posedge clk) begin
        dl_q <= ioctl_download;
        if (!pll_locked) begin
            busy <= 1'b1; st <= 2'd0; ioctl_wait <= 1'b0; f_req <= 1'b0; s_req <= 1'b0;
            game_id <= 8'd0; flash_banks <= 4'd3; dsw <= 8'hff; loaded <= 1'b0;
        end else begin
            if (ioctl_download && !dl_q && ioctl_index == 16'd0) begin
                busy <= 1'b1;
                acc_be <= 8'd0;
            end
            case (st)
            2'd0: begin
                if (ioctl_download && ioctl_wr) begin
                    if (ioctl_index == 16'd1) begin
                        case (ioctl_addr[3:1])
                            3'd2: game_id <= ioctl_dout[15:8];
                            3'd3: flash_banks <= (ioctl_dout[3:0] == 4'd0) ? 4'd1 : (ioctl_dout[3:0] > 4'd8 ? 4'd8 : ioctl_dout[3:0]);
                            default: ;
                        endcase
                    end else if (ioctl_index == 16'd0) begin
                        if (is_flash) begin
                            acc[{ioctl_addr[2:1], 4'd0} +: 16] <= ov_dout;
                            if (ioctl_addr[2:1] == 2'd3) begin
                                f_req  <= 1'b1;
                                f_addr <= {ioctl_addr[26:3], 3'd0};
                                f_data <= {ov_dout, acc[47:0]};
                                f_be   <= 8'hff;
                                ioctl_wait <= 1'b1;
                                st <= 2'd1;
                            end
                        end else if (ioctl_addr - bios_base < 27'h20000) begin
                            s_req   <= 1'b1;
                            s_addr  <= 24'hc00000 + {7'd0, ioctl_addr[16:1]};   // byte 0x1800000 = word 0xc00000
                            s_len   <= 6'd1;
                            s_wdata <= ioctl_dout;
                            ioctl_wait <= 1'b1;
                            st <= 2'd2;
                        end
                    end
                end
                if (!ioctl_download && dl_q && ioctl_index == 16'd0) begin
                    // download finished: clear RAM banks 0-2 and the NVRAM area
                    loaded   <= 1'b1;
                    clr_addr <= 24'd0;
                    s_req    <= 1'b1;
                    s_addr   <= 24'd0;
                    s_len    <= 6'd32;
                    s_wdata  <= 16'd0;
                    st       <= 2'd3;
                end
            end
            2'd1: if (f_ack) begin f_req <= 1'b0; ioctl_wait <= 1'b0; st <= 2'd0; end
            2'd2: if (s_done) begin s_req <= 1'b0; ioctl_wait <= 1'b0; st <= 2'd0; end
            2'd3: if (s_done) begin
                logic [23:0] n;
                n = clr_addr + 24'd32;
                // banks 0-2 = words 0x000000-0xbfffff, NVRAM = words 0xc10000-0xc17fff
                if (n == 24'hc00000) n = 24'hc10000;
                if (n == 24'hc18000) begin
                    s_req <= 1'b0;
                    busy  <= 1'b0;
                    st    <= 2'd0;
                end else begin
                    clr_addr <= n;
                    s_addr   <= n;
                    s_req    <= 1'b1;
                end
            end
            endcase
            // DIP switches (index 254) in any state: Main_MiSTer sends them right after the ROM stream, often
            // while the RAM clear above is still running (they were dropped then)
            if (ioctl_download && ioctl_wr && ioctl_index == 16'd254 && ioctl_addr[26:1] == 26'd0) dsw <= ioctl_dout[7:0];
            // a stream index other than 0 does not reset the board
            if (!ioctl_download && dl_q && ioctl_index != 16'd0 && loaded) busy <= busy;
        end
    end
endmodule
