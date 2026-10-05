"""Search a per-frame RAM trace for addresses that behave a certain way.

trace.bin = N consecutive snapshots of SIZE bytes (one per frame), as written by lua/recon/ram_trace.lua
scripts. Usage examples:
  python tools/ramsearch.py trace.bin --size 0x2000 --rise 60:160 --fall 165:200 --word
  python tools/ramsearch.py trace.bin --show 0x0a3c:2 --frames 50:220
--rise/--fall: value strictly non-decreasing / non-increasing over the window AND changes by at
least --min. --const: unchanged over a window. --word = 16-bit little-endian, else bytes.
"""
import argparse, sys

def load(path, size):
    d = open(path, 'rb').read()
    return [d[i:i + size] for i in range(0, len(d) - size + 1, size)]

def val(snap, a, word, signed=False):
    v = snap[a] | (snap[a + 1] << 8) if word else snap[a]
    if signed:
        lim = 0x8000 if word else 0x80
        if v >= lim: v -= 2 * lim
    return v

def rng(s):
    a, b = s.split(':'); return int(a, 0), int(b, 0)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('trace'); ap.add_argument('--size', type=lambda x: int(x, 0), default=0x2000)
    ap.add_argument('--word', action='store_true'); ap.add_argument('--min', type=int, default=8)
    ap.add_argument('--rise', action='append', default=[]); ap.add_argument('--fall', action='append', default=[])
    ap.add_argument('--const', action='append', default=[]); ap.add_argument('--changes', action='append', default=[])
    ap.add_argument('--show', action='append', default=[]); ap.add_argument('--frames', default=None)
    ap.add_argument('--step', type=int, default=1); ap.add_argument('--signed', action='store_true')
    a = ap.parse_args()
    snaps = load(a.trace, a.size)
    if a.show:
        f0, f1 = rng(a.frames) if a.frames else (0, len(snaps))
        for spec in a.show:
            addr, n = (spec.split(':') + ['1'])[:2]; addr = int(addr, 0); n = int(n)
            vals = [val(snaps[f], addr, n == 2, a.signed) for f in range(f0, min(f1, len(snaps)), a.step)]
            print(f'{addr:#06x}:', ' '.join(str(v) for v in vals))
        return
    width = 2 if a.word else 1
    hits = []
    for addr in range(0, a.size - width + 1):
        ok = True
        for spec, kind in [(s, 'rise') for s in a.rise] + [(s, 'fall') for s in a.fall] + \
                          [(s, 'const') for s in a.const] + [(s, 'changes') for s in a.changes]:
            f0, f1 = rng(spec)
            vs = [val(snaps[f], addr, a.word) for f in range(f0, f1)]
            if kind == 'rise': ok = all(y >= x for x, y in zip(vs, vs[1:])) and vs[-1] - vs[0] >= a.min
            elif kind == 'fall': ok = all(y <= x for x, y in zip(vs, vs[1:])) and vs[0] - vs[-1] >= a.min
            elif kind == 'const': ok = len(set(vs)) == 1
            else: ok = len(set(vs)) > 1
            if not ok: break
        if ok: hits.append(addr)
    for h in hits[:200]: print(f'{h:#06x}')
    print(f'{len(hits)} hits', file=sys.stderr)

if __name__ == '__main__':
    main()
