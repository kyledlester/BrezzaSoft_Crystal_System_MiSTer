// Verification wrapper: sound register file + sample engine with an external sample tick.
module vr0_sound_top (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        io_sel,
    input  wire        io_we,
    input  wire [9:0]  io_addr,
    input  wire  [3:0] io_be,
    input  wire [31:0] io_wdata,
    output wire [31:0] io_rdata,
    input  wire        tick,
    output wire        m_req,
    output wire [23:0] m_addr,
    output wire  [5:0] m_len,
    input  wire        m_rvalid,
    input  wire [15:0] m_rdata,
    input  wire        m_done,
    output wire signed [15:0] out_l,
    output wire signed [15:0] out_r,
    output wire        out_strobe,
    output wire        irq,
    output wire [31:0] status
);
    wire [8:0]  eng_addr;
    wire [15:0] eng_rdata, eng_wdata;
    wire        eng_we;
    wire [31:0] int_mask, int_pend, st_clr, pend_set, touched, touch_clr;
    wire [4:0]  max_chan;
    wire [7:0]  clk_num;
    wire [15:0] ctrl;
    vr0_sound_regs regs (
        .clk(clk), .rst_n(rst_n), .io_sel(io_sel), .io_we(io_we), .io_addr(io_addr), .io_be(io_be),
        .io_wdata(io_wdata), .io_rdata(io_rdata),
        .eng_addr(eng_addr), .eng_rdata(eng_rdata), .eng_we(eng_we), .eng_wdata(eng_wdata),
        .status(status), .note_on(), .int_mask(int_mask), .int_pend(int_pend), .eng_status_clr(st_clr),
        .eng_pend_set(pend_set), .max_chan(max_chan), .chan_clk_num(clk_num), .ctrl(ctrl), .irq_clear(),
        .touched(touched), .touch_clr(touch_clr)
    );
    vr0_sound #(.EXT_TICK(1)) eng (
        .clk(clk), .rst_n(rst_n), .tick_in(tick),
        .eng_addr(eng_addr), .eng_rdata(eng_rdata), .eng_we(eng_we), .eng_wdata(eng_wdata),
        .status(status), .int_mask(int_mask), .int_pend(int_pend), .max_chan(max_chan), .chan_clk_num(clk_num),
        .ctrl(ctrl), .eng_status_clr(st_clr), .eng_pend_set(pend_set), .irq(irq), .touched(touched),
        .touch_clr(touch_clr),
        .m_req(m_req), .m_addr(m_addr), .m_len(m_len), .m_rvalid(m_rvalid), .m_rdata(m_rdata), .m_done(m_done),
        .out_l(out_l), .out_r(out_r), .out_strobe(out_strobe)
    );
endmodule
