// Small QR code encoder for the Settings app (Wi-Fi join code): byte mode,
// error correction level L, versions 1..5 (one RS block each, up to 106
// bytes), mask chosen by the standard penalty rules. Written from the QR
// spec (ISO/IEC 18004); placement order as in Nayuki's description.
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#define QR_MAX 37 // version 5: 17 + 4 * 5

static const uint8_t k_data[6] = {0, 19, 34, 55, 80, 108}; // data codewords, level L
static const uint8_t k_ecc[6] = {0, 7, 10, 15, 20, 26};    // EC codewords, level L
static const uint8_t k_align[6] = {0, 0, 18, 22, 26, 30};  // second alignment centre

static uint8_t s_exp[512], s_log[256];

static void gf_init(void)
{
    if (s_exp[0]) return;
    int x = 1;
    for (int i = 0; i < 255; i++) {
        s_exp[i] = (uint8_t)x;
        s_log[x] = (uint8_t)i;
        x <<= 1;
        if (x & 0x100) x ^= 0x11D;
    }
    for (int i = 255; i < 512; i++) s_exp[i] = s_exp[i - 255];
}

static uint8_t gmul(uint8_t a, uint8_t b) { return a && b ? s_exp[s_log[a] + s_log[b]] : 0; }

// ec[0..k-1] = remainder of d(x) * x^k by the generator prod (x - a^i).
static void rs(const uint8_t *d, int n, uint8_t *ec, int k)
{
    uint8_t g[32] = {1}; // low -> high, monic
    int gl = 1;
    for (int i = 0; i < k; i++) {
        uint8_t ng[32] = {0};
        for (int j = 0; j < gl; j++) {
            ng[j] ^= gmul(g[j], s_exp[i]);
            ng[j + 1] ^= g[j];
        }
        gl++;
        memcpy(g, ng, gl);
    }
    memset(ec, 0, k);
    for (int i = 0; i < n; i++) {
        uint8_t f = d[i] ^ ec[0];
        memmove(ec, ec + 1, k - 1);
        ec[k - 1] = 0;
        for (int j = 0; j < k; j++) ec[j] ^= gmul(g[k - 1 - j], f);
    }
}

typedef struct {
    int n;
    uint8_t m[QR_MAX * QR_MAX];  // 1 = dark
    uint8_t fn[QR_MAX * QR_MAX]; // 1 = function module
} qr_t;

static void put(qr_t *q, int x, int y, int dark) // x = column, y = row
{
    q->m[y * q->n + x] = (uint8_t)dark;
    q->fn[y * q->n + x] = 1;
}

static void finder(qr_t *q, int cx, int cy)
{
    for (int dy = -4; dy <= 4; dy++)
        for (int dx = -4; dx <= 4; dx++) {
            int x = cx + dx, y = cy + dy;
            if (x < 0 || y < 0 || x >= q->n || y >= q->n) continue;
            int d = abs(dx) > abs(dy) ? abs(dx) : abs(dy);
            put(q, x, y, d != 2 && d != 4);
        }
}

static void format_bits(qr_t *q, int mask)
{
    int data = (1 << 3) | mask; // level L = 01
    int r = data;
    for (int i = 0; i < 10; i++) r = (r << 1) ^ ((r >> 9) * 0x537);
    int bits = ((data << 10) | r) ^ 0x5412;
    int n = q->n;
    for (int i = 0; i <= 5; i++) put(q, 8, i, (bits >> i) & 1);
    put(q, 8, 7, (bits >> 6) & 1);
    put(q, 8, 8, (bits >> 7) & 1);
    put(q, 7, 8, (bits >> 8) & 1);
    for (int i = 9; i < 15; i++) put(q, 14 - i, 8, (bits >> i) & 1);
    for (int i = 0; i < 8; i++) put(q, n - 1 - i, 8, (bits >> i) & 1);
    for (int i = 8; i < 15; i++) put(q, 8, n - 15 + i, (bits >> i) & 1);
    put(q, 8, n - 8, 1); // dark module
}

static int masked(int mask, int y, int x)
{
    switch (mask) {
    case 0: return (x + y) % 2 == 0;
    case 1: return y % 2 == 0;
    case 2: return x % 3 == 0;
    case 3: return (x + y) % 3 == 0;
    case 4: return (y / 2 + x / 3) % 2 == 0;
    case 5: return x * y % 2 + x * y % 3 == 0;
    case 6: return (x * y % 2 + x * y % 3) % 2 == 0;
    default: return ((x + y) % 2 + x * y % 3) % 2 == 0;
    }
}

static int get(const qr_t *q, int x, int y) { return q->m[y * q->n + x]; }

static int penalty(const qr_t *q)
{
    int n = q->n, p = 0, dark = 0;
    for (int pass = 0; pass < 2; pass++) // rows, then columns
        for (int a = 0; a < n; a++) {
            int run = 0, last = -1;
            for (int b = 0; b < n; b++) {
                int c = pass ? get(q, a, b) : get(q, b, a);
                if (c == last) run++;
                else {
                    if (run >= 5) p += 3 + run - 5;
                    run = 1;
                    last = c;
                }
            }
            if (run >= 5) p += 3 + run - 5;
            // finder-like 1:1:3:1:1 with 4 light modules on one side
            for (int b = 0; b + 10 < n; b++) {
                static const uint8_t pa[11] = {1, 0, 1, 1, 1, 0, 1, 0, 0, 0, 0};
                int f1 = 1, f2 = 1;
                for (int k = 0; k < 11; k++) {
                    int c = pass ? get(q, a, b + k) : get(q, b + k, a);
                    if (c != pa[k]) f1 = 0;
                    if (c != pa[10 - k]) f2 = 0;
                }
                p += 40 * (f1 + f2);
            }
        }
    for (int y = 0; y + 1 < n; y++)
        for (int x = 0; x + 1 < n; x++) {
            int c = get(q, x, y);
            if (c == get(q, x + 1, y) && c == get(q, x, y + 1) && c == get(q, x + 1, y + 1)) p += 3;
        }
    for (int i = 0; i < n * n; i++) dark += q->m[i];
    int total = n * n;
    int k = (abs(dark * 20 - total * 10) + total - 1) / total - 1;
    return p + k * 10;
}

// Encodes text[0..len) into out (size * size bytes, 1 = dark, row-major).
// Returns size (21..37), or 0 if the text is too long. mask_req < 0 picks
// the best mask; 0..7 forces one (tests).
int32_t cr_qr_encode_mask(const uint8_t *text, int32_t len, uint8_t *out, int32_t mask_req)
{
    static qr_t q, best;
    gf_init();
    int v = 1;
    while (v <= 5 && len > k_data[v] - 2) v++;
    if (v > 5 || len < 0) return 0;
    int nd = k_data[v], ne = k_ecc[v];
    uint8_t cw[134];
    memset(cw, 0, sizeof cw);
    // mode 0100, 8-bit count, data, terminator, pad bytes
    int bit = 0;
#define PUTB(val, nb) do { for (int _i = (nb) - 1; _i >= 0; _i--, bit++) if (((val) >> _i) & 1) cw[bit >> 3] |= 0x80 >> (bit & 7); } while (0)
    PUTB(4, 4);
    PUTB(len, 8);
    for (int i = 0; i < len; i++) PUTB(text[i], 8);
    int term = nd * 8 - bit;
    PUTB(0, term < 4 ? term : 4);
    bit = (bit + 7) & ~7;
    for (int i = bit / 8, k = 0; i < nd; i++, k++) cw[i] = k & 1 ? 0x11 : 0xEC;
#undef PUTB
    rs(cw, nd, cw + nd, ne);

    int n = 17 + 4 * v;
    memset(&q, 0, sizeof q);
    q.n = n;
    for (int i = 0; i < n; i++) { // timing
        put(&q, 6, i, i % 2 == 0);
        put(&q, i, 6, i % 2 == 0);
    }
    finder(&q, 3, 3);
    finder(&q, n - 4, 3);
    finder(&q, 3, n - 4);
    if (v >= 2) {
        int c = k_align[v];
        for (int dy = -2; dy <= 2; dy++)
            for (int dx = -2; dx <= 2; dx++) put(&q, c + dx, c + dy, (abs(dx) > abs(dy) ? abs(dx) : abs(dy)) != 1);
    }
    format_bits(&q, 0); // reserves the format areas
    // data, two columns at a time from the right, zigzag
    int total = (nd + ne) * 8, i = 0;
    for (int right = n - 1; right >= 1; right -= 2) {
        if (right == 6) right = 5;
        for (int vert = 0; vert < n; vert++)
            for (int j = 0; j < 2; j++) {
                int x = right - j;
                int up = ((right + 1) & 2) == 0;
                int y = up ? n - 1 - vert : vert;
                if (q.fn[y * n + x]) continue;
                int b = i < total ? (cw[i >> 3] >> (7 - (i & 7))) & 1 : 0;
                q.m[y * n + x] = (uint8_t)b;
                i++;
            }
    }
    int best_p = 0x7FFFFFFF, best_m = 0;
    for (int m = 0; m < 8; m++) {
        if (mask_req >= 0 && m != mask_req) continue;
        qr_t *t = &best;
        if (mask_req < 0) t = (qr_t *)malloc(sizeof(qr_t));
        if (!t) t = &best;
        memcpy(t, &q, sizeof q);
        for (int y = 0; y < n; y++)
            for (int x = 0; x < n; x++)
                if (!t->fn[y * n + x] && masked(m, y, x)) t->m[y * n + x] ^= 1;
        format_bits(t, m);
        int p = penalty(t);
        if (p < best_p) {
            best_p = p;
            best_m = m;
            if (t != &best) memcpy(&best, t, sizeof best);
        }
        if (t != &best) free(t);
    }
    (void)best_m;
    memcpy(out, best.m, n * n);
    return n;
}

int32_t cr_qr_encode(const uint8_t *text, int32_t len, uint8_t *out)
{
    return cr_qr_encode_mask(text, len, out, -1);
}
