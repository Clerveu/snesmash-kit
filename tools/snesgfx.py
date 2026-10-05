"""SNES graphics helpers for offline tools (game-independent).

A "capture" is a directory written by lua/lib/capture.lua at startFrame:
  vram.bin (64 KB), cgram.bin (512 B), oam.bin (544 B), ppu.txt (emu.getState() "ppu.*" keys), screen.png
Everything here works from a capture: decode/encode tiles, palettes, and a background renderer
(modes 0 and 1, all map sizes, 8x8 tiles, scroll, priorities; no OBJ, windows or colour math) whose output
is checked against the capture's screenshot, so tools know exactly which pixels they understand.
"""
import os
from PIL import Image

W, H = 256, 224
BPP = {0: (2, 2, 2, 2), 1: (4, 4, 2, None)}  # bits per pixel of BG1-4 per mode


def bgr555_to_rgb(v):
    r, g, b = v & 31, (v >> 5) & 31, (v >> 10) & 31
    return (r << 3 | r >> 2, g << 3 | g >> 2, b << 3 | b >> 2)  # Mesen's screenshot conversion


def rgb_to_bgr555(c):
    return (c[0] >> 3) | ((c[1] >> 3) << 5) | ((c[2] >> 3) << 10)


def fnv1a(data):
    """32-bit FNV-1a (lua/lib/bg_patch.lua computes the same in Lua)."""
    h = 2166136261
    for x in data:
        h = ((h ^ x) * 16777619) & 0xFFFFFFFF
    return h


def decode_tile(data, bpp):
    """bytes (8*bpp) -> 8 rows of 8 colour indices."""
    rows = []
    for r in range(8):
        row = []
        for c in range(8):
            s, v = 7 - c, 0
            for plane in range(bpp):
                byte = data[(plane // 2) * 16 + r * 2 + (plane & 1)]
                v |= ((byte >> s) & 1) << plane
            row.append(v)
        rows.append(row)
    return rows


def encode_tile(rows, bpp):
    out = bytearray(8 * bpp)
    for r in range(8):
        for c in range(8):
            v, bit = rows[r][c], 1 << (7 - c)
            for plane in range(bpp):
                if v & (1 << plane):
                    out[(plane // 2) * 16 + r * 2 + (plane & 1)] |= bit
    return bytes(out)


def flip(rows, word):
    if word & 0x4000:
        rows = [row[::-1] for row in rows]
    if word & 0x8000:
        rows = rows[::-1]
    return rows


class Capture:
    def __init__(self, d):
        self.dir = d
        self.vram = open(os.path.join(d, "vram.bin"), "rb").read()
        self.cg = open(os.path.join(d, "cgram.bin"), "rb").read()
        self.ppu = {}
        for line in open(os.path.join(d, "ppu.txt")):
            if "=" in line:
                k, v = line.strip().split("=", 1)
                self.ppu[k] = {"true": True, "false": False}.get(v, v)
                if isinstance(self.ppu[k], str):
                    try:
                        self.ppu[k] = int(v)
                    except ValueError:
                        pass
        self.screen = Image.open(os.path.join(d, "screen.png")).convert("RGB")
        self._cells, self._layers = {}, {}
        self.mode = self.ppu["ppu.bgMode"]
        if self.mode not in BPP:
            raise ValueError(f"BG mode {self.mode} not supported (modes 0 and 1 only)")

    def color(self, i):
        return bgr555_to_rgb(self.cg[i * 2] | (self.cg[i * 2 + 1] << 8))

    def backdrop(self):
        return self.color(0)

    # ------------------------------------------------------------ layers
    def layer(self, i):
        """Register setup of BG(i+1), byte addresses."""
        if i not in self._layers:
            self._layers[i] = self._layer(i)
        return self._layers[i]

    def _layer(self, i):
        k = f"ppu.layers[{i}]."
        bpp = BPP[self.mode][i]
        if bpp is None:
            return None
        if self.ppu.get(k + "largeTiles"):
            raise ValueError(f"BG{i + 1} uses 16x16 tiles (not supported)")
        return {
            "bg": i, "bpp": bpp, "chr": self.ppu[k + "chrAddress"] * 2, "map": self.ppu[k + "tilemapAddress"] * 2,
            "chr_word": self.ppu[k + "chrAddress"], "map_word": self.ppu[k + "tilemapAddress"],
            "w": 64 if self.ppu.get(k + "doubleWidth") else 32, "h": 64 if self.ppu.get(k + "doubleHeight") else 32,
            "hs": self.ppu.get(k + "hscroll", 0), "vs": self.ppu.get(k + "vscroll", 0),
            "on": bool(self.ppu["ppu.mainScreenLayers"] & (1 << i)),
        }

    def palette_base(self, lay, pal):
        if self.mode == 0:
            return lay["bg"] * 32 + pal * 4
        return pal * (1 << lay["bpp"])

    def map_offset(self, lay, cx, cy):
        """Byte offset (from the map base) of map cell (cx, cy) in layer coordinates."""
        cx, cy = cx % lay["w"], cy % lay["h"]
        sc = (cx // 32) + ((cy // 32) * (2 if lay["w"] == 64 else 1))
        return sc * 0x800 + ((cy % 32) * 32 + (cx % 32)) * 2

    def map_word(self, lay, cx, cy):
        a = lay["map"] + self.map_offset(lay, cx, cy)
        return self.vram[a] | (self.vram[a + 1] << 8)

    def tile_bytes(self, lay, n):
        size = 8 * lay["bpp"]
        a = (lay["chr"] + n * size) & 0xFFFF
        return self.vram[a:a + size]

    def cell(self, lay, cx, cy):
        """(map word, 8x8 indices with flips applied, palette) of a layer cell."""
        key = (lay["bg"], cx % lay["w"], cy % lay["h"])
        if key not in self._cells:
            w = self.map_word(lay, cx, cy)
            self._cells[key] = (w, flip(decode_tile(self.tile_bytes(lay, w & 0x3FF), lay["bpp"]), w), (w >> 10) & 7)
        return self._cells[key]

    def screen_to_layer(self, lay, x, y):
        """Screen pixel -> layer pixel. BG line y appears on screen line y - 1 (vscroll 0)."""
        return (x + lay["hs"]) % (lay["w"] * 8), (y + 1 + lay["vs"]) % (lay["h"] * 8)

    # ------------------------------------------------------------ priorities
    def order(self):
        """Front-to-back list of (bg index, tile priority) for the enabled BG layers (OBJ omitted)."""
        if self.mode == 0:
            seq = [(0, 1), (1, 1), (0, 0), (1, 0), (2, 1), (3, 1), (2, 0), (3, 0)]
        elif self.ppu.get("ppu.mode1Bg3Priority"):
            seq = [(2, 1), (0, 1), (1, 1), (0, 0), (1, 0), (2, 0)]
        else:
            seq = [(0, 1), (1, 1), (0, 0), (1, 0), (2, 1), (2, 0)]
        return [(b, p) for b, p in seq if self.layer(b) and self.layer(b)["on"]]

    def layers_at(self, x, y):
        """Front-to-back list of (bg, prio, colour index, palette, cell x, cell y, map word) at a screen
        pixel, every enabled layer (also transparent ones, index 0)."""
        out = []
        for b, p in self.order():
            lay = self.layer(b)
            lx, ly = self.screen_to_layer(lay, x, y)
            cx, cy = lx // 8, ly // 8
            w, px, pal = self.cell(lay, cx, cy)
            if ((w >> 13) & 1) != p:
                continue
            out.append((b, p, px[ly % 8][lx % 8], pal, cx, cy, w))
        return out

    def render(self, override=None):
        """Screen image from the BG layers. override: {(bg, cx, cy): (rows, palette, prio)} replaces cells."""
        img = Image.new("RGB", (W, H))
        pix = img.load()
        order = self.order()
        lays = {b: self.layer(b) for b, _ in order}
        for y in range(H):
            for x in range(W):
                col = self.backdrop()
                for b, p in order:
                    lay = lays[b]
                    lx, ly = self.screen_to_layer(lay, x, y)
                    cx, cy = lx // 8, ly // 8
                    if override and (b, cx, cy) in override:
                        rows, pal, prio = override[(b, cx, cy)]
                    else:
                        w, rows, pal = self.cell(lay, cx, cy)
                        prio = (w >> 13) & 1
                    if prio != p:
                        continue
                    v = rows[ly % 8][lx % 8]
                    if v:
                        col = self.color(self.palette_base(lay, pal) + v)
                        break
                pix[x, y] = col
        return img
