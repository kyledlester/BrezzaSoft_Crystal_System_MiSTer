// BrezzaSoft Crystal System MiSTer core -- Dallas DS1302 timekeeper.
// Copyright (C) 2026 Kyle Lester. SPDX-License-Identifier: GPL-3.0-or-later
//
// Serial protocol and register/RAM behaviour as MAME machine/ds1302.cpp (Curt Coder, c2334733): command byte
// LSB first on SCLK rising edges, read data shifted out on falling edges, burst mode, write protect, 31 bytes of
// RAM, user copy of the clock registers taken at CE rising edge. The clock is loaded from MiSTer's RTC (BCD,
// hps_io RTC[64:0]) when `rtc_load` pulses and then ticks once per second.
module crystal_ds1302 #(
    parameter integer CLK_HZ = 85909080
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        ce,
    input  wire        sclk,
    input  wire        io_in,
    input  wire        sample,       // pulse: ce/sclk/io_in were written (PIO write)
    output reg         io_out,

    input  wire        rtc_load,
    input  wire [47:0] rtc_bcd       // {year, month, date, hours, minutes, seconds} BCD (MiSTer RTC[47:0] order)
);
    localparam S_CMD = 2'd0, S_IN = 2'd1, S_OUT = 2'd2;
    reg  [1:0] state;
    reg  [3:0] bits;
    reg  [7:0] cmd, data;
    reg  [4:0] addr;
    reg        ce_q, clk_q;
    reg  [7:0] regs [0:8];
    reg  [7:0] user [0:8];
    reg  [7:0] ram  [0:30];
    reg [26:0] sec_div;
    integer i;

    wire cmd_rd    = cmd[0];
    wire cmd_ram   = cmd[6];
    wire cmd_burst = (cmd[5:1] == 5'h1f);

    function automatic [7:0] bcd_inc(input [7:0] v, input [7:0] mod, output logic carry);
        logic [7:0] n;
        n = (v[3:0] == 4'd9) ? {v[7:4] + 4'd1, 4'd0} : v + 8'd1;
        carry = (n >= mod);
        return carry ? 8'd0 : n;
    endfunction

    task automatic load_shift;
        if (cmd_rd) begin
            if (cmd_ram) data <= (addr < 5'd31) ? ram[addr] : 8'd0;
            else         data <= (addr < 5'd9)  ? user[addr] : 8'd0;
        end
    endtask

    always @(posedge clk) begin
        if (!rst_n) begin
            state <= S_CMD; bits <= 4'd0; ce_q <= 1'b0; clk_q <= 1'b0; io_out <= 1'b0;
            sec_div <= 27'd0;
        end else begin
            // one-second tick
            if (sec_div == CLK_HZ - 1) begin
                logic c1, c2, c3;
                sec_div <= 27'd0;
                if (!regs[0][7]) begin
                    regs[0][6:0] <= bcd_inc({1'b0, regs[0][6:0]}, 8'h60, c1);
                    if (c1) begin
                        regs[1] <= bcd_inc(regs[1], 8'h60, c2);
                        if (c2) regs[2] <= bcd_inc(regs[2], 8'h24, c3);
                    end
                end
            end else
                sec_div <= sec_div + 27'd1;

            if (rtc_load) begin
                regs[0] <= {1'b0, rtc_bcd[6:0]};
                regs[1] <= rtc_bcd[15:8];
                regs[2] <= rtc_bcd[23:16];
                regs[3] <= rtc_bcd[31:24];
                regs[4] <= rtc_bcd[39:32];
                regs[6] <= rtc_bcd[47:40];
            end

            if (sample) begin
                // ce_w, then io_w, then sclk_w (MAME pioldat_w order)
                logic ce_n, clk_n;
                ce_n  = ce;
                clk_n = sclk;
                if (ce_n && !ce_q) for (i = 0; i < 9; i++) user[i] <= regs[i];
                else if (!ce_n && ce_q) begin state <= S_CMD; bits <= 4'd0; end
                ce_q <= ce_n;
                if (ce_n) begin
                    if (!clk_q && clk_n) begin
                        // input_bit with io = io_in
                        case (state)
                        S_CMD: begin
                            logic [7:0] nc;
                            nc = {io_in, cmd[7:1]};
                            cmd <= nc;
                            if (bits == 4'd7) begin
                                bits <= 4'd0;
                                addr <= (nc[5:1] == 5'h1f) ? 5'd0 : nc[5:1];
                                if (nc[7]) begin
                                    if (nc[0]) begin
                                        // load_shift_register (read) using the new command/address
                                        if (nc[6]) data <= ((nc[5:1] == 5'h1f ? 5'd0 : nc[5:1]) < 5'd31) ? ram[nc[5:1] == 5'h1f ? 5'd0 : nc[5:1]] : 8'd0;
                                        else       data <= ((nc[5:1] == 5'h1f ? 5'd0 : nc[5:1]) < 5'd9)  ? (ce_n && !ce_q ? regs[nc[5:1] == 5'h1f ? 5'd0 : nc[5:1]] : user[nc[5:1] == 5'h1f ? 5'd0 : nc[5:1]]) : 8'd0;
                                        state <= S_OUT;
                                    end else
                                        state <= S_IN;
                                end else
                                    state <= S_CMD;
                            end else
                                bits <= bits + 4'd1;
                        end
                        S_IN: begin
                            logic [7:0] nd;
                            nd = {io_in, data[7:1]};
                            data <= nd;
                            if (bits == 4'd7) begin
                                bits <= 4'd0;
                                if (!regs[7][7] || (!cmd_ram && addr == 5'd7)) begin
                                    // MAME checks WRITE_PROTECT before every store (the control register too)
                                end
                                if (!regs[7][7]) begin
                                    if (cmd_ram) begin if (addr < 5'd31) ram[addr] <= nd; end
                                    else if (addr < 5'd9) regs[addr] <= nd;
                                end
                                if (cmd_burst) begin
                                    addr <= addr + 5'd1;
                                    if (addr + 5'd1 == (cmd_ram ? 5'd31 : 5'd9)) state <= S_CMD;
                                end else
                                    state <= S_CMD;
                            end else
                                bits <= bits + 4'd1;
                        end
                        default: ;
                        endcase
                    end else if (clk_q && !clk_n) begin
                        // output_bit
                        if (state == S_OUT) begin
                            io_out <= data[0];
                            data   <= {1'b0, data[7:1]};
                            if (bits == 4'd7) begin
                                bits <= 4'd0;
                                if (cmd_burst) begin
                                    addr <= addr + 5'd1;
                                    if (addr + 5'd1 == (cmd_ram ? 5'd31 : 5'd9)) state <= S_CMD;
                                    else begin
                                        if (cmd_ram) data <= (addr + 5'd1 < 5'd31) ? ram[addr + 5'd1] : 8'd0;
                                        else         data <= (addr + 5'd1 < 5'd9) ? user[addr + 5'd1] : 8'd0;
                                    end
                                end else
                                    state <= S_CMD;
                            end else
                                bits <= bits + 4'd1;
                        end
                    end
                end else if (!ce_n) begin
                    // MAME: io_w stores the line even when CE is low; output follows the last driven value
                end
                clk_q <= clk_n;
                // MAME io_w: the shared line takes the written value (read back by PIOEDAT b28)
                if (!(ce_n && clk_q && !clk_n && state == S_OUT)) io_out <= io_in;
            end
        end
    end

    initial begin
        for (i = 0; i < 9; i++) begin regs[i] = 8'd0; user[i] = 8'd0; end
        regs[3] = 8'h01; regs[4] = 8'h01; regs[5] = 8'h01; regs[6] = 8'h01;
        for (i = 0; i < 31; i++) ram[i] = 8'd0;
    end
endmodule
