"""Minimal 65816 disassembler for SNES ROMs (LoROM / HiROM), for reading code found via traces.

python tools/dis65816.py ROM BANK:ADDR [count] [--m8|--m16] [--x8|--x16] [--hirom]
  e.g. python tools/dis65816.py "ROMS/Super Ghouls 'N Ghosts.sfc" 01:8EA0 40

Accumulator/index widths start at 8-bit (override with --m16/--x16) and follow REP/SEP as they are
decoded linearly; after branches/jumps that may be wrong, so re-run from a known entry if output
looks off. A 512-byte copier header is detected and skipped.
"""
import argparse, os

MODES = {  # name: (operand bytes, format)
    'imp': (0, ''), 'acc': (0, 'A'), 'imm8': (1, '#${:02X}'), 'immM': (None, '#${}'), 'immX': (None, '#${}'),
    'dp': (1, '${:02X}'), 'dpx': (1, '${:02X},X'), 'dpy': (1, '${:02X},Y'), 'idp': (1, '(${:02X})'),
    'idpx': (1, '(${:02X},X)'), 'idpy': (1, '(${:02X}),Y'), 'ildp': (1, '[${:02X}]'), 'ildpy': (1, '[${:02X}],Y'),
    'abs': (2, '${:04X}'), 'absx': (2, '${:04X},X'), 'absy': (2, '${:04X},Y'), 'long': (3, '${:06X}'),
    'longx': (3, '${:06X},X'), 'iabs': (2, '(${:04X})'), 'iabsx': (2, '(${:04X},X)'), 'ilabs': (2, '[${:04X}]'),
    'sr': (1, '${:02X},S'), 'isry': (1, '(${:02X},S),Y'), 'rel': (1, 'rel'), 'rell': (2, 'rell'), 'bm': (2, 'bm'),
}

T = """
00 BRK imm8|01 ORA idpx|02 COP imm8|03 ORA sr|04 TSB dp|05 ORA dp|06 ASL dp|07 ORA ildp|08 PHP imp|09 ORA immM|0A ASL acc|0B PHD imp|0C TSB abs|0D ORA abs|0E ASL abs|0F ORA long
10 BPL rel|11 ORA idpy|12 ORA idp|13 ORA isry|14 TRB dp|15 ORA dpx|16 ASL dpx|17 ORA ildpy|18 CLC imp|19 ORA absy|1A INC acc|1B TCS imp|1C TRB abs|1D ORA absx|1E ASL absx|1F ORA longx
20 JSR abs|21 AND idpx|22 JSL long|23 AND sr|24 BIT dp|25 AND dp|26 ROL dp|27 AND ildp|28 PLP imp|29 AND immM|2A ROL acc|2B PLD imp|2C BIT abs|2D AND abs|2E ROL abs|2F AND long
30 BMI rel|31 AND idpy|32 AND idp|33 AND isry|34 BIT dpx|35 AND dpx|36 ROL dpx|37 AND ildpy|38 SEC imp|39 AND absy|3A DEC acc|3B TSC imp|3C BIT absx|3D AND absx|3E ROL absx|3F AND longx
40 RTI imp|41 EOR idpx|42 WDM imm8|43 EOR sr|44 MVP bm|45 EOR dp|46 LSR dp|47 EOR ildp|48 PHA imp|49 EOR immM|4A LSR acc|4B PHK imp|4C JMP abs|4D EOR abs|4E LSR abs|4F EOR long
50 BVC rel|51 EOR idpy|52 EOR idp|53 EOR isry|54 MVN bm|55 EOR dpx|56 LSR dpx|57 EOR ildpy|58 CLI imp|59 EOR absy|5A PHY imp|5B TCD imp|5C JML long|5D EOR absx|5E LSR absx|5F EOR longx
60 RTS imp|61 ADC idpx|62 PER rell|63 ADC sr|64 STZ dp|65 ADC dp|66 ROR dp|67 ADC ildp|68 PLA imp|69 ADC immM|6A ROR acc|6B RTL imp|6C JMP iabs|6D ADC abs|6E ROR abs|6F ADC long
70 BVS rel|71 ADC idpy|72 ADC idp|73 ADC isry|74 STZ dpx|75 ADC dpx|76 ROR dpx|77 ADC ildpy|78 SEI imp|79 ADC absy|7A PLY imp|7B TDC imp|7C JMP iabsx|7D ADC absx|7E ROR absx|7F ADC longx
80 BRA rel|81 STA idpx|82 BRL rell|83 STA sr|84 STY dp|85 STA dp|86 STX dp|87 STA ildp|88 DEY imp|89 BIT immM|8A TXA imp|8B PHB imp|8C STY abs|8D STA abs|8E STX abs|8F STA long
90 BCC rel|91 STA idpy|92 STA idp|93 STA isry|94 STY dpx|95 STA dpx|96 STX dpy|97 STA ildpy|98 TYA imp|99 STA absy|9A TXS imp|9B TXY imp|9C STZ abs|9D STA absx|9E STZ absx|9F STA longx
A0 LDY immX|A1 LDA idpx|A2 LDX immX|A3 LDA sr|A4 LDY dp|A5 LDA dp|A6 LDX dp|A7 LDA ildp|A8 TAY imp|A9 LDA immM|AA TAX imp|AB PLB imp|AC LDY abs|AD LDA abs|AE LDX abs|AF LDA long
B0 BCS rel|B1 LDA idpy|B2 LDA idp|B3 LDA isry|B4 LDY dpx|B5 LDA dpx|B6 LDX dpy|B7 LDA ildpy|B8 CLV imp|B9 LDA absy|BA TSX imp|BB TYX imp|BC LDY absx|BD LDA absx|BE LDX absy|BF LDA longx
C0 CPY immX|C1 CMP idpx|C2 REP imm8|C3 CMP sr|C4 CPY dp|C5 CMP dp|C6 DEC dp|C7 CMP ildp|C8 INY imp|C9 CMP immM|CA DEX imp|CB WAI imp|CC CPY abs|CD CMP abs|CE DEC abs|CF CMP long
D0 BNE rel|D1 CMP idpy|D2 CMP idp|D3 CMP isry|D4 PEI dp|D5 CMP dpx|D6 DEC dpx|D7 CMP ildpy|D8 CLD imp|D9 CMP absy|DA PHX imp|DB STP imp|DC JML ilabs|DD CMP absx|DE DEC absx|DF CMP longx
E0 CPX immX|E1 SBC idpx|E2 SEP imm8|E3 SBC sr|E4 CPX dp|E5 SBC dp|E6 INC dp|E7 SBC ildp|E8 INX imp|E9 SBC immM|EA NOP imp|EB XBA imp|EC CPX abs|ED SBC abs|EE INC abs|EF SBC long
F0 BEQ rel|F1 SBC idpy|F2 SBC idp|F3 SBC isry|F4 PEA abs|F5 SBC dpx|F6 INC dpx|F7 SBC ildpy|F8 SED imp|F9 SBC absy|FA PLX imp|FB XCE imp|FC JSR iabsx|FD SBC absx|FE INC absx|FF SBC longx
"""
OPS = {}
for chunk in T.replace('\n', '|').split('|'):
    chunk = chunk.strip()
    if chunk:
        code, mn, mode = chunk.split()
        OPS[int(code, 16)] = (mn, mode)


class Rom:
    def __init__(self, path, hirom=False):
        d = open(path, 'rb').read()
        if len(d) % 0x8000 == 512:
            d = d[512:]
        self.d, self.hirom = d, hirom

    def off(self, bank, addr):
        if self.hirom:
            return ((bank & 0x3F) << 16 | addr) % len(self.d)
        return (((bank & 0x7F) << 15) | (addr & 0x7FFF)) % len(self.d)

    def byte(self, bank, addr):
        return self.d[self.off(bank, addr)]


def disasm(rom, bank, addr, count, m8=True, x8=True):
    out = []
    for _ in range(count):
        op = rom.byte(bank, addr)
        mn, mode = OPS[op]
        n, fmt = MODES[mode]
        if mode == 'immM': n = 1 if m8 else 2
        if mode == 'immX': n = 1 if x8 else 2
        ops = [rom.byte(bank, (addr + 1 + i) & 0xFFFF) for i in range(n)]
        val = 0
        for i, b in enumerate(ops): val |= b << (8 * i)
        if mode in ('immM', 'immX'): txt = '#$' + ('{:02X}' if n == 1 else '{:04X}').format(val)
        elif mode == 'rel': txt = '${:04X}'.format((addr + 2 + (val - 256 if val > 127 else val)) & 0xFFFF)
        elif mode == 'rell': txt = '${:04X}'.format((addr + 3 + (val - 65536 if val > 32767 else val)) & 0xFFFF)
        elif mode == 'bm': txt = '${:02X},${:02X}'.format(ops[1], ops[0])
        else: txt = fmt.format(val) if fmt else ''
        raw = ' '.join('{:02X}'.format(b) for b in [op] + ops)
        out.append('{:02X}:{:04X}  {:<12} {} {}'.format(bank, addr, raw, mn, txt).rstrip())
        if mn == 'REP':
            if val & 0x20: m8 = False
            if val & 0x10: x8 = False
        if mn == 'SEP':
            if val & 0x20: m8 = True
            if val & 0x10: x8 = True
        addr = (addr + 1 + n) & 0xFFFF
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('rom'); ap.add_argument('at'); ap.add_argument('count', nargs='?', type=int, default=32)
    ap.add_argument('--m16', action='store_true'); ap.add_argument('--x16', action='store_true')
    ap.add_argument('--hirom', action='store_true')
    a = ap.parse_args()
    bank, addr = (int(p, 16) for p in a.at.split(':'))
    for line in disasm(Rom(a.rom, a.hirom), bank, addr, a.count, not a.m16, not a.x16):
        print(line)


if __name__ == '__main__':
    main()
