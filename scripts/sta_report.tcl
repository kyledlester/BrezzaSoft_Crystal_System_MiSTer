# TimeQuest report script (does not modify the project):
#   quartus_sta Crystal -c Crystal --report_script=scripts/sta_report.tcl
set clk {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}
report_timing -setup -to_clock $clk -npaths 40 -detail summary -file build/sta_clk_sys.txt
report_timing -setup -to_clock SDRAM_CLK -npaths 20 -detail summary -file build/sta_sdram_clk.txt
report_timing -setup -from_clock SDRAM_CLK -npaths 10 -detail summary -file build/sta_sdram_in.txt
