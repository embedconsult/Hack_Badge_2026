// Badge-link robot tournaments (crystal/net/PROTOCOL.md, message T). Portable
// C like robonet.c, which it builds on: sources travel as robonet B chunks
// and live in robonet's cache, named by CRC-32 and length. Every badge plays
// the whole tournament itself (src/robots/tourney.cr: the same robots in the
// same order with the same seed give the same tournament) and the organizer
// compares everyone's tournament hash, then sends the standings to all.
//
// Roles: the organizer is the badge with the lowest MAC among the badges
// that announce robot battles (caps bit 16). A badge asked to start a
// tournament organizes it if it is the lowest, else asks the lowest (T/O).
//   organizer: Q to every peer -> E (its slot robots by CRC + length)
//              S (wanted chunks) -> owner pushes B chunks
//              P (the plan: seed, seeds, badges, robots in order) -> A (missing count)
//              each badge plays it; R (tournament hash) -> W (standings + who agreed)
// The caller serialises every tn_* call with the robonet ones (one lock).
#pragma once
#include "robonet.h"

#define TN_PEERS 7    // other badges in a tournament
#define TN_BADGES (TN_PEERS + 1)
#define TN_ROBOTS 48  // as Tour::MAX
#define TN_MINE 8     // robots a badge brings (its slots)
#define TN_ENTRY 6    // W standings entry: robot, wins, draws, played, damage sum u16

typedef struct {
    rn_addr_t addr;
    uint8_t mac[6];
    char name[13];
} tn_peer_t;

typedef struct {
    void (*send)(rn_addr_t to, char type, const void *body, int n);
    void (*event)(int what); // TN_EV_*
    // this badge's slot robots, added to the robonet cache: their indices
    int (*mine)(int *idx, int max);
    // the built-in robots, added to the cache (organizer only)
    int (*builtins)(int *idx, int max);
    // the live peers that play robot battles (announce caps bit 16)
    int (*peers)(tn_peer_t *p, int max, int64_t now);
} tn_io_t;

enum { TN_EV_STATUS = 0, TN_EV_RUN = 1, TN_EV_DONE = 2 };
// tn_status verdicts
enum { TN_IDLE = 0, TN_BUSY = 1, TN_RUNNING = 2, TN_WAITING = 3, TN_SAME = 4, TN_DIFFERENT = 5, TN_FAILED = 6 };

void tn_init(const tn_io_t *io, const uint8_t me[6], const char *name);
void tn_set_me(const uint8_t me[6], const char *name);

// Start a tournament with the live robot peers: organize it when this
// badge has the lowest MAC, else ask the lowest one to (seed 0: random).
// 0 ok, -1 busy, -2 no peers.
int tn_start(uint32_t seed, int seeds, int64_t now);

// A T message (body after the 12-byte header).
void tn_rx(rn_addr_t from, const uint8_t mac[6], const char *name, const uint8_t *b, int n, int64_t now);
void tn_tick(int64_t now);

// The plan, once all its sources are here (once per tournament): id, seed,
// seeds, robots as cache indices in order, owner badge of each (0 = the
// organizer, k = badge k of tn_badge_name, 255 = built-in).
bool tn_take_run(uint32_t *tid, uint32_t *seed, int *seeds, int *n, int idx[TN_ROBOTS], uint8_t owner[TN_ROBOTS]);
// This badge's result of tournament tid: its hash and its standings
// (TN_ENTRY bytes per robot in rank order, then champion, final winner).
void tn_result(uint32_t tid, uint32_t hash, const uint8_t *table, int len, int64_t now);
// The organizer's W once it is here: tid, the official hash, standings as
// tn_result's table; their length (0: none yet).
int tn_standings(uint32_t *tid, uint32_t *hash, uint8_t *table, int max);
// One line for the screen; the TN_* verdict.
int tn_status(char *buf, int max);
// Name of badge k of the current plan ("" if none).
const char *tn_badge_name(int k);
bool tn_busy(void);
