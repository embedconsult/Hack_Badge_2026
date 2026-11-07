#!/usr/bin/env python3
"""Generate Sketch's "Quick draw" table (QD_PTS / QD_N in firmware/src/main.cr).

    python3 crystal/tools/gen_quickdraw.py [--preview out.png] [--write]

Our own six-shooter (muzzle right, grip lower left), built from curve
primitives and drawn as ONE continuous Etch-a-Sketch path. Tone comes from
the firmware's incremental ink (UPD_INK): every ink pull a pixel is touched
in darkens it one step (1 pass = light grey ... 5 passes = black, capped,
never lighter). So each stroke has a tone class = how many pulls trace it:

    LIGHT  1 pass   soft hatching (barrel underside, cylinder shadow, guard)
    MID    2 passes denser hatching, flutes, hammer checkering
    GRAIN  3 passes the grip's wood grain
    LINE   5 passes outlines

Pull plan (a pull break in the table = the firmware runs one ink pull):
  reveal  everything once, in drawing order, split into REVEAL_PULLS
          chunks so the gun visibly builds up (light tones first: every
          stroke starts at 1 pass);
  then    MID+GRAIN+LINE, GRAIN+LINE, LINE, LINE: one pull each.
Moves between strokes run along outlines already drawn (they end black
anyway), so hatching never picks up extra passes from travel.

Table format: 6 hex digits per point (x, y: 3 digits each, screen pixels);
"FFFFFF" = run an ink pull here. The path starts and ends at the pen's home
(centre of the pen area), so no stray line joins it to the pen.
"""
import heapq, math, re, sys

LIGHT, MID, GRAIN, LINE = 1, 2, 3, 5
REVEAL_PULLS = 9
SCALE = 0.92
OFFSET = 2.0                      # second outline edge, px (local)
HOME = (479, 310)                 # Sketch blank(): centre of the pen area
PEN = (134, 123, 824, 498)        # X_MIN, PEN_Y_MIN, X_MAX, PEN_Y_MAX

# ---- primitives (local coordinates, px) --------------------------------------

def cr(pts, n=6, closed=False):
    """Catmull-Rom spline through pts."""
    P = list(pts)
    if closed:
        P = [P[-1]] + P + [P[0], P[1]]
    else:
        P = [P[0]] + P + [P[-1]]
    out = [P[1]]
    for i in range(1, len(P) - 2):
        p0, p1, p2, p3 = P[i - 1], P[i], P[i + 1], P[i + 2]
        for k in range(1, n + 1):
            t = k / n
            out.append(tuple(0.5 * (2 * p1[j] + (-p0[j] + p2[j]) * t
                                    + (2 * p0[j] - 5 * p1[j] + 4 * p2[j] - p3[j]) * t * t
                                    + (-p0[j] + 3 * p1[j] - 3 * p2[j] + p3[j]) * t ** 3) for j in range(2)))
    return out

def ellipse(cx, cy, rx, ry, a0=0, a1=360, n=24):
    return [(cx + rx * math.cos(math.radians(a0 + (a1 - a0) * k / n)),
             cy + ry * math.sin(math.radians(a0 + (a1 - a0) * k / n))) for k in range(n + 1)]

def lerp(a, b, f):
    return (a[0] + (b[0] - a[0]) * f, a[1] + (b[1] - a[1]) * f)

def resample(pl, n):
    """n+1 points evenly spaced along polyline pl."""
    L = [0.0]
    for a, b in zip(pl, pl[1:]):
        L.append(L[-1] + math.dist(a, b))
    out, j = [], 0
    for k in range(n + 1):
        s = L[-1] * k / n
        while j < len(pl) - 2 and L[j + 1] < s:
            j += 1
        seg = L[j + 1] - L[j] or 1
        out.append(lerp(pl[j], pl[j + 1], (s - L[j]) / seg))
    return out

def spikes(anchor, x0, x1, step, dx, dy, back=True):
    """Hatching along a horizontal anchor line: walk the anchor, at every
    step go (dx, dy) out and back (one pull = one pass however often)."""
    y = anchor
    pts = [(x0, y)]
    x = x0
    while x <= x1:
        pts += [(x, y), (x + dx, y + dy), (x, y)]
        x += step
    return pts

def spikes_on(curve, step_pts, length, inward, every=1):
    """Hatching along a curve: short strokes towards `inward` and back."""
    out = []
    for i, p in enumerate(curve):
        out.append(p)
        if i % every == 0 and 0 < i < len(curve) - 1:
            d = math.dist(p, inward) or 1
            q = (p[0] + (inward[0] - p[0]) * length / d, p[1] + (inward[1] - p[1]) * length / d)
            out += [q, p]
    return out

# ---- the drawing ---------------------------------------------------------------
strokes = []  # (name, tone, points) in reveal order

def S(name, tone, pts):
    strokes.append((name, tone, [tuple(p) for p in pts]))

# Hammer: spur pointing back and up from the top strap, with checkering.
ham_out = cr([(214, 90), (210, 76), (200, 64), (186, 56), (176, 56), (174, 62), (184, 68), (194, 80), (200, 98)], 4)
# Top strap over the cylinder to the barrel; barrel with rib and sight.
# Recoil shield (barrel/frame join) curving up the front of the frame.
shield = cr([(318, 86), (312, 112), (316, 150), (320, 190)], 5)
S("frame bottom", LINE, [(320, 190), (226, 190), (320, 190)]) # starts at the pen's home
S("shield", LINE, shield[::-1])
S("top strap", LINE, [(318, 86), (214, 90)])
S("hammer", LINE, ham_out)
S("rib", LINE, [(318, 86), (326, 86), (326, 88), (520, 88), (532, 75), (546, 75), (550, 88), (556, 88), (556, 98)])
S("barrel top", LINE, [(556, 98), (318, 98)])
S("rib back", LINE, [(318, 98), (318, 86)])
S("muzzle", LINE, [(556, 98), (556, 124)])
S("muzzle crown", LINE, ellipse(556, 111, 4, 13, -90, 270, 16))
S("barrel bottom", LINE, [(556, 124), (330, 124)])
# Ejector housing under the barrel, rounded front, rod knob.
ej = [(330, 124), (330, 146), (456, 146)] + cr([(456, 146), (468, 142), (472, 133), (472, 124)], 3)[1:]
S("ejector", LINE, ej)
S("rod", LINE, [(472, 130), (484, 130)] + cr([(484, 130), (488, 135), (484, 140)], 3)[1:] + [(472, 140)])
S("ejector back", LINE, [(472, 124), (330, 124)])
# Barrel underside shading: light hatch on the barrel, mid near the edge.
S("barrel hatch", LIGHT, spikes(124, 478, 550, 6, 7, -12))
S("barrel hatch dark", MID, spikes(124, 481, 547, 6, 3, -6))
S("ejector hatch", LIGHT, [(456, 146)] + spikes(146, 340, 452, 6, 6, -9))
S("rib line", MID, [(452, 146), (456, 146), (468, 142), (472, 133), (472, 124), (330, 124), (330, 135), (460, 135), (330, 135), (330, 124)])
# Hammer spur checkering: short strokes across the spur, there and back.
sp_o = resample(cr([(200, 64), (186, 56), (176, 56)], 6), 6)
sp_i = resample(cr([(194, 80), (184, 68), (174, 62)], 6), 6)
chk = [sp_o[0]]
for k in range(1, 6):
    chk += [sp_o[k], sp_i[k], sp_o[k]]
S("checkering", MID, chk)
# Cylinder: rounded box, flutes (open U slots from the rear edge),
# shadow hatch along the bottom, front chamber arcs.
cyl = cr([(236, 96), (304, 96), (312, 104), (313, 140), (312, 176), (304, 184), (236, 184), (227, 176), (226, 140), (227, 104)], 4, closed=True)
k = min(range(len(cyl)), key=lambda i: math.dist(cyl[i], (304, 96)))
cyl = cyl[k:] + cyl[1:k + 1]
S("cylinder", LINE, [(318, 98), (312, 96)] + cyl)
for yc in (114, 140, 166):
    S("flute %d" % yc, MID, [(226, yc - 7), (290, yc - 7)] + ellipse(290, yc, 7, 7, -90, 90, 8)[1:] + [(226, yc + 7)] + [(226, yc - 7)])
S("cylinder shadow", LIGHT, [(236, 184)] + spikes(184, 236, 300, 4, 3, -9))
S("cylinder shadow dark", MID, [(238, 184)] + spikes(184, 238, 298, 4, 1, -4))
for yc in (110, 140, 170):
    S("chamber %d" % yc, MID, [(313, yc - 12)] + ellipse(313, yc, 5, 12, -90, 90, 8)[1:])
# Frame below the cylinder, trigger guard, trigger.
guard = cr([(292, 190), (294, 214), (280, 238), (252, 247), (228, 238), (218, 214), (220, 190)], 4)
S("guard", LINE, [(320, 190), (292, 190)] + guard)
S("guard inner", LINE, cr([(282, 190), (283, 210), (272, 230), (252, 237), (234, 230), (228, 212), (229, 190)], 4))
trig = cr([(262, 190), (266, 204), (263, 220), (254, 230), (246, 229)], 3)
S("trigger", LINE, [(229, 190), (262, 190)] + trig + trig[::-1])
# Guard interior shading: hatch from the inner guard towards its centre.
gin = cr([(282, 190), (283, 210), (272, 230), (252, 237), (234, 230), (228, 212), (229, 190)], 4)
S("guard shade", LIGHT, spikes_on(gin, 1, 7, (256, 205), every=1))
# Grip: outline (back edge from the hammer, butt, front edge to the guard),
# an inner panel and flowing wood grain between the panel's sides.
gb = cr([(200, 98), (186, 130), (162, 175), (132, 228), (104, 280), (86, 318), (86, 340), (102, 354)], 6)
gf = cr([(220, 190), (212, 214), (196, 250), (180, 290), (170, 325), (160, 350)], 6)
S("grip back", LINE, [(214, 90), (200, 98)] + gb + [(130, 358), (160, 350)])
S("grip front", LINE, gf[::-1])
S("frame rear", LINE, [(220, 190), (217, 140), (214, 90)])
pb = cr([(204, 124), (186, 164), (160, 212), (134, 262), (112, 304), (106, 332)], 6)
pf = cr([(212, 168), (204, 200), (190, 238), (176, 276), (164, 310), (152, 338)], 6)
S("panel", LINE, [(216, 124), (204, 124)] + pb + [(152, 338)] + pf[::-1] + [(204, 124)])
NB, NF = resample(pb, 40), resample(pf, 40)
for i, (f, w, ph) in enumerate([(0.2, 2.2, 0.0), (0.38, 2.8, 1.3), (0.56, 2.4, 2.1), (0.74, 2.0, 0.7), (0.88, 1.5, 2.9)]):
    pts = []
    for k in range(41):
        t = k / 40
        g = f + (0.05 * math.sin(2 * math.pi * (w * t) + ph) if 0 < k < 40 else 0)
        pts.append(lerp(NB[k], NF[k], g))
    if i % 2:
        pts = pts[::-1]
    S("grain %d" % i, GRAIN, pts)
# A knot in the grain.
S("knot", GRAIN, [lerp(NB[20], NF[20], 0.38)] + ellipse(*lerp(NB[22], NF[22], 0.47), 7, 4, 200, 560, 14))

# Cross-hatching (second direction, later in the shading phase): where it
# crosses the first hatch the pixels get a second pass, i.e. darker grey.
S("barrel cross", LIGHT, spikes(124, 484, 550, 6, -7, -12))
S("ejector cross", LIGHT, [(452, 146)] + spikes(146, 346, 452, 6, -6, -9))
S("cylinder cross", LIGHT, [(300, 184)] + spikes(184, 242, 300, 6, -6, -10))
S("guard cross", LIGHT, spikes_on(gin[::-1], 1, 11, (256, 212), every=2))
# Grip shadow along its back edge: short hatches into the grip.
gbs = resample(gb, 34)
S("grip shade", LIGHT, [(200, 98)] + spikes_on(gbs, 1, 9, (260, 260), every=1))

# ---- graph routing -------------------------------------------------------------

def dense(pl, step=3.0):
    out = [pl[0]]
    for a, b in zip(pl, pl[1:]):
        n = max(1, int(math.dist(a, b) / step))
        out += [lerp(a, b, k / n) for k in range(1, n + 1)]
    return out

class Graph:
    def __init__(self):
        self.adj = {}
        self.nodes = []

    def key(self, p):
        return (round(p[0] * 2) / 2, round(p[1] * 2) / 2)

    def add(self, pl):
        d = [self.key(p) for p in dense(pl)]
        for a, b in zip(d, d[1:]):
            self.edge(a, b)
        for p in d:
            if p not in self.adj:
                self.adj[p] = {}
            for q in self.nodes:          # junctions: points within 2.5 px meet
                if q != p and abs(q[0] - p[0]) <= 2.5 and abs(q[1] - p[1]) <= 2.5:
                    self.edge(p, q)
            self.nodes.append(p)

    def edge(self, a, b):
        w = math.dist(a, b)
        self.adj.setdefault(a, {})[b] = w
        self.adj.setdefault(b, {})[a] = w

    def nearest(self, p):
        return min(self.adj, key=lambda q: math.dist(q, p))

    def route(self, a, b):
        a, b = self.nearest(a), self.nearest(b)
        dist, prev, h = {a: 0}, {}, [(0, a)]
        while h:
            d, u = heapq.heappop(h)
            if u == b:
                break
            if d > dist.get(u, 1e18):
                continue
            for v, w in self.adj[u].items():
                if d + w < dist.get(v, 1e18):
                    dist[v] = d + w
                    prev[v] = u
                    heapq.heappush(h, (d + w, v))
        if b not in dist:
            return None
        out = [b]
        while out[-1] != a:
            out.append(prev[out[-1]])
        return out[::-1]

def offset(pl, d):
    """pl shifted d px along its left normal (a second, hand-inked edge)."""
    out = []
    for i, p in enumerate(pl):
        a = pl[max(0, i - 1)]
        b = pl[min(len(pl) - 1, i + 1)]
        L = math.dist(a, b) or 1
        out.append((p[0] - (b[1] - a[1]) / L * d, p[1] + (b[0] - a[0]) / L * d))
    return out

PHASE = {LINE: 0, MID: 1, GRAIN: 1, LIGHT: 2}
PULLS = (4, 5, 5) # outline, details (+ second outline edges), shading

def build():
    """Every pull adds new line work: outlines, then details with a second
    offset edge on every outline, then hatching / cross-hatching."""
    g = Graph()
    order = []
    for ph in range(3):
        order.append([(n, t, pts) for n, t, pts in strokes if PHASE[t] == ph])
    order[1] = [(n + " edge", LINE, offset(pts, OFFSET)) for n, t, pts in order[0]] + order[1]
    # interleave the edges with the details so both grow across the phase
    edges = [x for x in order[1] if x[0].endswith(" edge")]
    dets = [x for x in order[1] if not x[0].endswith(" edge")]
    mixed = []
    while edges or dets:
        if edges:
            mixed.append(edges.pop(0))
        if dets:
            mixed.append(dets.pop(0))
    order[1] = mixed
    path, bridges = [], []
    for ph, group in enumerate(order):
        seg = []
        for name, tone, pts in group:
            if seg or path:
                here = seg[-1] if seg else [p for p in path if p is not None][-1]
                if math.dist(here, pts[0]) >= 1.5:
                    r = g.route(here, pts[0]) if g.adj else None
                    if r is None or math.dist(r[-1], pts[0]) > 3 or math.dist(r[0], here) > 3:
                        bridges.append((name, here, pts[0]))
                    else:
                        seg.extend(r[1:])
            seg.extend(pts)
            if tone in (LINE, GRAIN):
                g.add(pts)
        # split this phase into PULLS[ph] chunks of equal drawn length
        L = [0.0]
        for a, b in zip(seg, seg[1:]):
            L.append(L[-1] + math.dist(a, b))
        n = PULLS[ph]
        marks = set(next(i for i, s in enumerate(L) if s >= L[-1] * k / n) for k in range(1, n))
        for i, p in enumerate(seg):
            path.append(p)
            if i in marks:
                path.append(None)
        path.append(None)
    return path, bridges

def main():
    path, bridges = build()
    # scale, then translate so the first point is the pen's home
    first = path[0]
    def tx(p):
        return (round(HOME[0] + (p[0] - first[0]) * SCALE), round(HOME[1] + (p[1] - first[1]) * SCALE))
    pts = [None if p is None else tx(p) for p in path]
    # back home at the end (along the outline)
    # drop repeats and collinear points (Bresenham draws the same pixels)
    clean = []
    for p in pts:
        if p is not None and clean and clean[-1] == p:
            continue
        clean.append(p)
    def collinear(a, b, c):
        return a and b and c and (b[0] - a[0]) * (c[1] - a[1]) == (b[1] - a[1]) * (c[0] - a[0]) and \
            min(a[0], c[0]) <= b[0] <= max(a[0], c[0]) and min(a[1], c[1]) <= b[1] <= max(a[1], c[1])
    out = []
    for p in clean:
        while len(out) >= 2 and p is not None and collinear(out[-2], out[-1], p):
            out.pop()
        out.append(p)
    xs = [p[0] for p in out if p]
    ys = [p[1] for p in out if p]
    print("points %d, pulls %d, bbox x %d..%d y %d..%d, bridges %d" % (
        len(out), out.count(None), min(xs), max(xs), min(ys), max(ys), len(bridges)), file=sys.stderr)
    for n, a, b in bridges:
        print("  bridge to %s: %s -> %s (%.1f px)" % (n, a, b, math.dist(a, b)), file=sys.stderr)
    assert PEN[0] <= min(xs) and max(xs) <= PEN[2] and PEN[1] <= min(ys) and max(ys) <= PEN[3], "outside the pen area"
    table = "".join("FFFFFF" if p is None else "%03X%03X" % p for p in out)
    if "--preview" in sys.argv:
        preview(out, sys.argv[sys.argv.index("--preview") + 1])
    if "--write" in sys.argv:
        f = __file__.rsplit("/", 2)[0] + "/firmware/src/main.cr"
        s = open(f).read()
        s = re.sub(r'QD_PTS = "[0-9A-F]*"', 'QD_PTS = "%s"' % table, s)
        s = re.sub(r'QD_N     = \d+ #', 'QD_N     = %d #' % len(out), s)
        open(f, "w").write(s)
        print("wrote", f, file=sys.stderr)
    return out

def preview(out, fn):
    """Simulates the ink: per-pixel pass counts (one per pull touched)."""
    from PIL import Image, ImageDraw
    W, H = 960, 672
    passes = [[0] * W for _ in range(H)]
    cur = Image.new("1", (W, H), 0)
    d = ImageDraw.Draw(cur)
    pen = HOME
    def flush():
        px = cur.load()
        for y in range(H):
            for x in range(W):
                if px[x, y]:
                    passes[y][x] = min(5, passes[y][x] + 1)
        d.rectangle((0, 0, W, H), fill=0)
    for p in out:
        if p is None:
            flush()
            continue
        d.line([pen, p], fill=1, width=3)
        pen = p
    im = Image.new("L", (W, H), 255)
    px = im.load()
    for y in range(H):
        for x in range(W):
            px[x, y] = 255 - passes[y][x] * 45
    im.crop((PEN[0] - 4, PEN[1] - 4, PEN[2] + 4, PEN[3] + 4)).save(fn)

if __name__ == "__main__":
    main()
