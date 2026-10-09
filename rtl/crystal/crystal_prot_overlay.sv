// BrezzaSoft Crystal System MiSTer core -- MAME-compatible protection overlay (game-specific, isolated).
// Copyright (C) 2026 Kyle Lester. SPDX-License-Identifier: GPL-3.0-or-later
//
// The Crystal of Kings cartridge PIC ("dgSMART-PR3", undumped) supplies eight code words that the flash dump
// holds as 0xDEAD. MAME's init_crysking() (c2334733) writes the expected words into the flash region; this
// module substitutes exactly the same words into the download stream on its way to the volatile DDR3 flash
// store. The ZIP / MRA / ROM files are untouched. Enabled only for game id 1 (MRA board record). docs/PROTECTION.md
// Evolution Soccer (game id 2): the same mechanism for MAME's init_evosocc() (PIC "dgSMART-PR2" undumped), eight
// words in flash bank 2 (u16 offset 0x1000000 = byte 0x2000000).
// Two views of one table: `dout`/`hit` substitute the words in a streamed download; `idx` -> `p_off`/`p_val`/`p_ok`
// lists them, for the loader to write them into the DDR3 flash store after a fast (DDR3) ROM load.
module crystal_prot_overlay (
    input  wire  [7:0] game_id,
    input  wire [26:0] flash_off,    // byte offset of the 16-bit word (even)
    input  wire [15:0] din,
    output reg  [15:0] dout,
    output reg         hit,
    input  wire  [2:0] idx,          // table entry
    output reg  [26:0] p_off,
    output reg  [15:0] p_val,
    output reg         p_ok          // the game has a protection overlay (all 8 entries valid)
);
    function automatic [43:0] entry(input [7:0] g, input [2:0] i);   // {valid, byte offset, word}
        entry = '0;
        if (g == 8'd1) begin
            case (i)
                3'd0: entry = {1'b1, 27'h0007bb6, 16'hdf01};   // CALL +2
                3'd1: entry = {1'b1, 27'h0007bb8, 16'h9c00};   // POP %PC
                3'd2: entry = {1'b1, 27'h000976a, 16'h901c};   // PUSH %R4-%R2
                3'd3: entry = {1'b1, 27'h000976c, 16'h9001};   // PUSH %R0
                3'd4: entry = {1'b1, 27'h0008096, 16'h90fc};   // PUSH %R7-%R2
                3'd5: entry = {1'b1, 27'h0008098, 16'h9001};   // PUSH %R0
                3'd6: entry = {1'b1, 27'h0008a52, 16'h4000};   // LERI 0x0
                3'd7: entry = {1'b1, 27'h0008a54, 16'h403c};   // LERI 0x3c
            endcase
        end
        if (g == 8'd2) begin
            case (i)
                3'd0: entry = {1'b1, 27'h297388e, 16'h90fc};   // PUSH R2..R7
                3'd1: entry = {1'b1, 27'h2973890, 16'h9001};   // PUSH R0
                3'd2: entry = {1'b1, 27'h2971058, 16'h907c};   // PUSH R2..R6
                3'd3: entry = {1'b1, 27'h2971060, 16'h9001};   // PUSH R0
                3'd4: entry = {1'b1, 27'h2978036, 16'h900c};   // PUSH R2-R3
                3'd5: entry = {1'b1, 27'h2978038, 16'h8303};   // LD (%SP,0xC),R3
                3'd6: entry = {1'b1, 27'h2974ed0, 16'h90fc};   // PUSH R7-R6-R5-R4-R3-R2
                3'd7: entry = {1'b1, 27'h2974ed2, 16'h9001};   // PUSH R0
            endcase
        end
    endfunction

    always @* begin
        hit  = 1'b0;
        dout = din;
        for (int i = 0; i < 8; i++) begin
            logic [43:0] e;
            e = entry(game_id, 3'(i));
            if (e[43] && e[42:16] == flash_off) begin dout = e[15:0]; hit = 1'b1; end
        end
        {p_ok, p_off, p_val} = entry(game_id, idx);
    end
endmodule
