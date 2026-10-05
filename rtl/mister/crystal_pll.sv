// BrezzaSoft Crystal System MiSTer core -- system PLL.
// Copyright (C) 2026 Kyle Lester. SPDX-License-Identifier: GPL-3.0-or-later
//
// 50 MHz board clock -> clk_sys = 85.909080 MHz = 6 x 14.31818 MHz.
//
// 14.31818 MHz is the Crystal System board crystal; MAME clocks the VRender0 SoC at 6 x 14.31818 MHz and the
// SE3208 core at 3 x 14.31818 MHz (crystal.cpp, MAME c2334733). Every core clock is a synchronous clock enable
// derived from clk_sys; no other fabric clock exists in the core. 85.909080 / 50 is not reachable with integer
// counters inside the Cyclone V VCO range, hence the fractional-N PLL; the achieved frequency is reported in the
// fitter PLL usage summary.
//
// HIERARCHY IS LOAD-BEARING (same shape as the author's NB-1/NB-2 cores): sys/sys_top.sdc puts the core clock
// in its own exclusive clock group only if it matches *|pll|pll_inst|altera_pll_i|*[*].*|divclk, i.e. emu
// instantiates this module as "pll", which contains "pll_inst", which contains the altera_pll "altera_pll_i".
module crystal_pll (
    input  wire refclk,   // CLK_50M
    input  wire rst,
    output wire clk_sys,  // 85.909080 MHz
    output wire locked
);
    crystal_pll_core pll_inst (
        .refclk(refclk),
        .rst(rst),
        .clk_sys(clk_sys),
        .locked(locked)
    );
endmodule

module crystal_pll_core (
    input  wire refclk,
    input  wire rst,
    output wire clk_sys,
    output wire locked
);
    wire [0:0] clocks;

    altera_pll #(
        .fractional_vco_multiplier("true"),
        .reference_clock_frequency("50.0 MHz"),
        .operation_mode("direct"),
        .number_of_clocks(1),
        .output_clock_frequency0("85.909080 MHz"),
        .phase_shift0("0 ps"),
        .duty_cycle0(50),
        .pll_type("General"),
        .pll_subtype("General")
    ) altera_pll_i (
        .refclk(refclk),
        .rst(rst),
        .outclk(clocks),
        .locked(locked),
        .fboutclk(),
        .fbclk(1'b0)
    );

    assign clk_sys = clocks[0];
endmodule
