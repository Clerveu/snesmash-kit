"""Animated GIF from screenshots, for showing the user a feature in motion.

python tools/gif.py DIR PATTERN OUT.gif [fps] [scale]
  e.g. python tools/gif.py out/tour "t*.png" out/tour.gif 60 2
Frames are sorted by file name. Screenshot every frame for smooth motion (TOUR_SHOT_EVERY=1); fps is
the playback rate (60 = real time when every frame was captured). scale uses nearest-neighbour, so
pixels stay sharp.
"""
import glob, os, sys
from PIL import Image

d, pat, out = sys.argv[1:4]
fps = float(sys.argv[4]) if len(sys.argv) > 4 else 60
scale = int(sys.argv[5]) if len(sys.argv) > 5 else 1
frames = []
for f in sorted(glob.glob(os.path.join(d, pat))):
    try:
        im = Image.open(f).convert("RGB")
    except Exception:
        continue  # empty/partial screenshot
    if scale != 1:
        im = im.resize((im.width * scale, im.height * scale), Image.NEAREST)
    frames.append(im.convert("P", palette=Image.ADAPTIVE, colors=256))
if not frames:
    sys.exit("no frames")
frames[0].save(out, save_all=True, append_images=frames[1:], duration=max(20, round(1000 / fps)), loop=0,
               optimize=False, disposal=1)
print(len(frames), "frames ->", out)
