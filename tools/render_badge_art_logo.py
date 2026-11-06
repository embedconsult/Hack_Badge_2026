import numpy as np, subprocess
from PIL import Image, ImageDraw, ImageFont
W, H, SIDE = 960, 672, 600
base = Image.open("/tmp/portrait_a.png")  # rebuilt below at SIDE
exec(open("/tmp/render.py").read().split("build(672")[0])  # reuse build()
build(SIDE, 1.15, "/tmp/portrait_640.png")
im = Image.open("/tmp/portrait_640.png")
im = im.crop((0, 0, W, H))
# official logo -> 3 inks
LW = 340
subprocess.run(["rsvg-convert", "-w", str(LW), "-b", "white", "/tmp/bb.svg", "-o", "/tmp/bb_s.png"], check=True)
lg = np.asarray(Image.open("/tmp/bb_s.png").convert("RGB")).astype(int)
ref = {0: (255,255,255), 1: (0x23,0x1f,0x20), 3: (0xa9,0x7f,0x2c), 4: (0x88,0x63,0x27), 2: (0xf2,0x63,0x22), 5: (0xa7,0x46,0x24)}
keys = list(ref); cols = np.array([ref[k] for k in keys])
d = ((lg[:, :, None, :] - cols[None, None]) ** 2).sum(-1)
idx = np.array(keys)[d.argmin(-1)]
yy, xx = np.indices(idx.shape)
chk = ((yy + xx) % 2)
ink = np.select([idx == 0, idx == 2, idx == 5, (idx == 3) | (idx == 4)], [0, 2, 2, chk], 1).astype(np.uint8)
a = np.asarray(im).copy()
x0, y0 = W - LW - 8, 500
a[y0:y0 + ink.shape[0], x0:x0 + LW] = ink
im = Image.fromarray(a, "P"); im.putpalette([255,255,255, 0,0,0, 255,0,0] + [0]*759)
dr = ImageDraw.Draw(im)
f1 = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf", 64)
dr.text((x0, 190), "Jason", font=f1, fill=1)
dr.text((x0, 270), "Kridner", font=f1, fill=1)
im.save("/tmp/portrait_c.png", optimize=True, bits=2)
