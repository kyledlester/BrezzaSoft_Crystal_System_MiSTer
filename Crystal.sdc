# BrezzaSoft Crystal System MiSTer core -- core timing constraints (sys/sys_top.sdc covers the framework).
derive_pll_clocks

# ---------------------------------------------------------------------------
# SDRAM pins (rtl/memory/crystal_sdram.sv, clocked by clk_sys = 85.909 MHz; no second clock).
# Same physical interface and constraint values as the author's hardware-proven NB-1/NB-2 cores:
# commands/address/write data launched on clk_sys rising edges; SDRAM_CLK = clk_sys inverted (altddio_out).
set crys_core_clock_pin [get_pins -compatibility_mode {*|pll|pll_inst|altera_pll_i|*|divclk}]
create_generated_clock -name SDRAM_CLK -source $crys_core_clock_pin \
    -divide_by 1 -invert [get_ports {SDRAM_CLK}]

set_input_delay -max -clock SDRAM_CLK 6.4 [get_ports {SDRAM_DQ[*]}]
set_input_delay -min -clock SDRAM_CLK 3.7 [get_ports {SDRAM_DQ[*]}]

# Read capture: the DQ sample of a READ is taken on the second clk_sys rising edge after the SDRAM_CLK edge that
# launched the data (CL=2, crystal_sdram dq_q), hence a setup multicycle of 2 (NA-1/NB-1 analysis).
set_multicycle_path -setup 2 -from [get_clocks {SDRAM_CLK}] \
    -to [get_clocks {*|pll|pll_inst|altera_pll_i|*|divclk}]

set crys_sdram_outputs [get_ports {
    SDRAM_A[*] SDRAM_BA[*]
    SDRAM_nCS SDRAM_nWE SDRAM_nRAS SDRAM_nCAS
    SDRAM_DQMH SDRAM_DQML SDRAM_DQ[*]
}]
set_output_delay -max -clock SDRAM_CLK 1.6 $crys_sdram_outputs
set_output_delay -min -clock SDRAM_CLK -0.9 $crys_sdram_outputs

derive_clock_uncertainty
