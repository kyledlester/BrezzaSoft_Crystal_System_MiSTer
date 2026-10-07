// Microchip PIC16 mid-range (PIC16F84A / PIC16F628A) reference model for the Crystal System protection PIC.
//
// Derived from MAME commit c233473382353a00fb2d8b00d98c197cee910854, src/devices/cpu/pic16x8x/pic16x8x.cpp
// (BSD-3-Clause; copyright-holders Tony La Porta, Grull Osgo, Dirk Best): the same instruction semantics, flags,
// cycle counts, TMR0/prescaler, EEPROM, watchdog and the same register maps (PIC16F84A: core registers mirrored
// at 0x80, RAM 0x0c-0x4f; PIC16F628A: data_map with banks 0-3). Restructured for a deterministic board model:
// step() executes one instruction and returns its instruction cycles (1 or 2); the watchdog is counted in
// instruction cycles (18 ms at the 3.579545 MHz board clock = 16,108 cycles, times the prescaler).
// Firmware image layout as MAME (16-bit little-endian words): program at word 0, configuration word at word
// 0x2007, EEPROM bytes at byte offset 0x4200 + 2*i.
//
// Copyright (C) 2026 Kyle Lester for the restructuring. BSD-3-Clause, as the MAME source it derives from.
#pragma once
#include <cstdint>
#include <cstring>
#include <functional>
#include <vector>

namespace pic16 {

enum Model { F84A, F628A };

class Pic {
public:
    // port A: read of the pins, write of the driven value with the output mask (MAME m_read_port/m_write_port)
    std::function<uint8_t()> porta_in;
    std::function<void(uint8_t data, uint8_t mask)> porta_out;

    Model model = F84A;
    uint16_t prog[0x800] = {};
    uint8_t eeprom[128] = {};
    uint16_t config = 0x3fff;
    uint32_t prog_mask = 0x3ff, eeprom_size = 64;
    uint8_t status_mask = 0x3f, porta_mask = 0x1f;

    // state
    uint16_t pc = 0, prevpc = 0, opcode = 0;
    uint8_t w = 0, option = 0xff, alu = 0, tmr0 = 0, status = 0x18, fsr = 0, eedata = 0, eeadr = 0, pclath = 0,
            eecon1 = 0, intcon = 0;
    uint8_t port_data[2] = {0, 0}, port_tris[2] = {0xff, 0xff};
    uint16_t stack[8] = {};
    uint16_t prescaler = 0;
    int delay_timer = 0;
    uint8_t status_wp = 0x18, inst_cycles = 0, sp = 0, portb_mismatch = 0xff;
    bool sleeping = false;
    int ee_unlock = 0;           // 0 locked, 1 55 written, 2 AA written
    uint8_t ram[0x200] = {};     // general purpose RAM by data address
    // 16F628A peripherals MAME keeps as plain registers
    uint8_t pir1 = 0, t1con = 0, t2con = 0, ccp1con = 0, rcsta = 0, cmcon = 0, pie1 = 0, pcon = 0x08, txsta = 0x02,
            vrcon = 0;
    int64_t wdt_left = -1;       // instruction cycles until the watchdog fires (-1 = disabled)
    uint64_t instructions = 0;

    bool load(Model m, const std::vector<uint8_t> &image)
    {
        model = m;
        if (m == F84A) { prog_mask = 0x3ff; eeprom_size = 64;  status_mask = 0x3f; porta_mask = 0x1f; }
        else           { prog_mask = 0x7ff; eeprom_size = 128; status_mask = 0xff; porta_mask = 0xff; }
        if (image.size() != 0x4200 + eeprom_size * 2) return false;
        auto w16 = [&](size_t i) { return uint16_t(image[2 * i] | (image[2 * i + 1] << 8)); };
        for (uint32_t i = 0; i <= prog_mask; i++) prog[i] = w16(i) & 0x3fff;
        config = w16(0x2007);
        for (uint32_t i = 0; i < eeprom_size; i++) eeprom[i] = image[0x4200 + 2 * i];
        return true;
    }

    void reset()
    {
        pc = 0; prevpc = 0;
        port_tris[0] = port_tris[1] = 0xff;
        option = 0xff; status = 0x18; pclath = 0; intcon = 0; eecon1 = 0;
        prescaler = 0; delay_timer = 0; inst_cycles = 0; status_wp = 0x18; sp = 0; portb_mismatch = 0xff;
        sleeping = false; ee_unlock = 0;
        if (model == F628A) { pir1 = 0; t1con = 0; t2con = 0; ccp1con = 0; rcsta = 0; cmcon = 0; pie1 = 0; pcon = 0x08; txsta = 0x02; vrcon = 0; }
        restart_wdt();
    }

    // one instruction (or one sleeping cycle); returns instruction cycles
    int step()
    {
        check_irqs();
        if (sleeping) {
            inst_cycles = 1;
        } else {
            prevpc = pc;
            opcode = prog[pc & prog_mask];
            set_pc(pc + 1);
            execute();
            status_wp = 0x18;
            update_timer(inst_cycles);
            instructions++;
        }
        if (wdt_left >= 0) {
            wdt_left -= inst_cycles;
            if (wdt_left <= 0) wdt_timeout();
        }
        return inst_cycles;
    }

private:
    void set_pc(uint16_t a) { pc = a & 0x1fff; }
    uint16_t pop() { sp = (sp - 1) & 7; return stack[sp] & 0x1fff; }
    void push(uint16_t d) { stack[sp] = d & 0x1fff; sp = (sp + 1) & 7; }
    uint32_t addr() const { return ((status & 0x60) << 2) | (opcode & 0x7f); }
    int bitpos() const { return (opcode >> 7) & 7; }

    void restart_wdt()
    {
        if (config & 0x04) {
            int pre = (option & 0x08) ? (1 << (option & 7)) : 1;
            wdt_left = int64_t(16108) * pre;     // 18 ms * prescaler at 894.886 kHz instruction cycles
        } else
            wdt_left = -1;
    }
    void wdt_timeout()
    {
        if (sleeping) { sleeping = false; status &= ~0x18; }
        else {
            uint8_t keep = status & (0x08 | 0x07);
            uint8_t pkeep = pcon & 0x03;
            reset();
            status = keep;
            if (model == F628A) pcon = 0x08 | pkeep;
        }
        restart_wdt();
    }

    bool irq_active() const
    {
        if ((intcon >> 3) & intcon & 0x07) return true;
        if (model == F84A) return (intcon & 0x40) && (eecon1 & 0x10);
        return (intcon & 0x40) && (pir1 & pie1);
    }
    void check_irqs()
    {
        // port B change detection: port B pins read as 0 (nothing connected)
        uint8_t im = port_tris[1] & 0xf0;
        if (im && ((0 & im) != (portb_mismatch & im))) intcon |= 0x01;
        if (!irq_active()) return;
        if (sleeping) { sleeping = false; restart_wdt(); return; }
        if (intcon & 0x80) { intcon &= ~0x80; push(pc); set_pc(4); }
    }
    void update_timer(int counts)
    {
        if (option & 0x20) counts = 0;           // T0CKI counting: no edges on this board
        if (delay_timer > 0) { int dt = delay_timer; delay_timer -= inst_cycles; counts -= dt; }
        if (delay_timer > 0 || counts <= 0) return;
        int inc = 0;
        if ((option & 0x08) == 0) {
            prescaler += counts;
            int div = 2 << (option & 7);
            if (prescaler >= div) { inc = prescaler / div; prescaler %= div; }
        } else inc = counts;
        if (inc > 0) { uint16_t n = tmr0 + inc; if (n > 0xff) intcon |= 0x04; tmr0 = uint8_t(n); }
    }

    // ---------------------------------------------------------------- register file
    uint8_t porta_r()
    {
        uint8_t d = porta_in ? porta_in() : 0xff;
        d &= port_tris[0];
        d |= uint8_t(~port_tris[0]) & port_data[0];
        return d & porta_mask;
    }
    void porta_w(uint8_t d)
    {
        d &= porta_mask;
        uint8_t m = uint8_t(~port_tris[0]) & porta_mask;
        port_data[0] = d;
        if (porta_out) porta_out(d & m, m);
    }
    uint8_t portb_r()
    {
        uint8_t d = 0;                           // no port B input on this board
        d &= port_tris[1];
        d |= uint8_t(~port_tris[1]) & port_data[1];
        portb_mismatch = d & 0xf0;
        return d;
    }
    void portb_w(uint8_t d) { portb_r(); port_data[1] = d; }
    void trisa_w(uint8_t d)
    {
        d |= uint8_t(~porta_mask);
        if (port_tris[0] != d) {
            port_tris[0] = d;
            uint8_t m = uint8_t(~port_tris[0]) & porta_mask;
            if (porta_out) porta_out(port_data[0] & m, m);
        }
    }
    void trisb_w(uint8_t d) { port_tris[1] = d; }
    void option_w(uint8_t d)
    {
        uint8_t old = option;
        option = d;
        if ((old ^ d) & 0x0f) { prescaler = 0; restart_wdt(); }
    }
    void eecon1_w(uint8_t d)
    {
        if (d & 0x04) eecon1 |= 0x04; else eecon1 &= ~0x04;
        eecon1 &= (d | uint8_t(~0x18));
        if (d & 0x01) eedata = eeadr < eeprom_size ? eeprom[eeadr] : 0xff;
        if (d & 0x02) {
            if ((eecon1 & 0x04) && ee_unlock == 2) {
                if (eeadr < eeprom_size) eeprom[eeadr] = eedata;
                if (model == F84A) eecon1 |= 0x10; else pir1 |= 0x80;
            }
        }
        ee_unlock = 0;
    }
    void eecon2_w(uint8_t d)
    {
        if (ee_unlock == 0 && d == 0x55) ee_unlock = 1;
        else if (ee_unlock == 1 && d == 0xaa) ee_unlock = 2;
        else ee_unlock = 0;
    }

    // core registers (both models); returns true when handled
    bool core_rd(uint32_t a, uint8_t &v)
    {
        switch (a) {
        case 0x02: v = uint8_t(pc); return true;
        case 0x03: v = status; return true;
        case 0x04: v = fsr; return true;
        case 0x0a: v = pclath; return true;
        case 0x0b: v = intcon; return true;
        }
        return false;
    }
    bool core_wr(uint32_t a, uint8_t d)
    {
        switch (a) {
        case 0x02: set_pc((pclath << 8) | d); inst_cycles++; return true;
        case 0x03: status = ((status & status_wp) | (d & uint8_t(~status_wp))) & status_mask; return true;
        case 0x04: fsr = d; return true;
        case 0x0a: pclath = d & 0x1f; return true;
        case 0x0b: intcon = d; return true;
        }
        return false;
    }

    uint8_t read_data(uint32_t a)
    {
        uint8_t v = 0;
        if (model == F84A) {
            a &= 0xff;
            uint32_t lo = a & 0x7f;
            if (lo == 0x00 || lo == 0x07) return 0;
            if (core_rd(lo, v)) return v;
            if (lo >= 0x0c && lo <= 0x4f) return ram[lo];
            if (lo >= 0x50) return 0;
            if (a & 0x80) {
                switch (lo) {
                case 0x01: return option;
                case 0x05: return port_tris[0];
                case 0x06: return port_tris[1];
                case 0x08: return eecon1;
                case 0x09: return 0;
                }
                return 0;
            }
            switch (lo) {
            case 0x01: return tmr0;
            case 0x05: return porta_r();
            case 0x06: return portb_r();
            case 0x08: return eedata;
            case 0x09: return eeadr;
            }
            return 0;
        }
        // PIC16F628A data_map (MAME): 9-bit addresses
        a &= 0x1ff;
        uint32_t lo = a & 0x7f, bank = a >> 7;
        if (lo == 0x00 || lo == 0x07) return 0;
        if (lo == 0x02 || lo == 0x03 || lo == 0x04 || lo == 0x0a || lo == 0x0b) { core_rd(lo, v); return v; }
        if (lo >= 0x70) return ram[0x70 + (lo - 0x70)];
        switch (bank) {
        case 0:
            switch (lo) {
            case 0x01: return tmr0;
            case 0x05: return porta_r();
            case 0x06: return portb_r();
            case 0x0c: return pir1;
            case 0x10: return t1con;
            case 0x12: return t2con;
            case 0x17: return ccp1con;
            case 0x18: return rcsta;
            case 0x1f: return cmcon;
            }
            if (lo >= 0x20) return ram[a];
            return 0;
        case 1:
            switch (lo) {
            case 0x01: return option;
            case 0x05: return port_tris[0];
            case 0x06: return port_tris[1];
            case 0x0c: return pie1;
            case 0x0e: return pcon;
            case 0x18: return txsta;
            case 0x1a: return eedata;
            case 0x1b: return eeadr;
            case 0x1c: return eecon1;
            case 0x1f: return vrcon;
            }
            if (lo >= 0x20 && lo <= 0x6f) return ram[a];
            return 0;
        case 2:
            if (lo == 0x01) return tmr0;
            if (lo == 0x06) return portb_r();
            if (lo >= 0x20 && lo <= 0x4f) return ram[a];
            return 0;
        default:
            if (lo == 0x01) return option;
            if (lo == 0x06) return port_tris[1];
            return 0;
        }
    }

    void write_data(uint32_t a, uint8_t d)
    {
        if (model == F84A) {
            a &= 0xff;
            uint32_t lo = a & 0x7f;
            if (lo == 0x00 || lo == 0x07) return;
            if (core_wr(lo, d)) return;
            if (lo >= 0x0c && lo <= 0x4f) { ram[lo] = d; return; }
            if (lo >= 0x50) return;
            if (a & 0x80) {
                switch (lo) {
                case 0x01: option_w(d); return;
                case 0x05: trisa_w(d); return;
                case 0x06: trisb_w(d); return;
                case 0x08: eecon1_w(d); return;
                case 0x09: eecon2_w(d); return;
                }
                return;
            }
            switch (lo) {
            case 0x01: tmr0_w(d); return;
            case 0x05: porta_w(d); return;
            case 0x06: portb_w(d); return;
            case 0x08: eedata = d; return;
            case 0x09: eeadr = d; return;
            }
            return;
        }
        a &= 0x1ff;
        uint32_t lo = a & 0x7f, bank = a >> 7;
        if (lo == 0x00 || lo == 0x07) return;
        if (core_wr(lo, d)) return;
        if (lo >= 0x70) { ram[0x70 + (lo - 0x70)] = d; return; }
        switch (bank) {
        case 0:
            switch (lo) {
            case 0x01: tmr0_w(d); return;
            case 0x05: porta_w(d); return;
            case 0x06: portb_w(d); return;
            case 0x0c: pir1 = d & 0xf7; return;
            case 0x10: t1con = d; return;
            case 0x12: t2con = d; return;
            case 0x17: ccp1con = d; return;
            case 0x18: rcsta = d; return;
            case 0x1f: cmcon = d; return;
            }
            if (lo >= 0x20) ram[a] = d;
            return;
        case 1:
            switch (lo) {
            case 0x01: option_w(d); return;
            case 0x05: trisa_w(d); return;
            case 0x06: trisb_w(d); return;
            case 0x0c: pie1 = d & 0xf7; return;
            case 0x0e: pcon = d; return;
            case 0x18: txsta = d; return;
            case 0x1a: eedata = d; return;
            case 0x1b: eeadr = d; return;
            case 0x1c: eecon1_w(d); return;
            case 0x1d: eecon2_w(d); return;
            case 0x1f: vrcon = d; return;
            }
            if (lo >= 0x20 && lo <= 0x6f) ram[a] = d;
            return;
        case 2:
            if (lo == 0x01) { tmr0_w(d); return; }
            if (lo == 0x06) { portb_w(d); return; }
            if (lo >= 0x20 && lo <= 0x4f) ram[a] = d;
            return;
        default:
            if (lo == 0x01) { option_w(d); return; }
            if (lo == 0x06) { trisb_w(d); return; }
            return;
        }
    }
    void tmr0_w(uint8_t d)
    {
        delay_timer = inst_cycles + 2;
        if ((option & 0x08) == 0) prescaler = 0;
        tmr0 = d;
    }

    uint8_t get_reg(uint32_t a)
    {
        if ((a & 0x7f) == 0) a = ((status & 0x80) << 1) | fsr;
        return read_data(a);
    }
    void set_reg(uint32_t a, uint8_t d)
    {
        if ((a & 0x7f) == 0) a = ((status & 0x80) << 1) | fsr;
        write_data(a, d);
    }
    void store(uint32_t a, uint8_t d) { if (opcode & 0x80) set_reg(a, d); else w = d; }
    void zf() { if (alu == 0) status |= 0x04; else status &= ~0x04; }
    void addf(uint8_t aug)
    {
        zf();
        if (aug > alu) status |= 0x01; else status &= ~0x01;
        if ((aug & 0x0f) > (alu & 0x0f)) status |= 0x02; else status &= ~0x02;
    }
    void subf(uint8_t min)
    {
        zf();
        if (min < alu) status &= ~0x01; else status |= 0x01;
        if ((min & 0x0f) < (alu & 0x0f)) status &= ~0x02; else status |= 0x02;
    }

    void execute()
    {
        const uint16_t op = opcode;
        const uint8_t k = uint8_t(op);
        inst_cycles = 1;
        status_wp = 0x18;
        if ((op & 0x3f80) == 0) {
            // 00 0000 0xxx xxxx group
            switch (k & 0x7f) {
            case 0x00: case 0x20: case 0x40: case 0x60: break;                                 // nop
            case 0x08: inst_cycles = 2; set_pc(pop()); break;                                  // return
            case 0x09: inst_cycles = 2; set_pc(pop()); intcon |= 0x80; break;                  // retfie
            case 0x62: option_w(w); break;                                                     // option
            case 0x63: status |= 0x10; status &= ~0x08; sleeping = true; restart_wdt(); break; // sleep
            case 0x64: status |= 0x18; restart_wdt(); break;                                   // clrwdt
            case 0x65: trisa_w(w); break;                                                      // tris 5
            case 0x66: trisb_w(w); break;                                                      // tris 6
            default: break;                                                                    // illegal
            }
            return;
        }
        const uint32_t g = (op >> 7) & 0x7f;
        const uint32_t a = addr();
        auto alu_flags = [&]() { status_wp = 0x18 | 0x07; };
        if (g < 0x20) {
            switch (g >> 1) {
            case 0x00: set_reg(a, w); break;                                                   // movwf (g=1)
            case 0x01: if (g & 1) { alu_flags(); set_reg(a, 0); status |= 0x04; }               // clrf
                       else { alu_flags(); w = 0; status |= 0x04; } break;                     // clrw
            case 0x02: { alu_flags(); uint8_t m = get_reg(a); alu = m - w; store(a, alu); subf(m); } break;
            case 0x03: alu_flags(); alu = get_reg(a) - 1; store(a, alu); zf(); break;          // decf
            case 0x04: alu_flags(); alu = get_reg(a) | w; store(a, alu); zf(); break;          // iorwf
            case 0x05: alu_flags(); alu = get_reg(a) & w; store(a, alu); zf(); break;          // andwf
            case 0x06: alu_flags(); alu = get_reg(a) ^ w; store(a, alu); zf(); break;          // xorwf
            case 0x07: { alu_flags(); uint8_t au = get_reg(a); alu = au + w; store(a, alu); addf(au); } break;
            case 0x08: alu_flags(); alu = get_reg(a); store(a, alu); zf(); break;              // movf
            case 0x09: alu_flags(); alu = uint8_t(~get_reg(a)); store(a, alu); zf(); break;    // comf
            case 0x0a: alu_flags(); alu = get_reg(a) + 1; store(a, alu); zf(); break;          // incf
            case 0x0b: alu = get_reg(a) - 1; store(a, alu); if (alu == 0) { set_pc(pc + 1); inst_cycles++; } break;
            case 0x0c: { alu_flags(); alu = get_reg(a); int c = alu & 1; alu >>= 1; if (status & 1) alu |= 0x80;
                         store(a, alu); if (c) status |= 1; else status &= ~1; } break;        // rrf
            case 0x0d: { alu_flags(); alu = get_reg(a); int c = alu >> 7; alu <<= 1; if (status & 1) alu |= 1;
                         store(a, alu); if (c) status |= 1; else status &= ~1; } break;        // rlf
            case 0x0e: { uint8_t r = get_reg(a); alu = uint8_t(r << 4 | r >> 4); store(a, alu); } break;
            case 0x0f: alu = get_reg(a) + 1; store(a, alu); if (alu == 0) { set_pc(pc + 1); inst_cycles++; } break;
            }
            return;
        }
        if (g < 0x40) {
            switch (g >> 3) {
            case 4: alu = get_reg(a); alu &= ~(1 << bitpos()); set_reg(a, alu); break;       // bcf
            case 5: alu = get_reg(a); alu |= 1 << bitpos(); set_reg(a, alu); break;          // bsf
            case 6: if (!((get_reg(a) >> bitpos()) & 1)) { set_pc(pc + 1); inst_cycles++; } break; // btfsc
            case 7: if ((get_reg(a) >> bitpos()) & 1) { set_pc(pc + 1); inst_cycles++; } break;    // btfss
            }
            return;
        }
        if (g < 0x50) { inst_cycles = 2; push(pc); set_pc(((pclath & 0x18) << 8) | (op & 0x7ff)); return; } // call
        if (g < 0x60) { inst_cycles = 2; set_pc(((pclath & 0x18) << 8) | (op & 0x7ff)); return; }           // goto
        if (g < 0x68) { w = k; return; }                                                                    // movlw
        if (g < 0x70) { inst_cycles = 2; w = k; set_pc(pop()); return; }                                    // retlw
        alu_flags();
        switch ((g >> 1) & 7) {
        case 0: alu = k | w; w = alu; zf(); break;                                             // iorlw
        case 1: alu = k & w; w = alu; zf(); break;                                             // andlw
        case 2: case 3: alu = w ^ k; w = alu; zf(); break;                                     // xorlw
        case 4: case 5: alu = uint8_t(k - w); w = alu; subf(k); break;                         // sublw
        case 6: case 7: alu = uint8_t(k + w); w = alu; addf(k); break;                         // addlw
        }
    }
};

} // namespace pic16
