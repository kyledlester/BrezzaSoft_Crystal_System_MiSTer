// BrezzaSoft Crystal System MiSTer core -- SE3208 instruction cache.
// Copyright (C) 2026 Kyle Lester. SPDX-License-Identifier: GPL-3.0-or-later
//
// Direct mapped, 8 KiB: 512 lines of 16 bytes (8 x 16-bit). Caches SDRAM banks 0 (work RAM) and 3 (BIOS/NVRAM);
// other fetches are passed through uncached (one word). Line fills are 8-word SDRAM bursts; the fetch is answered
// as soon as its word streams in. Coherency: every data write (CPU or DMA) to a cacheable bank clears the tag at
// its index (no compare needed -- a spurious miss is harmless), so code written by the BIOS or by the game is
// always refetched. Tags and data are block RAMs: tag port A = lookup/fill, tag port B = invalidate (write only).
module crystal_icache (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        req,
    input  wire [24:0] addr,          // SDRAM byte address (bit 0 ignored)
    output reg         ack,
    output reg  [15:0] data,

    input  wire        inv,           // data write
    input  wire [24:0] inv_addr,

    output reg         m_req,
    output reg  [23:0] m_addr,        // SDRAM word address
    output reg   [5:0] m_len,
    input  wire        m_rvalid,
    input  wire [15:0] m_rdata,
    input  wire        m_done
);
    localparam S_IDLE = 3'd0, S_LOOK = 3'd1, S_FILL = 3'd2, S_NC = 3'd3, S_CLR = 3'd4;
    reg  [2:0]  st;
    (* ramstyle = "M10K" *) reg [13:0] tag  [0:511];   // {valid, addr[24:12]}, index addr[12:4]
    (* ramstyle = "M10K" *) reg [15:0] dram [0:4095];  // index addr[12:1]
    reg  [24:0] a_q;
    reg  [13:0] tag_q;
    reg  [15:0] d_q;
    reg   [2:0] fill_i;
    reg         answered, fill_inv, look_inv;
    reg   [8:0] clr_i;

    wire cacheable = (addr[24:23] == 2'b00) || (addr[24:23] == 2'b11);
    wire inv_c     = inv && ((inv_addr[24:23] == 2'b00) || (inv_addr[24:23] == 2'b11));
    wire [8:0] line_q = a_q[12:4];

    // tag port A: FSM
    reg        ta_we;
    reg  [8:0] ta_a;
    reg [13:0] ta_d;
    always @(posedge clk) begin
        if (ta_we) tag[ta_a] <= ta_d;
        tag_q <= tag[ta_a];
    end
    // tag port B: invalidate
    always @(posedge clk) if (inv_c) tag[inv_addr[12:4]] <= 14'd0;
    // data RAM
    reg        da_we;
    reg [11:0] da_wa;
    reg [15:0] da_d;
    always @(posedge clk) begin
        if (da_we) dram[da_wa] <= da_d;
        d_q <= dram[addr[12:1]];
    end

    always @* begin
        ta_we = 1'b0; ta_a = addr[12:4]; ta_d = 14'd0;
        da_we = 1'b0; da_wa = {line_q, fill_i}; da_d = m_rdata;
        case (st)
            S_CLR:  begin ta_we = 1'b1; ta_a = clr_i; ta_d = 14'd0; end
            S_LOOK: begin ta_a = line_q; end
            S_FILL: begin
                ta_a = line_q;
                if (m_rvalid) begin
                    da_we = 1'b1;
                    if (fill_i == 3'd7) begin
                        ta_we = 1'b1;
                        ta_d  = (fill_inv || (inv_c && inv_addr[12:4] == line_q)) ? 14'd0 : {1'b1, a_q[24:12]};
                    end
                end
            end
            default: ;
        endcase
    end

    always @(posedge clk) begin
        ack <= 1'b0;
        if (!rst_n) begin
            st <= S_CLR;
            clr_i <= 9'd0;
            m_req <= 1'b0;
        end else begin
            case (st)
            S_CLR: begin
                clr_i <= clr_i + 9'd1;
                if (clr_i == 9'd511) st <= S_IDLE;
            end
            S_IDLE: if (req && !ack) begin
                a_q      <= addr;
                look_inv <= inv_c && inv_addr[12:4] == addr[12:4];
                if (cacheable) st <= S_LOOK;
                else begin
                    st     <= S_NC;
                    m_req  <= 1'b1;
                    m_addr <= addr[24:1];
                    m_len  <= 6'd1;
                end
            end
            S_LOOK: begin
                if (tag_q == {1'b1, a_q[24:12]} && !look_inv && !(inv_c && inv_addr[12:4] == line_q)) begin
                    ack  <= 1'b1;
                    data <= d_q;
                    st   <= S_IDLE;
                end else begin
                    m_req    <= 1'b1;
                    m_addr   <= {a_q[24:4], 3'd0};
                    m_len    <= 6'd8;
                    fill_i   <= 3'd0;
                    answered <= 1'b0;
                    fill_inv <= 1'b0;
                    st       <= S_FILL;
                end
            end
            S_FILL: begin
                if (inv_c && inv_addr[12:4] == line_q) fill_inv <= 1'b1;
                if (m_rvalid) begin
                    fill_i <= fill_i + 3'd1;
                    if (fill_i == a_q[3:1] && !answered) begin
                        ack      <= 1'b1;
                        data     <= m_rdata;
                        answered <= 1'b1;
                    end
                    if (fill_i == 3'd7) begin
                        m_req <= 1'b0;
                        st    <= S_IDLE;
                    end
                end
                if (m_done) m_req <= 1'b0;
            end
            S_NC: begin
                if (m_rvalid) begin ack <= 1'b1; data <= m_rdata; end
                if (m_done) begin m_req <= 1'b0; st <= S_IDLE; end
            end
            default: st <= S_IDLE;
            endcase
        end
    end
endmodule
