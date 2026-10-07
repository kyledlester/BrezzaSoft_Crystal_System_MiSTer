// BrezzaSoft Crystal System MiSTer core -- ordered texture-RAM write queue.
// Copyright (C) 2026 Kyle Lester. SPDX-License-Identifier: GPL-3.0-or-later
//
// Why: MAME renders each display-list packet almost as soon as it is queued (one per 1100 clocks), so by the time
// the CPU goes on to upload the next frame's sprite textures, the list it submitted has long been drawn. The
// Crystal of Kings updates animation textures IN PLACE right after submitting a list (measured with
// sim/reference/tex_race.cpp: up to ~500 rewritten lines per frame during the How-to-Play fights). The RTL
// renderer draws pixel by pixel and may still be drawing that list, so without ordering it mixes the next pose
// into the current frame (sprite jitter) and draws half-uploaded rows (flashing lines) -- the first hardware build.
//
// How: CPU/DMA writes to texture RAM and the display-list queue-front updates (written by the CPU to the video
// registers) go through ONE ordered queue:
//   * a texture write is applied to SDRAM only when the renderer has caught up with the queue front it can see
//     (drain_ok: idle with nothing queued, stopped at a flip-sync packet, or not started) -- so everything
//     submitted before the write is drawn with the old data, as in MAME;
//   * a queue-front update is passed to the renderer when it reaches the head -- so packets queued after a write
//     are only drawn once the write is in SDRAM.
// The CPU does not wait: texture writes are acknowledged when queued (it stalls only when the queue is full).
// A texture-RAM read of a 64-byte block with no queued write goes to the D-cache; one whose block still has a
// queued write is answered from the forwarding shadow (below) when that holds the newest bytes it asks for, and
// otherwise waits until the block's writes have drained. Other SDRAM requests pass through untouched; the queue
// takes the D-cache port only between CPU transactions.
//
// Forwarding shadow: 1024 dwords, direct mapped on the texture dword address. Every queued texture write merges
// its bytes into the entry of its dword (replacing the entry if it held another dword), so an entry whose tag
// matches holds the newest value of the bytes in its mask. All texture writes come through this queue, so a
// matching entry stays correct after the writes drain. The shadow is swept clear after every reset. The games
// re-read texture lines they have just written (Top Blade V, Office Yeoin Cheonha): all such reads measured in
// sim/integration/tb_core.cpp are covered, where waiting for the drain would stall the CPU until the renderer has
// caught up.
module crystal_texq #(
    parameter integer AW = 12                // 2^AW entries (Evolution Soccer peaks above 2,000)
) (
    input  wire        clk,
    input  wire        rst_n,

    // CPU/DMA SDRAM requests (flash and NVRAM already excluded)
    input  wire        c_req,
    input  wire        c_we,
    input  wire [24:0] c_addr,               // SDRAM byte address
    input  wire  [3:0] c_be,
    input  wire [31:0] c_wdata,
    output wire        c_ack,
    output reg         c_fwd,                // c_ack answers a read from the forwarding shadow: data on c_fwd_data
    output reg  [31:0] c_fwd_data,

    // to the D-cache
    output wire        d_req,
    output wire        d_we,
    output wire [24:0] d_addr,
    output wire  [3:0] d_be,
    output wire [31:0] d_wdata,
    input  wire        d_ack,
    input  wire        d_idle,               // the D-cache has no transaction in progress

    // display-list queue front (video registers)
    input  wire        front_wr,             // CPU wrote the queue front (merged 16-bit value)
    input  wire [15:0] front_wr_val,
    output reg         front_set,            // apply it to the renderer
    output reg  [15:0] front_set_val,
    input  wire        drain_ok,             // the renderer has caught up with the front it sees
    output wire        empty,
    output reg  [15:0] max_used,             // statistics: highest occupancy
    output wire  [2:0] dbg_state             // {own, read blocked by a pending write, empty}
);
    localparam integer DEPTH = 1 << AW;
    // entry: {front, be[3:0], word[22:2] (21 bits), data[31:0]}
    localparam integer EW = 1 + 4 + 21 + 32;

    reg  [AW-1:0] wr_ptr, rd_ptr;
    reg  [AW:0]   cnt;
    reg  [1:0]    settle;                    // clocks until the RAM output shows the head
    reg           ack_q;
    reg           own;                        // the queue owns the D-cache port (a drain write in flight)
    wire [EW-1:0] head;

    wire is_tex  = c_addr[24:23] == 2'b01;
    wire tex_wr  = c_req && c_we && is_tex;
    wire tex_rd  = c_req && !c_we && is_tex;
    // pending texture writes per 64-byte block (128 buckets, block index mod 128): a CPU/DMA texture read waits
    // only while a write to its block is still queued (read-after-write), not for the whole queue
    reg  [AW:0] pend [0:127];
    reg [127:0] pz;                             // pend[b] == 0, kept beside the counts (1-bit lookup for reads)
    wire  [6:0] rd_bkt   = c_addr[12:6];
    // looked up one clock after the read is presented and held in a register (timing: keeps the counters and the
    // address compare off the CPU's direct path). The CPU holds a read until it is acked and cannot push a write
    // meanwhile; queued writes only drain, so the result stays valid. Cleared on the ack so the next read is
    // looked up afresh. Texture RAM is uncached, the extra clock is negligible.
    reg         rd_seen_q, rd_free_q;           // the held read was seen last clock / its block had no write queued
    wire        rd_ok_q = rd_seen_q && rd_free_q;
    reg         pw_q, pq_q;                     // a push / a drain write counted one clock late
    reg   [6:0] pwb_q, pqb_q;
    wire        rd_block = !rd_ok_q;

    // forwarding shadow: entry {tag = dword[22:12], mask, data}; read address follows the CPU port, so its output
    // shows the held read's entry one clock after the read appears (and a push's old entry the clock after it)
    localparam integer SW = 11 + 4 + 32;
    wire [SW-1:0] sh_q;
    reg           sh_we;
    reg     [9:0] sh_wa;
    reg  [SW-1:0] sh_wd;
    reg    [31:0] pwd_q;                        // the push being merged (pw_q): address, lanes, data
    reg    [20:0] pwa_q;
    reg     [3:0] pwbe_q;
    reg           clr_busy;                     // sweeping the shadow clear after reset
    reg     [9:0] clr_a;
    wire          sh_hit = sh_q[SW-1:36] == c_addr[22:12] && (sh_q[35:32] & c_be) == c_be;
    crystal_sdpram #(.AW(10), .DW(SW)) shadow (
        .clk(clk), .we(sh_we), .waddr(sh_wa), .wdata(sh_wd), .raddr(c_addr[11:2]), .rdata(sh_q)
    );
    // a read whose block has a queued write, seen last clock, answered now (registered: c_fwd)
    wire fwd_go = rd_seen_q && !rd_free_q && !clr_busy && !c_fwd && sh_hit && c_be != 4'd0;
    wire push_ev = front_wr;
    wire push_wr = tex_wr && !ack_q && !front_wr && cnt < DEPTH - 16;
    wire push    = push_ev || push_wr;
    wire [EW-1:0] wdata = push_ev ? {1'b1, 4'd0, 21'd0, 16'd0, front_wr_val}
                                  : {1'b0, c_be, c_addr[22:2], c_wdata};

    assign empty = (cnt == 0);
    assign dbg_state = {own, tex_rd && rd_block, empty};
    wire head_ok    = !empty && settle == 2'd0;
    wire head_front = head[EW-1];
    wire pop_front  = head_ok && head_front;
    wire cpu_pass   = c_req && !tex_wr && !(tex_rd && rd_block) && !c_fwd;
    // take the D-cache port only between transactions: no CPU request on the bus and the D-cache idle (a CPU
    // request it accepted may still be in progress after the request line dropped)
    wire start_own  = head_ok && !head_front && drain_ok && !own && !cpu_pass && d_idle;
    wire pop_wr     = own && d_ack;
    wire pop        = pop_front || pop_wr;

    crystal_sdpram #(.AW(AW), .DW(EW)) mem (
        .clk(clk), .we(push), .waddr(wr_ptr), .wdata(wdata), .raddr(rd_ptr), .rdata(head)
    );

    assign d_req   = own ? 1'b1 : cpu_pass;
    assign d_we    = own ? 1'b1 : c_we;
    assign d_addr  = own ? {2'b01, head[52:32], 2'b00} : c_addr;
    assign d_be    = own ? head[56:53] : c_be;
    assign d_wdata = own ? head[31:0] : c_wdata;
    assign c_ack   = ack_q || c_fwd || (!own && cpu_pass && d_ack);

    always @(posedge clk) begin
        ack_q     <= push_wr;
        front_set <= 1'b0;
        c_fwd     <= rst_n && fwd_go;
        c_fwd_data <= sh_q[31:0];
        pwd_q  <= c_wdata;
        pwa_q  <= c_addr[22:2];
        pwbe_q <= c_be;
        // shadow write port: merge the push from the previous clock (sh_q holds its dword's old entry), else sweep
        sh_we <= 1'b0;
        if (pw_q) begin
            sh_we <= 1'b1;
            sh_wa <= pwa_q[9:0];
            if (sh_q[SW-1:36] == pwa_q[20:10] && !clr_busy) begin
                for (int b = 0; b < 4; b++)
                    sh_wd[8*b +: 8] <= pwbe_q[b] ? pwd_q[8*b +: 8] : sh_q[8*b +: 8];
                sh_wd[SW-1:32] <= {pwa_q[20:10], sh_q[35:32] | pwbe_q};
            end else
                sh_wd <= {pwa_q[20:10], pwbe_q, pwd_q};
        end else if (clr_busy) begin
            sh_we <= 1'b1;
            sh_wa <= clr_a;
            sh_wd <= '0;
            clr_a <= clr_a + 1'b1;
            if (clr_a == 10'h3ff) clr_busy <= 1'b0;
        end
        if (!rst_n) begin
            wr_ptr <= '0; rd_ptr <= '0; cnt <= '0; settle <= 2'd0; own <= 1'b0; ack_q <= 1'b0; rd_seen_q <= 1'b0; pw_q <= 1'b0; pq_q <= 1'b0; pz <= '1;
            clr_busy <= 1'b1; clr_a <= '0;
            for (int k = 0; k < 128; k++) pend[k] <= '0;
            max_used <= 16'd0;
        end else begin
            if (push) wr_ptr <= wr_ptr + 1'b1;
            if (pop)  rd_ptr <= rd_ptr + 1'b1;
            cnt <= cnt + (push ? 1'b1 : 1'b0) - (pop ? 1'b1 : 1'b0);
            if (cnt > max_used) max_used <= cnt;
            // the registered RAM output follows rd_ptr two clocks later; a write into the head slot also needs it
            if (pop || (push && wr_ptr == rd_ptr)) settle <= 2'd2;
            else if (settle != 2'd0) settle <= settle - 2'd1;
            if (pop_front) begin front_set <= 1'b1; front_set_val <= head[15:0]; end
            if (start_own) own <= 1'b1;
            if (pop_wr)    own <= 1'b0;
            // a push reaches its counter one clock late (pw_q); no read is looked up in that clock
            // (two halves registered separately: the counter lookup does not wait for the address decode)
            rd_seen_q <= tex_rd && !c_ack && !pw_q;
            rd_free_q <= pz[rd_bkt];
            pw_q  <= push_wr;
            pwb_q <= c_addr[12:6];
            pq_q  <= pop_wr;
            pqb_q <= head[42:36];
            // per-block pending counts (a push and a pop of the same block cancel). Both are counted one clock
            // late (timing); a late decrement only keeps a read waiting one clock longer. The pop of an entry
            // comes at least two clocks after its push (RAM settle), so its increment always comes first.
            if (pw_q && !(pq_q && pwb_q == pqb_q)) begin
                pend[pwb_q] <= pend[pwb_q] + 1'b1;
                pz[pwb_q]   <= 1'b0;
            end
            if (pq_q && !(pw_q && pwb_q == pqb_q)) begin
                pend[pqb_q] <= pend[pqb_q] - 1'b1;
                pz[pqb_q]   <= pend[pqb_q] == 1;
            end
        end
    end
    integer bi;
    initial begin
        for (bi = 0; bi < 128; bi = bi + 1) pend[bi] = '0;
        pz = '1;
    end
endmodule
