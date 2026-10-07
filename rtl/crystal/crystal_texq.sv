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
// The CPU does not wait: texture writes are acknowledged when queued (it stalls only when the queue is full, or
// on a texture-RAM read while writes are pending). Other SDRAM requests pass through untouched; the queue takes
// the D-cache port only between CPU transactions.
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
    output reg  [15:0] max_used              // statistics: highest occupancy
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
    wire push_ev = front_wr;
    wire push_wr = tex_wr && !ack_q && !front_wr && cnt < DEPTH - 16;
    wire push    = push_ev || push_wr;
    wire [EW-1:0] wdata = push_ev ? {1'b1, 4'd0, 21'd0, 16'd0, front_wr_val}
                                  : {1'b0, c_be, c_addr[22:2], c_wdata};

    assign empty = (cnt == 0);
    wire head_ok    = !empty && settle == 2'd0;
    wire head_front = head[EW-1];
    wire pop_front  = head_ok && head_front;
    wire cpu_pass   = c_req && !tex_wr && !(tex_rd && !empty);
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
    assign c_ack   = ack_q || (!own && cpu_pass && d_ack);

    always @(posedge clk) begin
        ack_q     <= push_wr;
        front_set <= 1'b0;
        if (!rst_n) begin
            wr_ptr <= '0; rd_ptr <= '0; cnt <= '0; settle <= 2'd0; own <= 1'b0; ack_q <= 1'b0;
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
        end
    end
endmodule
