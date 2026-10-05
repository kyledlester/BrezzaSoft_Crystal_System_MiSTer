# Report the worst setup paths of the core clocks (run: quartus_sta -t scripts/sta_paths.tcl)
project_open Crystal -revision Crystal
create_timing_netlist
read_sdc
update_timing_netlist
foreach clk {{emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk} SDRAM_CLK} {
    puts "==== $clk"
    report_timing -setup -to_clock $clk -npaths 25 -detail summary -file build/sta_[string map {| _ ~ _ [ _ ] _ . _} [string range $clk 0 10]].txt
}
report_timing -setup -from_clock SDRAM_CLK -npaths 10 -detail full_path -file build/sta_sdram_in.txt
report_timing -setup -to [get_ports SDRAM_*] -npaths 10 -detail full_path -file build/sta_sdram_out.txt
project_close
