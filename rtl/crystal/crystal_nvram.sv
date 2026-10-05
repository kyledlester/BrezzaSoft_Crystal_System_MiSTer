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
    output reg  [31:0] rdata,

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
    (* ramstyle = "M10K" *) reg [31:0] ram [0:16383];
    reg        dirty = 1'b0;
    reg        sess_q = 1'b0;
    reg [31:0] b_q;
    reg        b_half;
    reg  [1:0] rd_wait = 2'd0;

    assign upload_req = dirty;
    assign ioctl_din  = b_half ? b_q[31:16] : b_q[15:0];
    assign ioctl_wait = (rd_wait != 2'd0);

    wire sess = (ioctl_download || ioctl_upload) && ioctl_index == INDEX;

    // port A (CPU)
    always @(posedge clk) begin
        ack <= 1'b0;
        if (req && !ack) begin
            if (we) begin
                if (be[0]) ram[addr][7:0]   <= wdata[7:0];
                if (be[1]) ram[addr][15:8]  <= wdata[15:8];
                if (be[2]) ram[addr][23:16] <= wdata[23:16];
                if (be[3]) ram[addr][31:24] <= wdata[31:24];
            end
            rdata <= ram[addr];
            ack   <= 1'b1;
        end
    end

    // port B (hps_io)
    always @(posedge clk) begin
        sess_q <= sess;
        if (sess && !sess_q) dirty <= 1'b0;
        else if (req && !ack && we) dirty <= 1'b1;

        if (rd_wait != 2'd0) rd_wait <= rd_wait - 2'd1;
        if (ioctl_download && ioctl_index == INDEX && ioctl_wr && ioctl_addr < 27'h10000) begin
            if (ioctl_addr[1]) ram[ioctl_addr[15:2]][31:16] <= ioctl_dout;
            else               ram[ioctl_addr[15:2]][15:0]  <= ioctl_dout;
        end
        if (ioctl_upload && ioctl_index == INDEX && ioctl_rd) rd_wait <= 2'd2;
        b_q    <= ram[ioctl_addr[15:2]];
        b_half <= ioctl_addr[1];
    end

    integer i;
    initial for (i = 0; i < 16384; i++) ram[i] = 32'd0;
endmodule
