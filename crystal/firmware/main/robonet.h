// Badge-to-badge robot battles over the badge link (crystal/net/PROTOCOL.md,
// messages B K G J Z). Portable C, no ESP-IDF: main/net.c drives it on the
// badge, test/robonet/host_badge.c on a PC. Not thread-safe: the caller
// serialises every rn_* call.
//
// The idea: both badges run the same battle themselves. The challenger
// sends a challenge (G) naming the robots by CRC-32 and length, the seed
// and the cycle limit; the other badge answers (J) which sources it lacks,
// the challenger sends those in chunks (B, each acknowledged with K) and
// challenges again. When both have every source, both simulate the battle
// (the engine is deterministic) and exchange results (Z) to cross-check.
#pragma once
#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

#define RN_CHUNK 512      // source bytes per B message
#define RN_SRC_MAX 8160   // largest robot source (a flash slot)
#define RN_CACHE 56       // sources kept (received or sent; tournaments need many), 8 KB each in PSRAM
#define RN_ROBOTS 4

typedef struct {
    uint32_t ip;   // network byte order
    uint16_t port; // host byte order
} rn_addr_t;

typedef struct {
    void (*send)(rn_addr_t to, char type, const void *body, int n);
    void (*event)(int what); // RN_EV_*: a match is ready, or the status changed
    void *(*alloc)(size_t n);
} rn_io_t;

enum { RN_EV_STATUS = 0, RN_EV_MATCH = 1 };

// verdicts (rn_status)
enum { RN_IDLE = 0, RN_BUSY = 1, RN_RUNNING = 2, RN_WAIT_RESULT = 3, RN_SAME = 4, RN_DIFFERENT = 5, RN_FAILED = 6 };

void rn_init(const rn_io_t *io);
uint32_t rn_crc32(const uint8_t *p, int n);

// Put a source into the cache (kept until evicted); its index, or -1.
int rn_add(const uint8_t *src, int len);
// Source of cache entry i into buf; its length, or -1.
int rn_read(int i, uint8_t *buf, int max);

// For tournaments (main/tourney_net.c), same lock as the rest:
// the complete entry with this CRC and length, or -1;
int rn_find(uint32_t crc, int len);
// its chunks received so far (bit k = chunk k; all ones when complete, 0 none);
uint32_t rn_got(uint32_t crc, int len);
// CRC and length of complete entry i;
bool rn_info(int i, uint32_t *crc, int *len);
// keep entry i (not evicted) / let all go;
void rn_pin(int i, bool on);
void rn_unpin_all(void);
// send up to max of its chunks not in got to `to` as B messages (the peer
// stores them, as for a challenge); the number sent, -1 if we lack it.
int rn_push(rn_addr_t to, uint32_t crc, int len, uint32_t got, int max);

// Challenge the badge at `to` (name for messages) to a battle of the cached
// sources idx[0..n-1], in that order, with this seed and cycle limit.
// 0 = started, -1 = bad arguments, -2 = a match is already going on.
int rn_challenge(rn_addr_t to, const uint8_t mac[6], const char *name, const int *idx, int n,
                 uint32_t seed, uint32_t limit, int64_t now);

// A received B K G J Z message (body after the 12-byte header).
void rn_rx(rn_addr_t from, const uint8_t mac[6], const char *name, char type, const uint8_t *b, int n,
           int64_t now);
void rn_tick(int64_t now);

// A match ready to run (once per match): its id, seed, limit and the cache
// indices of its robots in order. True when there is one.
bool rn_take_match(uint32_t *id, uint32_t *seed, uint32_t *limit, int *n, int idx[RN_ROBOTS]);

// This badge's result of match id; dmg[n] per robot, hash: the engine's
// result hash (RB.result_hash).
void rn_result(uint32_t id, uint32_t cycles, int winner, int n, const uint8_t *dmg, uint32_t hash, int64_t now);

// One line about the current match for the screen; returns RN_* verdict.
int rn_status(char *buf, int max);
// The match id the status is about (0 none).
uint32_t rn_match_id(void);
