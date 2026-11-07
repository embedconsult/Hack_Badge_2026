// Badge-to-badge robot battles: see robonet.h and crystal/net/PROTOCOL.md.
#include <string.h>
#include <stdio.h>
#include "robonet.h"

#define NCHUNK ((RN_SRC_MAX + RN_CHUNK - 1) / RN_CHUNK)
#define RETRY_MS 400
#define TRIES 15
#define Z_EVERY_MS 1000
#define Z_FOR_MS 120000

typedef struct {
    uint32_t crc, got, stamp;
    int len;
    bool done;
    uint8_t *data;
} ent_t;

enum { M_NONE, M_ASK, M_SEND, M_READY, M_RUN, M_DONE, M_OVER, M_FAIL };

static const rn_io_t *s_io;
static ent_t s_c[RN_CACHE];
static uint32_t s_stamp;

static struct {
    int state;
    bool initiator, taken;
    uint32_t id, seed, limit;
    int n, idx[RN_ROBOTS];
    uint32_t crc[RN_ROBOTS];
    uint16_t len[RN_ROBOTS];
    rn_addr_t peer;
    uint8_t mac[6];
    char name[13];
    int64_t next;
    int tries;
    uint8_t missing;
    int cur, off;
    bool mine, theirs;
    uint32_t cyc[2], hash[2];
    int8_t win[2];
    uint8_t dmg[2][RN_ROBOTS];
    int64_t z_until;
    char why[40];
} M;

// ---- little-endian fields -------------------------------------------------------
static void put32(uint8_t *p, uint32_t v) { p[0] = v, p[1] = v >> 8, p[2] = v >> 16, p[3] = v >> 24; }
static void put16(uint8_t *p, uint16_t v) { p[0] = v, p[1] = v >> 8; }
static uint32_t get32(const uint8_t *p) { return p[0] | p[1] << 8 | p[2] << 16 | (uint32_t)p[3] << 24; }
static uint16_t get16(const uint8_t *p) { return p[0] | p[1] << 8; }

uint32_t rn_crc32(const uint8_t *p, int n)
{
    uint32_t c = 0xFFFFFFFFu;
    for (int i = 0; i < n; i++) {
        c ^= p[i];
        for (int k = 0; k < 8; k++) c = (c >> 1) ^ (0xEDB88320u & (0u - (c & 1)));
    }
    return ~c;
}

void rn_init(const rn_io_t *io)
{
    s_io = io;
    memset(s_c, 0, sizeof s_c);
    memset(&M, 0, sizeof M);
}

static void event(int what)
{
    if (s_io && s_io->event) s_io->event(what);
}

static void fail(const char *why)
{
    M.state = M_FAIL;
    snprintf(M.why, sizeof M.why, "%s", why);
    event(RN_EV_STATUS);
}

// A match is being set up, played, or still waiting for the peer's result.
static bool busy(void)
{
    return (M.state >= M_ASK && M.state <= M_RUN) || (M.state == M_DONE && !M.theirs);
}

// ---- cache --------------------------------------------------------------------------
static bool pinned(int i)
{
    if (M.state == M_NONE || M.state == M_OVER || M.state == M_FAIL) return false;
    for (int k = 0; k < M.n; k++)
        if (M.idx[k] == i) return true;
    return false;
}

static int find(uint32_t crc, int len, bool done_only)
{
    for (int i = 0; i < RN_CACHE; i++)
        if (s_c[i].data && s_c[i].crc == crc && s_c[i].len == len && (s_c[i].done || !done_only)) return i;
    return -1;
}

// A free or least recently used, unpinned entry, emptied; -1 if none.
static int take_entry(uint32_t crc, int len)
{
    int best = -1;
    for (int i = 0; i < RN_CACHE; i++) {
        if (pinned(i)) continue;
        if (!s_c[i].data) { best = i; break; }
        if (best < 0 || s_c[i].stamp < s_c[best].stamp) best = i;
    }
    if (best < 0) return -1;
    ent_t *e = &s_c[best];
    if (!e->data) e->data = s_io->alloc(RN_SRC_MAX);
    if (!e->data) return -1;
    e->crc = crc, e->len = len, e->got = 0, e->done = false, e->stamp = ++s_stamp;
    return best;
}

int rn_add(const uint8_t *src, int len)
{
    if (len < 0 || len > RN_SRC_MAX) return -1;
    uint32_t crc = rn_crc32(src, len);
    int i = find(crc, len, true);
    if (i < 0) {
        i = take_entry(crc, len);
        if (i < 0) return -1;
        memcpy(s_c[i].data, src, len);
        s_c[i].done = true;
    }
    s_c[i].stamp = ++s_stamp;
    return i;
}

int rn_read(int i, uint8_t *buf, int max)
{
    if (i < 0 || i >= RN_CACHE || !s_c[i].done) return -1;
    int n = s_c[i].len < max ? s_c[i].len : max;
    memcpy(buf, s_c[i].data, n);
    return n;
}

// ---- sending ------------------------------------------------------------------------
static void send_g(void)
{
    uint8_t b[13 + 6 * RN_ROBOTS];
    put32(b, M.id), put32(b + 4, M.seed), put32(b + 8, M.limit);
    b[12] = M.n;
    for (int k = 0; k < M.n; k++) put32(b + 13 + 6 * k, M.crc[k]), put16(b + 17 + 6 * k, M.len[k]);
    s_io->send(M.peer, 'G', b, 13 + 6 * M.n);
}

static void send_b(void)
{
    ent_t *e = &s_c[M.idx[M.cur]];
    uint8_t b[8 + RN_CHUNK];
    int n = e->len - M.off < RN_CHUNK ? e->len - M.off : RN_CHUNK;
    put32(b, e->crc), put16(b + 4, e->len), put16(b + 6, M.off);
    memcpy(b + 8, e->data + M.off, n);
    s_io->send(M.peer, 'B', b, 8 + n);
}

static void send_z(void)
{
    uint8_t b[15 + RN_ROBOTS];
    put32(b, M.id), put32(b + 4, M.cyc[0]);
    b[8] = (uint8_t)M.win[0], b[9] = M.n;
    memcpy(b + 10, M.dmg[0], M.n);
    put32(b + 10 + M.n, M.hash[0]);
    b[14 + M.n] = M.theirs; // "I have your result": no need to answer
    s_io->send(M.peer, 'Z', b, 15 + M.n);
}

static void send_j(rn_addr_t to, uint32_t id, int status, int mask)
{
    uint8_t b[6];
    put32(b, id);
    b[4] = status, b[5] = mask;
    s_io->send(to, 'J', b, 6);
}

// First missing robot from `from` on (initiator, sending); false when none.
static bool next_missing(int from)
{
    for (int k = from; k < M.n; k++)
        if (M.missing & (1 << k)) {
            M.cur = k, M.off = 0;
            return true;
        }
    return false;
}

int rn_challenge(rn_addr_t to, const uint8_t mac[6], const char *name, const int *idx, int n,
                 uint32_t seed, uint32_t limit, int64_t now)
{
    if (n < 2 || n > RN_ROBOTS) return -1;
    for (int k = 0; k < n; k++)
        if (idx[k] < 0 || idx[k] >= RN_CACHE || !s_c[idx[k]].done) return -1;
    if (busy()) return -2;
    memset(&M, 0, sizeof M);
    M.initiator = true;
    M.peer = to;
    memcpy(M.mac, mac, 6);
    snprintf(M.name, sizeof M.name, "%s", name);
    M.n = n, M.seed = seed, M.limit = limit;
    uint32_t id = (uint32_t)now * 2654435761u ^ seed ^ 0x5A5A1234u;
    for (int k = 0; k < n; k++) {
        M.idx[k] = idx[k];
        M.crc[k] = s_c[idx[k]].crc, M.len[k] = s_c[idx[k]].len;
        id = id * 31 + M.crc[k];
    }
    M.id = id ? id : 1;
    M.state = M_ASK;
    send_g();
    M.next = now + RETRY_MS;
    event(RN_EV_STATUS);
    return 0;
}

// ---- receiving ---------------------------------------------------------------------
static bool from_peer(rn_addr_t from, const uint8_t mac[6])
{
    return !memcmp(mac, M.mac, 6);
}

static void verdict(void)
{
    bool same = M.cyc[0] == M.cyc[1] && M.win[0] == M.win[1] && M.hash[0] == M.hash[1] &&
                !memcmp(M.dmg[0], M.dmg[1], M.n);
    M.state = M_OVER;
    snprintf(M.why, sizeof M.why, "%s", same ? "same" : "different");
    event(RN_EV_STATUS);
}

static void rx_b(rn_addr_t from, const uint8_t *b, int n)
{
    if (n < 8) return;
    uint32_t crc = get32(b);
    int len = get16(b + 4), off = get16(b + 6), dl = n - 8;
    uint8_t k[7];
    put32(k, crc), put16(k + 4, off);
    k[6] = 1;
    if (len <= 0 || len > RN_SRC_MAX || off % RN_CHUNK || off >= len ||
        dl != (len - off < RN_CHUNK ? len - off : RN_CHUNK)) {
        s_io->send(from, 'K', k, 7);
        return;
    }
    int i = find(crc, len, false);
    if (i < 0) i = take_entry(crc, len);
    if (i < 0) {
        s_io->send(from, 'K', k, 7);
        return;
    }
    ent_t *e = &s_c[i];
    e->stamp = ++s_stamp;
    if (!e->done) {
        memcpy(e->data + off, b + 8, dl);
        e->got |= 1u << (off / RN_CHUNK);
        int nch = (len + RN_CHUNK - 1) / RN_CHUNK;
        if (e->got == (nch >= 32 ? 0xFFFFFFFFu : (1u << nch) - 1)) {
            if (rn_crc32(e->data, len) == crc) e->done = true;
            else e->got = 0; // damaged: start over
        }
    }
    k[6] = 0;
    s_io->send(from, 'K', k, 7);
}

static void rx_g(rn_addr_t from, const uint8_t mac[6], const char *name, const uint8_t *b, int n, int64_t now)
{
    if (n < 13) return;
    uint32_t id = get32(b);
    int cnt = b[12];
    if (cnt < 2 || cnt > RN_ROBOTS || n < 13 + 6 * cnt) return;
    if (M.id == id && !M.initiator && M.state >= M_READY) { // our J got lost
        send_j(from, id, 0, 0);
        return;
    }
    if (busy()) {
        send_j(from, id, 2, 0);
        return;
    }
    int idx[RN_ROBOTS], mask = 0;
    for (int k = 0; k < cnt; k++) {
        idx[k] = find(get32(b + 13 + 6 * k), get16(b + 17 + 6 * k), true);
        if (idx[k] < 0) mask |= 1 << k;
        else s_c[idx[k]].stamp = ++s_stamp;
    }
    if (mask) {
        send_j(from, id, 1, mask);
        return;
    }
    memset(&M, 0, sizeof M);
    M.initiator = false;
    M.peer = from;
    memcpy(M.mac, mac, 6);
    snprintf(M.name, sizeof M.name, "%s", name);
    M.id = id, M.seed = get32(b + 4), M.limit = get32(b + 8), M.n = cnt;
    for (int k = 0; k < cnt; k++) M.idx[k] = idx[k], M.crc[k] = get32(b + 13 + 6 * k), M.len[k] = get16(b + 17 + 6 * k);
    M.state = M_READY;
    send_j(from, id, 0, 0);
    event(RN_EV_MATCH);
}

static void rx_j(const uint8_t *b, int n, int64_t now)
{
    if (n < 6 || !M.initiator || get32(b) != M.id || M.state != M_ASK) return;
    if (b[4] == 0) {
        M.state = M_READY;
        event(RN_EV_MATCH);
    } else if (b[4] == 1) {
        M.missing = b[5];
        if (!next_missing(0)) return;
        M.state = M_SEND;
        M.tries = 0;
        send_b();
        M.next = now + RETRY_MS;
        event(RN_EV_STATUS);
    } else {
        fail("is busy");
    }
}

static void rx_k(const uint8_t *b, int n, int64_t now)
{
    if (n < 7 || M.state != M_SEND) return;
    ent_t *e = &s_c[M.idx[M.cur]];
    if (get32(b) != e->crc || get16(b + 4) != M.off) return;
    if (b[6] != 0) {
        fail("refused a robot");
        return;
    }
    M.tries = 0;
    M.off += RN_CHUNK;
    if (M.off >= e->len && !next_missing(M.cur + 1)) {
        M.state = M_ASK; // all sent: challenge again
        send_g();
    } else {
        send_b();
    }
    M.next = now + RETRY_MS;
    event(RN_EV_STATUS);
}

static void rx_z(const uint8_t *b, int n, int64_t now)
{
    if (n < 10 || get32(b) != M.id || M.state < M_READY) return;
    int cnt = b[9];
    if (cnt != M.n || n < 14 + cnt) return;
    bool first = !M.theirs;
    M.theirs = true;
    M.cyc[1] = get32(b + 4);
    M.win[1] = (int8_t)b[8];
    memcpy(M.dmg[1], b + 10, cnt);
    M.hash[1] = get32(b + 10 + cnt);
    bool has_mine = n >= 15 + cnt && b[14 + cnt];
    if (M.mine) {
        if (!has_mine) send_z(); // the peer still lacks ours (or lost it)
        if (first) verdict();
    } else {
        event(RN_EV_STATUS);
    }
}

void rn_rx(rn_addr_t from, const uint8_t mac[6], const char *name, char type, const uint8_t *b, int n,
           int64_t now)
{
    if (!s_io) return;
    if (type == 'B') rx_b(from, b, n);
    else if (type == 'G') rx_g(from, mac, name, b, n, now);
    else if (type == 'J' && from_peer(from, mac)) rx_j(b, n, now);
    else if (type == 'K' && from_peer(from, mac)) rx_k(b, n, now);
    else if (type == 'Z' && from_peer(from, mac)) rx_z(b, n, now);
}

void rn_tick(int64_t now)
{
    if (!s_io) return;
    if ((M.state == M_ASK || M.state == M_SEND) && now >= M.next) {
        if (++M.tries > TRIES) {
            fail("did not answer");
            return;
        }
        if (M.state == M_ASK) send_g();
        else send_b();
        M.next = now + RETRY_MS;
    } else if (M.state == M_DONE && !M.theirs && now >= M.next) {
        if (now > M.z_until) {
            fail("sent no result");
            return;
        }
        send_z();
        M.next = now + Z_EVERY_MS;
    }
}

bool rn_take_match(uint32_t *id, uint32_t *seed, uint32_t *limit, int *n, int idx[RN_ROBOTS])
{
    if (M.state != M_READY || M.taken) return false;
    M.taken = true;
    M.state = M_RUN;
    *id = M.id, *seed = M.seed, *limit = M.limit, *n = M.n;
    for (int k = 0; k < M.n; k++) idx[k] = M.idx[k];
    event(RN_EV_STATUS);
    return true;
}

void rn_result(uint32_t id, uint32_t cycles, int winner, int n, const uint8_t *dmg, uint32_t hash, int64_t now)
{
    if (id != M.id || M.state != M_RUN || n != M.n) return;
    M.mine = true;
    M.cyc[0] = cycles, M.win[0] = (int8_t)winner, M.hash[0] = hash;
    memcpy(M.dmg[0], dmg, n);
    M.state = M_DONE;
    M.z_until = now + Z_FOR_MS;
    send_z();
    M.next = now + Z_EVERY_MS;
    if (M.theirs) verdict();
    else event(RN_EV_STATUS);
}

uint32_t rn_match_id(void) { return M.id; }

int rn_status(char *buf, int max)
{
    const char *nm = M.name[0] ? M.name : "peer";
    int sent = 0, all = 0;
    for (int k = 0; k < M.n; k++)
        if (M.missing & (1 << k)) {
            all++;
            if (k < M.cur || (k == M.cur && M.state != M_SEND)) sent++;
        }
    switch (M.state) {
    case M_ASK: snprintf(buf, max, "challenging %s", nm); return RN_BUSY;
    case M_SEND: snprintf(buf, max, "sending robots to %s (%d/%d)", nm, sent + 1, all); return RN_BUSY;
    case M_READY:
    case M_RUN: snprintf(buf, max, "battle with %s", nm); return RN_RUNNING;
    case M_DONE: snprintf(buf, max, "waiting for %s's result", nm); return RN_WAIT_RESULT;
    case M_OVER:
        if (!strcmp(M.why, "same")) {
            snprintf(buf, max, "%s got the same result", nm);
            return RN_SAME;
        }
        snprintf(buf, max, "%s got a DIFFERENT result!", nm);
        return RN_DIFFERENT;
    case M_FAIL: snprintf(buf, max, "%s %s", nm, M.why); return RN_FAILED;
    default: buf[0] = 0; return RN_IDLE;
    }
}
