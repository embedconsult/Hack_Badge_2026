// Host specs for joining a badge-link robot tournament (main/tourney_net.c):
// joining is opt-in. With `robot autojoin on` (the default) a badge joins
// when it shows Home or ROBOTS or has been untouched for 60 s; otherwise,
// and always with autojoin off, it only notes the invitation (the top bar's
// TOURNEY NEARBY) and its screen stays as it is. A badge that asked for
// the tournament itself always joins.
//   gcc -I../../main -o bin/test_join test_join.c ../../main/tourney_net.c ../../main/robonet.c && bin/test_join
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "tourney_net.h"

static int fails, checks;
#define CHECK(c) do { checks++; if (!(c)) { fails++; printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #c); } } while (0)

// the badge's state, as main/net.c sees it
static bool g_autojoin = true, g_home_or_robots;
static int64_t g_touched;
static int g_sent_e, g_runs, g_events;
static char g_last;

static void send(rn_addr_t to, char type, const void *body, int n)
{
    const uint8_t *b = body;
    if (type == 'T') g_last = b[0];
    if (type == 'T' && b[0] == 'E') g_sent_e++;
}
static void event(int what)
{
    g_events++;
    if (what == TN_EV_RUN) g_runs++; // net.c would switch to ROBOTS here
}
static void *alloc(size_t n) { return calloc(1, n); }
static int none(int *idx, int max) { return 0; }
static const uint8_t ORG[6] = {0x02, 0, 0, 0, 0, 1}, ME[6] = {0x02, 0, 0, 0, 0, 9};
static int peers(tn_peer_t *p, int max, int64_t now)
{
    memset(p, 0, sizeof *p);
    memcpy(p->mac, ORG, 6);
    snprintf(p->name, sizeof p->name, "Organizer");
    p->addr.port = 4626;
    return 1;
}
static bool may_join(int64_t now) { return tn_may_join(g_autojoin, g_home_or_robots, now - g_touched); }

static const rn_io_t rio = {send, NULL, alloc};
static const tn_io_t tio = {send, event, none, none, peers, may_join};

static void fresh(void)
{
    rn_init(&rio);
    tn_init(&tio, ME, "Me");
    g_sent_e = g_runs = g_events = 0;
    g_last = 0;
}

// The organizer's Q for tournament tid, at time now.
static void q(uint32_t tid, int64_t now)
{
    uint8_t b[5] = {'Q', tid, tid >> 8, tid >> 16, tid >> 24};
    rn_addr_t from = {0x0100007f, 4626};
    tn_rx(from, ORG, "Organizer", b, 5, now);
}

static bool joined(void)
{
    char st[80];
    tn_status(st, sizeof st);
    return strstr(st, "joined") != NULL;
}

int main(void)
{
    char name[16];
    int64_t t = 1000000;

    // the rule itself
    CHECK(tn_may_join(true, true, 0));               // on Home / ROBOTS: at once
    CHECK(!tn_may_join(true, false, 0));             // in another app, in use: no
    CHECK(!tn_may_join(true, false, TN_IDLE_JOIN_MS - 1));
    CHECK(tn_may_join(true, false, TN_IDLE_JOIN_MS)); // untouched for 60 s: yes
    CHECK(!tn_may_join(false, true, 10 * TN_IDLE_JOIN_MS)); // autojoin off: never

    // rule 1: on Home or ROBOTS, in use: joins (answers E)
    fresh();
    g_autojoin = true, g_home_or_robots = true, g_touched = t - 1000;
    q(7, t);
    CHECK(joined() && g_sent_e == 1 && g_last == 'E');
    CHECK(!tn_nearby(name, sizeof name, t));

    // rule 2: another app, touched 10 s ago: does not join, only notes it
    fresh();
    g_home_or_robots = false, g_touched = t - 10000;
    q(8, t);
    CHECK(!joined() && g_sent_e == 0 && g_runs == 0 && !tn_busy());
    CHECK(tn_nearby(name, sizeof name, t) && !strcmp(name, "Organizer"));
    CHECK(tn_nearby(NULL, 0, t + TN_NEARBY_MS));
    CHECK(!tn_nearby(NULL, 0, t + TN_NEARBY_MS + 1)); // the hint goes away
    // ... and joins on the organizer's next Q once the badge is on ROBOTS
    g_home_or_robots = true;
    q(8, t + 400);
    CHECK(joined() && g_sent_e == 1);
    CHECK(!tn_nearby(NULL, 0, t + 400)); // joined: no hint

    // rule 3: another app, untouched for 60 s: joins
    fresh();
    g_home_or_robots = false, g_touched = t - TN_IDLE_JOIN_MS;
    q(9, t);
    CHECK(joined() && g_sent_e == 1);
    fresh();
    g_touched = t - TN_IDLE_JOIN_MS + 1;
    q(9, t);
    CHECK(!joined() && tn_nearby(NULL, 0, t));

    // rule 4: autojoin off: never joins, not even on ROBOTS after an hour
    fresh();
    g_autojoin = false, g_home_or_robots = true, g_touched = t - 3600000;
    q(10, t);
    q(10, t + 400);
    CHECK(!joined() && g_sent_e == 0 && tn_nearby(name, sizeof name, t + 400));

    // rule 5: a badge that asked for the tournament (robot tourney net) joins it
    fresh();
    g_autojoin = false, g_home_or_robots = false, g_touched = t;
    CHECK(tn_start(0, 2, t) == 0); // the organizer has the lower MAC: we ask it
    q(11, t + 3000);
    CHECK(joined() && g_sent_e == 1);

    printf("test_join: %d checks, %d failed\n", checks, fails);
    return fails != 0;
}
