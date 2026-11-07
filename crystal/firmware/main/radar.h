// Radar app (main/radar.c, src/apps/radar.cr): what the link (main/net.c)
// knows about nearby badges, and the distance / map model built from it.
// Pure C (no ESP-IDF), so test/apps/ runs it on the host.
//
// Idea and map approach after yigitabi5444's badge os Radar (app_radar.c,
// RADAR_RESEARCH.md); this is our own implementation on RSSI from the badge
// link (crystal/net/PROTOCOL.md, "Radar").
#pragma once
#include <stdint.h>
#include <stdbool.h>

#define RADAR_HEARD 8
#define RADAR_PEERS 12

typedef struct {
    uint8_t mac[6];
    int8_t rssi;   // dBm, 127 = unknown
    int16_t cm;    // FTM distance, -1 = unknown
} radar_heard_t;

// One peer as net.c knows it (cr_net_peers).
typedef struct {
    uint8_t mac[6];
    char name[13];
    uint8_t kind;          // 1 BeagleBadge, 2 Crystal, 3 badge os
    int8_t rssi;           // what I hear from it (max over 4 s), 127 unknown
    int8_t their;          // what it hears from me (its heard list), 127 unknown
    int16_t cm;            // FTM distance to me, -1 unknown
    int32_t age_ms;        // since last heard
    uint8_t nh;            // its own heard list (shared in its announces)
    radar_heard_t h[RADAR_HEARD];
} radar_peer_t;

#define RADAR_NODES 9      // me + up to 8 badges on the map

typedef struct {
    uint8_t mac[6];
    char name[13];
    uint8_t kind;
    float x, y;            // metres, me at (0, 0)
    bool placed;
} radar_node_t;

typedef struct {           // smoothed link between two MACs
    uint8_t a[6], b[6];    // a < b (memcmp)
    float db;              // EMA of the RSSI, dBm
    int16_t cm;            // last FTM distance, -1 none
    int32_t seen;          // radar time (ms) of the last sample
} radar_edge_t;

#define RADAR_EDGES 48

typedef struct {
    uint8_t me[6];
    char my_name[13];
    int32_t now;
    radar_edge_t e[RADAR_EDGES];
    int ne;
    // the current list: peers sorted by distance
    int np;
    struct { uint8_t mac[6]; char name[13]; uint8_t kind; float m; int8_t rssi; int32_t age_ms; } p[RADAR_PEERS];
    // the map (nodes[0] = me), valid when nn >= 3
    radar_node_t n[RADAR_NODES];
    int nn;
    float d[RADAR_NODES][RADAR_NODES]; // metres, < 0 unknown
    bool partial;          // some badge-to-badge distances are unknown
    bool net_on;
} radar_t;

// Distance model (PROTOCOL.md): d = 10 ^ ((RSSI_1M - rssi) / (10 N)).
#define RADAR_RSSI_1M (-45.0f)
#define RADAR_N 2.5f
#define RADAR_ALPHA 0.35f  // EMA weight of a new sample (one per update, ~1 Hz)
#define RADAR_FORGET_MS 30000

float radar_metres(float rssi_db);
void radar_init(radar_t *r, const uint8_t me[6], const char *my_name);
// One update (about once a second): new peer snapshot at time now (ms).
void radar_update(radar_t *r, const radar_peer_t *peers, int n, int32_t now);
// Fits the 2-D layout (called by radar_update; exposed for tests).
void radar_fit(radar_t *r);
float radar_stress(const radar_t *r);
// A hash of what the screen shows (rounded), to skip refreshes.
uint32_t radar_signature(const radar_t *r);
void radar_draw(const radar_t *r, uint8_t *plane);
