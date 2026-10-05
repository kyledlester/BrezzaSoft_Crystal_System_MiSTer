// crystal_ddr_mux bench: flash-store-style 8-beat read bursts and screen_rotate-style pixel writes (one every
// 12 clocks, no wait) share a DDR3 model with random BUSY and read latency.
// Checks: every flash read beat returns the model's data for its address, in order; every pixel write reaches
// the model with its address, half-select and data; no write is dropped; reads are not starved.
// Copyright (C) 2026 Kyle Lester. SPDX-License-Identifier: GPL-3.0-or-later
//   Run: scripts/sim/ddr_mux_test.sh
`timescale 1ns/1ps
module tb_ddr_mux;
    reg clk = 0;
    always #5.82 clk = ~clk;

    // ---------------- DUT
    reg  [7:0]  f_burstcnt = 8; reg [28:0] f_addr = 0; reg [63:0] f_din = 0; reg [7:0] f_be = 0;
    reg         f_we = 0, f_rd = 0;
    wire        f_busy;
    reg  [28:0] r_addr = 0; reg [63:0] r_din = 0; reg [7:0] r_be = 0; reg r_we = 0;
    reg         DDRAM_BUSY = 0;
    wire [7:0]  DDRAM_BURSTCNT, DDRAM_BE; wire [28:0] DDRAM_ADDR; wire [63:0] DDRAM_DIN; wire DDRAM_WE, DDRAM_RD;
    wire [15:0] drops;
    crystal_ddr_mux dut (.clk(clk), .f_burstcnt(f_burstcnt), .f_addr(f_addr), .f_din(f_din), .f_be(f_be), .f_we(f_we),
        .f_rd(f_rd), .f_busy(f_busy), .r_addr(r_addr), .r_din(r_din), .r_be(r_be), .r_we(r_we),
        .DDRAM_BUSY(DDRAM_BUSY), .DDRAM_BURSTCNT(DDRAM_BURSTCNT), .DDRAM_ADDR(DDRAM_ADDR), .DDRAM_DIN(DDRAM_DIN),
        .DDRAM_BE(DDRAM_BE), .DDRAM_WE(DDRAM_WE), .DDRAM_RD(DDRAM_RD), .drops(drops));

    function automatic [63:0] rdval(input [28:0] a); rdval = {3'b101, a, 3'b010, ~a}; endfunction

    // ---------------- DDR3 model: random BUSY; read bursts answered after a random latency, in order
    int errors = 0, reads_ok = 0, writes_seen = 0, writes_sent = 0;
    reg [63:0] wmem [int];        // address -> merged data
    reg  [7:0] wbe  [int];
    int rq_addr[$]; int rq_len[$];
    int lat = 0, beat = 0; bit lat_set = 0;
    reg [63:0] dout = 0; reg dout_ready = 0;
    always @(posedge clk) begin
        dout_ready <= 0;
        if (!DDRAM_BUSY && DDRAM_RD) begin rq_addr.push_back(DDRAM_ADDR); rq_len.push_back(DDRAM_BURSTCNT); end
        if (!DDRAM_BUSY && DDRAM_WE) begin
            if (DDRAM_BURSTCNT != 1) begin errors++; $display("ERROR write burst %0d", DDRAM_BURSTCNT); end
            writes_seen++;
            if (!wmem.exists(DDRAM_ADDR)) begin wmem[DDRAM_ADDR] = 0; wbe[DDRAM_ADDR] = 0; end
            for (int k = 0; k < 8; k++) if (DDRAM_BE[k]) wmem[DDRAM_ADDR][k*8 +: 8] = DDRAM_DIN[k*8 +: 8];
            wbe[DDRAM_ADDR] |= DDRAM_BE;
        end
        DDRAM_BUSY <= ($urandom % 100) < 25;
        if (rq_addr.size() != 0) begin
            if (!lat_set) begin lat = 10 + $urandom % 40; lat_set = 1; end
            if (lat > 0) lat--;
            else if (($urandom % 100) < 85) begin
                dout <= rdval(rq_addr[0] + beat); dout_ready <= 1;
                beat++;
                if (beat == rq_len[0]) begin beat = 0; lat_set = 0; void'(rq_addr.pop_front()); void'(rq_len.pop_front()); end
            end
        end
    end

    // ---------------- flash-store master: as crystal_flash_ddr (RD held until !busy, then 8 beats)
    int f_beat = 0; reg [28:0] f_cur = 0; bit f_wait = 0; int f_bursts = 0; longint f_lat_sum = 0, f_t0 = 0, cyc = 0;
    always @(posedge clk) begin
        cyc++;
        if (!f_busy) begin f_rd <= 0; end
        if (!f_wait && !f_rd && ($urandom % 100) < 30) begin
            f_cur = 29'h06400000 + (($urandom % 65536) << 3);
            f_addr <= f_cur; f_rd <= 1; f_wait = 1; f_beat = 0; f_t0 = cyc;
        end
        if (dout_ready) begin
            if (!f_wait) begin errors++; $display("ERROR unexpected read data"); end
            else if (dout !== rdval(f_cur + f_beat)) begin errors++; if (errors < 10) $display("ERROR read beat %0d of %h", f_beat, f_cur); end
            else reads_ok++;
            f_beat++;
            if (f_beat == 8) begin f_wait = 0; f_bursts++; f_lat_sum += cyc - f_t0; end
        end
    end

    // ---------------- screen_rotate master: one pixel every 12 clocks (fire and forget)
    reg [63:0] exp_d [int]; reg [7:0] exp_be [int];
    int div = 0; reg [22:0] pa = 0;
    always @(posedge clk) begin
        r_we <= 0;
        if (++div == 12) begin
            reg [31:0] px; reg [28:0] a;
            div = 0;
            pa = pa + 23'd4 * (1 + $urandom % 3);
            px = $urandom;
            a = {7'b0010010, 2'd1, pa[22:3]};
            r_addr <= a; r_din <= {px, px}; r_be <= pa[2] ? 8'hF0 : 8'h0F; r_we <= 1;
            if (!exp_d.exists(a)) begin exp_d[a] = 0; exp_be[a] = 0; end
            if (pa[2]) exp_d[a][63:32] = px; else exp_d[a][31:0] = px;
            exp_be[a] |= pa[2] ? 8'hF0 : 8'h0F;
            writes_sent++;
        end
    end

    initial begin
        repeat (400000) @(posedge clk);
        repeat (2000) @(posedge clk);         // drain
        foreach (exp_d[a]) begin
            if (!wmem.exists(a) || wbe[a] != exp_be[a]) begin errors++; if (errors < 20) $display("ERROR pixel write %h missing", a); end
            else for (int k = 0; k < 8; k++) if (exp_be[a][k] && wmem[a][k*8 +: 8] != exp_d[a][k*8 +: 8]) begin
                errors++; if (errors < 20) $display("ERROR pixel data %h", a); break;
            end
        end
        if (writes_seen != writes_sent) begin errors++; $display("ERROR writes sent %0d seen %0d", writes_sent, writes_seen); end
        if (drops != 0) begin errors++; $display("ERROR %0d pixel writes dropped", drops); end
        $display("flash bursts %0d (%0d beats checked, mean latency %0d clk), pixel writes %0d, drops %0d",
                 f_bursts, reads_ok, f_bursts ? int'(f_lat_sum / f_bursts) : 0, writes_seen, drops);
        if (errors == 0 && f_bursts > 1000) $display("PASS DDR MUX"); else $display("FAIL DDR MUX: %0d errors", errors);
        $finish;
    end
endmodule
