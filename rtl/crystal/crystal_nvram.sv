// BrezzaSoft Crystal System MiSTer core -- 64 KiB battery-backed RAM (0x01400000) with MiSTer persistence.
// Copyright (C) 2026 Kyle Lester. SPDX-License-Identifier: GPL-3.0-or-later
//
// Storage: block RAM, 16 Ki x 32 with byte enables. Port A = CPU/DMA data accesses (the board's memory port for
// physical addresses 0x1820000-0x182FFFF), answered one clock after the request. Port B = hps_io.
//
// MiSTer mechanism (as the author's NB-1 core, nb1_nvram.sv; Main_MiSTer mra_loader/menu, hps_io):
// * Load: the MRA sends a zero image on index 2 and then `<nvram index="2" size="65536"/>` makes the HPS send the
//   saved .nvm (if any) on the same index, both before the main ROM stream, so the board starts with it.
// * Save: on entering the OSD the HPS asks for an upload; hps_io answers once per rising edge of
//   ioctl_upload_req (= dirty). The HPS reads the image on index 2 and writes the .nvm file.
// * dirty: set by CPU writes only, cleared when an upload or a download on index 2 starts.
// File format = MAME's nvram/crysking/nvram: byte i = CPU address 0x01400000 + i (little endian).
module crystal_nvram #(
    parameter [15:0] INDEX = 16'd2
) (
    input  wire        clk,

    // CPU side
    input  wire        req,
    input  wire        we,
    input  wire [15:2] addr,
    input  wire  [3:0] be,
    input  wire [31:0] wdata,
    output reg         ack,
    output reg  [31:0] rdata,      // valid with ack

    // hps_io (WIDE = 1)
    input  wire        ioctl_download,
    input  wire        ioctl_upload,
    input  wire [15:0] ioctl_index,
    input  wire        ioctl_wr,
    input  wire        ioctl_rd,
    input  wire [26:0] ioctl_addr,
    input  wire [15:0] ioctl_dout,
    output wire [15:0] ioctl_din,
    output wire        ioctl_wait,
    output wire        upload_req
);
    reg        dirty = 1'b0;
    reg        sess_q = 1'b0;
    reg        b_half;
    reg  [1:0] rd_wait = 2'd0;
    wire [31:0] a_q, b_q;

    assign upload_req = dirty;
    assign ioctl_din  = b_half ? b_q[31:16] : b_q[15:0];
    assign ioctl_wait = (rd_wait != 2'd0);

    wire sess = (ioctl_download || ioctl_upload) && ioctl_index == INDEX;
    wire a_go = req && !ack;
    wire b_wr = ioctl_download && ioctl_index == INDEX && ioctl_wr && ioctl_addr < 27'h10000;

    // four byte lanes, true dual port: A = CPU, B = hps_io
    genvar gl;
    generate for (gl = 0; gl < 4; gl++) begin : g_lane
        crystal_tdpram #(.AW(14), .DW(8)) lane (
            .clk(clk),
            .a_we(a_go && we && be[gl]), .a_addr(addr), .a_wdata(wdata[gl*8 +: 8]), .a_rdata(a_q[gl*8 +: 8]),
            .b_we(b_wr && (ioctl_addr[1] == ((gl / 2) == 1))), .b_addr(ioctl_addr[15:2]),
            .b_wdata((gl % 2) == 1 ? ioctl_dout[15:8] : ioctl_dout[7:0]), .b_rdata(b_q[gl*8 +: 8])
        );
    end endgenerate

    always @(posedge clk) begin
        ack <= a_go;
        sess_q <= sess;
        if (sess && !sess_q) dirty <= 1'b0;
        else if (a_go && we) dirty <= 1'b1;
        if (rd_wait != 2'd0) rd_wait <= rd_wait - 2'd1;
        if (ioctl_upload && ioctl_index == INDEX && ioctl_rd) rd_wait <= 2'd2;
        b_half <= ioctl_addr[1];
    end
    always @* rdata = a_q;
endmodule
