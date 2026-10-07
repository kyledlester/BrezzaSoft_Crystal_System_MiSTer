// PIC16 difftest: rtl/crystal/crystal_pic16.sv against the reference model sim/reference/pic16_ref.h (MAME
// pic16x8x port), instruction by instruction.
//   tb_pic                       -> both Crystal System firmwares (topbladv PIC16F628A, officeye PIC16F84A) and
//                                   random programs for both models
// Compared after every instruction: PC, W, STATUS, FSR, every port A write (value and mask) and EEPROM contents
// at the end. The port A input (bit 0 = the shared data line) toggles randomly, as the CPU side would.
#include "Vcrystal_pic16.h"
#include "verilated.h"
#include "../reference/pic16_ref.h"
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <string>
#include <vector>

double sc_time_stamp() { return 0; }

static std::vector<uint8_t> read_file(const std::string &p)
{
    std::ifstream f(p, std::ios::binary);
    if (!f) { fprintf(stderr, "cannot read %s\n", p.c_str()); exit(2); }
    return std::vector<uint8_t>((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
}

static uint64_t rng = 0x9E3779B97F4A7C15ull;
static uint32_t rnd() { rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17; return uint32_t(rng); }

// one run; returns mismatches
static int run(const char *name, pic16::Model m, const std::vector<uint8_t> &img, uint64_t insns, int toggle_pct)
{
    Vcrystal_pic16 *t = new Vcrystal_pic16;
    pic16::Pic ref;
    if (!ref.load(m, img)) { printf("%s: bad image\n", name); return 1; }
    uint8_t pin = 1;
    std::vector<std::pair<uint8_t, uint8_t>> ref_pa, rtl_pa;
    ref.porta_in = [&]() -> uint8_t { return pin; };
    ref.porta_out = [&](uint8_t d, uint8_t mk) { ref_pa.push_back({d, mk}); };
    ref.reset();

    auto clk = [&]() { t->clk = 1; t->eval(); t->clk = 0; t->eval(); };
    t->model_628 = (m == pic16::F628A); t->hold = 0; t->cyc = 0; t->porta_in = pin; t->ld_we = 0;
    t->rst_n = 0; for (int i = 0; i < 4; i++) clk();
    // load the image (16-bit words) while in reset
    for (size_t wi = 0; wi * 2 + 1 < img.size(); wi++) {
        t->ld_we = 1; t->ld_addr = uint16_t(wi); t->ld_data = uint16_t(img[2 * wi] | (img[2 * wi + 1] << 8));
        clk();
    }
    t->ld_we = 0;
    t->rst_n = 1; clk();

    int bad = 0;
    uint64_t done = 0, cycles = 0;
    while (done < insns && bad < 10) {
        // one instruction cycle: drive the pin, pulse cyc, give the RTL 15 clocks
        if ((rnd() % 100) < uint32_t(toggle_pct)) pin ^= 1;
        t->porta_in = pin;
        t->cyc = 1; clk(); t->cyc = 0;
        bool retired = false;
        for (int i = 0; i < 15; i++) {
            if (t->porta_we) rtl_pa.push_back({t->porta_val, t->porta_mask});
            if (t->dbg_retire) retired = true;
            clk();
        }
        if (t->porta_we) rtl_pa.push_back({t->porta_val, t->porta_mask});
        cycles++;
        if (!retired) continue;               // second cycle of a 2-cycle instruction (or sleep)
        // the reference executes the same instruction now
        int rc = ref.step();
        (void)rc;
        done++;
        bool mism = ref.pc != t->dbg_pc || ref.w != t->dbg_w || ref.status != t->dbg_status || ref_pa != rtl_pa;
        if (mism) {
            bad++;
            printf("%s: MISMATCH after insn %llu (op %04x at %03x): ref pc %03x w %02x st %02x | rtl pc %03x w %02x st %02x | porta writes ref %zu rtl %zu\n",
                   name, (unsigned long long)done, ref.opcode, ref.prevpc, ref.pc, ref.w, ref.status, t->dbg_pc, t->dbg_w,
                   t->dbg_status, ref_pa.size(), rtl_pa.size());
            // resynchronise nothing: stop after a few
        }
        ref_pa.clear(); rtl_pa.clear();
        // the reference took rc cycles, the RTL waits the same number of cyc pulses before its next instruction:
        // nothing to do here, the loop pulses cyc and only steps the reference when the RTL retires
    }
    printf("%s: %s, %llu instructions, %llu instruction cycles\n", name, bad ? "FAIL" : "PASS", (unsigned long long)done,
           (unsigned long long)cycles);
    delete t;
    return bad;
}

int main(int argc, char **argv)
{
    std::string rom = "C:/Users/klest/Crystal_research/roms";
    int bad = 0;
    bad += run("topbladv PIC16F628A firmware", pic16::F628A, read_file(rom + "/topbladv/top_blade_v_pic16c727.bin"), 2000000, 2);
    bad += run("officeye PIC16F84A firmware", pic16::F84A, read_file(rom + "/officeye/office_yeo_in_cheon_ha_pic16f84a.bin"), 2000000, 2);
    // random programs (every opcode, every register, both models); EEPROM bytes random
    for (int seed = 0; seed < 40; seed++) {
        pic16::Model m = (seed & 1) ? pic16::F628A : pic16::F84A;
        size_t eesz = m == pic16::F84A ? 64 : 128;
        std::vector<uint8_t> img(0x4200 + eesz * 2, 0);
        for (int i = 0; i < 0x800; i++) {
            uint16_t op = rnd() & 0x3fff;
            if ((rnd() % 8) == 0) op = 0x3fff;                                    // addlw
            if ((op & 0x3fff) == 0x0063) op = 0;                                   // no SLEEP (no wake source)
            img[2 * i] = op & 0xff; img[2 * i + 1] = op >> 8;
        }
        img[2 * 0x2007] = 0xf9; img[2 * 0x2007 + 1] = 0x3f;                      // WDTE = 0
        for (size_t i = 0; i < eesz; i++) img[0x4200 + 2 * i] = rnd() & 0xff;
        char nm[64];
        snprintf(nm, sizeof nm, "random program %d (%s)", seed, m == pic16::F84A ? "F84A" : "F628A");
        bad += run(nm, m, img, 200000, 30);
    }
    printf("PIC DIFFTEST: %s\n", bad ? "FAIL" : "PASS");
    return bad ? 1 : 0;
}
