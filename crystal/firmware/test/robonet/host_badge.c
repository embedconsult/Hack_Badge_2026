// A badge's robot-battle link on a PC: main/robonet.c (the badge's own code)
// over a UDP socket, with the badge's battle engine (bin/rb, built from
// test/robots/empty_prelude.cr with --prelude=empty) simulating each match.
// For test/robonet/run.sh against crystal/net/sim_badge.py.
//
//   host_badge --port P --engine bin/rb [--name N] [--bcast host:port] [--secs S]
//              [--loss PERCENT] [--challenge BADGE [--seed N] robot.cr robot.cr ...]
//
// Exit: 0 same result as the peer, 3 different, 4 failed, 5 timed out.
#include <arpa/inet.h>
#include <netinet/in.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>
#include "robonet.h"

static int s_sock;
static uint8_t s_me[6] = {0xf4, 0x12, 0xfa, 0xc0, 0, 0};
static uint8_t s_seq;
static const char *s_engine = "bin/rb";
static int s_events;
static int s_loss; // percent of sent packets dropped (--loss), to test the retries

static int64_t now_ms(void)
{
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (int64_t)t.tv_sec * 1000 + t.tv_nsec / 1000000;
}

static void send_to(rn_addr_t to, char type, const void *body, int n)
{
    if (s_loss && rand() % 100 < s_loss) return;
    uint8_t b[12 + 700];
    memcpy(b, "BLK", 3);
    b[3] = 1, b[4] = type, b[5] = s_seq++;
    memcpy(b + 6, s_me, 6);
    memcpy(b + 12, body, n);
    struct sockaddr_in a = {.sin_family = AF_INET, .sin_port = htons(to.port), .sin_addr.s_addr = to.ip};
    sendto(s_sock, b, 12 + n, 0, (struct sockaddr *)&a, sizeof a);
}

static void on_event(int what) { s_events++; }

static void *alloc(size_t n) { return calloc(1, n); }

static const rn_io_t s_io = {send_to, on_event, alloc};

// Play match: write the sources, run the engine, hand the result over.
static void play(void)
{
    uint32_t id, seed, limit;
    int n, idx[RN_ROBOTS];
    if (!rn_take_match(&id, &seed, &limit, &n, idx)) return;
    char cmd[1024], tmpl[] = "/tmp/robonetXXXXXX";
    char *dir = mkdtemp(tmpl);
    int k = snprintf(cmd, sizeof cmd, "%s %u %u", s_engine, seed, limit);
    static uint8_t src[RN_SRC_MAX];
    for (int r = 0; r < n; r++) {
        int len = rn_read(idx[r], src, sizeof src);
        char f[64];
        snprintf(f, sizeof f, "%s/r%d.cr", dir, r);
        FILE *o = fopen(f, "wb");
        fwrite(src, 1, len < 0 ? 0 : len, o);
        fclose(o);
        k += snprintf(cmd + k, sizeof cmd - k, " %s", f);
    }
    FILE *p = popen(cmd, "r");
    char line[256];
    uint32_t cycles = 0, hash = 0;
    int winner = -1, nd = 0;
    uint8_t dmg[RN_ROBOTS] = {0};
    while (p && fgets(line, sizeof line, p)) {
        int a, b, c;
        unsigned h;
        if (sscanf(line, "cycles %d winner %d hash %u", &a, &b, &h) == 3) cycles = a, winner = b, hash = h;
        else if (sscanf(line, "robot %d damage %d x %d", &a, &b, &c) == 3 && nd < RN_ROBOTS) dmg[nd++] = b;
    }
    if (p) pclose(p);
    for (int r = 0; r < n; r++) {
        char f[64];
        snprintf(f, sizeof f, "%s/r%d.cr", dir, r);
        unlink(f);
    }
    rmdir(dir);
    printf("host: match %08x seed %u: cycles %u winner %d hash %08x\n", id, seed, cycles, winner, hash);
    rn_result(id, cycles, winner, n, dmg, hash, now_ms());
}

int main(int argc, char **argv)
{
    int port = 4626, secs = 60, nfiles = 0;
    const char *name = "HostBadge", *badge = NULL, *files[RN_ROBOTS];
    uint32_t seed = 12345;
    rn_addr_t bcast = {htonl(INADDR_BROADCAST), 4626};
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--port") && i + 1 < argc) port = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--engine") && i + 1 < argc) s_engine = argv[++i];
        else if (!strcmp(argv[i], "--name") && i + 1 < argc) name = argv[++i];
        else if (!strcmp(argv[i], "--secs") && i + 1 < argc) secs = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--loss") && i + 1 < argc) s_loss = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--seed") && i + 1 < argc) seed = strtoul(argv[++i], NULL, 10);
        else if (!strcmp(argv[i], "--bcast") && i + 1 < argc) {
            char *c = strrchr(argv[++i], ':');
            *c = 0;
            bcast.ip = inet_addr(argv[i]), bcast.port = atoi(c + 1);
        } else if (!strcmp(argv[i], "--challenge") && i + 1 < argc) badge = argv[++i];
        else if (nfiles < RN_ROBOTS) files[nfiles++] = argv[i];
    }
    s_me[4] = port >> 8, s_me[5] = port;
    s_sock = socket(AF_INET, SOCK_DGRAM, 0);
    int one = 1;
    setsockopt(s_sock, SOL_SOCKET, SO_BROADCAST, &one, sizeof one);
    setsockopt(s_sock, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    struct timeval tv = {0, 10000};
    setsockopt(s_sock, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
    struct sockaddr_in a = {.sin_family = AF_INET, .sin_port = htons(port), .sin_addr.s_addr = htonl(INADDR_ANY)};
    if (bind(s_sock, (struct sockaddr *)&a, sizeof a) < 0) {
        perror("bind");
        return 2;
    }
    rn_init(&s_io);
    int idx[RN_ROBOTS];
    for (int k = 0; k < nfiles; k++) {
        static uint8_t src[RN_SRC_MAX];
        FILE *f = fopen(files[k], "rb");
        if (!f) { perror(files[k]); return 2; }
        int n = fread(src, 1, sizeof src, f);
        fclose(f);
        idx[k] = rn_add(src, n);
    }
    bool challenged = false;
    int done = -1;
    char last[96] = "";
    int64_t end = now_ms() + secs * 1000LL, next_hello = 0;
    uint8_t peer_mac[6];
    char peer_name[13] = "";
    rn_addr_t peer = {0, 0};
    while (now_ms() < end) {
        int64_t now = now_ms();
        if (now >= next_hello) { // announce, as net.c does (kind 2, no heard list)
            uint8_t h[23] = {2, 1, 255, 0};
            snprintf((char *)h + 10, 13, "%s", name);
            send_to(bcast, 'H', h, 23);
            next_hello = now + 1000;
        }
        uint8_t b[2048];
        struct sockaddr_in from;
        socklen_t fl = sizeof from;
        int n = recvfrom(s_sock, b, sizeof b, 0, (struct sockaddr *)&from, &fl);
        if (n >= 12 && !memcmp(b, "BLK", 3) && b[3] == 1 && memcmp(b + 6, s_me, 6)) {
            rn_addr_t src = {from.sin_addr.s_addr, ntohs(from.sin_port)};
            char t = b[4];
            if (t == 'H' && n >= 12 + 23 && b[12] != 3) {
                memcpy(peer_mac, b + 6, 6);
                memcpy(peer_name, b + 22, 12);
                peer_name[12] = 0;
                peer = src;
            } else {
                rn_rx(src, b + 6, peer_name[0] ? peer_name : "peer", t, b + 12, n - 12, now);
            }
        }
        rn_tick(now_ms());
        if (badge && !challenged && peer.port && !strncmp(peer_name, badge, strlen(badge))) {
            int r = rn_challenge(peer, peer_mac, peer_name, idx, nfiles, seed, 500000, now_ms());
            printf("host: challenge %s -> %d\n", peer_name, r);
            challenged = true;
        }
        play();
        char st[96];
        int v = rn_status(st, sizeof st);
        if (strcmp(st, last)) {
            printf("host: %s\n", st);
            fflush(stdout);
            snprintf(last, sizeof last, "%s", st);
        }
        int code = v == RN_SAME ? 0 : v == RN_DIFFERENT ? 3 : v == RN_FAILED ? 4 : -1;
        if (code >= 0 && done < 0) { // linger a little: the peer may still want our result
            done = code;
            if (end > now_ms() + 1500) end = now_ms() + 1500;
        }
    }
    if (done >= 0) return done;
    printf("host: timed out\n");
    return 5;
}
