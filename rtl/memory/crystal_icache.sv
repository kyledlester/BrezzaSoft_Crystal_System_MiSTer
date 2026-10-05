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
    input  wire [24:0] pre_addr,      // likely address of the next request (read the RAMs one clock early)
    output wire        ack,
    output wire [15:0] data,

    input  wire        inv,           // data write
    input  wire [24:0] inv_addr,
    input  wire        hold,          // posted data writes pending: do not read SDRAM yet

    output reg         m_req,
    output reg  [23:0] m_addr,        // SDRAM word address
    output reg   [5:0] m_len,
    input  wire        m_rvalid,
    input  wire [15:0] m_rdata,
    input  wire        m_done
);
    localparam S_IDLE = 3'd0, S_LOOK = 3'd1, S_FILL = 3'd2, S_NC = 3'd3, S_CLR = 3'd4, S_TAGW = 3'd5;
    reg  [2:0]  st;
    // tag RAM {valid, addr[24:12]}, index addr[12:4]: a single write port shared by the FSM (fills, clear) and the
    // invalidations; an invalidation that collides with an FSM write waits one clock in inv_pend (lookups of that
    // index miss meanwhile).
    (* ramstyle = "M10K" *) reg [15:0] dram [0:4095];  // index addr[12:1]
    reg  [24:0] a_q;
    reg  [24:0] rd_q;                 // address the RAM outputs belong to
    reg  [13:0] tag_q;
    reg  [15:0] d_q;
    reg   [2:0] fill_i;
    reg         answered, fill_inv, look_inv;
    reg         ack_r;
    reg  [15:0] data_r;
    wire        hit_look = (st == S_LOOK) && tag_q == {1'b1, a_q[24:12]} && !look_inv && !(inv_c && inv_addr[12:4] == a_q[12:4])
                           && !(inv_pend && inv_idx == a_q[12:4]);
    // early hit: request in IDLE whose address was read last clock through pre_addr
    wire        hit_idle = (st == S_IDLE) && req && !ack_r && cacheable && rd_q[24:1] == addr[24:1] &&
                           tag_q == {1'b1, addr[24:12]} && !look_inv_pre && !(inv_c && inv_addr[12:4] == addr[12:4]) &&
                           !(inv_pend && inv_idx == addr[12:4]);
    wire        hit = hit_look || hit_idle;
    reg         look_inv_pre;
    assign ack  = hit || ack_r;
    assign data = hit ? d_q : data_r;
    reg   [8:0] clr_i;

    wire cacheable = (addr[24:23] == 2'b00) || (addr[24:23] == 2'b11);
    wire inv_c     = inv && ((inv_addr[24:23] == 2'b00) || (inv_addr[24:23] == 2'b11));
    wire [8:0] line_q = a_q[12:4];

    reg        ta_we;
    reg  [8:0] ta_a;
    reg [13:0] ta_d;
    reg  [8:0] ta_wa_w;
    reg        inv_pend;
    reg  [8:0] inv_idx;
    // the FSM writes only while no invalidation is pending, so at most one invalidation ever waits
    wire       inv_now = inv_c && st != S_CLR;
    wire       tw_we   = ta_we || inv_pend || inv_now;
    wire [8:0] tw_addr = ta_we ? ta_wa_w : inv_pend ? inv_idx : inv_addr[12:4];
    wire [13:0] tw_data = ta_we ? ta_d : 14'd0;
    wire [13:0] tag_rd;
    crystal_sdpram #(.AW(9), .DW(14)) tagram (
        .clk(clk), .we(tw_we), .waddr(tw_addr), .wdata(tw_data), .raddr(ta_a), .rdata(tag_rd)
    );
    always @(posedge clk) begin
        // pending invalidation bookkeeping
        if (!rst_n) inv_pend <= 1'b0;
        else if (ta_we && inv_now) begin
            inv_pend <= 1'b1;                    // the FSM writes this clock: the invalidation waits one clock
            inv_idx  <= inv_addr[12:4];
        end else if (inv_pend && inv_now) begin
            inv_idx  <= inv_addr[12:4];          // the pending one is written now, the new one waits
        end else
            inv_pend <= 1'b0;
    end
    always @* tag_q = tag_rd;
    // data RAM
    reg        da_we;
    reg [11:0] da_wa;
    reg [15:0] da_d;
    always @(posedge clk) begin
        if (da_we) dram[da_wa] <= da_d;
        d_q <= dram[rd_addr[12:1]];
    end

    // RAM read address: in IDLE the pre-address (unless a request is waiting there), else the request
    wire [24:0] rd_addr = (st == S_IDLE && !(req && !ack_r && !hit_idle)) ? pre_addr : addr;
    always @* begin
        ta_we = 1'b0; ta_a = rd_addr[12:4]; ta_d = 14'd0; ta_wa_w = rd_addr[12:4];
        da_we = 1'b0; da_wa = {line_q, fill_i}; da_d = m_rdata;
        case (st)
            S_CLR:  begin ta_we = 1'b1; ta_wa_w = clr_i; ta_d = 14'd0; end
            S_LOOK: begin ta_a = line_q; end
            S_FILL: begin
                ta_a = line_q;
                if (m_rvalid) da_we = 1'b1;
            end
            S_TAGW: begin
                // the line is complete: write its tag (after a pending invalidation, if any)
                if (!inv_pend) begin
                    ta_we   = 1'b1;
                    ta_wa_w = line_q;
                    ta_d    = (fill_inv || (inv_c && inv_addr[12:4] == line_q)) ? 14'd0 : {1'b1, a_q[24:12]};
                end
            end
            default: ;
        endcase
    end

    always @(posedge clk) begin
        ack_r <= 1'b0;
        rd_q  <= (st == S_LOOK) ? a_q : rd_addr;
        look_inv_pre <= inv_c && inv_addr[12:4] == rd_addr[12:4];
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
            S_IDLE: if (req && !ack_r && !hit_idle) begin
                a_q      <= addr;
                look_inv <= inv_c && inv_addr[12:4] == addr[12:4];
                if (cacheable) st <= S_LOOK;
                else if (!hold) begin
                    st     <= S_NC;
                    m_req  <= 1'b1;
                    m_addr <= addr[24:1];
                    m_len  <= 6'd1;
                end
            end
            S_LOOK: begin
                if (hit) begin
                    st <= S_IDLE;
                end else if (!hold) begin
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
                        ack_r    <= 1'b1;
                        data_r   <= m_rdata;
                        answered <= 1'b1;
                    end
                    if (fill_i == 3'd7) begin
                        m_req <= 1'b0;
                        st    <= S_TAGW;
                    end
                end
                if (m_done) m_req <= 1'b0;
            end
            S_TAGW: begin
                if (inv_c && inv_addr[12:4] == line_q) fill_inv <= 1'b1;
                if (!inv_pend) st <= S_IDLE;
            end
            S_NC: begin
                if (m_rvalid) begin ack_r <= 1'b1; data_r <= m_rdata; end
                if (m_done) begin m_req <= 1'b0; st <= S_IDLE; end
            end
            default: st <= S_IDLE;
            endcase
        end
    end
endmodule
