// BrezzaSoft Crystal System MiSTer core -- MAME-compatible protection overlay (game-specific, isolated).
// Copyright (C) 2026 Kyle Lester. SPDX-License-Identifier: GPL-3.0-or-later
//
// The Crystal of Kings cartridge PIC ("dgSMART-PR3", undumped) supplies eight code words that the flash dump
// holds as 0xDEAD. MAME's init_crysking() (c2334733) writes the expected words into the flash region; this
// module substitutes exactly the same words into the download stream on its way to the volatile DDR3 flash
// store. The ZIP / MRA / ROM files are untouched. Enabled only for game id 1 (MRA board record). docs/PROTECTION.md
// Evolution Soccer (game id 2): the same mechanism for MAME's init_evosocc() (PIC "dgSMART-PR2" undumped), eight
// words in flash bank 2 (u16 offset 0x1000000 = byte 0x2000000).
// Donggul Donggul Haerong (game id 5): MAME's init_donghaer() (PIC "dgSMART-PR2" undumped), eight words in bank 0,
// plus four words beyond MAME: the game's own PIC challenges (in a module XOR-encrypted with 0x2a401ae9 and decrypted
// into RAM at boot) are made to report "pass". Without them every challenge fails, as in MAME, and the game punishes
// itself: its timer-2 interrupt corrupts 8 random work-RAM words every 21 ticks (MAME's "randomly corrupts itself"),
// and a later check spins forever (MAME's hangs). docs/PROTECTION.md.
// Two views of one table: `dout`/`hit` substitute the words in a streamed download; `idx` -> `p_off`/`p_val`/`p_ok`
// lists them, for the loader to write them into the DDR3 flash store after a fast (DDR3) ROM load.
module crystal_prot_overlay (
    input  wire  [7:0] game_id,
    input  wire [26:0] flash_off,    // byte offset of the 16-bit word (even)
    input  wire [15:0] din,
    output reg  [15:0] dout,
    output reg         hit,
    input  wire  [3:0] idx,          // table entry
    output reg  [26:0] p_off,
    output reg  [15:0] p_val,
    output reg         p_ok          // entry idx is valid (entries are packed from 0)
);
    function automatic [43:0] entry(input [7:0] g, input [3:0] i);   // {valid, byte offset, word}
        entry = '0;
        if (g == 8'd1) begin
            case (i)
                4'd0: entry = {1'b1, 27'h0007bb6, 16'hdf01};   // CALL +2
                4'd1: entry = {1'b1, 27'h0007bb8, 16'h9c00};   // POP %PC
                4'd2: entry = {1'b1, 27'h000976a, 16'h901c};   // PUSH %R4-%R2
                4'd3: entry = {1'b1, 27'h000976c, 16'h9001};   // PUSH %R0
                4'd4: entry = {1'b1, 27'h0008096, 16'h90fc};   // PUSH %R7-%R2
                4'd5: entry = {1'b1, 27'h0008098, 16'h9001};   // PUSH %R0
                4'd6: entry = {1'b1, 27'h0008a52, 16'h4000};   // LERI 0x0
                4'd7: entry = {1'b1, 27'h0008a54, 16'h403c};   // LERI 0x3c
            endcase
        end
        if (g == 8'd2) begin
            case (i)
                4'd0: entry = {1'b1, 27'h297388e, 16'h90fc};   // PUSH R2..R7
                4'd1: entry = {1'b1, 27'h2973890, 16'h9001};   // PUSH R0
                4'd2: entry = {1'b1, 27'h2971058, 16'h907c};   // PUSH R2..R6
                4'd3: entry = {1'b1, 27'h2971060, 16'h9001};   // PUSH R0
                4'd4: entry = {1'b1, 27'h2978036, 16'h900c};   // PUSH R2-R3
                4'd5: entry = {1'b1, 27'h2978038, 16'h8303};   // LD (%SP,0xC),R3
                4'd6: entry = {1'b1, 27'h2974ed0, 16'h90fc};   // PUSH R7-R6-R5-R4-R3-R2
                4'd7: entry = {1'b1, 27'h2974ed2, 16'h9001};   // PUSH R0
            endcase
        end
        if (g == 8'd5) begin
            case (i)
                4'd0: entry = {1'b1, 27'h00037a2, 16'h9004};   // PUSH %R2
                4'd1: entry = {1'b1, 27'h00037a4, 16'h8202};   // LD (%SP,0x8),%R2
                4'd2: entry = {1'b1, 27'h0003834, 16'h9001};   // PUSH %R0
                4'd3: entry = {1'b1, 27'h0003836, 16'h9200};   // PUSH %SR
                4'd4: entry = {1'b1, 27'h000ac9e, 16'h9004};   // PUSH %R2
                4'd5: entry = {1'b1, 27'h000aca0, 16'h4081};   // LERI 0x81
                4'd6: entry = {1'b1, 27'h0019c70, 16'h900c};   // PUSH %R2-%R3
                4'd7: entry = {1'b1, 27'h0019c72, 16'h9001};   // PUSH %R0
                // encrypted: RAM 0x02012116.. = flash + 0x200f4a0, word ^ 0x1ae9 (RAM addr % 4 == 0) / ^ 0x2a40
                4'd8:  entry = {1'b1, 27'h0002c76, 16'hc241};  // CALL 0x20118f4 -> LDI 0x1,%R0 (challenge 1 passes)
                4'd9:  entry = {1'b1, 27'h0002cae, 16'hc241};  // CALL 0x20117b8 -> LDI (challenge 2)
                4'd10: entry = {1'b1, 27'h0002cbc, 16'hf2e8};  // CALL 0x2011c42 -> LDI (challenge 3)
                4'd11: entry = {1'b1, 27'h0002cf6, 16'hc241};  // CALL 0x2011f80 -> LDI (challenge 4)
            endcase
        end
    endfunction

    always @* begin
        hit  = 1'b0;
        dout = din;
        for (int i = 0; i < 16; i++) begin
            logic [43:0] e;
            e = entry(game_id, 4'(i));
            if (e[43] && e[42:16] == flash_off) begin dout = e[15:0]; hit = 1'b1; end
        end
        {p_ok, p_off, p_val} = entry(game_id, idx);
    end
endmodule
