"""Edit a static SNES screen as a PNG; get a live patch for lua/lib/bg_patch.lua. Game-independent.

  python tools/screen_patch.py kit   <capture dir> <out dir>
      clean.png (the screen, 1:1), palettes.png (the screen's palettes, labelled), palette.gpl
      (GIMP/Aseprite palette of every colour on the BG layers). Edit a copy of clean.png.
  python tools/screen_patch.py build <capture dir> <edited.png> <out.lua> [--preview p.png]
      Diffs the PNG against the capture, decides which layer each changed pixel goes on and which
      palette each touched 8x8 cell uses, and writes the final tiles + what the runtime must verify.
      Then re-renders the screen from those tiles: the result must equal the PNG pixel for pixel.
      Problems (colour not in a usable palette, pixel covered by a sprite...) are listed and marked in
      <edited>_problems.png; nothing is written then.

Rules the hardware imposes (docs/PLAYBOOK.md 3b): every 8x8 cell of a layer uses ONE palette (16
colours on 4bpp layers, 4 on 2bpp), colours are 15-bit (use the swatch: exact colours only), and a pixel
painted in the backdrop colour means "nothing here" (all layers transparent). Painting where a layer
in front has content takes that front pixel away (so the colour shows).
"""
import argparse, os, sys
from collections import defaultdict
from PIL import Image, ImageDraw

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import snesgfx as G  # noqa: E402


def kit(cap_dir, out):
    cap = G.Capture(cap_dir)
    os.makedirs(out, exist_ok=True)
    cap.screen.save(os.path.join(out, "clean.png"))
    # which palettes the BG layers use on screen
    used = defaultdict(int)
    for b, _ in cap.order():
        lay = cap.layer(b)
        for cy in range(lay["h"]):
            for cx in range(lay["w"]):
                w, rows, pal = cap.cell(lay, cx, cy)
                if any(any(r) for r in rows):
                    used[(b, pal)] += 1
    S = 24
    img = Image.new("RGB", (16 * S + 150, (len(used) + 1) * (S + 6) + 10), (40, 40, 40))
    d = ImageDraw.Draw(img)
    d.text((4, 4), "backdrop", fill=(255, 255, 255))
    d.rectangle([150, 2, 150 + S - 2, S], fill=cap.backdrop())
    colours = [cap.backdrop()]
    for i, (b, pal) in enumerate(sorted(used)):
        lay = cap.layer(b)
        y = (i + 1) * (S + 6) + 4
        d.text((4, y + 6), f"BG{b + 1} palette {pal} ({used[(b, pal)]} cells)", fill=(255, 255, 255))
        base = cap.palette_base(lay, pal)
        for k in range(1, 1 << lay["bpp"]):
            c = cap.color(base + k)
            d.rectangle([150 + k * S, y, 150 + k * S + S - 2, y + S - 2], fill=c)
            if c not in colours:
                colours.append(c)
    img.save(os.path.join(out, "palettes.png"))
    with open(os.path.join(out, "palette.gpl"), "w") as f:
        f.write("GIMP Palette\nName: %s\nColumns: 16\n#\n" % os.path.basename(os.path.normpath(out)))
        for c in colours:
            f.write("%3d %3d %3d\n" % c)
    print(f"kit -> {out}: clean.png, palettes.png, palette.gpl ({len(colours)} colours)")


def build(cap_dir, png, out_lua, preview=None):
    cap = G.Capture(cap_dir)
    base = cap.render()
    ed = Image.open(png).convert("RGB")
    if ed.size != (G.W, G.H):
        sys.exit(f"{png} is {ed.size[0]}x{ed.size[1]}, must be {G.W}x{G.H} (1:1 screen)")
    sp, bp, ep = cap.screen.load(), base.load(), ed.load()
    backdrop = cap.backdrop()
    problems = []  # (x, y, why)
    edits = defaultdict(dict)  # (bg, cx, cy) -> {(row, col): rgb or None (transparent)}

    def palettes_with(lay, rgb):
        return [p for p in range(8) if rgb in [cap.color(cap.palette_base(lay, p) + k) for k in range(1, 1 << lay["bpp"])]]

    changed = [(x, y) for y in range(G.H) for x in range(G.W) if ep[x, y] != sp[x, y]]
    for x, y in changed:
        c = ep[x, y]
        if bp[x, y] != sp[x, y]:
            problems.append((x, y, "covered by a sprite/effect in the capture (not a BG pixel)"))
            continue
        stack = []
        for b, p in cap.order():
            lay = cap.layer(b)
            lx, ly = cap.screen_to_layer(lay, x, y)
            w, rows, pal = cap.cell(lay, lx // 8, ly // 8)
            if ((w >> 13) & 1) == p:
                stack.append((b, lx // 8, ly // 8, ly % 8, lx % 8, rows, pal))
        if c == backdrop:  # erase: every layer transparent here
            for b, cx, cy, r, col, rows, pal in stack:
                if rows[r][col]:
                    edits[(b, cx, cy)][(r, col)] = None
            continue
        placed = False
        # where can colour c go? A cell that has art keeps its palette; an empty one can take any palette
        # that holds every colour painted into it. Prefer layers with art here (front to back), then
        # empty cells on the layer with the most colours (4bpp before 2bpp).
        def allowed(b, cx, cy, rows, pal):
            lay = cap.layer(b)
            if any(any(rr) for rr in rows):
                return {pal} & set(palettes_with(lay, c))
            ok = set(palettes_with(lay, c))
            for v in edits.get((b, cx, cy), {}).values():
                if v is not None:
                    ok &= set(palettes_with(lay, v))
            return ok
        ranked = sorted(range(len(stack)), key=lambda i: (
            0 if any(any(rr) for rr in stack[i][5]) else 1, -cap.layer(stack[i][0])["bpp"], i))
        for i in ranked:
            b, cx, cy, r, col, rows, pal = stack[i]
            if allowed(b, cx, cy, rows, pal):
                edits[(b, cx, cy)][(r, col)] = c
                for fb, fcx, fcy, fr, fc, frows, _ in stack[:i]:  # clear what's in front
                    if frows[fr][fc] or edits.get((fb, fcx, fcy), {}).get((fr, fc)) is not None:
                        edits[(fb, fcx, fcy)][(fr, fc)] = None
                placed = True
                break
        if not placed:
            problems.append((x, y, "colour #%02x%02x%02x isn't in this cell's palette on any layer here" % c))

    # resolve each touched cell: final pixels -> one palette -> tile
    cells, override = [], {}
    for (b, cx, cy), px in sorted(edits.items()):
        if not px:
            continue
        lay = cap.layer(b)
        w, rows, pal = cap.cell(lay, cx, cy)
        pb = cap.palette_base(lay, pal)
        final = [[px[(r, c)] if (r, c) in px else (cap.color(pb + rows[r][c]) if rows[r][c] else None)
                  for c in range(8)] for r in range(8)]
        need = {v for row in final for v in row if v is not None}
        choice = None
        for p in [pal] + [q for q in range(8) if q != pal]:
            entries = {}
            for k in range((1 << lay["bpp"]) - 1, 0, -1):  # first occurrence wins
                entries[cap.color(cap.palette_base(lay, p) + k)] = k
            if need <= set(entries):
                choice = (p, entries)
                break
        if not choice:
            problems.append((None, None, f"BG{b + 1} cell ({cx},{cy}): colours {sorted(need)} don't fit one palette"))
            continue
        p, entries = choice
        new_rows = [[entries[v] if v is not None else 0 for v in row] for row in final]
        orig = cap.tile_bytes(lay, w & 0x3FF)
        cells.append({"bg": b, "off": cap.map_offset(lay, cx, cy), "word": w, "hash": G.fnv1a(orig),
                      "pal": p, "tile": G.encode_tile(new_rows, lay["bpp"]), "cx": cx, "cy": cy})
        override[(b, cx, cy)] = (new_rows, p, (w >> 13) & 1)

    if not problems:
        check = cap.render(override)
        cp = check.load()
        bad = [(x, y) for y in range(G.H) for x in range(G.W) if cp[x, y] != ep[x, y] and bp[x, y] == sp[x, y]]
        for x, y in bad[:50]:
            problems.append((x, y, "re-render differs from the PNG (tool bug?)"))
    if problems:
        mark = ed.copy()
        for x, y, _ in problems:
            if x is not None:
                mark.putpixel((x, y), (255, 0, 255))
        mp = os.path.splitext(png)[0] + "_problems.png"
        mark.resize((G.W * 3, G.H * 3), Image.NEAREST).save(mp)
        print(f"{len(problems)} problem(s); marked magenta in {mp}:")
        for x, y, why in problems[:30]:
            print(f"  ({x},{y}) {why}" if x is not None else f"  {why}")
        sys.exit(1)

    if preview:
        check.resize((G.W * 3, G.H * 3), Image.NEAREST).save(preview)
    by_layer = defaultdict(list)
    for c in cells:
        by_layer[c["bg"]].append(c)
    L = ["-- GENERATED by tools/screen_patch.py from %s; do not edit." % os.path.relpath(png).replace("\\", "/"),
         "-- Live patch for lua/lib/bg_patch.lua: per BG layer, the register setup and map cells it applies",
         "-- to (map word + tile hash must match before anything is written) and each cell's final tile.",
         "return {", "  mode = %d," % cap.mode, "  layers = {"]
    for b, cs in sorted(by_layer.items()):
        lay = cap.layer(b)
        L.append("    { bg = %d, bpp = %d, chr = 0x%04X, map = 0x%04X, w = %d, h = %d, cells = {"
                 % (b, lay["bpp"], lay["chr_word"], lay["map_word"], lay["w"], lay["h"]))
        for c in cs:
            L.append('      { off = 0x%04X, word = 0x%04X, hash = 0x%08X, pal = %d, tile = "%s" }, -- (%d,%d)'
                     % (c["off"], c["word"], c["hash"], c["pal"], c["tile"].hex(), c["cx"], c["cy"]))
        L.append("    } },")
    L += ["  },", "}"]
    os.makedirs(os.path.dirname(out_lua), exist_ok=True)
    with open(out_lua, "w") as f:
        f.write("\n".join(L) + "\n")
    print(f"{len(changed)} px changed -> {len(cells)} cells on BG{', BG'.join(str(b + 1) for b in sorted(by_layer))} "
          f"-> {os.path.relpath(out_lua)}; re-render matches the PNG")


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    k = sub.add_parser("kit"); k.add_argument("cap"); k.add_argument("out")
    bd = sub.add_parser("build"); bd.add_argument("cap"); bd.add_argument("png"); bd.add_argument("out")
    bd.add_argument("--preview")
    a = ap.parse_args()
    if a.cmd == "kit":
        kit(a.cap, a.out)
    else:
        build(a.cap, a.png, a.out, a.preview)
