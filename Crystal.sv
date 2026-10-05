//============================================================================
//
//  BrezzaSoft Crystal System MiSTer core -- top level (emu).
//  Copyright (C) 2026 Kyle Lester
//
//  This program is free software: you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation, either version 3 of the License, or (at your option)
//  any later version.
//
//  This program is distributed in the hope that it will be useful, but WITHOUT
//  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
//  FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
//  more details.
//
//  You should have received a copy of the GNU General Public License along
//  with this program.  If not, see <https://www.gnu.org/licenses/>.
//
//  Structure follows MiSTer-devel/Template_MiSTer (Template.sv, GPL-2.0+) and the
//  author's Namco NB-1/NB-2 cores.
//
//============================================================================
//
// MiSTer glue around rtl/crystal/crystal_core.sv (the Crystal System board): hps_io, the 85.909 MHz PLL, the
// OSD and the framework video/audio paths.

module emu
(
	`include "sys/emu_ports.vh"
);

assign ADC_BUS  = 'Z;
assign USER_OUT = '1;
assign {UART_RTS, UART_TXD, UART_DTR} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;
assign VGA_F1 = 0;
assign VGA_SCALER  = 0;
assign VGA_DISABLE = 0;
assign HDMI_FREEZE = 0;
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT = 0;
assign AUDIO_S = 1;
assign LED_POWER = 0;
assign BUTTONS = 0;

assign FB_EN = 0;
assign FB_FORMAT = 0;
assign FB_WIDTH = 0;
assign FB_HEIGHT = 0;
assign FB_BASE = 0;
assign FB_STRIDE = 0;
assign FB_FORCE_BLANK = 0;

wire [1:0] ar = status[122:121];
assign VIDEO_ARX = (!ar) ? 12'd4 : (ar - 1'd1);
assign VIDEO_ARY = (!ar) ? 12'd3 : 12'd0;

`include "build_id.v"
// Status bits: 0 Reset, 5 Service (test) switch, 6 CPU pacing off, 10:9 Stereo mix, 12:11 Scandoubler Fx, 122:121 Aspect ratio.
localparam CONF_STR = {
	"Crystal;;",
	"-;",
	"O[122:121],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
	"O[12:11],Scandoubler Fx,None,HQ2x,CRT 25%,CRT 50%;",
	"-;",
	"O[5],Test switch (SW3),Off,On;",
	"O[6],CPU speed,MAME (14.3 MIPS),Unlimited;",
	"-;",
	"O[10:9],Stereo mix,None,25%,50%,100%;",
	"-;",
	"T[0],Reset;",
	"R[0],Reset and close OSD;",
	"-;",
	"J1,Button 1,Button 2,Button 3,Button 4,Start,Coin,Service;",
	"jn,A,B,X,Y,Start,Select,R;",
	"v,0;",
	"V,v",`BUILD_DATE
};

wire         forced_scandoubler, direct_video;
wire  [21:0] gamma_bus;
wire   [1:0] buttons;
wire [127:0] status;
wire  [31:0] joystick_0, joystick_1, joystick_2, joystick_3;

wire        ioctl_download, ioctl_wr, ioctl_wait;
wire [64:0] rtc;
wire [15:0] ioctl_index, ioctl_dout;
wire [26:0] ioctl_addr;

hps_io #(.CONF_STR(CONF_STR), .WIDE(1)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),
	.EXT_BUS(),
	.gamma_bus(gamma_bus),
	.forced_scandoubler(forced_scandoubler),
	.direct_video(direct_video),
	.buttons(buttons),
	.status(status),
	.status_menumask(16'd0),
	.joystick_0(joystick_0),
	.joystick_1(joystick_1),
	.joystick_2(joystick_2),
	.joystick_3(joystick_3),
	.ioctl_download(ioctl_download),
	.ioctl_index(ioctl_index),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_wait(ioctl_wait),
	.RTC(rtc)
);

///////////////////////   CLOCKS   ///////////////////////////////

wire clk_sys;      // 85.909080 MHz = 6 x 14.31818 MHz (VRender0 clock)
wire pll_locked;
crystal_pll pll (.refclk(CLK_50M), .rst(1'b0), .clk_sys(clk_sys), .locked(pll_locked));

///////////////////////   CRYSTAL SYSTEM BOARD   ///////////////////////////

wire        ce_pix, hblank, vblank, hsync, vsync;
wire [7:0]  core_r, core_g, core_b;
wire signed [15:0] snd_l, snd_r;
wire        rom_loading, cpu_running;
wire [15:0] sdram_dq_o;
wire        sdram_dq_oe;
assign SDRAM_DQ = sdram_dq_oe ? sdram_dq_o : 16'hzzzz;

crystal_core core
(
	.clk_sys(clk_sys),
	.pll_locked(pll_locked),
	.reset_request(RESET | status[0] | buttons[1]),
	.ioctl_download(ioctl_download),
	.ioctl_index(ioctl_index),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_wait(ioctl_wait),
	.joy0(joystick_0), .joy1(joystick_1), .joy2(joystick_2), .joy3(joystick_3),
	.sw_test(status[5]),
	.cpu_turbo(status[6]),
	.rtc(rtc),
	.SDRAM_DQ_I(SDRAM_DQ), .SDRAM_DQ_O(sdram_dq_o), .SDRAM_DQ_OE(sdram_dq_oe), .SDRAM_A(SDRAM_A), .SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH), .SDRAM_BA(SDRAM_BA),
	.SDRAM_nCS(SDRAM_nCS), .SDRAM_nWE(SDRAM_nWE), .SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS),
	.SDRAM_CKE(SDRAM_CKE), .SDRAM_CLK(SDRAM_CLK),
	.DDRAM_BUSY(DDRAM_BUSY), .DDRAM_BURSTCNT(DDRAM_BURSTCNT), .DDRAM_ADDR(DDRAM_ADDR), .DDRAM_DOUT(DDRAM_DOUT),
	.DDRAM_DOUT_READY(DDRAM_DOUT_READY), .DDRAM_RD(DDRAM_RD), .DDRAM_DIN(DDRAM_DIN), .DDRAM_BE(DDRAM_BE),
	.DDRAM_WE(DDRAM_WE),
	.ce_pix(ce_pix), .r(core_r), .g(core_g), .b(core_b), .hblank(hblank), .vblank(vblank), .hsync(hsync),
	.vsync(vsync),
	.audio_l(snd_l), .audio_r(snd_r),
	.rom_loading(rom_loading), .cpu_running(cpu_running),
	.dbg_retire(), .dbg_pc(), .dbg_illegal(), .dbg_underflows(), .dbg_cpu_state(), .dbg_render_pixels()
);
assign DDRAM_CLK = clk_sys;

assign AUDIO_L   = snd_l;
assign AUDIO_R   = snd_r;
assign AUDIO_MIX = status[10:9];

///////////////////////   VIDEO   //////////////////////////////

arcade_video #(.WIDTH(320), .DW(24), .GAMMA(1)) arcade_video
(
	.clk_video(clk_sys),
	.ce_pix(ce_pix),
	.RGB_in({core_r, core_g, core_b}),
	.HBlank(hblank),
	.VBlank(vblank),
	.HSync(hsync),
	.VSync(vsync),
	.CLK_VIDEO(CLK_VIDEO),
	.CE_PIXEL(CE_PIXEL),
	.VGA_R(VGA_R),
	.VGA_G(VGA_G),
	.VGA_B(VGA_B),
	.VGA_HS(VGA_HS),
	.VGA_VS(VGA_VS),
	.VGA_DE(VGA_DE),
	.VGA_SL(VGA_SL),
	.fx({1'b0, status[12:11]}),
	.forced_scandoubler(forced_scandoubler),
	.gamma_bus(gamma_bus)
);

assign LED_DISK = {1'b0, rom_loading};
reg [5:0] blink = '0;
reg       vb_d = 1'b0;
always @(posedge clk_sys) begin
	vb_d <= vblank;
	if (vblank && !vb_d) blink <= blink + 6'd1;
end
assign LED_USER = cpu_running ? blink[5] : 1'b1;

endmodule
