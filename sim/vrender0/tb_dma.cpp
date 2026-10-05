// vr0_sys DMA test: random transfers (width 8/16/32, source/destination increment/decrement/hold, counts 0-40,
// both channels) through the register interface, served by a byte memory model; the expected memory image is
// computed with the reference model's MAME-master DMA algorithm (crystal::Board::dma_step semantics: one unit
// per step, src/dst += +-w or hold, count--, IRQ 7+n when the count reaches 0, aligned accesses).
#include "Vvr0_sys.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

double sc_time_stamp() { return 0; }
static uint64_t rng = 0xC0FFEE1234567ull;
static uint32_t rnd() { rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17; return uint32_t(rng); }

int main()
{
    Vvr0_sys *t = new Vvr0_sys;
    std::vector<uint8_t> mem(1 << 16), ref;
    auto tick = [&]() { t->clk = 1; t->eval(); t->clk = 0; t->eval(); };
    t->rst_n = 0; t->io_sel = 0; t->irq_req = 0; t->dma_ack = 0; t->hpos = 0; t->vpos = 0; t->frame_odd = 0; t->pio_edat = 0;
    for (int i = 0; i < 4; i++) tick();
    t->rst_n = 1;
    auto wreg = [&](uint32_t off, uint32_t v) {
        t->io_sel = 1; t->io_we = 1; t->io_addr = off >> 2; t->io_be = 0xf; t->io_wdata = v;
        tick();
        t->io_sel = 0; t->io_we = 0;
        tick();
    };
    // enable DMA interrupts 7/8
    wreg(0x0c08, (1u << 7) | (1u << 8));
    int fails = 0, tests = 0;
    for (int n = 0; n < 400 && !fails; n++) {
        for (auto &b : mem) b = uint8_t(rnd());
        ref = mem;
        int ch = rnd() & 1;
        uint32_t ctrl = (rnd() & 0x3f);               // width, dirs, holds
        uint32_t w = (ctrl & 2) ? 4 : (1u << (ctrl & 1));
        uint32_t cnt = rnd() % 41;
        uint32_t src = 0x4000 + (rnd() % 0x2000), dst = 0xA000 + (rnd() % 0x2000);
        src &= ~(w - 1); dst &= ~(w - 1);
        // reference
        {
            uint32_t s = src, d = dst;
            int si = (ctrl & 0x20) ? 0 : ((ctrl & 0x10) ? -int(w) : int(w));
            int di = (ctrl & 0x08) ? 0 : ((ctrl & 0x04) ? -int(w) : int(w));
            for (uint32_t i = 0; i < cnt; i++) {
                for (uint32_t b = 0; b < w; b++) ref[(d + b) & 0xffff] = ref[(s + b) & 0xffff];
                s += si; d += di;
            }
        }
        uint32_t base = ch ? 0x0810 : 0x0800;
        wreg(base + 4, src);
        wreg(base + 8, dst);
        wreg(base + 12, cnt);
        wreg(base, ctrl | 0x400);
        // serve the DMA master until the completion interrupt
        int guard = 0;
        bool irq_seen = false;
        while (!irq_seen && guard++ < 100000) {
            t->dma_ack = 0;
            if (t->dma_req) {
                t->dma_ack = 1;
                uint32_t a = t->dma_addr & ~3u;
                if (t->dma_we) { for (int b = 0; b < 4; b++) if (t->dma_be & (1 << b)) mem[(a + b) & 0xffff] = uint8_t(t->dma_wdata >> (8 * b)); }
                else t->dma_rdata = mem[a & 0xffff] | mem[(a + 1) & 0xffff] << 8 | mem[(a + 2) & 0xffff] << 16 | uint32_t(mem[(a + 3) & 0xffff]) << 24;
            }
            tick();
            if (t->cpu_irq) irq_seen = true;
        }
        tests++;
        uint32_t vec = t->irq_vector & 0x1f;
        if (!irq_seen || vec != uint32_t(7 + ch)) { printf("FAIL test %d: no/incorrect completion IRQ (vector %u)\n", n, vec); fails++; }
        if (mem != ref) {
            int bad = 0;
            for (size_t i = 0; i < mem.size() && bad < 4; i++) if (mem[i] != ref[i]) { printf("FAIL test %d ch%d ctrl %02x cnt %u src %04x dst %04x: byte %04zx rtl %02x ref %02x\n", n, ch, ctrl, cnt, src, dst, i, mem[i], ref[i]); bad++; }
            fails++;
        }
        // acknowledge the interrupt (INTVEC byte 0)
        t->io_sel = 1; t->io_we = 1; t->io_addr = 0x0c04 >> 2; t->io_be = 1; t->io_wdata = 7 + ch; tick();
        t->io_sel = 0; t->io_we = 0; tick();
        // count must read 0, enable bit cleared
        t->io_sel = 1; t->io_we = 0; t->io_addr = base >> 2; t->io_be = 0xf; tick(); t->io_sel = 0; tick();
        if (t->io_rdata & 0x400) { printf("FAIL test %d: enable bit still set\n", n); fails++; }
    }
    printf("DMA TEST: %s tests=%d\n", fails ? "FAIL" : "PASS", tests);
    delete t;
    return fails ? 1 : 0;
}
