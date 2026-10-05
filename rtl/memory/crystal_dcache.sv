// BrezzaSoft Crystal System MiSTer core -- CPU/DMA data port to SDRAM: data cache + posted writes.
// Copyright (C) 2026 Kyle Lester. SPDX-License-Identifier: GPL-3.0-or-later
//
// * Cacheable: SDRAM bank 0 (work RAM) and bank 3 (BIOS, NVRAM). Direct mapped, 8 KiB, 512 lines x 16 bytes,
//   write-through, update on write hit, no allocate on write. Read hits answer one clock after the request.
// * Writes to banks 0/3 are posted into a 8-entry FIFO and acknowledged at once; the FIFO drains to the SDRAM in
//   order. Writes to texture/frame RAM (banks 1/2) are not posted: the video and sound engines read those banks,
//   and a display list must be in SDRAM before the CPU can start the engine through an I/O register.
// * Every read waits for the FIFO when it would read SDRAM (miss or uncached), so reads always see older writes.
// * `wb_busy` (FIFO not empty) holds instruction-cache fills off, `inv` reports every data write to the I-cache.
// Only CPU and DMA use this port (crystal_board arbitrates them), so no other writer can touch cached data.
module crystal_dcache (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        req,
    input  wire        we,
    input  wire [24:0] addr,          // SDRAM byte address, dword aligned
    input  wire  [3:0] be,
    input  wire [31:0] wdata,
    output wire        ack,
    output wire [31:0] rdata,

    output reg         inv,
    output reg  [24:0] inv_addr,
    output reg         wr_done,       // pulse: a synchronous (texture / frame RAM) write reached the SDRAM
    output reg  [24:0] wr_done_addr,  //   (its last word was issued), for the renderer's texture-cache snoop
    output wire        wb_busy,

    // SDRAM client
    output reg         m_req,
    output reg         m_we,
    output reg  [23:0] m_addr,
    output reg   [5:0] m_len,
    output wire [15:0] m_wdata,
    output wire  [1:0] m_wbe,
    input  wire        m_wnext,
    input  wire        m_rvalid,
    input  wire [15:0] m_rdata,
    input  wire        m_done
);
    // ------------------------------------------------------------------ storage
    (* ramstyle = "M10K" *) reg [13:0] tram [0:511];    // {valid, addr[24:23] bank, addr[22:13]} index addr[12:4]
    wire [31:0] d_q;
    reg  [13:0] t_q;
    // RAM write ports are driven combinationally by the state machine (below), so a write takes effect on the
    // same clock edge the FSM decides it and the next lookup can never read stale tags/data.
    reg         d_we;
    reg  [10:0] d_wa;
    reg  [31:0] d_wd;
    reg   [3:0] d_wbe;
    reg         t_we;
    reg   [8:0] t_wa;
    reg  [13:0] t_wd;
    // data: one 2048 x 8 block RAM per byte lane (byte-enable writes)
    genvar gl;
    generate for (gl = 0; gl < 4; gl++) begin : g_lane
        crystal_sdpram #(.AW(11), .DW(8)) lane (
            .clk(clk), .we(d_we && d_wbe[gl]), .waddr(d_wa), .wdata(d_wd[gl*8 +: 8]),
            .raddr(addr[12:2]), .rdata(d_q[gl*8 +: 8])
        );
    end endgenerate
    always @(posedge clk) begin
        if (t_we) tram[t_wa] <= t_wd;
        t_q <= tram[addr[12:4]];
    end

    // ------------------------------------------------------------------ write FIFO
    reg  [24:0] f_addr [0:7];
    reg  [31:0] f_data [0:7];
    reg   [3:0] f_be   [0:7];
    reg   [2:0] f_rd, f_wr;
    reg   [3:0] f_cnt;
    wire        f_full  = f_cnt == 4'd8;
    assign wb_busy = f_cnt != 4'd0;

    // ------------------------------------------------------------------ request side
    localparam S_IDLE = 3'd0, S_LOOK = 3'd1, S_FILL = 3'd2, S_UNC = 3'd3, S_WRS = 3'd4, S_CLR = 3'd5, S_WRH = 3'd6;
    reg  [2:0]  st;
    reg  [24:0] a_q;
    reg         we_q;
    reg  [31:0] wd_q;
    reg   [3:0] be_q;
    reg         ack_r;
    reg  [31:0] rd_r;
    reg   [3:0] fill_i;
    reg  [31:0] fill_acc;
    reg   [8:0] clr_i;
    reg         unc_hi;           // uncached access: word index

    wire cacheable_q = (a_q[24:23] == 2'b00) || (a_q[24:23] == 2'b11);
    wire hit = (st == S_LOOK) && !we_q && t_q == {1'b1, a_q[24:13]};
    assign ack   = hit || ack_r;
    assign rdata = hit ? d_q : rd_r;

    // drain / memory sequencer shares the SDRAM client: 0 idle, 1 drain write, 2 fill read, 3 uncached
    reg  [1:0]  ms;
    reg         mw_hi;            // which half of the 32-bit write is presented
    reg  [31:0] mw_data;
    reg   [3:0] mw_be;
    assign m_wdata = mw_hi ? mw_data[31:16] : mw_data[15:0];
    assign m_wbe   = mw_hi ? mw_be[3:2] : mw_be[1:0];

    always @* begin
        d_we = 1'b0; d_wa = a_q[12:2]; d_wd = wd_q; d_wbe = be_q;
        t_we = 1'b0; t_wa = a_q[12:4]; t_wd = {1'b1, a_q[24:13]};
        case (st)
            S_CLR: begin t_we = 1'b1; t_wa = clr_i; t_wd = 14'd0; end
            S_WRH: d_we = (t_q == {1'b1, a_q[24:13]});
            S_FILL: begin
                if (m_rvalid && fill_i[0]) begin
                    d_we = 1'b1; d_wa = {a_q[12:4], fill_i[2:1]}; d_wd = {m_rdata, fill_acc[15:0]}; d_wbe = 4'hf;
                end
                if (m_done) t_we = 1'b1;
            end
            default: ;
        endcase
    end

    wire f_push = rst_n && st == S_IDLE && req && !ack_r && we && (addr[24:23] == 2'b00 || addr[24:23] == 2'b11) && !f_full;
    wire f_pop  = rst_n && ms == 2'd1 && m_done;

    always @(posedge clk) begin
        ack_r <= 1'b0;
        inv   <= 1'b0;
        wr_done <= 1'b0;
        if (rst_n) f_cnt <= f_cnt + (f_push ? 4'd1 : 4'd0) - (f_pop ? 4'd1 : 4'd0);
        if (!rst_n) begin
            st <= S_CLR; clr_i <= 9'd0;
            m_req <= 1'b0; ms <= 2'd0;
            f_rd <= 3'd0; f_wr <= 3'd0; f_cnt <= 4'd0;
        end else begin
            // ---------------- FIFO drain (when the request side does not need the SDRAM client)
            if (ms == 2'd0 && f_cnt != 4'd0 && st != S_FILL && st != S_UNC) begin
                logic lo, hi;
                lo = f_be[f_rd][1:0] != 2'b00;
                hi = f_be[f_rd][3:2] != 2'b00;
                m_req   <= 1'b1;
                m_we    <= 1'b1;
                m_addr  <= {f_addr[f_rd][24:2], !lo};
                m_len   <= (lo && hi) ? 6'd2 : 6'd1;
                mw_data <= f_data[f_rd];
                mw_be   <= f_be[f_rd];
                mw_hi   <= !lo;
                ms      <= 2'd1;
            end
            if (ms == 2'd1) begin
                if (m_wnext) mw_hi <= 1'b1;
                if (m_done) begin
                    m_req <= 1'b0;
                    ms    <= 2'd0;
                    f_rd  <= f_rd + 3'd1;
                end
            end

            case (st)
            S_CLR: begin
                clr_i <= clr_i + 9'd1;
                if (clr_i == 9'd511) st <= S_IDLE;
            end
            S_IDLE: if (req && !ack_r) begin
                a_q  <= addr;
                we_q <= we;
                wd_q <= wdata;
                be_q <= be;
                if (we) begin
                    inv <= 1'b1;
                    inv_addr <= addr;
                end
                if (we && (addr[24:23] == 2'b00 || addr[24:23] == 2'b11)) begin
                    if (!f_full) begin
                        // post the write
                        f_addr[f_wr] <= addr;
                        f_data[f_wr] <= wdata;
                        f_be[f_wr]   <= be;
                        f_wr  <= f_wr + 3'd1;
                        st <= S_WRH;      // update the cached copy if the line is present (tag read now)
                    end
                end else if (we)
                    st <= S_WRS;
                else
                    st <= S_LOOK;
            end
            S_WRH: begin
                ack_r <= 1'b1;
                st <= S_IDLE;
            end
            S_LOOK: begin
                if (hit) st <= S_IDLE;
                else if (f_cnt == 4'd0 && ms == 2'd0) begin
                    if (cacheable_q) begin
                        m_req  <= 1'b1; m_we <= 1'b0;
                        m_addr <= {a_q[24:4], 3'd0};
                        m_len  <= 6'd8;
                        fill_i <= 4'd0;
                        ms     <= 2'd2;
                        st     <= S_FILL;
                    end else begin
                        m_req  <= 1'b1; m_we <= 1'b0;
                        m_addr <= {a_q[24:2], (be_q[1:0] == 2'b00)};
                        m_len  <= (be_q[1:0] != 2'b00 && be_q[3:2] != 2'b00) ? 6'd2 : 6'd1;
                        unc_hi <= (be_q[1:0] == 2'b00);
                        rd_r   <= 32'd0;
                        ms     <= 2'd3;
                        st     <= S_UNC;
                    end
                end
            end
            S_FILL: begin
                if (m_rvalid) begin
                    logic [31:0] acc;
                    acc = fill_i[0] ? {m_rdata, fill_acc[15:0]} : {16'd0, m_rdata};
                    fill_acc <= acc;
                    if (fill_i[0] && fill_i[2:1] == a_q[3:2]) begin rd_r <= acc; ack_r <= 1'b1; end
                    fill_i <= fill_i + 4'd1;
                end
                if (m_done) begin
                    m_req <= 1'b0;
                    ms <= 2'd0;
                    st <= S_IDLE;
                end
            end
            S_UNC: begin
                if (m_rvalid) begin
                    if (unc_hi) rd_r[31:16] <= m_rdata; else rd_r[15:0] <= m_rdata;
                    unc_hi <= 1'b1;
                end
                if (m_done) begin
                    m_req <= 1'b0; ms <= 2'd0; ack_r <= 1'b1; st <= S_IDLE;
                end
            end
            S_WRS: begin
                // synchronous write (texture / frame RAM): after older posted writes
                if (f_cnt == 4'd0 && ms == 2'd0) begin
                    logic lo, hi;
                    lo = be_q[1:0] != 2'b00;
                    hi = be_q[3:2] != 2'b00;
                    m_req   <= 1'b1;
                    m_we    <= 1'b1;
                    m_addr  <= {a_q[24:2], !lo};
                    m_len   <= (lo && hi) ? 6'd2 : 6'd1;
                    mw_data <= wd_q;
                    mw_be   <= be_q;
                    mw_hi   <= !lo;
                    ms      <= 2'd3;
                end
                if (ms == 2'd3) begin
                    if (m_wnext) mw_hi <= 1'b1;
                    if (m_done) begin
                        m_req <= 1'b0; ms <= 2'd0; ack_r <= 1'b1; st <= S_IDLE;
                        wr_done <= 1'b1; wr_done_addr <= a_q;
                    end
                end
            end
            default: st <= S_IDLE;
            endcase
        end
    end
endmodule
