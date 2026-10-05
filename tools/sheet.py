"""Contact sheet: python tools/sheet.py DIR PATTERN OUT [cols] [scale]  (labels each tile with its file name)."""
import sys, glob, os
from PIL import Image, ImageDraw
d, pat, out = sys.argv[1:4]
cols = int(sys.argv[4]) if len(sys.argv) > 4 else 6
scale = float(sys.argv[5]) if len(sys.argv) > 5 else 1.0
fs, ims = [], []
for f in sorted(glob.glob(os.path.join(d, pat))):
    try:
        ims.append(Image.open(f).convert('RGB')); fs.append(f)
    except Exception:
        pass  # empty/partial screenshot (e.g. taken before the first frame)
w, h = int(ims[0].width * scale), int(ims[0].height * scale)
rows = (len(ims) + cols - 1) // cols
s = Image.new('RGB', (w * cols, h * rows)); dr = ImageDraw.Draw(s)
for i, (f, im) in enumerate(zip(fs, ims)):
    x, y = (i % cols) * w, (i // cols) * h
    s.paste(im.resize((w, h), Image.NEAREST), (x, y))
    dr.text((x + 3, y + 3), os.path.splitext(os.path.basename(f))[0], fill=(255, 255, 0))
s.save(out)
print(len(fs), 'frames ->', out)
