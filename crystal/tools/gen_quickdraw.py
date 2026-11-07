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
SCALE = 0.42
JUNC = 4.0                        # points this close (local) meet
OFFSET = 4.5                      # second outline edge, px (local)
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

def dense(pl, step=3.0):
    out = [pl[0]]
    for a, b in zip(pl, pl[1:]):
        n = max(1, int(math.dist(a, b) / step))
        out += [lerp(a, b, k / n) for k in range(1, n + 1)]
    return out

# ---- the drawing ---------------------------------------------------------------
# A Colt Single Action Army. The silhouette and the trigger-guard opening
# are traced from a 316 x 316 px product photo of a 4.75 in SAA (threshold,
# border following, smoothing, Douglas-Peucker; image px, see
# /tmp-style helper in the commit message), interior lines placed on the
# same photo. The plain part of the barrel and ejector housing is then
# stretched to the 7.5 in Cavalry barrel (cylinder ~1.6 in long = 46 px, so
# barrel 4.75 -> 7.5 in from the cylinder face; ~13 in overall).
OUTLINE = [
    (277.8, 104.8), (280.9, 104.2), (284.9, 105.1), (287.7, 107.3), (291.2, 111.8), (296.6, 113.4),
    (298.3, 114.7), (299.4, 117.6), (299.6, 121.8), (298.9, 126.9), (297.3, 129.3), (294.9, 129.9),
    (282.4, 130.4), (280.7, 131.7), (278.5, 136.5), (276.6, 137.6), (273.9, 137.9), (191.0, 138.0),
    (179.4, 139.4), (177.7, 140.7), (175.6, 144.6), (172.1, 149.1), (169.0, 160.0), (167.5, 162.5),
    (158.7, 166.7), (145.4, 169.4), (142.8, 170.8), (140.3, 173.3), (138.4, 177.4), (137.8, 186.8),
    (136.9, 189.9), (134.2, 193.2), (130.1, 196.1), (126.4, 197.4), (121.9, 197.9), (114.1, 197.9),
    (110.7, 197.3), (108.1, 195.9), (105.6, 193.4), (100.0, 185.0), (97.6, 183.4), (94.5, 182.5),
    (91.3, 182.4), (88.2, 183.2), (82.6, 186.6), (78.3, 191.3), (76.8, 193.8), (74.3, 203.3),
    (74.0, 210.0), (74.4, 215.6), (78.4, 232.2), (77.9, 234.0), (76.9, 234.9), (74.7, 235.7),
    (64.9, 236.9), (42.0, 237.0), (28.2, 235.8), (26.6, 235.4), (25.0, 234.1), (24.5, 232.1),
    (25.2, 229.2), (39.4, 192.4), (44.3, 181.3), (48.4, 174.4), (55.8, 165.8), (64.2, 159.2),
    (73.2, 155.2), (84.8, 152.7), (89.8, 147.8), (94.9, 144.3), (95.1, 142.5), (93.7, 135.8),
    (93.8, 130.1), (93.1, 127.9), (87.0, 122.0), (83.5, 115.5), (78.5, 110.5), (79.3, 109.1),
    (81.1, 108.6), (84.0, 109.1), (86.5, 110.5), (92.5, 115.5), (95.4, 116.6), (97.9, 116.8),
    (101.9, 115.9), (108.9, 110.9), (113.2, 109.2), (130.1, 108.3), (138.0, 109.0), (165.7, 108.3),
    (173.0, 110.0), (178.4, 112.6), (182.0, 113.0), (271.9, 112.9), (274.3, 112.3), (275.3, 111.3),
    (276.5, 106.5), (277.8, 104.8),
]
GUARD_HOLE = [
    (120.4, 173.4), (127.8, 173.2), (132.6, 175.4), (135.4, 178.6), (136.6, 181.4), (136.7, 183.8),
    (135.9, 186.9), (133.7, 190.7), (129.8, 194.3), (121.0, 196.0), (115.1, 195.9), (112.0, 195.1),
    (108.3, 192.6), (105.5, 188.5), (105.0, 185.0), (105.5, 180.5), (108.5, 177.1), (108.5, 180.7),
    (109.7, 186.3), (113.3, 191.7), (115.7, 193.2), (116.2, 192.6), (116.0, 191.0), (112.2, 183.8),
    (112.3, 177.3), (114.0, 175.0), (120.4, 173.4),
]

def stretch(p):
    """Photo px -> 7.5 in barrel: x 178..270 (plain barrel) stretched."""
    x, y = p
    if x > 270:
        x += 77
    elif x > 178:
        x = 178 + (x - 178) * (92 + 77) / 92
    return (x * 4, y * 4)   # local units = 1/4 photo px

def T(pts):
    return [stretch(p) for p in pts]

strokes = []  # (name, tone, points) in drawing order (phases sort them)

def S(name, tone, pts):
    strokes.append((name, tone, [tuple(p) for p in pts]))

OUT = T(dense(OUTLINE + [OUTLINE[0]], 1.0))

def snap(p):
    """Nearest point of the outline (interior strokes start/end on it)."""
    return min(OUT, key=lambda q: math.dist(q, p))

def tween(a, b, pts):
    """Interior stroke in photo px with both ends snapped to the outline."""
    q = T(pts)
    return [snap(q[0])] + q + [snap(q[-1])] if a else q

# Outline first: the whole silhouette from the frame bottom (nearest to the
# pen's home), then the trigger-guard opening with the trigger.
BBC = ((min(p[0] for p in OUT) + max(p[0] for p in OUT)) / 2, (min(p[1] for p in OUT) + max(p[1] for p in OUT)) / 2)
k0 = min(range(len(OUT)), key=lambda i: math.dist(OUT[i], BBC))
S("silhouette", LINE, OUT[k0:] + OUT[1:k0 + 1])
GH = T(GUARD_HOLE + [GUARD_HOLE[0]])
S("guard opening", LINE, [snap(GH[0])] + GH)
# Barrel / ejector housing seam, frame front, cylinder drum, recoil shield,
# hammer front, frame lower edge, grip wood top.
S("barrel seam", LINE, [snap(stretch((178, 129))), stretch((178, 129)), stretch((280, 129)), snap(stretch((282, 129)))])
S("frame front", LINE, [snap(stretch((176.5, 110))), stretch((176.5, 129))])
CX0, CX1, CY0, CY1 = 118 * 4, 159 * 4, 114.5 * 4, 158.5 * 4
CYM = (CY0 + CY1) / 2
RR, RF = (CY1 - CY0) / 2, (CY1 - CY0) / 2

def rear_x(y):
    return CX0 - 12 * math.sqrt(max(0, 1 - ((y - CYM) / RR) ** 2))

def front_x(y):
    return CX1 + 16 * math.sqrt(max(0, 1 - ((y - CYM) / RF) ** 2))

top = cr([(CX0, CY0 + 2), (CX0 + 50, CY0 - 3), (CX1 - 50, CY0 - 3), (CX1, CY0 + 2)], 5)
bot = cr([(CX1, CY1 - 2), (CX1 - 50, CY1 + 3), (CX0 + 50, CY1 + 3), (CX0, CY1 - 2)], 5)
rear = ellipse(CX0, CYM, 12, RR - 2, 90, 270, 16)     # bottom -> top via the left
frnt = ellipse(CX1, CYM, 16, RF - 2, -90, 90, 16)     # top -> bottom via the right
S("cylinder", LINE, [snap((CX0, CY0)), (CX0, CY0 + 2)] + top[1:] + frnt[1:] + bot[1:] + rear[1:])
S("recoil shield", LINE, [snap(stretch((101, 112)))] + T(cr([(101, 112), (95.5, 126), (96, 142), (104, 154), (116, 158.5)], 5)))
S("hammer front", LINE, [snap(stretch((91, 110.5)))] + T(cr([(91, 110.5), (95, 119), (100, 127), (101, 133)], 4)))
fl = T(cr([(93, 181), (108, 175.5), (125, 170), (145, 165), (163, 162.5), (172, 162)], 5))
S("frame lower edge", LINE, [snap(fl[0])] + fl + [snap(fl[-1])])
# Grip: wood panel inset in the silhouette, grain, screw.
gbk = [p for p in OUTLINE if p[0] < 72 and p[1] > 156]      # back strap side
gfr = [p for p in OUTLINE if 70 < p[0] < 100 and p[1] > 168] # front strap side
gbk.sort(key=lambda p: p[1])
gfr.sort(key=lambda p: p[1])
BK = resample(T([(69, 157.5)] + gbk), 40)
FR = resample(T([(91, 160)] + gfr), 40)
NB = [lerp(BK[k], FR[k], 0.1) for k in range(41)]
NF = [lerp(BK[k], FR[k], 0.88) for k in range(41)]
NB[-1] = lerp(NB[-1], NB[-2], 0.0)
S("grip top", LINE, [snap(BK[0]), FR[0], snap(FR[0])])
S("panel", LINE, [lerp(BK[0], FR[0], 0.1)] + NB[1:] + NF[::-1] + [lerp(BK[0], FR[0], 0.88)])
for i, (f, w, ph) in enumerate([(0.17, 2.2, 0.0), (0.33, 2.8, 1.3), (0.5, 2.4, 2.1), (0.66, 2.0, 0.7), (0.82, 1.5, 2.9)]):
    pts = []
    for k in range(41):
        g = f + (0.02 * math.sin(2 * math.pi * (w * 0.6 * k / 40) + ph) if 0 < k < 40 else 0)
        pts.append(lerp(NB[k], NF[k], g))
    S("grain %d" % i, GRAIN, pts[::-1] if i % 2 else pts)
S("knot", GRAIN, [lerp(NB[24], NF[24], 0.33)] + ellipse(*lerp(NB[26], NF[26], 0.41), 10, 6, 200, 560, 14))
S("screw", MID, [lerp(NB[17], NF[17], 0.33)] + ellipse(*lerp(NB[17], NF[17], 0.42), 9, 9, 180, 540, 12))
# Cylinder flutes (lens-shaped, following the drum) and chamber mouths.
R = RR - 14
for a in (-62, -24, 24, 62):
    yc = CYM - R * math.sin(math.radians(a))
    h = 13 * math.cos(math.radians(a))
    bow = 5 * math.sin(math.radians(a))
    xa, xb = CX0 + 10, CX1 - 22
    ts = [k / 12 for k in range(13)]
    up = [(xa + (xb - xa) * t, yc - (h + bow) * math.sin(math.pi * t)) for t in ts]
    dn = [(xa + (xb - xa) * t, yc + (h - bow) * math.sin(math.pi * t)) for t in ts]
    S("flute %d" % a, MID, [(rear_x(yc), yc)] + up + dn[::-1] + [(rear_x(yc), yc)])
for yc in (CYM - 40, CYM + 40):
    fx = front_x(yc)
    S("chamber %d" % yc, MID, ellipse(fx - 6, yc, 6, 13, 0, 360, 12))
S("ejector rod", MID, [snap(stretch((180, 133))), stretch((180, 133)), stretch((272, 133)), stretch((180, 133)), snap(stretch((180, 133)))])
# Shading (light single-pass ink; density = tone, crossings darker).
SEAM = 129 * 4
X0, X1 = stretch((182, 0))[0], stretch((276, 0))[0]
S("barrel shade", LIGHT, [stretch((180, 129))] + spikes(SEAM, X0, X1, 8, 8, -16))
S("barrel shade dark", LIGHT, [stretch((180, 129))] + spikes(SEAM, X0 + 3, X1, 8, 3, -8))
EB = 136.5 * 4
S("ejector shade", LIGHT, [snap((X0, EB))] + spikes(EB, X0, stretch((270, 0))[0], 8, 7, -12))

def contour(edge, dy, flip):
    pts = sorted((x, y + dy) for x, y in resample(edge, 14))
    pts = [(rear_x(pts[0][1]), pts[0][1])] + pts[1:-1] + [(front_x(pts[-1][1]), pts[-1][1])]
    return pts[::-1] if flip else pts
for i, off in enumerate((5, 10, 17)):
    S("drum top %d" % off, LIGHT, contour(top, off, i % 2 == 0))
for i, off in enumerate((4, 8, 13, 20)):
    S("drum bottom %d" % off, LIGHT, contour(bot, -off, i % 2 == 1))
S("drum shadow", LIGHT, [bot[-4]] + spikes(CY1, CX0 + 30, CX1 - 30, 7, 4, -16))
gin = resample(GH, 40)
cen = (sum(p[0] for p in gin) / len(gin), sum(p[1] for p in gin) / len(gin))
S("guard shade", LIGHT, spikes_on(gin, 1, 8, cen, every=1))
S("barrel cross", LIGHT, [stretch((180, 129))] + spikes(SEAM, X0 + 8, X1, 8, -8, -16))
S("ejector cross", LIGHT, [snap((X0, EB))] + spikes(EB, X0 + 8, stretch((270, 0))[0], 8, -7, -12))
gbs = resample(BK, 30)
S("grip shade", LIGHT, [gbs[0]] + spikes_on(gbs, 1, 12, (FR[20][0] + 200, FR[20][1]), every=1))
S("frame shade", LIGHT, [fl[0]] + spikes_on(resample(fl, 24), 1, 10, (fl[12][0], fl[12][1] - 200), every=1))

# Start at the outline point nearest the drawing's centre (it lands on the
# pen's home, so the drawing sits centred): that stroke is split there and
# goes first.
_all = [(i, k, p) for i, (n, t, pts) in enumerate(strokes) if t == LINE for k, p in enumerate(pts)]
_xs = [p[0] for _, _, p in _all]
_ys = [p[1] for _, _, p in _all]
_c = ((min(_xs) + max(_xs)) / 2, (min(_ys) + max(_ys)) / 2)
def _fits(e):
    hx, hy = e[2]
    return (PEN[0] + 4 <= HOME[0] + (min(_xs) - hx) * SCALE and HOME[0] + (max(_xs) - hx) * SCALE <= PEN[2] - 4 and
            PEN[1] + 4 <= HOME[1] + (min(_ys) - hy) * SCALE and HOME[1] + (max(_ys) - hy) * SCALE <= PEN[3] - 4)
_i, _k, _ = min((e for e in _all if _fits(e)), key=lambda e: math.dist(e[2], _c))
_n, _t, _pts = strokes.pop(_i)
strokes[0:0] = [(_n, _t, _pts[_k:]), (_n + " b", _t, _pts[:_k + 1][::-1])]
if _n != "silhouette":   # the silhouette (closed) then starts where that ends
    _j = next(i for i, x in enumerate(strokes) if x[0] == "silhouette")
    _end = strokes[1][2][-1]
    _m = min(range(len(OUT)), key=lambda i: math.dist(OUT[i], _end))
    strokes[_j] = ("silhouette", LINE, OUT[_m:] + OUT[1:_m + 1])

# ---- graph routing -------------------------------------------------------------

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
                if q != p and abs(q[0] - p[0]) <= JUNC and abs(q[1] - p[1]) <= JUNC:
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
                    if r is None or math.dist(r[-1], pts[0]) > 7 or math.dist(r[0], here) > 7:
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
