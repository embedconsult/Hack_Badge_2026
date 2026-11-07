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
SCALE = 1.12
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
# Local px (a single-action revolver's proportions: the barrel with the
# ejector housing about as long as frame + cylinder + grip; short rounded
# drum; S-curve from the hammer into the back strap; plow-handle grip
# angled back ~30 deg; small oval trigger guard; small hammer spur; blade
# front sight). Scaled by SCALE about the start point (frame bottom front),
# which lands on the pen's home.
strokes = []  # (name, tone, points) in drawing order (phases sort them)

def S(name, tone, pts):
    strokes.append((name, tone, [tuple(p) for p in pts]))

MZ = 596              # muzzle x
FX = 350              # frame front x
BT, BB = 226, 254     # barrel top / bottom
EB = 272              # ejector housing bottom
EJ = 556              # ejector housing front x
TS = 214              # top strap y
CX0, CX1 = 232, 336   # cylinder rear / front (drum side view)
CY0, CY1 = 214, 318   # cylinder top / bottom
CYM = (CY0 + CY1) / 2
RR = (CY1 - CY0) / 2 - 5   # rear arc half-height
RF = (CY1 - CY0) / 2 - 3   # front arc half-height

def rear_x(y):
    return CX0 - 7 * math.sqrt(max(0, 1 - ((y - CYM) / RR) ** 2))

def front_x(y):
    return CX1 + 10 * math.sqrt(max(0, 1 - ((y - CYM) / RF) ** 2))

# Frame: bottom under the cylinder (start: the pen's home), front, top strap.
fbot = cr([(FX, 312), (330, 320), (300, 323), (282, 323)], 4) + [(222, 324)]
S("frame bottom", LINE, fbot + fbot[::-1][1:])
S("frame front", LINE, [(FX, 312), (FX, TS)])
S("top strap", LINE, cr([(FX, TS), (280, TS - 1), (232, TS), (214, TS + 3)], 4))
# Small hammer spur, then the S-curve from the hammer into the back strap
# and the plow-handle grip, butt, front edge up to the guard.
ham = cr([(214, TS + 3), (206, TS - 6), (194, TS - 12), (180, TS - 10), (178, TS - 5), (188, TS - 1), (198, TS + 8), (203, TS + 22)], 4)
S("hammer", LINE, ham)
back = cr([(203, TS + 22), (196, 262), (186, 288), (166, 320), (138, 360), (106, 400), (74, 436), (58, 456), (62, 466)], 6)
butt = cr([(62, 466), (100, 470), (140, 468), (156, 462)], 4)
front = cr([(156, 462), (160, 432), (172, 396), (194, 358), (212, 336), (222, 324)], 6)
S("grip", LINE, back + butt[1:] + front[1:])
# Small oval trigger guard and a curved trigger.
guard = cr([(282, 323), (286, 346), (276, 374), (250, 386), (222, 378), (210, 356), (216, 330)], 4)
S("guard", LINE, guard)
gin = cr([(272, 323), (275, 344), (266, 366), (248, 375), (228, 369), (220, 352), (224, 330)], 4)
S("guard inner", LINE, [(272, 323)] + gin[1:])
trig = cr([(250, 323), (256, 340), (253, 356), (243, 366), (236, 364)], 3)
S("trigger", LINE, [(272, 323), (250, 323)] + trig + trig[::-1])
# Recoil shield behind the cylinder, from the top strap down to the frame.
S("shield", LINE, [(250, 323)] + cr([(224, 323), (220, 290), (218, 250), (214, TS + 3)], 4))
# Barrel, blade front sight at the muzzle, crown, ejector housing and rod.
S("barrel top", LINE, [(FX, TS), (FX, BT)] + [(MZ - 22, BT)] + cr([(MZ - 22, BT), (MZ - 20, BT - 9), (MZ - 14, BT - 12), (MZ - 9, BT - 9), (MZ - 8, BT)], 3)[1:] + [(MZ, BT)])
S("muzzle", LINE, [(MZ, BT), (MZ, BB)])
S("crown", LINE, ellipse(MZ, (BT + BB) / 2, 4, (BB - BT) / 2, -90, 270, 16))
S("barrel bottom", LINE, [(MZ, BB), (FX, BB)])
ej = [(FX + 4, BB), (FX + 4, EB), (EJ - 12, EB)] + cr([(EJ - 12, EB), (EJ - 3, EB - 4), (EJ, EB - 10), (EJ, BB)], 3)[1:]
S("ejector", LINE, ej)
S("rod", LINE, [(EJ, BB + 6), (EJ + 10, BB + 6)] + cr([(EJ + 10, BB + 6), (EJ + 14, BB + 11), (EJ + 10, BB + 16)], 3)[1:] + [(EJ, BB + 16)])
# Cylinder: short drum; bulging bottom edge, convex front face, rear edge
# curving into the frame (its top runs along the top strap).
rear = ellipse(CX0, CYM, 7, RR, 270, 90, 14)          # top -> bottom, bulging left
bot = cr([(CX0 + 2, CY1 - 4), (CX0 + 22, CY1), (CX1 - 22, CY1), (CX1 - 2, CY1 - 4)], 5)
frnt = ellipse(CX1, CYM, 10, RF, 90, -90, 14)         # bottom -> top, bulging right
top = cr([(CX0 + 2, CY0 + 5), (CX0 + 22, CY0 + 1), (CX1 - 22, CY0 + 1), (CX1 - 2, CY0 + 4)], 5)
rear = ellipse(CX0, CYM, 7, RR, -90, -270, 14)        # top -> bottom via the left
S("cylinder", LINE, [(CX0, TS)] + rear + bot[1:] + frnt[1:] + top[::-1][1:] + [(CX0, TS)])
# Grip wood panel: inset from the grip edges, top below the frame line.
GB = resample([p for p in back if p[1] >= 300], 40)
GF = resample(front[::-1], 40)
GF = [p for p in GF]
NB = [lerp(GB[k], GF[k], 0.14) for k in range(41)]
NF = [lerp(GB[k], GF[k], 0.86) for k in range(41)]
S("panel", LINE, [GB[0]] + NB + NF[::-1] + [NB[0]])
for i, (f, w, ph) in enumerate([(0.18, 2.2, 0.0), (0.34, 2.8, 1.3), (0.5, 2.4, 2.1), (0.66, 2.0, 0.7), (0.82, 1.5, 2.9)]):
    pts = []
    for k in range(41):
        g = f + (0.04 * math.sin(2 * math.pi * (w * k / 40) + ph) if 0 < k < 40 else 0)
        pts.append(lerp(NB[k], NF[k], g))
    S("grain %d" % i, GRAIN, pts[::-1] if i % 2 else pts)
S("knot", GRAIN, [lerp(NB[22], NF[22], 0.34)] + ellipse(*lerp(NB[24], NF[24], 0.42), 6, 3.5, 200, 560, 14))
# Grip screw.
S("screw", MID, [lerp(NB[8], NF[8], 0.5)] + ellipse(*lerp(NB[8], NF[8], 0.56), 4, 4, 180, 540, 12))
# Hammer spur checkering.
sp_o = resample(cr([(206, TS - 6), (194, TS - 12), (182, TS - 10)], 6), 5)
sp_i = resample(cr([(198, TS + 8), (188, TS - 1), (179, TS - 5)], 6), 5)
chk = [sp_o[0]]
for k in range(1, 5):
    chk += [sp_o[k], sp_i[k], sp_o[k]]
S("checkering", MID, chk)
# Flutes: lens-shaped grooves following the drum. A flute at angle a
# around the axis sits at y = CYM - R sin(a), foreshortened by cos(a).
R = (CY1 - CY0) / 2 - 8
for a in (-50, -17, 17, 50):
    yc = CYM - R * math.sin(math.radians(a))
    h = 8 * math.cos(math.radians(a))
    xa, xb = CX0 + 4, CX1 - 14
    bow = 3 * math.sin(math.radians(a))
    ts = [k / 10 for k in range(11)]
    up = [(xa + (xb - xa) * t, yc - (h + bow) * math.sin(math.pi * t)) for t in ts]
    dn = [(xa + (xb - xa) * t, yc + (h - bow) * math.sin(math.pi * t)) for t in ts]
    S("flute %d" % a, MID, [(rear_x(yc), yc)] + up + dn[::-1] + [(rear_x(yc), yc)])
# Chamber mouths on the front face.
for yc in (CYM - 26, CYM + 26):
    fx = front_x(yc)
    S("chamber %d" % yc, MID, ellipse(fx - 4, yc, 4, 8, 0, 360, 12))
S("ejector line", MID, [(EJ, BB), (FX + 4, BB), (FX + 4, (BB + EB) / 2), (EJ - 6, (BB + EB) / 2), (FX + 4, (BB + EB) / 2), (FX + 4, BB)])
# Shading (light single-pass ink; density = tone, crossings darker).
S("barrel hatch", LIGHT, spikes(BB, EJ + 18, MZ - 6, 5, 6, -10))
S("ejector hatch", LIGHT, [(EJ - 12, EB)] + spikes(EB, FX + 12, EJ - 16, 6, 6, -9))
def contour(edge, dy, flip):
    pts = sorted((x, y + dy) for x, y in resample(edge, 12))
    pts = [(rear_x(pts[0][1]), pts[0][1])] + pts[1:-1] + [(front_x(pts[-1][1]), pts[-1][1])]
    return pts[::-1] if flip else pts
for i, off in enumerate((3, 6, 10)):
    S("drum top %d" % off, LIGHT, contour(top, off, i % 2 == 0))
for i, off in enumerate((3, 5, 8, 12)):
    S("drum bottom %d" % off, LIGHT, contour(bot, -off, i % 2 == 1))
S("drum shadow", LIGHT, [(CX0 + 22, CY1)] + spikes(CY1, CX0 + 22, CX1 - 22, 5, 3, -11))
S("guard shade", LIGHT, spikes_on(gin, 1, 6, (248, 345), every=1))
S("barrel cross", LIGHT, spikes(BB, EJ + 22, MZ - 6, 5, -6, -10))
S("ejector cross", LIGHT, [(EJ - 12, EB)] + spikes(EB, FX + 18, EJ - 16, 6, -6, -9))
S("guard cross", LIGHT, spikes_on(gin[::-1], 1, 9, (248, 350), every=2))
gbs = resample([p for p in back if p[1] >= 300], 26)
S("grip shade", LIGHT, [gbs[0]] + spikes_on(gbs, 1, 8, (260, 420), every=1))

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
