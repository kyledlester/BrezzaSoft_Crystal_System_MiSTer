// Crystal System whole-board reference model. See crystal_ref.h for provenance and license.
#include "crystal_ref.h"
#include <algorithm>
#include <cstring>

namespace crystal {

static inline uint32_t combine(uint32_t old, uint32_t data, uint32_t mask) { return (old & ~mask) | (data & mask); }

// ------------------------------------------------------------------------------------------------ construction

Board::Board()
    : bios(0x20000, 0), nvram(0x10000, 0), workram(0x800000, 0), texram(0x800000, 0), frameram(0x800000, 0)
{
    cpu.bus.read = [this](uint32_t a, int s) { return read(a, s); };
    cpu.bus.write = [this](uint32_t a, int s, uint32_t d) { write(a, s, d); };
    cpu.bus.fetch = [this](uint32_t a) { return fetch(a); };
    cpu.bus.iack = [this]() { return irq_vector(); };
}

bool Board::load_bios(const std::vector<uint8_t> &b)
{
    if (b.size() != 0x20000) return false;
    bios = b;
    return true;
}

void Board::load_flash(const std::vector<uint8_t> &f)
{
    flash = f;
    maxbank = uint32_t(flash.size() / 0x1000000);
    auto w16 = [&](uint32_t a, uint16_t v) { if (a + 1 < flash.size()) { flash[a] = v & 0xff; flash[a + 1] = v >> 8; } };
    if (cfg.game == "evosocc") {
        // init_evosocc(): u16 words at 0x1000000 u16 units = byte 0x2000000 into the flash region
        const uint32_t b = 0x2000000;
        w16(b + 0x97388e, 0x90fc);  // PUSH R2..R7
        w16(b + 0x973890, 0x9001);  // PUSH R0
        w16(b + 0x971058, 0x907c);  // PUSH R2..R6
        w16(b + 0x971060, 0x9001);  // PUSH R0
        w16(b + 0x978036, 0x900c);  // PUSH R2-R3
        w16(b + 0x978038, 0x8303);  // LD (%SP,0xC),R3
        w16(b + 0x974ed0, 0x90fc);  // PUSH R7-R6-R5-R4-R3-R2
        w16(b + 0x974ed2, 0x9001);  // PUSH R0
    }
    if (cfg.game == "crysking" && cfg.crysking_patch && flash.size() >= 0x10000) {
        // init_crysking(): u16 little-endian words written into the flash region (docs/PROTECTION.md)
        w16(0x7bb6, 0xdf01);
        w16(0x7bb8, 0x9c00);
        w16(0x976a, 0x901c);
        w16(0x976c, 0x9001);
        w16(0x8096, 0x90fc);
        w16(0x8098, 0x9001);
        w16(0x8a52, 0x4000);
        w16(0x8a54, 0x403c);
    }
}

bool Board::load_pic(pic16::Model m, const std::vector<uint8_t> &image)
{
    pic = std::make_unique<pic16::Pic>();
    if (!pic->load(m, image)) { pic.reset(); return false; }
    // crystal_state::pic_porta_r / pic_porta_w
    pic->porta_in = [this]() -> uint8_t { return pic_data ? 1 : 0; };
    pic->porta_out = [this](uint8_t d, uint8_t mask) { if (mask & 1) pic_data = d & 1; };
    return true;
}

void Board::reset()
{
    // crystal_state::machine_reset
    bank = 0;
    flashcmd = 0xff;
    // vrender0soc_device::device_reset
    std::fill(std::begin(crtc), std::end(crtc), 0);
    crtc[1] = 0x2a;
    int_high = 0;
    for (auto &d : dma) { d.ctrl = 0; d.next = UINT64_MAX; }
    for (auto &t : tmr) { t.control = 0xff << 8; t.fire = UINT64_MAX; }
    // vr0video_device::device_reset
    std::fill(std::begin(internal_palette), std::end(internal_palette), 0);
    last_pal_update = 0xffffffff;
    display_dest = draw_dest = 0;
    now = 0;
    frame = 0;
    next_pipe = PIPE_TICKS;
    scr_htot = 455; scr_vtot = 262; scr_hdisp = 320; scr_vdisp = 240; scr_tpp = 12;
    frame_start = 0;
    next_vblank = uint64_t(scr_htot) * scr_vdisp * scr_tpp;   // master ticks (screen runs on the crystal)
    next_sample = SOUND_TICKS;
    pic_next = 0;
    pic_reset = false;
    if (pic) pic->reset();
    next_rtc = 85909080ull;
    cpu.reset();
}

// ------------------------------------------------------------------------------------------------ scheduling

int Board::vpos() const
{
    uint64_t t = v2m(now) - frame_start;
    return int((t / scr_tpp) / scr_htot);
}

int Board::hpos() const
{
    uint64_t t = v2m(now) - frame_start;
    return int((t / scr_tpp) % scr_htot);
}

void Board::process_events()
{
    for (;;) {
        uint64_t t = UINT64_MAX;
        int which = -1;
        auto cand = [&](uint64_t when, int id) { if (when < t) { t = when; which = id; } };
        for (int i = 0; i < 4; i++) cand(tmr[i].fire, i);
        for (int i = 0; i < 2; i++) cand(dma[i].next, 4 + i);
        cand(next_pipe, 6);
        cand(m2v(next_vblank), 7);
        cand(next_sample, 8);
        cand(m2v(next_rtc), 9);
        if (t > now) return;
        switch (which) {
        case 0: case 1: case 2: case 3: {
            static const int num[] = {0, 1, 9, 10};
            Timer &tm = tmr[which];
            tm.fire = UINT64_MAX;
            if (tm.control & 2) timer_start(which);
            else tm.control &= ~1u;
            // timer_start reschedules relative to "now" in MAME (timer fires at callback time)
            int_req(num[which]);
            break;
        }
        case 4: case 5:
            dma_step(which - 4);
            break;
        case 6:
            next_pipe += PIPE_TICKS;
            pipeline_tick();
            break;
        case 7:
            screen_vblank();
            break;
        case 8: {
            next_sample += SOUND_TICKS;
            int16_t l, r;
            sound_sample(l, r);
            if (hooks.sample) hooks.sample(l, r);
            break;
        }
        case 9:
            next_rtc += 85909080ull;
            rtc.tick_second();
            break;
        }
    }
}

void Board::step_insn()
{
    now += TICKS_PER_INSN;
    process_events();
    cpu.irq_line = int_line;
    cpu.step();
    // protection PIC: one instruction cycle per 96 master ticks (3.579545 MHz / 4), interleaved with the CPU
    if (pic) {
        const uint64_t m = v2m(now);
        while (pic_next <= m) pic_next += 96ull * (pic_reset ? 1 : pic->step());
    }
    st.op[cpu.last_op]++;
    if (cpu.last_took_irq) { st.irqs++; st.irq_vectors[cpu.last_irq_vector]++; }
}

void Board::run_ticks(uint64_t ticks)
{
    uint64_t end = now + ticks;
    while (now < end) step_insn();
}

void Board::run_frames(int frames)
{
    int target = frame + frames;
    while (frame < target) step_insn();
}

// ------------------------------------------------------------------------------------------------ interrupts

void Board::update_int_line() { int_line = intst != 0; }

void Board::int_req(int num)
{
    if (inten & (1u << num)) {
        intst |= (1u << num);
        int_line = true;
    }
}

uint8_t Board::irq_vector()
{
    for (int i = 0; i < 32; ++i)
        if (intst & (1u << i))
            return uint8_t((int_high << 5) | i);
    return 0;
}

// ------------------------------------------------------------------------------------------------ timers / DMA

void Board::timer_start(int w)
{
    Timer &t = tmr[w];
    uint32_t pd = (t.control >> 8) & 0xff;
    uint32_t tcv = t.count & 0xffff;
    t.fire = now + 2ull * (pd + 1) * (tcv + 1);
}

static int dma_setup_hold(uint32_t setting, int holdbit, int dirbit)
{
    if ((setting >> holdbit) & 1) return 0;
    int amount = (setting & 2) ? 4 : (1 << (setting & 1));
    return ((setting >> dirbit) & 1) ? -amount : amount;
}

void Board::dma_step(int w)
{
    Dma &d = dma[w];
    d.next = UINT64_MAX;
    if (!(d.ctrl & (1 << 10))) return;
    if (d.size == 0) {
        d.ctrl &= ~(1 << 10);
        int_req(7 + w);
        return;
    }
    int si = dma_setup_hold(d.ctrl, 5, 4);
    int di = dma_setup_hold(d.ctrl, 3, 2);
    switch (d.ctrl & 3) {
    case 0: write(d.dst, 1, read(d.src, 1)); break;
    case 1: write(d.dst & ~1u, 2, read(d.src & ~1u, 2)); break;
    default: write(d.dst & ~3u, 4, read(d.src & ~3u, 4)); break;
    }
    d.src += si;
    d.dst += di;
    d.size--;
    d.next = now + 4;
}

// ------------------------------------------------------------------------------------------------ CRTC

uint32_t Board::crtc_r(int off)
{
    uint32_t res = crtc[off];
    if (off == 0) {
        res &= 0x03ff;
        uint32_t hdisp = crtc[0x0c / 4] + 1;
        uint32_t vdisp = crtc[0x1c / 4] + 1;
        if (crt_interlaced()) vdisp <<= 1;
        int vp = vpos(), hp = hpos();
        if (uint32_t(vp) <= vdisp) res |= 1 << 14;
        if (uint32_t(hp) <= hdisp && uint32_t(vp) <= vdisp) res |= 1 << 13;
        if (uint32_t(hp) <= hdisp) res |= 1 << 15;
    }
    return res;
}

void Board::crtc_w(int off, uint32_t data, uint32_t mask)
{
    if ((crtc[0] & 0x0100) && off > 0 && off < 0x28 / 4) return;
    uint32_t old = crtc[off];
    switch (off * 4) {
    case 0x00: mask &= ~0xfffffc00u; break;
    case 0x04: mask &= ~0xffffc000u; break;
    case 0x08: mask &= ~0xffff0000u; break;
    case 0x0c: mask &= ~0xfffffc00u; break;
    case 0x10: mask &= ~0xfffffe00u; break;
    case 0x14: mask &= ~0xffff80c0u; break;
    case 0x18: mask &= ~0xffffff00u; break;
    case 0x1c: mask &= ~0xfffffe00u; break;
    case 0x20: mask &= ~0xffffe000u; if (!(data & (1 << 10))) return; break;
    case 0x24: mask &= ~0xfffff000u; if (!(data & (1 << 11))) return; break;
    case 0x28: mask &= ~0xfffffc00u; break;
    case 0x2c: mask &= ~0xffff8000u; break;
    case 0x30: mask &= ~0xffff8000u; break;
    default: return;
    }
    crtc[off] = combine(crtc[off], data, mask);
    if (old ^ crtc[off]) crtc_update();
}

void Board::crtc_update()
{
    uint32_t hdisp = crtc[0x0c / 4] + 1;
    uint32_t vdisp = crtc[0x1c / 4];
    if (hdisp == 0 || vdisp == 0) return;
    bool interlace = crt_interlaced();
    if (interlace) vdisp <<= 1;
    uint32_t htot = (crtc[0x20 / 4] & 0x3ff) + 1;
    uint32_t vtot = (crtc[0x24 / 4] & 0x7ff);
    if (htot <= 1 || htot <= hdisp) {
        uint32_t hbp = (crtc[0x08 / 4] & 0xff00) >> 8;
        uint32_t hsw = (crtc[0x08 / 4] & 0xff);
        uint32_t hsfp = crtc[0x10 / 4] & 0xff;
        if (hbp == 0 && hsw == 0 && hsfp == 0) return;
        htot = hdisp + (hbp + 1) + (hsw + 1) + (hsfp + 1);
        crtc[0x20 / 4] = ((htot & 0x3ff) - 1);
    }
    if (vtot == 0) {
        uint32_t vbp = (crtc[0x08 / 4] & 0xff);
        if (vbp == 0) return;
        vtot = vdisp + (vbp + 1);
        crtc[0x24 / 4] = ((vtot & 0x7ff) - 1);
    }
    if (!(crtc[0x04 / 4] & 8)) {
        log.push_back("crtc_update: external VCLK selected (MAME fatalerror)");
        return;
    }
    // pixel clock = 14318180 [*2] / (div+1); ticks per pixel = 85909080 / pixel clock
    uint32_t tpp = 6 * ((crtc[0x04 / 4] & 7) + 1);
    if (crtc[0x04 / 4] & 0x80) tpp /= 2;
    if (!interlace) { vtot >>= 1; vtot += 1; }
    vtot += 9;
    char buf[160];
    snprintf(buf, sizeof buf, "frame %d crtc_update: total %ux%u display %ux%u ticks/pixel %u", frame, htot, vtot,
             hdisp, vdisp, tpp);
    log.push_back(buf);
    // MAME screen_device::configure keeps the current frame running and re-times from the next vblank;
    // we apply the new geometry at the next frame boundary (docs/MAME_REFERENCE.md).
    scr_htot = htot; scr_vtot = vtot; scr_hdisp = hdisp; scr_vdisp = vdisp; scr_tpp = tpp;
}

void Board::screen_vblank()
{
    // vblank rising edge at the first line after the visible area
    bool active = true;
    if (crt_interlaced()) active = ((frame & 1) ^ ((crtc[0] & 8) >> 3)) != 0;
    if (active) {
        int_req(24);
        execute_flipping();
    }
    if (hooks.vblank) hooks.vblank(frame);
    st.max_frame_px = std::max(st.max_frame_px, st.frame_px);
    st.max_frame_considered = std::max(st.max_frame_considered, st.frame_considered);
    st.frame_px = st.frame_considered = 0;
    st.snd_max_chan_seen = std::max<uint32_t>(st.snd_max_chan_seen, snd_max_chan);
    st.snd_ctrl_seen |= snd_ctrl;
    if (snd_chan_clk_num) st.snd_clk_seen = snd_chan_clk_num;
    frame++;
    // next frame
    uint64_t frame_len = uint64_t(scr_htot) * scr_vtot * scr_tpp;
    uint64_t prev_vblank = next_vblank;
    frame_start = prev_vblank + uint64_t(scr_htot) * (scr_vtot - scr_vdisp) * scr_tpp;
    (void)frame_len;
    next_vblank = frame_start + uint64_t(scr_htot) * scr_vdisp * scr_tpp;
}

// ------------------------------------------------------------------------------------------------ video engine

uint16_t Board::vid_r16(uint32_t off)
{
    switch (off) {
    case 0x80: return queue_front & 0x7ff;
    case 0x82: return queue_rear & 0x7ff;
    case 0x8c: return (draw_select ? 0x80 : 0) | (render_reset ? 0x8 : 0) | (render_start ? 0x4 : 0) | dither_mode;
    case 0x8e: return display_bank;
    case 0x90: return bank1_select ? 0x8000 : 0;
    case 0xa6: return flip_count;
    }
    unmapped_reads++;
    return 0;
}

void Board::vid_w16(uint32_t off, uint16_t data, uint16_t mask)
{
    switch (off) {
    case 0x80: queue_front = uint16_t(combine(queue_front, data, mask)); break;
    case 0x8c:
        if (mask & 0x00ff) {
            draw_select = (data >> 7) & 1;
            render_reset = (data >> 3) & 1;
            render_start = (data >> 2) & 1;
            dither_mode = data & 3;
            if (render_reset) queue_front = queue_rear = 0;
        }
        break;
    case 0x90: bank1_select = (data >> 15) & 1; break;
    case 0xa6:
        if (mask & 0x00ff) {
            int fc = data & 0xff;
            if (fc == 1) flip_count++;
            else if (fc == 0) flip_count = 0;
        }
        break;
    default: unmapped_writes++; break;
    }
}

static constexpr uint16_t NOTRANSCOLOR = 0xecda;
static inline uint8_t pal5bit(uint8_t b) { b &= 0x1f; return uint8_t((b << 3) | (b >> 2)); }
static inline uint8_t pal6bit(uint8_t b) { b &= 0x3f; return uint8_t((b << 2) | (b >> 4)); }
static inline uint16_t RGB16(uint32_t r, uint32_t g, uint32_t b) { return uint16_t(((r & 0xf8) << 8) | ((g & 0xfc) << 3) | ((b & 0xf8) >> 3)); }
static inline uint16_t RGB32TO16(uint32_t rgb) { return uint16_t((((rgb >> 19) & 0x1f) << 11) | (((rgb >> 10) & 0x3f) << 5) | ((rgb >> 3) & 0x1f)); }
static inline uint32_t R8(uint16_t s) { return pal5bit(uint8_t(s >> 11)); }
static inline uint32_t G8(uint16_t s) { return pal6bit(uint8_t(s >> 5)); }
static inline uint32_t B8(uint16_t s) { return pal5bit(uint8_t(s)); }
static inline uint32_t fb_addr(uint32_t x, uint32_t y) { return ((x & 0x3ff) | ((y & 0x1ff) << 10)) << 1; }

static uint16_t do_shade(uint16_t src, uint32_t shade)
{
    uint32_t r = (R8(src) * ((shade >> 16) & 0xff)) >> 8;
    uint32_t g = (G8(src) * ((shade >> 8) & 0xff)) >> 8;
    uint32_t b = (B8(src) * ((shade >> 0) & 0xff)) >> 8;
    return RGB16(r, g, b);
}

struct Quad {
    uint32_t dest = 0, dx = 0, dy = 0, endx = 0, endy = 0;
    uint32_t tx = 0, ty = 0, txdx = 0, tydx = 0, txdy = 0, tydy = 0;
    uint16_t twidth = 0, theight = 0;
    uint32_t texaddr = 0, tile = 0;
    const uint16_t *pal = nullptr;
    uint32_t trans_color = 0, shade = 0;
    bool clamp = false, trans = false;
    uint8_t src_alpha = 0, dst_alpha = 0;
    uint32_t src_color = 0, dst_color = 0;
};

static void blend_factor(uint8_t sel, uint32_t color, uint32_t scr, uint32_t scg, uint32_t scb, uint32_t dcr,
                         uint32_t dcg, uint32_t dcb, uint32_t qsrc, uint32_t qdst, uint32_t &mr, uint32_t &mg, uint32_t &mb)
{
    (void)color;
    switch (sel & 0x1f) {
    case 0x02: mr = (qsrc >> 16) & 0xff; mg = (qsrc >> 8) & 0xff; mb = qsrc & 0xff; break;
    case 0x04: mr = scr; mg = scg; mb = scb; break;
    case 0x08: mr = (qdst >> 16) & 0xff; mg = (qdst >> 8) & 0xff; mb = qdst & 0xff; break;
    case 0x10: mr = dcr; mg = dcg; mb = dcb; break;
    default: mr = mg = mb = 0; break;
    }
    if (sel & 0x20) { mr = 0x100 - mr; mg = 0x100 - mg; mb = 0x100 - mb; }
}

static uint16_t do_alpha(const Quad &q, uint16_t src, uint16_t dst)
{
    uint32_t scr = R8(src), scg = G8(src), scb = B8(src);
    uint32_t dcr = R8(dst), dcg = G8(dst), dcb = B8(dst);
    uint32_t smr, smg, smb, dmr, dmg, dmb;
    blend_factor(q.src_alpha, 0, scr, scg, scb, dcr, dcg, dcb, q.src_color, q.dst_color, smr, smg, smb);
    blend_factor(q.dst_alpha, 0, scr, scg, scb, dcr, dcg, dcb, q.src_color, q.dst_color, dmr, dmg, dmb);
    dcr = (scr * smr + dcr * dmr) >> 8; if (dcr > 0xff) dcr = 0xff;
    dcg = (scg * smg + dcg * dmg) >> 8; if (dcg > 0xff) dcg = 0xff;
    dcb = (scb * smb + dcb * dmb) >> 8; if (dcb > 0xff) dcb = 0xff;
    return RGB16(dcr, dcg, dcb);
}

int Board::process_packet(uint32_t ptr)
{
    uint16_t pkt[32];
    for (int i = 0; i < 32; i++) pkt[i] = tex16((ptr + i) << 1);
    if (hooks.packet) hooks.packet(ptr, pkt);
    packets_done++;
    uint32_t dx = pkt[1] & 0x3ff, dy = pkt[2] & 0x1ff, endx = pkt[3] & 0x3ff, endy = pkt[4] & 0x1ff;
    uint8_t blend_mode = 0;
    uint16_t p0 = pkt[0];
    if (p0 & 0x81) {
        st.flips++;
        last_pal_update = 0xffffffff;
        return p0 & 0x81;
    }
    if (p0 & (1 << 9)) {
        rs.tx = pkt[5] | ((pkt[6] & 0x1f) << 16);
        rs.ty = pkt[7] | ((pkt[8] & 0x1f) << 16);
    } else {
        rs.tx = rs.ty = 0;
    }
    if (p0 & (1 << 10)) {
        rs.txdx = pkt[9] | ((pkt[10] & 0x1f) << 16);
        rs.tydx = pkt[11] | ((pkt[12] & 0x1f) << 16);
        rs.txdy = pkt[13] | ((pkt[14] & 0x1f) << 16);
        rs.tydy = pkt[15] | ((pkt[16] & 0x1f) << 16);
    } else {
        rs.txdx = 1 << 9; rs.tydx = 0; rs.txdy = 0; rs.tydy = 1 << 9;
    }
    if (p0 & (1 << 11)) {
        rs.src_alpha_color = pkt[17] | ((pkt[18] & 0xff) << 16);
        rs.src_blend = (pkt[18] >> 8) & 0x3f;
        rs.dst_alpha_color = pkt[19] | ((pkt[20] & 0xff) << 16);
        rs.dst_blend = (pkt[20] >> 8) & 0x3f;
    }
    if (p0 & (1 << 12)) rs.shade_color = pkt[21] | ((pkt[22] & 0xff) << 16);
    if (p0 & (1 << 13)) rs.trans_color = pkt[23] | ((pkt[24] & 0xff) << 16);
    if (p0 & (1 << 14)) {
        rs.tile_offset = pkt[25];
        rs.font_offset = pkt[26];
        rs.pal_offset = pkt[27] >> 3;
        rs.palette_bank = (pkt[28] >> 8) & 0xf;
        rs.texture_mode = (pkt[28] >> 12) & 1;
        rs.pixel_format = (pkt[28] >> 6) & 3;
        rs.width = uint16_t(8 << ((pkt[28] >> 0) & 7));
        rs.height = uint16_t(8 << ((pkt[28] >> 3) & 7));
    }
    if ((p0 & (1 << 6)) && rs.pal_offset != last_pal_update) {
        uint32_t pal = 1024 * rs.pal_offset;
        uint16_t trans = RGB32TO16(rs.trans_color);
        for (int i = 0; i < 256; ++i) {
            uint32_t p = tex32(pal + (i << 2));
            uint16_t v = RGB32TO16(p);
            if ((v == trans && p != rs.trans_color) || v == NOTRANSCOLOR) {
                if ((v & 0x1f) != 0x1f) v++;
                else v--;
            }
            internal_palette[i] = v;
        }
        last_pal_update = rs.pal_offset;
        st.pal_loads++;
    }
    if (p0 & (1 << 8)) {
        Quad q;
        if (p0 & (1 << 1)) {
            q.src_alpha = uint8_t(rs.src_blend);
            q.dst_alpha = uint8_t(rs.dst_blend);
            q.src_color = rs.src_alpha_color;
            q.dst_color = rs.dst_alpha_color;
            blend_mode |= 1;
        } else
            q.src_alpha = 0;
        q.dx = dx; q.dy = dy; q.endx = endx; q.endy = endy;
        q.dest = draw_dest;
        q.tx = rs.tx; q.ty = rs.ty; q.txdx = rs.txdx; q.tydx = rs.tydx; q.txdy = rs.txdy; q.tydy = rs.tydy;
        if (p0 & (1 << 4)) { q.shade = rs.shade_color; blend_mode |= 2; }
        else q.shade = 0xffffff;
        q.trans_color = rs.trans_color;
        q.twidth = rs.width;
        q.theight = rs.height;
        q.trans = (p0 >> 2) & 1;
        q.clamp = (p0 >> 5) & 1;
        st.quads++;
        if (blend_mode & 1) { st.quads_blend++; st.blend_modes[(rs.src_blend << 8) | rs.dst_blend]++; }
        if (blend_mode & 2) st.quads_shade++;
        if (q.clamp) st.quads_clamp++;
        if (q.trans) st.quads_trans++;
        if (p0 & (1 << 3)) {
            st.quads_tex++;
            st.quads_bpp[rs.pixel_format == 0 ? 0 : rs.pixel_format == 1 ? 1 : 2]++;
            if (rs.texture_mode) st.quads_tiled++;
            if (q.tydx || q.txdy) st.quads_rot++;
            else if (q.txdx != (1u << 9) || q.tydy != (1u << 9)) st.quads_scaled++;
        } else
            st.quads_fill++;
        if (p0 & (1 << 3)) {
            q.texaddr = 128 * rs.font_offset;
            q.tile = 128 * rs.tile_offset;
            q.pal = rs.pixel_format ? internal_palette : internal_palette + (rs.palette_bank * 16);
            int bpp = rs.pixel_format == 0 ? 4 : rs.pixel_format == 1 ? 8 : 16;
            bool tiled = rs.texture_mode;
            uint32_t trans_color = q.trans ? RGB32TO16(q.trans_color) : NOTRANSCOLOR;
            uint32_t maskw = q.twidth - 1, maskh = q.theight - 1, w = q.twidth >> 3;
            int32_t y_tx = int32_t(q.tx), y_ty = int32_t(q.ty);
            for (uint32_t y = q.dy; int32_t(y) <= int32_t(q.endy); y++, y_tx += q.txdy, y_ty += q.tydy) {
                int32_t x_tx = y_tx, x_ty = y_ty;
                for (uint32_t x = q.dx; int32_t(x) <= int32_t(q.endx); x++, x_tx += q.txdx, x_ty += q.tydx) {
                    uint32_t fba = q.dest + fb_addr(x, y);
                    uint32_t tx = uint32_t(x_tx) >> 9, ty = uint32_t(x_ty) >> 9;
                    st.px_considered++;
                    st.frame_considered++;
                    if (q.clamp) {
                        if (tx > maskw || ty > maskh) continue;
                    } else {
                        tx &= maskw;
                        ty &= maskh;
                    }
                    uint32_t offset;
                    if (tiled) {
                        uint32_t index = tex16(q.tile + (((ty >> 3) * w + (tx >> 3)) << 1));
                        if (hooks.tex_read) hooks.tex_read(q.tile + (((ty >> 3) * w + (tx >> 3)) << 1));
                        st.tile_reads++;
                        if (index == 0) continue;
                        offset = (index << 6) + ((ty & 7) << 3) + (tx & 7);
                    } else
                        offset = ty * q.twidth + tx;
                    uint16_t color;
                    st.texel_reads++;
                    if (hooks.tex_read)
                        hooks.tex_read(bpp == 4 ? q.texaddr + (offset >> 1) : bpp == 8 ? q.texaddr + offset : q.texaddr + (offset << 1));
                    if (bpp == 4) {
                        uint8_t texel = tex8(q.texaddr + (offset >> 1));
                        color = q.pal[(texel >> ((~offset & 1) << 2)) & 0xf];
                    } else if (bpp == 8) {
                        color = q.pal[tex8(q.texaddr + offset)];
                    } else {
                        color = tex16(q.texaddr + (offset << 1));
                    }
                    if (color != trans_color) {
                        uint16_t pixel = fb16(fba), prev = pixel;
                        if (blend_mode & 2) color = do_shade(color, q.shade);
                        if (blend_mode & 1) pixel = do_alpha(q, color, pixel);
                        else pixel = color;
                        if (prev != pixel) fbw16(fba, pixel);
                        pixels_drawn++;
                        st.px_written_tex++;
                        st.frame_px++;
                        if (blend_mode & 1) st.fb_reads_blend++;
                    } else
                        st.px_skipped++;
                }
            }
        } else {
            uint16_t shade_color = RGB32TO16(q.shade);
            for (uint32_t y = q.dy; y <= q.endy; y++)
                for (uint32_t x = q.dx; x <= q.endx; x++) {
                    uint32_t fba = q.dest + fb_addr(x, y);
                    uint16_t pixel = fb16(fba), prev = pixel;
                    pixel = q.src_alpha ? do_alpha(q, shade_color, pixel) : shade_color;
                    if (prev != pixel) fbw16(fba, pixel);
                    pixels_drawn++;
                    st.px_fill++;
                    st.frame_px++;
                    st.frame_considered++;
                    if (q.src_alpha) st.fb_reads_blend++;
                }
        }
    }
    return 0;
}

void Board::pipeline_tick()
{
    if (!render_start) return;
    if (flip_sync) return;
    if ((queue_rear & 0x7ff) == (queue_front & 0x7ff)) return;
    if (hooks.before_packet) hooks.before_packet(uint32_t(queue_rear) * 32);
    int do_flip = process_packet(uint32_t(queue_rear) * 32);
    queue_rear = (queue_rear + 1) & 0x7ff;
    if (do_flip & 1) flip_sync = true;
    if (do_flip & 0x80) {
        uint32_t B0 = 0, B1 = bank1_select ? 0x400000 : 0x100000;
        uint32_t front = (display_bank & 1) ? B1 : B0, back = (display_bank & 1) ? B0 : B1;
        draw_dest = draw_select ? back : front;
    }
}

void Board::execute_flipping()
{
    if (!render_start) return;
    if (!flip_count) return;
    uint32_t B0 = 0, B1 = bank1_select ? 0x400000 : 0x100000;
    uint32_t front = (display_bank & 1) ? B1 : B0, back = (display_bank & 1) ? B0 : B1;
    draw_dest = draw_select ? front : back;
    display_dest = front;
    flip_sync = false;
    if (flip_count) {
        flip_count--;
        display_bank ^= 1;
    }
}

// ------------------------------------------------------------------------------------------------ sound engine

static const uint16_t ulaw_to_16[] = {
    0x8000,0x8400,0x8800,0x8c00,0x9000,0x9400,0x9800,0x9c00,0xa000,0xa400,0xa800,0xac00,0xb000,0xb400,0xb800,0xbc00,
    0x4000,0x4400,0x4800,0x4c00,0x5000,0x5400,0x5800,0x5c00,0x6000,0x6400,0x6800,0x6c00,0x7000,0x7400,0x7800,0x7c00,
    0xc000,0xc200,0xc400,0xc600,0xc800,0xca00,0xcc00,0xce00,0xd000,0xd200,0xd400,0xd600,0xd800,0xda00,0xdc00,0xde00,
    0x2000,0x2200,0x2400,0x2600,0x2800,0x2a00,0x2c00,0x2e00,0x3000,0x3200,0x3400,0x3600,0x3800,0x3a00,0x3c00,0x3e00,
    0xe000,0xe100,0xe200,0xe300,0xe400,0xe500,0xe600,0xe700,0xe800,0xe900,0xea00,0xeb00,0xec00,0xed00,0xee00,0xef00,
    0x1000,0x1100,0x1200,0x1300,0x1400,0x1500,0x1600,0x1700,0x1800,0x1900,0x1a00,0x1b00,0x1c00,0x1d00,0x1e00,0x1f00,
    0xf000,0xf080,0xf100,0xf180,0xf200,0xf280,0xf300,0xf380,0xf400,0xf480,0xf500,0xf580,0xf600,0xf680,0xf700,0xf780,
    0x0800,0x0880,0x0900,0x0980,0x0a00,0x0a80,0x0b00,0x0b80,0x0c00,0x0c80,0x0d00,0x0d80,0x0e00,0x0e80,0x0f00,0x0f80,
    0xf800,0xf840,0xf880,0xf8c0,0xf900,0xf940,0xf980,0xf9c0,0xfa00,0xfa40,0xfa80,0xfac0,0xfb00,0xfb40,0xfb80,0xfbc0,
    0x0400,0x0440,0x0480,0x04c0,0x0500,0x0540,0x0580,0x05c0,0x0600,0x0640,0x0680,0x06c0,0x0700,0x0740,0x0780,0x07c0,
    0xfc00,0xfc20,0xfc40,0xfc60,0xfc80,0xfca0,0xfcc0,0xfce0,0xfd00,0xfd20,0xfd40,0xfd60,0xfd80,0xfda0,0xfdc0,0xfde0,
    0x0200,0x0220,0x0240,0x0260,0x0280,0x02a0,0x02c0,0x02e0,0x0300,0x0320,0x0340,0x0360,0x0380,0x03a0,0x03c0,0x03e0,
    0xfe00,0xfe10,0xfe20,0xfe30,0xfe40,0xfe50,0xfe60,0xfe70,0xfe80,0xfe90,0xfea0,0xfeb0,0xfec0,0xfed0,0xfee0,0xfef0,
    0x0100,0x0110,0x0120,0x0130,0x0140,0x0150,0x0160,0x0170,0x0180,0x0190,0x01a0,0x01b0,0x01c0,0x01d0,0x01e0,0x01f0,
    0x0000,0x0008,0x0010,0x0018,0x0020,0x0028,0x0030,0x0038,0x0040,0x0048,0x0050,0x0058,0x0060,0x0068,0x0070,0x0078,
    0xff80,0xff88,0xff90,0xff98,0xffa0,0xffa8,0xffb0,0xffb8,0xffc0,0xffc8,0xffd0,0xffd8,0xffe0,0xffe8,0xfff0,0xfff8,
};

enum { MODE_LOOP = 1, MODE_SUSTAIN = 2, MODE_ENVELOPE = 4, MODE_PINGPONG = 8, MODE_ULAW = 16, MODE_8BIT = 32, MODE_TEXTURE = 64 };
enum { CTRL_RS = 1 << 15, CTRL_TM = 1 << 5 };

static int32_t sext32(uint32_t v, int bits) { uint32_t m = 1u << (bits - 1); v &= (1u << bits) - 1; return int32_t((v ^ m) - m); }

uint16_t Board::Channel::read(int off) const
{
    switch (off) {
    case 0: return cur_saddr & 0xffff;
    case 1: return (cur_saddr >> 16) & 0xffff;
    case 2: return uint16_t(env_vol & 0xffff);
    case 3: return uint16_t(0x6000 | (ld ? 0x1000 : 0) | ((env_stage << 8) & 0x0f00) | ((uint32_t(env_vol) & 0xff0000) >> 16));
    case 4: return ds_addr;
    case 5: return (modes << 8) & 0x7f00;
    case 6: return loop_begin & 0xffff;
    case 7: return uint16_t(((l_chn_vol << 8) & 0x7f00) | ((loop_begin & 0x3f0000) >> 16));
    case 8: return loop_end & 0xffff;
    case 9: return uint16_t(((r_chn_vol << 8) & 0x7f00) | ((loop_end & 0x3f0000) >> 16));
    case 10: case 11: case 12: case 13: return uint16_t(env_rate[off - 10] & 0xffff);
    case 14: case 15: {
        int b = (off - 14) * 2;
        uint16_t ret = uint16_t((env_target[b] & 0x7f) | ((env_target[b + 1] << 8) & 0x7f00));
        ret |= uint16_t(((uint32_t(env_rate[b]) & 0x10000) >> 9) | ((uint32_t(env_rate[b + 1]) & 0x10000) >> 1));
        return ret;
    }
    }
    return 0;
}

void Board::Channel::write(int off, uint16_t data, uint16_t mask)
{
    uint16_t d = uint16_t(combine(read(off), data, mask));
    switch (off) {
    case 0: cur_saddr = (cur_saddr & 0xffff0000) | d; break;
    case 1: cur_saddr = (cur_saddr & 0x0000ffff) | (uint32_t(d) << 16); break;
    case 2: env_vol = int32_t((uint32_t(env_vol) & ~0xffffu) | d); break;
    case 3:
        ld = (d >> 12) & 1;
        env_stage = (d & 0x0f00) >> 8;
        env_vol = sext32((uint32_t(env_vol) & 0x00ffff) | ((uint32_t(d) << 16) & 0xff0000), 24);
        break;
    case 4: ds_addr = d; break;
    case 5: modes = (d & 0x7f00) >> 8; break;
    case 6: loop_begin = (loop_begin & 0x3f0000) | d; break;
    case 7: l_chn_vol = (d & 0x7f00) >> 8; loop_begin = (loop_begin & 0xffff) | ((uint32_t(d) << 16) & 0x3f0000); break;
    case 8: loop_end = (loop_end & 0x3f0000) | d; break;
    case 9: r_chn_vol = (d & 0x7f00) >> 8; loop_end = (loop_end & 0xffff) | ((uint32_t(d) << 16) & 0x3f0000); break;
    case 10: case 11: case 12: case 13:
        env_rate[off - 10] = int32_t((uint32_t(env_rate[off - 10]) & ~0xffffu) | d);
        break;
    case 14: case 15: {
        int b = (off - 14) * 2;
        env_target[b] = d & 0x7f;
        env_target[b + 1] = (d & 0x7f00) >> 8;
        env_rate[b] = sext32((uint32_t(env_rate[b]) & 0xffff) | ((d & 0x0080) << 9), 17);
        env_rate[b + 1] = sext32((uint32_t(env_rate[b + 1]) & 0xffff) | ((d & 0x8000u) << 1), 17);
        break;
    }
    }
}

uint16_t Board::snd_r16(uint32_t off)
{
    if (off < 0x400) return ch[(off >> 5) & 0x1f].read((off >> 1) & 0xf);
    switch (off) {
    case 0x404: case 0x406: return uint16_t(snd_status >> (((off >> 1) & 1) << 2));     // MAME shift (sic)
    case 0x408: case 0x40a: return uint16_t(snd_note_on >> (((off >> 1) & 1) << 2));   // MAME shift (sic)
    case 0x410: return snd_rev_factor & 0xff;
    case 0x412: return (snd_buffer_addr >> 14) & 0x7f;
    case 0x420: return snd_buffer_size[0] & 0xfff;
    case 0x422: return snd_buffer_size[1] & 0xfff;
    case 0x440: return snd_buffer_size[2] & 0xfff;
    case 0x442: return snd_buffer_size[3] & 0xfff;
    case 0x480: case 0x482: return uint16_t(snd_int_mask >> (((off >> 1) & 1) << 2));
    case 0x500: case 0x502: return uint16_t(snd_int_pend >> (((off >> 1) & 1) << 2));
    case 0x600: return uint16_t(((snd_max_chan & 0x1f) << 8) | snd_chan_clk_num);
    case 0x602: return snd_ctrl;
    }
    unmapped_reads++;
    return 0;
}

void Board::snd_w16(uint32_t off, uint16_t data, uint16_t mask)
{
    if (off < 0x400) {
        ch[(off >> 5) & 0x1f].write((off >> 1) & 0xf, data, mask);
        return;
    }
    switch (off) {
    case 0x404: case 0x406: {
        uint32_t c = data & 0x1f;
        if (data & 0x8000) snd_status |= 1u << c;
        else snd_status &= ~(1u << c);
        break;
    }
    case 0x408: case 0x40a: {
        uint32_t c = data & 0x1f;
        if (data & 0x8000) snd_note_on |= 1u << c;
        else snd_note_on &= ~(1u << c);
        break;
    }
    case 0x410: if (mask & 0xff) snd_rev_factor = data & 0xff; break;
    case 0x412: if (mask & 0xff) snd_buffer_addr = (snd_buffer_addr & ~(0x7fu << 14)) | ((data & 0x7fu) << 14); break;
    case 0x420: snd_buffer_size[0] = uint16_t(combine(snd_buffer_size[0], data & 0xfff, mask)); break;
    case 0x422: snd_buffer_size[1] = uint16_t(combine(snd_buffer_size[1], data & 0xfff, mask)); break;
    case 0x440: snd_buffer_size[2] = uint16_t(combine(snd_buffer_size[2], data & 0xfff, mask)); break;
    case 0x442: snd_buffer_size[3] = uint16_t(combine(snd_buffer_size[3], data & 0xfff, mask)); break;
    case 0x480: case 0x482: {
        int sh = ((off >> 1) & 1) << 2;
        snd_int_mask = (snd_int_mask & ~(uint32_t(mask) << sh)) | (uint32_t(data & mask) << sh);
        break;
    }
    case 0x500: case 0x502: {
        int sh = ((off >> 1) & 1) << 2;
        snd_int_pend &= ~(uint32_t(data & mask) << sh);
        break;
    }
    case 0x600:
        if (mask & 0x00ff) snd_chan_clk_num = data & 0xff;
        if (mask & 0xff00) snd_max_chan = (data >> 8) & 0x1f;
        break;
    case 0x602: snd_ctrl = uint16_t(combine(snd_ctrl, data, mask)); break;
    default: unmapped_writes++; break;
    }
}

void Board::sound_sample(int16_t &lo, int16_t &ro)
{
    int div = snd_chan_clk_num ? ((30 << 16) | 0x8000) / (snd_chan_clk_num + 1) : (1 << 16);
    int32_t ls = 0, rsum = 0;
    for (int i = 0; i <= snd_max_chan; i++) {
        Channel &c = ch[i];
        int32_t sample;
        uint32_t lb = c.loop_begin << 10, le = c.loop_end << 10;
        if (!(snd_status & (1u << i)) || !(snd_ctrl & CTRL_RS)) continue;
        st.snd_voice_samples++;
        bool tex = (c.modes & MODE_TEXTURE) && (snd_ctrl & CTRL_TM);
        auto rd8 = [&](uint32_t a) -> uint8_t { return tex ? texram[a & 0x7fffff] : frameram[a & 0x7fffff]; };
        auto rd16 = [&](uint32_t a) -> uint16_t { return tex ? tex16(a) : fb16(a); };
        if (c.modes & MODE_ULAW) {
            sample = int16_t(ulaw_to_16[rd8(c.cur_saddr >> 9)]);
        } else if (c.modes & MODE_8BIT) {
            sample = int16_t(uint16_t(rd8(c.cur_saddr >> 9) << 8));
        } else {
            sample = int16_t(rd16((c.cur_saddr >> 9) & ~1u));
        }
        c.cur_saddr += uint32_t(int32_t(uint32_t(c.ds_addr) * uint32_t(div)) >> 16);   // C int arithmetic as MAME
        if (c.cur_saddr >= le) {
            if (c.modes & MODE_LOOP)
                c.cur_saddr = (c.cur_saddr - le) + lb;
            else {
                snd_status &= ~(1u << (i & 0x1f));
                if (snd_int_mask != 0xffffffff) {
                    uint32_t old = snd_int_pend;
                    snd_int_pend |= (~snd_int_mask & (1u << (i & 0x1f)));
                    if (snd_int_pend != 0 && old != snd_int_pend) int_req(2);
                }
                break;   // MAME quirk: abandons the remaining channels for this sample
            }
        }
        int32_t v = c.env_vol >> 16;
        sample = (sample * v) >> 8;
        if (c.modes & MODE_ENVELOPE) {
            for (int level = 0; level < 4; level++) {
                if (c.env_stage & (1 << level)) {
                    int32_t rate = int32_t((int64_t(c.env_rate[level]) * div) >> 16);
                    c.env_vol += rate;
                    if (rate > 0) {
                        if (((c.env_vol >> 16) & 0x7f) >= c.env_target[level]) c.env_stage <<= 1;
                    } else if (rate < 0) {
                        if (((c.env_vol >> 16) & 0x7f) <= c.env_target[level]) c.env_stage <<= 1;
                    }
                }
            }
        }
        ls += (sample * c.l_chn_vol) >> 8;
        rsum += (sample * c.r_chn_vol) >> 8;
    }
    lo = int16_t(std::clamp(ls, -32768, 32767));
    ro = int16_t(std::clamp(rsum, -32768, 32767));
}

// ------------------------------------------------------------------------------------------------ DS1302

enum { RTC_COMMAND, RTC_INPUT, RTC_OUTPUT };

void Board::Rtc::ce_w(bool st)
{
    if (st && !ce) {
        for (int i = 0; i < 9; i++) user[i] = reg[i];
    } else if (!st && ce) {
        state = RTC_COMMAND;
        bits = 0;
    }
    ce = st;
}

void Board::Rtc::load_shift_register()
{
    bool rd = cmd & 1, ramsel = cmd & 0x40;
    if (rd) {
        if (ramsel) data = addr < 0x1f ? ram[addr] : 0;
        else data = addr < 9 ? user[addr] : 0;
    } else {
        if (ramsel) { if (addr < 0x1f) ram[addr] = data; }
        else if (addr < 9) reg[addr] = data;
    }
}

void Board::Rtc::input_bit()
{
    bool burst = ((cmd >> 1) & 0x1f) == 0x1f;
    switch (state) {
    case RTC_COMMAND:
        cmd >>= 1;
        cmd |= uint8_t(io << 7);
        bits++;
        if (bits == 8) {
            bits = 0;
            addr = (cmd >> 1) & 0x1f;
            if (cmd & 0x80) {
                if (((cmd >> 1) & 0x1f) == 0x1f) addr = 0;
                if (cmd & 1) { load_shift_register(); state = RTC_OUTPUT; }
                else state = RTC_INPUT;
            } else
                state = RTC_COMMAND;
        }
        break;
    case RTC_INPUT:
        data >>= 1;
        data |= uint8_t(io << 7);
        bits++;
        if (bits == 8) {
            bits = 0;
            if (!(reg[7] & 0x80)) load_shift_register();
            if (burst) {
                addr++;
                if (addr == ((cmd & 0x40) ? 0x1f : 9)) state = RTC_COMMAND;
            } else
                state = RTC_COMMAND;
        }
        break;
    }
}

void Board::Rtc::output_bit()
{
    if (state != RTC_OUTPUT) return;
    bool burst = ((cmd >> 1) & 0x1f) == 0x1f;
    io = data & 1;
    data >>= 1;
    bits++;
    if (bits == 8) {
        bits = 0;
        if (burst) {
            addr++;
            if (addr == ((cmd & 0x40) ? 0x1f : 9)) state = RTC_COMMAND;
            else load_shift_register();
        } else
            state = RTC_COMMAND;
    }
}

void Board::Rtc::sclk_w(bool st)
{
    if (ce) {
        if (!clk && st) input_bit();
        else if (clk && !st) output_bit();
    }
    clk = st;
}

void Board::Rtc::tick_second()
{
    // minimal BCD seconds/minutes/hours advance (halt bit honoured); date rollover is not needed for the model
    if (reg[0] & 0x80) return;
    auto inc = [](uint8_t &v, uint8_t mod) {
        int x = (v >> 4) * 10 + (v & 0xf) + 1;
        bool c = x >= mod;
        if (c) x = 0;
        v = uint8_t(((x / 10) << 4) | (x % 10));
        return c;
    };
    uint8_t sec = reg[0] & 0x7f;
    if (inc(sec, 60)) {
        if (inc(reg[1], 60)) inc(reg[2], 24);
    }
    reg[0] = (reg[0] & 0x80) | sec;
}

// ------------------------------------------------------------------------------------------------ bus

uint16_t Board::fetch(uint32_t a)
{
    in_fetch = true;
    uint16_t v = uint16_t(read(a & ~1u, 2));
    in_fetch = false;
    return v;
}

int Board::region(uint32_t a)
{
    if (a < 0x00020000) return Stats::R_BIOS;
    if (a >= 0x01400000 && a < 0x01410000) return Stats::R_NVRAM;
    if (a >= 0x02000000 && a < 0x03000000) return Stats::R_WRAM;
    if (a >= 0x03800000 && a < 0x04000000) return Stats::R_TEX;
    if (a >= 0x04000000 && a < 0x04800000) return Stats::R_FRAME;
    if (a >= 0x05000000 && a < 0x06000000) return Stats::R_FLASH;
    if (a >= 0x01800000 && a < 0x02000000) return Stats::R_SYS;
    if (a >= 0x03000000 && a < 0x03010000) return Stats::R_VID;
    if (a >= 0x04800000 && a < 0x04801000) return Stats::R_SND;
    if (a >= 0x01200000 && a < 0x01400000) return Stats::R_BOARD;
    return Stats::R_OTHER;
}

// VR0 system registers (base 0x01800000): 32-bit handlers; `off` is the dword-aligned offset.
uint32_t Board::sys_r32(uint32_t off, uint32_t mask)
{
    (void)mask;
    switch (off) {
    case 0x0000: return 0x00000a00;            // SYSID
    case 0x0004: return 0x00000041;            // CFGR
    case 0x0010: case 0x0014: return 0;        // watchdog (noprw)
    case 0x0800: return dma[0].ctrl;
    case 0x0804: return dma[0].src;
    case 0x0808: return dma[0].dst;
    case 0x080c: return dma[0].size & 0xffffff;
    case 0x0810: return dma[1].ctrl;
    case 0x0814: return dma[1].src;
    case 0x0818: return dma[1].dst;
    case 0x081c: return dma[1].size & 0xffffff;
    case 0x0c04: return uint32_t(int_high & 7) << 8;
    case 0x0c08: return inten;
    case 0x0c0c: return intst;
    case 0x1000: return uart_ucon[0];          // UART stub: idle, nothing transmitted (docs/VRENDER0_SYSTEM.md)
    case 0x1020: return uart_ucon[1];
    case 0x1010: return uart_ubdr[0];
    case 0x1030: return uart_ubdr[1];
    case 0x1400: return tmr[0].control;
    case 0x1404: return tmr[0].count;
    case 0x1408: return tmr[1].control;
    case 0x140c: return tmr[1].count;
    case 0x1410: return tmr[2].control;
    case 0x1414: return tmr[2].count;
    case 0x1418: return tmr[3].control;
    case 0x141c: return tmr[3].count;
    case 0x2004: return pio;                    // crystal_state::pioldat_r
    case 0x2008: {                              // crystal_state::pioedat_r
        uint32_t d = uint32_t(rtc.io_r()) << 28;
        if (cfg.pic_master) d |= uint32_t(pic_data) << 29;
        return d;
    }
    case 0x3448: return lightc;
    }
    if (off >= 0x3400 && off < 0x3438) return crtc_r((off - 0x3400) / 4);
    if (off >= 0x3438 && off < 0x3448) return 0;
    if ((off >= 0x1000 && off < 0x1040)) return 0;
    unmapped_reads++;
    return 0;
}

void Board::sys_w32(uint32_t off, uint32_t data, uint32_t mask)
{
    switch (off) {
    case 0x0010: case 0x0014: return;
    case 0x0800: case 0x0810: {
        int w = (off >> 4) & 1;
        Dma &d = dma[w];
        if (mask & 0xffff) {
            if (((data ^ d.ctrl) & (1 << 10)) && (data & (1 << 10))) {
                if (hooks.dma_start) hooks.dma_start(w, d.src, d.dst, d.size, data);
                d.next = now + 2;
            }
            d.ctrl = uint16_t(combine(d.ctrl, data, mask));
        }
        return;
    }
    case 0x0804: dma[0].src = combine(dma[0].src, data, mask); return;
    case 0x0808: dma[0].dst = combine(dma[0].dst, data, mask); return;
    case 0x080c: dma[0].size = combine(dma[0].size, data, mask) & 0xffffff; return;
    case 0x0814: dma[1].src = combine(dma[1].src, data, mask); return;
    case 0x0818: dma[1].dst = combine(dma[1].dst, data, mask); return;
    case 0x081c: dma[1].size = combine(dma[1].size, data, mask) & 0xffffff; return;
    case 0x0c04:
        if (mask & 0x000000ff) {
            intst &= ~(1u << (data & 0x1f));
            update_int_line();
        }
        if (mask & 0x0000ff00) int_high = (data >> 8) & 7;
        return;
    case 0x0c08:
        inten = combine(inten, data, mask);
        intst &= inten;
        update_int_line();
        return;
    case 0x0c0c: return;   // intst_w: no effect in MAME
    case 0x1400: case 0x1408: case 0x1410: case 0x1418: {
        int w = (off - 0x1400) >> 3;
        Timer &t = tmr[w];
        uint32_t old = t.control;
        t.control = combine(t.control, data, mask);
        if ((t.control ^ old) & 1) {
            if (t.control & 1) timer_start(w);
            else t.fire = UINT64_MAX;
        }
        return;
    }
    case 0x1404: case 0x140c: case 0x1414: case 0x141c: {
        int w = (off - 0x1404) >> 3;
        if (mask & 0xffff) tmr[w].count = uint16_t(combine(tmr[w].count, data, mask & 0xffff));
        return;
    }
    case 0x2004: {  // crystal_state::pioldat_w
        bool rst = (data >> 24) & 1, clk = (data >> 25) & 1, dat = (data >> 28) & 1;
        rtc.ce_w(rst);
        rtc.io_w(dat);
        rtc.sclk_w(clk);
        if (cfg.pic_master) pic_data = !((data >> 29) & 1);
        if (pic) {
            // MAME: set_input_line(INPUT_LINE_RESET, bit 30): held in reset while set
            bool r = (data >> 30) & 1;
            if (r && !pic_reset) pic->reset();
            pic_reset = r;
        }
        pio = combine(pio, data, mask);
        return;
    }
    case 0x3448:
        if (mask & 0xff) lightc = data & 3;
        return;
    }
    if (off >= 0x3400 && off < 0x3438) { crtc_w((off - 0x3400) / 4, data, mask); return; }
    if (off == 0x1000 || off == 0x1020) { uart_ucon[(off >> 5) & 1] = combine(uart_ucon[(off >> 5) & 1], data, mask); return; }
    if (off == 0x1010 || off == 0x1030) { uart_ubdr[(off >> 5) & 1] = combine(uart_ubdr[(off >> 5) & 1], data, mask); return; }
    if (off == 0x1008 || off == 0x1028) { uart_tx_count++; return; }
    if (off >= 0x1000 && off < 0x1040) return;  // UART stub
    unmapped_writes++;
}

uint32_t Board::read(uint32_t addr, int size)
{
    uint32_t sh = (addr & 3) * 8;
    uint32_t smask = size == 4 ? 0xffffffffu : ((1u << (size * 8)) - 1);
    uint32_t mask = smask << sh;
    uint32_t da = addr & ~3u;
    auto ram_rd = [&](const std::vector<uint8_t> &m, uint32_t off) {
        uint32_t v = 0;
        for (int i = 0; i < size; i++) v |= uint32_t(m[off + i]) << (8 * i);
        return v;
    };
    uint32_t r;
    {
        int rg = region(addr);
        if (in_fetch) st.fetch[rg]++;
        else {
            st.rd[rg]++;
            st.rd_size[size]++;
            if (rg >= Stats::R_SYS || (rg == Stats::R_FLASH && (addr & ~3u) == 0x05000000)) st.io_rd[addr & ~3u]++;
        }
    }
    if (addr < 0x00020000) return ram_rd(bios, addr);
    if (addr >= 0x02000000 && addr < 0x03000000) return ram_rd(workram, addr & 0x7fffff);
    if (addr >= 0x01400000 && addr < 0x01410000) return ram_rd(nvram, addr & 0xffff);
    if (addr >= 0x03800000 && addr < 0x04000000) return ram_rd(texram, addr & 0x7fffff);
    if (addr >= 0x04000000 && addr < 0x04800000) return ram_rd(frameram, addr & 0x7fffff);
    if (addr >= 0x05000000 && addr < 0x06000000) {
        if (da == 0x05000000) {
            uint32_t v;
            if ((flashcmd & 0xff) == 0xff) {
                if (bank < maxbank) { uint32_t o = bank * 0x1000000; v = flash[o] | flash[o + 1] << 8 | flash[o + 2] << 16 | uint32_t(flash[o + 3]) << 24; }
                else v = 0xffffffff;
            } else if ((flashcmd & 0xff) == 0x90) {
                v = bank < maxbank ? 0x00180089 : 0xffffffff;
            } else
                v = 0;
            r = (v >> sh) & smask;
        } else if (bank < maxbank) {
            r = ram_rd(flash, bank * 0x1000000 + (addr & 0xffffff));
        } else
            r = smask;   // erased
        if (hooks.io_access && da == 0x05000000) hooks.io_access(addr, size, r, false);
        return r;
    }
    // everything below is I/O: dword handler with lane extraction
    uint32_t v = 0;
    if (da == 0x01200000) v = in.p1p2;
    else if (da == 0x01200004) v = in.p3p4;
    else if (da == 0x01200008) v = (uint32_t(in.system) << 16) | in.dsw | 0xff00ff00u;
    else if (addr >= 0x01800000 && addr < 0x02000000) v = sys_r32(da - 0x01800000, mask);
    else if (addr >= 0x03000000 && addr < 0x03010000) {
        uint32_t o = da - 0x03000000;
        if (mask & 0x0000ffff) v |= vid_r16(o);
        if (mask & 0xffff0000) v |= uint32_t(vid_r16(o + 2)) << 16;
    } else if (addr >= 0x04800000 && addr < 0x04801000) {
        uint32_t o = da - 0x04800000;
        if (mask & 0x0000ffff) v |= snd_r16(o);
        if (mask & 0xffff0000) v |= uint32_t(snd_r16(o + 2)) << 16;
    } else if (cfg.reset_patch && addr >= 0x44414f4c && addr < 0x44414f80) {
        static const uint32_t patch[] = {0x40c0ea01, 0xe906400a, 0x40c02a20, 0xe906400a, 0xa1d03a20, 0xdef4d4fa};
        uint32_t i = (da - 0x44414f4c) / 4;
        v = i < 6 ? patch[i] : 0;
    } else {
        unmapped_reads++;
        v = 0;
    }
    r = (v >> sh) & smask;
    if (hooks.io_access) hooks.io_access(addr, size, r, false);
    return r;
}

void Board::write(uint32_t addr, int size, uint32_t data)
{
    uint32_t sh = (addr & 3) * 8;
    uint32_t smask = size == 4 ? 0xffffffffu : ((1u << (size * 8)) - 1);
    uint32_t mask = smask << sh;
    uint32_t da = addr & ~3u;
    uint32_t d32 = (data & smask) << sh;
    auto ram_wr = [&](std::vector<uint8_t> &m, uint32_t off) {
        for (int i = 0; i < size; i++) m[off + i] = uint8_t(data >> (8 * i));
    };
    {
        int rg = region(addr);
        st.wr[rg]++;
        st.wr_size[size]++;
        if (rg >= Stats::R_SYS || rg == Stats::R_FLASH) st.io_wr[addr & ~3u]++;
        if (rg == Stats::R_SND) {
            if ((addr & 0xfff) < 0x400 && ((addr >> 1) & 0xf) == 5) st.snd_modes_seen |= 1u << ((data >> 8) & 0x7f) % 32;
        }
    }
    if (addr < 0x00020000) return;  // ROM, nopw
    if (hooks.ram_write && ((addr >= 0x03800000 && addr < 0x04800000) || (addr >= 0x02000000 && addr < 0x03000000)))
        hooks.ram_write(addr, size, data);
    if (addr >= 0x02000000 && addr < 0x03000000) { ram_wr(workram, addr & 0x7fffff); return; }
    if (addr >= 0x01400000 && addr < 0x01410000) { ram_wr(nvram, addr & 0xffff); return; }
    if (addr >= 0x03800000 && addr < 0x04000000) { ram_wr(texram, addr & 0x7fffff); return; }
    if (addr >= 0x04000000 && addr < 0x04800000) { ram_wr(frameram, addr & 0x7fffff); return; }
    if (hooks.io_access) hooks.io_access(addr, size, data & smask, true);
    if (addr >= 0x05000000 && addr < 0x06000000) {
        if (da == 0x05000000) flashcmd = d32;
        else unmapped_writes++;
        return;
    }
    if (da == 0x01200000) {
        if (mask & 0xff) coin_counter = d32 & 3;
        return;
    }
    if (da == 0x01280000) { bank = (d32 >> 1) & 7; return; }
    if (da == 0x01320000) {
        if (mask & 0x000000ff) lamps[0] = d32 & 0xff;
        if (mask & 0x00ff0000) lamps[1] = (d32 >> 16) & 0xff;
        return;
    }
    if (addr >= 0x01800000 && addr < 0x02000000) { sys_w32(da - 0x01800000, d32, mask); return; }
    if (addr >= 0x03000000 && addr < 0x03010000) {
        uint32_t o = da - 0x03000000;
        if (mask & 0x0000ffff) vid_w16(o, uint16_t(d32), uint16_t(mask));
        if (mask & 0xffff0000) vid_w16(o + 2, uint16_t(d32 >> 16), uint16_t(mask >> 16));
        return;
    }
    if (addr >= 0x04800000 && addr < 0x04801000) {
        uint32_t o = da - 0x04800000;
        if (mask & 0x0000ffff) snd_w16(o, uint16_t(d32), uint16_t(mask));
        if (mask & 0xffff0000) snd_w16(o + 2, uint16_t(d32 >> 16), uint16_t(mask >> 16));
        return;
    }
    unmapped_writes++;
}

} // namespace crystal
