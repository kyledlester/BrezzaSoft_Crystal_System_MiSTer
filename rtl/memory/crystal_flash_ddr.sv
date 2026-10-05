// BrezzaSoft Crystal System MiSTer core -- cartridge flash store in the HPS DDR3.
// Copyright (C) 2026 Kyle Lester. SPDX-License-Identifier: GPL-3.0-or-later
//
// Flash byte offset f (bank*16 MiB + offset) lives at DDR3 byte BASE + f (DDRAM_ADDR = 64-bit word address,
// DDRAM_DOUT[8k+7:8k] = byte 8*address + k, little endian like the SE3208).
// Read side: two clients (CPU data/DMA = port 0, instruction fetch = port 1), each with a one-line (64-byte)
// buffer filled by an 8-beat DDR3 burst; sequential copies and code fetches hit the buffer. Flash is read-only
// for the SE3208 (the command register is in crystal_board), so the buffers never need invalidation except at
// load. Write side: the loader writes 64-bit words while the core is held in reset.
module crystal_flash_ddr #(
    parameter [31:0] BASE = 32'h3200_0000
) (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        r0_req,
    input  wire [26:0] r0_addr,       // byte offset (dword aligned)
    output reg         r0_ack,
    output reg  [31:0] r0_data,

    input  wire        r1_req,
    input  wire [26:0] r1_addr,       // byte offset (halfword aligned)
    output reg         r1_ack,
    output reg  [15:0] r1_data,

    input  wire        w_req,         // loader
    input  wire [26:0] w_addr,        // byte offset, 8-byte aligned
    input  wire [63:0] w_data,
    input  wire  [7:0] w_be,
    output reg         w_ack,

    input  wire        DDRAM_BUSY,
    output reg   [7:0] DDRAM_BURSTCNT,
    output reg  [28:0] DDRAM_ADDR,
    input  wire [63:0] DDRAM_DOUT,
    input  wire        DDRAM_DOUT_READY,
    output reg         DDRAM_RD,
    output reg  [63:0] DDRAM_DIN,
    output reg   [7:0] DDRAM_BE,
    output reg         DDRAM_WE
);
    reg  [63:0] line [0:1][0:7];
    reg  [20:0] ltag [0:1];           // byte offset [26:6]
    reg   [1:0] lval;
    reg   [1:0] st;                   // 0 idle, 1 read burst, 2 write
    reg         fp;                   // port being filled
    reg   [2:0] beat;
    reg   [1:0] pend_ans;             // a port waiting for its fill

    wire hit0 = lval[0] && ltag[0] == r0_addr[26:6];
    wire hit1 = lval[1] && ltag[1] == r1_addr[26:6];

    always @(posedge clk) begin
        r0_ack <= 1'b0;
        r1_ack <= 1'b0;
        w_ack  <= 1'b0;
        if (!DDRAM_BUSY) begin DDRAM_RD <= 1'b0; DDRAM_WE <= 1'b0; end
        if (!rst_n) begin
            st <= 2'd0;
            lval <= 2'b00;
            DDRAM_RD <= 1'b0;
            DDRAM_WE <= 1'b0;
        end else begin
            // hits answered in one cycle
            if (r0_req && !r0_ack && hit0 && !(st == 2'd1 && fp == 1'b0)) begin
                logic [63:0] q;
                q = line[0][r0_addr[5:3]];
                r0_data <= r0_addr[2] ? q[63:32] : q[31:0];
                r0_ack  <= 1'b1;
            end
            if (r1_req && !r1_ack && hit1 && !(st == 2'd1 && fp == 1'b1)) begin
                logic [63:0] q;
                q = line[1][r1_addr[5:3]];
                r1_data <= q[{r1_addr[2:1], 4'd0} +: 16];
                r1_ack  <= 1'b1;
            end
            case (st)
            2'd0: begin
                if (w_req && !w_ack) begin
                    DDRAM_WE       <= 1'b1;
                    DDRAM_BURSTCNT <= 8'd1;
                    DDRAM_ADDR     <= (BASE >> 3) + {5'd0, w_addr[26:3]};
                    DDRAM_DIN      <= w_data;
                    DDRAM_BE       <= w_be;
                    lval           <= 2'b00;
                    st             <= 2'd2;
                end else if (r0_req && !r0_ack && !hit0) begin
                    fp <= 1'b0;
                    ltag[0] <= r0_addr[26:6];
                    lval[0] <= 1'b0;
                    DDRAM_RD <= 1'b1; DDRAM_BURSTCNT <= 8'd8;
                    DDRAM_ADDR <= (BASE >> 3) + {5'd0, r0_addr[26:6], 3'd0};
                    beat <= 3'd0;
                    st <= 2'd1;
                end else if (r1_req && !r1_ack && !hit1) begin
                    fp <= 1'b1;
                    ltag[1] <= r1_addr[26:6];
                    lval[1] <= 1'b0;
                    DDRAM_RD <= 1'b1; DDRAM_BURSTCNT <= 8'd8;
                    DDRAM_ADDR <= (BASE >> 3) + {5'd0, r1_addr[26:6], 3'd0};
                    beat <= 3'd0;
                    st <= 2'd1;
                end
            end
            2'd1: if (DDRAM_DOUT_READY) begin
                line[fp][beat] <= DDRAM_DOUT;
                beat <= beat + 3'd1;
                if (beat == 3'd7) begin
                    lval[fp] <= 1'b1;
                    st <= 2'd0;
                end
            end
            2'd2: if (!DDRAM_BUSY) begin
                w_ack <= 1'b1;
                st <= 2'd0;
            end
            default: st <= 2'd0;
            endcase
        end
    end
endmodule
