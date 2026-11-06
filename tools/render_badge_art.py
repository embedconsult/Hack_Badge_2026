import numpy as np
from PIL import Image
src = Image.open("/tmp/portrait.png").convert("RGB")
W, H = 960, 672
def build(side, gamma, out):
    img = src.crop((40, 20, 1214, 1194)).resize((side, side), Image.LANCZOS)
    a = np.asarray(img).astype(np.float32) / 255
    r, g, b = a[..., 0], a[..., 1], a[..., 2]
    mx, mn = a.max(-1), a.min(-1)
    sat = (mx - mn) / np.maximum(mx, 1e-3)
    # shirt: strongly red, saturated, not skin (skin has more green)
    yy = np.arange(side)[:, None] / side
    red = (r > 0.5) & (sat > 0.65) & (g < 0.25) & (b < 0.25) & (yy > 0.6)
    lum = 0.299 * r + 0.587 * g + 0.114 * b
    # background light blue -> white
    bg = (b > 0.85) & (g > 0.8) & (r < 0.75)
    lum = np.where(bg, 1.0, lum) ** gamma
    # Floyd-Steinberg to black/white on luminance
    L = lum.copy(); out_bw = np.zeros_like(L, bool)
    h, w = L.shape
    for y in range(h):
        row = L[y]
        for x in range(w):
            old = row[x]; new = 1.0 if old > 0.5 else 0.0
            out_bw[y, x] = new == 0.0
            e = old - new
            if x + 1 < w: row[x + 1] += e * 7 / 16
            if y + 1 < h:
                if x > 0: L[y + 1, x - 1] += e * 3 / 16
                L[y + 1, x] += e * 5 / 16
                if x + 1 < w: L[y + 1, x + 1] += e * 1 / 16
    canvas = np.full((H, W), 0, np.uint8)  # 0 white, 1 black, 2 red
    tile = np.where(red, 2, np.where(out_bw, 1, 0)).astype(np.uint8)
    canvas[H - side:, :side] = tile
    p = Image.fromarray(canvas, "P")
    p.putpalette([255, 255, 255, 0, 0, 0, 255, 0, 0] + [0] * 759)
    p.save(out, optimize=True, bits=2)
build(672, 1.15, "/tmp/portrait_a.png")
from PIL import ImageDraw, ImageFont
im = Image.open("/tmp/portrait_a.png")
d = ImageDraw.Draw(im)
bold = "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"
f1 = ImageFont.truetype(bold, 58); f2 = ImageFont.truetype(bold, 34)
x0 = 690
d.text((x0, 150), "Jason", font=f1, fill=1)
d.text((x0, 225), "Kridner", font=f1, fill=1)
d.rectangle((x0, 330, 940, 338), fill=2)
d.text((x0, 360), "BeagleBoard", font=f2, fill=2)
d.text((x0, 400), ".org", font=f2, fill=2)
im.save("/tmp/portrait_b.png", optimize=True, bits=2)
