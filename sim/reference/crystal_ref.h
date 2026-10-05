// Crystal System whole-board reference model (behavioural specification for the MiSTer core).
//
// Derived from MAME commit c233473382353a00fb2d8b00d98c197cee910854:
//   src/mame/misc/crystal.cpp            (BSD-3-Clause, ElSemi, Angelo Salese)
//   src/devices/machine/vrender0.cpp     (BSD-3-Clause, Angelo Salese, ElSemi)
//   src/devices/video/vrender0.cpp       (BSD-3-Clause, ElSemi, Angelo Salese)
//   src/devices/sound/vrender0.cpp       (BSD-3-Clause, ElSemi)
//   src/devices/machine/ds1302.cpp       (BSD-3-Clause, Curt Coder)
// Restructured into a deterministic, single-threaded model with one time base: the VRender0 clock
// (85.909080 MHz = clk_sys of the FPGA core). See docs/MAME_REFERENCE.md for the mapping and deviations.
//
// Copyright (C) 2026 Kyle Lester for the restructuring. BSD-3-Clause, as the MAME sources it derives from.
#pragma once
#include "se3208_ref.h"
#include <array>
#include <cstdint>
#include <cstdio>
#include <functional>
#include <map>
#include <string>
#include <vector>

namespace crystal {

constexpr uint32_t TICKS_PER_INSN = 6;      // SE3208 at 42.95 MHz, 3 cycles per instruction (MAME master)
constexpr uint32_t SOUND_TICKS = 1944;      // sound clock (VR0/2) / 972
constexpr uint32_t PIPE_TICKS = 1100;       // MAME vr0video pipeline timer: clock / 1100 Hz period

struct Config {
    bool pic_master = true;          // MAME master: PIO bit 29 reads !(written bit 29); 0.289: reads 0
    bool reset_patch = false;        // MAME-only test-menu reset workaround (category: MAME convenience)
    bool crysking_patch = true;      // init_crysking() protection substitution
    int  bios = 0;                   // 0 = mx27l1000.u14, 1 = mx27l1000-alt.u14
};

struct Inputs {
    uint32_t p1p2 = 0xffffffff;
    uint32_t p3p4 = 0xffffffff;
    uint8_t  system = 0xff;   // active low: b0..3 start1-4, b4 coin1, b5 coin2, b6 service1, b7 service (test)
    uint8_t  dsw = 0xff;
};

// Statistics/trace hooks for research tools
struct Hooks {
    std::function<void(uint32_t addr, int size, uint32_t data, bool write)> io_access;  // non-RAM accesses
    std::function<void(uint32_t ptr, const uint16_t *pkt)> packet;                     // each processed packet
    std::function<void(int frame)> vblank;
    std::function<void(int which, uint32_t src, uint32_t dst, uint32_t cnt, uint32_t ctrl)> dma_start;
    std::function<void(int16_t l, int16_t r)> sample;
};

class Board {
public:
    Board();
    bool load_roms(const std::string &bios_zip_dir_files, const std::string &game_files); // see .cpp
    bool load_bios(const std::vector<uint8_t> &bios);
    void load_flash(const std::vector<uint8_t> &flash);   // concatenated u1,u2,u3 (bytes as in the ROM files)
    void reset();
    void run_ticks(uint64_t ticks);
    void run_frames(int frames);
    void step_insn();

    // memory
    std::vector<uint8_t> bios, nvram, workram, texram, frameram, flash;
    se3208::Cpu cpu;
    Config cfg;
    Inputs in;
    Hooks hooks;

    uint64_t now = 0;          // VR0 ticks since reset
    int frame = 0;

    // bus
    uint32_t read(uint32_t addr, int size);
    void write(uint32_t addr, int size, uint32_t data);
    uint16_t fetch(uint32_t addr);

    // ---- board state
    uint32_t bank = 0, maxbank = 0, flashcmd = 0xff, pio = 0;
    bool pic_data = true;
    uint8_t lamps[2] = {0, 0};
    uint8_t coin_counter = 0;
    void coin_insert(int chute) { int_req(chute ? 19 : 12); }

    // ---- VR0 system
    uint32_t inten = 0, intst = 0;
    uint8_t int_high = 0;
    bool int_line = false;
    void int_req(int num);
    uint8_t irq_vector();
    struct Timer { uint32_t control = 0xff00; uint16_t count = 0; uint64_t fire = UINT64_MAX; } tmr[4];
    void timer_start(int w);
    struct Dma { uint32_t src = 0, dst = 0, size = 0; uint16_t ctrl = 0; uint64_t next = UINT64_MAX; } dma[2];
    void dma_step(int w);
    uint32_t crtc[0x38 / 4] = {};
    uint8_t lightc = 0;
    uint32_t uart_ucon[2] = {1, 1}, uart_ubdr[2] = {1, 1};
    uint64_t uart_tx_count = 0;
    uint32_t crtc_r(int off);
    void crtc_w(int off, uint32_t data, uint32_t mask);
    void crtc_update();
    bool crt_interlaced() const { return !(crtc[0x30 / 4] & 1); }

    // screen timing (MAME screen_device equivalent)
    uint32_t scr_htot = 455, scr_vtot = 262, scr_hdisp = 320, scr_vdisp = 240, scr_tpp = 12;
    uint64_t frame_start = 0;   // tick of (0,0) of the current frame
    uint64_t next_vblank = 0;
    int vpos() const;
    int hpos() const;

    // ---- VR0 video
    uint16_t queue_rear = 0, queue_front = 0;
    bool bank1_select = false, draw_select = false, render_reset = false, render_start = false, flip_sync = false;
    uint8_t display_bank = 0, dither_mode = 0, flip_count = 0;
    uint32_t draw_dest = 0, display_dest = 0;
    uint16_t internal_palette[256] = {};
    uint32_t last_pal_update = 0xffffffff;
    struct RenderState {
        uint32_t tx = 0, ty = 0, txdx = 0, tydx = 0, txdy = 0, tydy = 0;
        uint32_t src_alpha_color = 0, src_blend = 0, dst_alpha_color = 0, dst_blend = 0;
        uint32_t shade_color = 0, trans_color = 0, tile_offset = 0, font_offset = 0, pal_offset = 0;
        uint8_t palette_bank = 0;
        bool texture_mode = false;
        uint8_t pixel_format = 0;
        uint16_t width = 0, height = 0;
    } rs;
    uint64_t next_pipe = PIPE_TICKS;
    uint64_t pixels_drawn = 0, packets_done = 0;
    void pipeline_tick();
    int process_packet(uint32_t ptr);
    void execute_flipping();
    void screen_vblank();
    uint16_t vid_r16(uint32_t off);
    void vid_w16(uint32_t off, uint16_t data, uint16_t mask);

    // ---- VR0 sound
    struct Channel {
        uint32_t cur_saddr = 0;
        int32_t env_vol = 0;
        uint8_t env_stage = 0;
        uint16_t ds_addr = 0;
        uint8_t modes = 0;
        bool ld = false;
        uint32_t loop_begin = 0, loop_end = 0;
        uint8_t l_chn_vol = 0, r_chn_vol = 0;
        int32_t env_rate[4] = {};
        uint8_t env_target[4] = {};
        uint16_t read(int off) const;
        void write(int off, uint16_t data, uint16_t mask);
    } ch[32];
    uint32_t snd_status = 0, snd_note_on = 0, snd_int_mask = 0, snd_int_pend = 0, snd_buffer_addr = 0;
    uint16_t snd_rev_factor = 0, snd_buffer_size[4] = {}, snd_ctrl = 0;
    uint8_t snd_max_chan = 0, snd_chan_clk_num = 0;
    uint64_t next_sample = SOUND_TICKS;
    void sound_sample(int16_t &l, int16_t &r);
    uint16_t snd_r16(uint32_t off);
    void snd_w16(uint32_t off, uint16_t data, uint16_t mask);

    // ---- DS1302
    struct Rtc {
        bool ce = false, clk = false, io = false;
        uint8_t state = 0, bits = 0, cmd = 0, data = 0, addr = 0;
        uint8_t reg[9] = {0x00, 0x00, 0x00, 0x01, 0x01, 0x01, 0x01, 0x00, 0x00};
        uint8_t user[9] = {};
        uint8_t ram[0x1f] = {};
        void ce_w(bool s);
        void sclk_w(bool s);
        void io_w(bool s) { io = s; }
        bool io_r() const { return io; }
        void input_bit();
        void output_bit();
        void load_shift_register();
        void tick_second();
    } rtc;
    uint64_t next_rtc = 85909080ull;

    // helpers
    uint8_t tex8(uint32_t a) const { return texram[a & 0x7fffff]; }
    uint16_t tex16(uint32_t a) const { a &= 0x7ffffe; return texram[a] | (texram[a + 1] << 8); }
    uint32_t tex32(uint32_t a) const { return tex16(a) | (uint32_t(tex16(a + 2)) << 16); }
    uint16_t fb16(uint32_t a) const { a &= 0x7ffffe; return frameram[a] | (frameram[a + 1] << 8); }
    void fbw16(uint32_t a, uint16_t v) { a &= 0x7ffffe; frameram[a] = v & 0xff; frameram[a + 1] = v >> 8; }

    // stats (research instrumentation; zero cost to behaviour)
    struct Stats {
        enum { R_BIOS, R_NVRAM, R_WRAM, R_TEX, R_FRAME, R_FLASH, R_SYS, R_VID, R_SND, R_BOARD, R_OTHER, R_N };
        uint64_t fetch[R_N] = {}, rd[R_N] = {}, wr[R_N] = {};
        uint64_t rd_size[5] = {}, wr_size[5] = {};
        uint64_t unaligned = 0;
        uint64_t op[se3208::OP_COUNT] = {};
        std::map<uint32_t, uint64_t> io_rd, io_wr;
        uint64_t quads = 0, quads_tex = 0, quads_fill = 0, quads_blend = 0, quads_shade = 0, quads_tiled = 0;
        uint64_t quads_bpp[3] = {}, quads_rot = 0, quads_scaled = 0, quads_clamp = 0, quads_trans = 0, flips = 0;
        uint64_t px_considered = 0, px_written_tex = 0, px_fill = 0, px_skipped = 0, fb_reads_blend = 0;
        uint64_t texel_reads = 0, tile_reads = 0, pal_loads = 0;
        uint64_t frame_px = 0, max_frame_px = 0, frame_considered = 0, max_frame_considered = 0;
        std::map<uint32_t, uint64_t> blend_modes;   // (src_blend<<8)|dst_blend
        uint32_t snd_modes_seen = 0, snd_ctrl_seen = 0, snd_max_chan_seen = 0, snd_clk_seen = 0;
        uint64_t snd_voice_samples = 0;
        uint64_t irqs = 0;
        std::map<uint8_t, uint64_t> irq_vectors;
    } st;
    bool in_fetch = false;
    static int region(uint32_t a);
    uint64_t unmapped_reads = 0, unmapped_writes = 0;
    std::vector<std::string> log;
private:
    uint32_t sys_r32(uint32_t off, uint32_t mask);
    void sys_w32(uint32_t off, uint32_t data, uint32_t mask);
    void process_events();
    void update_int_line();
};

} // namespace crystal
