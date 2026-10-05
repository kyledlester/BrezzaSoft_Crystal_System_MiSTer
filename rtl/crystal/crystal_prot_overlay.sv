// BrezzaSoft Crystal System MiSTer core -- MAME-compatible protection overlay (game-specific, isolated).
// Copyright (C) 2026 Kyle Lester. SPDX-License-Identifier: GPL-3.0-or-later
//
// The Crystal of Kings cartridge PIC ("dgSMART-PR3", undumped) supplies eight code words that the flash dump
// holds as 0xDEAD. MAME's init_crysking() (c2334733) writes the expected words into the flash region; this
// module substitutes exactly the same words into the download stream on its way to the volatile DDR3 flash
// store. The ZIP / MRA / ROM files are untouched. Enabled only for game id 1 (MRA board record). docs/PROTECTION.md
module crystal_prot_overlay (
    input  wire  [7:0] game_id,
    input  wire [26:0] flash_off,    // byte offset of the 16-bit word (even)
    input  wire [15:0] din,
    output reg  [15:0] dout,
    output reg         hit
);
    always @* begin
        hit  = 1'b0;
        dout = din;
        if (game_id == 8'd1) begin
            case (flash_off)
                27'h0007bb6: begin dout = 16'hdf01; hit = 1'b1; end   // CALL +2
                27'h0007bb8: begin dout = 16'h9c00; hit = 1'b1; end   // POP %PC
                27'h000976a: begin dout = 16'h901c; hit = 1'b1; end   // PUSH %R4-%R2
                27'h000976c: begin dout = 16'h9001; hit = 1'b1; end   // PUSH %R0
                27'h0008096: begin dout = 16'h90fc; hit = 1'b1; end   // PUSH %R7-%R2
                27'h0008098: begin dout = 16'h9001; hit = 1'b1; end   // PUSH %R0
                27'h0008a52: begin dout = 16'h4000; hit = 1'b1; end   // LERI 0x0
                27'h0008a54: begin dout = 16'h403c; hit = 1'b1; end   // LERI 0x3c
                default: ;
            endcase
        end
    end
endmodule
