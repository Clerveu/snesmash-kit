"""Decode a dumped SNES OAM/VRAM/CGRAM triple (from a *_ppudump.lua script).

python tools/snes_oam.py DIR TAG [--base 0x6000] [--offset 0x1000] [--mode 0] [--list] [--box x0,y0,x1,y1]
Writes DIR/render{TAG}.png: screenshot | sprite layer, 4x. --list prints each visible OAM entry.
--base/--offset are VRAM *word* addresses (Mesen state: ppu.oamBaseAddress / ppu.oamAddressOffset).
--mode is OBSEL size mode (ppu.oamMode): 0=8/16 1=8/32 2=8/64 3=16/32 4=16/64 5=32/64.
"""
import argparse
from PIL import Image, ImageDraw

SIZES = {0: (8, 16), 1: (8, 32), 2: (8, 64), 3: (16, 32), 4: (16, 64), 5: (32, 64), 6: (16, 32), 7: (16, 32)}

def load(d, tag):
    r = lambda n: open(f'{d}/{n}{tag}.bin', 'rb').read()
    return r('oam'), r('vram'), r('cg')

def entries(oam, mode):
    small, large = SIZES[mode]
    out = []
    for i in range(128):
        x, y, t, a = oam[i * 4:i * 4 + 4]
        hi = (oam[512 + i // 4] >> ((i % 4) * 2)) & 3
        x |= (hi & 1) << 8
        if x >= 256: x -= 512
        size = large if hi & 2 else small
        out.append(dict(i=i, x=x, y=y, tile=t | ((a & 1) << 8), pal=(a >> 1) & 7, prio=(a >> 4) & 3,
                        hf=(a >> 6) & 1, vf=a >> 7, size=size))
    return out

def visible(e):
    return not (e['y'] >= 224 and e['y'] + e['size'] <= 256) and e['x'] > -e['size']

def color(cg, i):
    v = cg[i * 2] | cg[i * 2 + 1] << 8
    return ((v & 31) * 255 // 31, ((v >> 5) & 31) * 255 // 31, ((v >> 10) & 31) * 255 // 31)

def tile4(vram, addr):
    px = [[0] * 8 for _ in range(8)]
    for r in range(8):
        p0, p1 = vram[(addr + r * 2) & 0xFFFF], vram[(addr + r * 2 + 1) & 0xFFFF]
        p2, p3 = vram[(addr + 16 + r * 2) & 0xFFFF], vram[(addr + 17 + r * 2) & 0xFFFF]
        for c in range(8):
            b = 7 - c
            px[r][c] = ((p0 >> b) & 1) | ((p1 >> b) & 1) << 1 | ((p2 >> b) & 1) << 2 | ((p3 >> b) & 1) << 3
    return px

def obj_tile_addr(base, offset, tile):
    """Byte address in VRAM of OBJ tile number 0-511."""
    N, t = tile >> 8, tile & 0xFF
    return ((base + N * offset) * 2 + t * 32) & 0xFFFF

def render(oam, vram, cg, base, offset, mode, only=None):
    img = Image.new('RGBA', (256, 256), (0, 0, 0, 0))
    for e in reversed(entries(oam, mode)):
        if not visible(e) or (only and e['i'] not in only): continue
        n = e['size'] // 8
        for ty in range(n):
            for tx in range(n):
                t = e['tile'] & 0xFF
                tt = (((t & 0xF0) + (ty << 4)) & 0xF0) | ((t + tx) & 0x0F)
                px = tile4(vram, obj_tile_addr(base, offset, (e['tile'] & 0x100) | tt))
                for r in range(8):
                    for c in range(8):
                        v = px[r][c]
                        if not v: continue
                        sx = (n - 1 - tx) * 8 + (7 - c) if e['hf'] else tx * 8 + c
                        sy = (n - 1 - ty) * 8 + (7 - r) if e['vf'] else ty * 8 + r
                        X, Y = e['x'] + sx, (e['y'] + 1 + sy) & 255
                        if 0 <= X < 256: img.putpixel((X, Y), color(cg, 128 + e['pal'] * 16 + v) + (255,))
    return img

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('dir'); ap.add_argument('tag')
    ap.add_argument('--base', type=lambda x: int(x, 0), default=0x6000)
    ap.add_argument('--offset', type=lambda x: int(x, 0), default=0x1000)
    ap.add_argument('--mode', type=int, default=0)
    ap.add_argument('--list', action='store_true')
    ap.add_argument('--box', default=None)
    a = ap.parse_args()
    oam, vram, cg = load(a.dir, a.tag)
    es = [e for e in entries(oam, a.mode) if visible(e)]
    if a.box:
        x0, y0, x1, y1 = map(int, a.box.split(','))
        es = [e for e in es if e['x'] < x1 and e['x'] + e['size'] > x0 and e['y'] < y1 and e['y'] + e['size'] > y0]
    if a.list:
        for e in es:
            print('#{i:3d} x={x:4d} y={y:3d} tile={tile:03x} pal={pal} prio={prio} hf={hf} vf={vf} size={size}'.format(**e))
    only = {e['i'] for e in es} if a.box else None
    spr = render(oam, vram, cg, a.base, a.offset, a.mode, only)
    scr = Image.open(f'{a.dir}/scr{a.tag}.png').convert('RGBA')
    both = Image.new('RGBA', (512, 224)); both.paste(scr, (0, 0))
    bg = Image.new('RGBA', (256, 224), (40, 0, 40, 255)); bg.alpha_composite(spr.crop((0, 0, 256, 224)))
    both.paste(bg, (256, 0))
    both.resize((1024, 448), Image.NEAREST).save(f'{a.dir}/render{a.tag}.png')

if __name__ == '__main__':
    main()
