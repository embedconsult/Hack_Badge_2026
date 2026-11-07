// Robot source slots for the ROBOTS app (src/apps/robots.cr), in the
// "storage" data partition (0x620000, unused by the firmware otherwise):
// SLOTS slots of SLOT_SIZE bytes, each one flash erase unit pair.
//   slot k at k * SLOT_SIZE: "RBT1", u32 length, u32 checksum of the source,
//   u32 0, the robot's name (main("...")) zero padded to 16 bytes, then the
//   source (crystal-robots language, plain text).
// Written by the shell (`robot put`), the Settings page (/robots) and later
// the badge link; read by the main task when a battle starts. One mutex
// serialises flash access.
#include <stdint.h>
#include <stdbool.h>
#include <string.h>
#include <stdio.h>
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "esp_partition.h"
#include "nvs.h"

#define SLOTS 8
#define SLOT_SIZE 8192
#define HDR 32
#define NAME 16
#define SRC_MAX (SLOT_SIZE - HDR)

static const esp_partition_t *s_part;
static SemaphoreHandle_t s_lock;

static bool open_part(void)
{
    if (!s_lock) s_lock = xSemaphoreCreateMutex();
    if (!s_part)
        s_part = esp_partition_find_first(ESP_PARTITION_TYPE_DATA, ESP_PARTITION_SUBTYPE_DATA_SPIFFS, "storage");
    return s_part && s_lock && s_part->size >= SLOTS * SLOT_SIZE;
}

int32_t cr_robot_slots(void) { return SLOTS; }
int32_t cr_robot_max(void) { return SRC_MAX; }

static uint32_t sum(const uint8_t *p, int32_t n)
{
    uint32_t s = 0;
    for (int32_t i = 0; i < n; i++) s = s * 31 + p[i];
    return s;
}

// Header of slot k: length, or -1 when empty / not valid.
static int32_t slot_len(int32_t k, uint32_t *chk)
{
    uint8_t h[HDR];
    if (esp_partition_read(s_part, (size_t)k * SLOT_SIZE, h, HDR) != ESP_OK) return -1;
    if (memcmp(h, "RBT1", 4) != 0) return -1;
    uint32_t len, c;
    memcpy(&len, h + 4, 4);
    memcpy(&c, h + 8, 4);
    if (len > SRC_MAX) return -1;
    if (chk) *chk = c;
    return (int32_t)len;
}

// Source length in slot k, -1 if empty.
int32_t cr_robot_len(int32_t k)
{
    if (k < 0 || k >= SLOTS || !open_part()) return -1;
    xSemaphoreTake(s_lock, portMAX_DELAY);
    int32_t n = slot_len(k, NULL);
    xSemaphoreGive(s_lock);
    return n;
}

// Copy slot k's source into buf (at most max bytes); its length, -1 if
// empty or damaged.
int32_t cr_robot_read(int32_t k, uint8_t *buf, int32_t max)
{
    if (k < 0 || k >= SLOTS || !open_part()) return -1;
    xSemaphoreTake(s_lock, portMAX_DELAY);
    uint32_t c = 0;
    int32_t n = slot_len(k, &c);
    if (n >= 0) {
        if (n > max) n = max;
        if (esp_partition_read(s_part, (size_t)k * SLOT_SIZE + HDR, buf, n) != ESP_OK || sum(buf, n) != c) n = -1;
    }
    xSemaphoreGive(s_lock);
    return n;
}

// Name saved with slot k into out (zero-terminated, out has NAME + 1
// bytes); false if the slot is empty.
bool cr_robot_name(int32_t k, char *out)
{
    out[0] = 0;
    if (k < 0 || k >= SLOTS || !open_part()) return false;
    xSemaphoreTake(s_lock, portMAX_DELAY);
    bool ok = slot_len(k, NULL) >= 0 &&
              esp_partition_read(s_part, (size_t)k * SLOT_SIZE + 16, out, NAME) == ESP_OK;
    xSemaphoreGive(s_lock);
    out[ok ? NAME : 0] = 0;
    return ok;
}

// Store src[0, n] in slot k with its name (zero-terminated, NULL = none;
// n = 0 empties the slot). True on success.
bool cr_robot_write(int32_t k, const uint8_t *src, int32_t n, const char *name)
{
    if (k < 0 || k >= SLOTS || n < 0 || n > SRC_MAX || !open_part()) return false;
    xSemaphoreTake(s_lock, portMAX_DELAY);
    bool ok = esp_partition_erase_range(s_part, (size_t)k * SLOT_SIZE, SLOT_SIZE) == ESP_OK;
    if (ok && n > 0) {
        uint8_t h[HDR] = {'R', 'B', 'T', '1'};
        uint32_t len = (uint32_t)n, c = sum(src, n);
        memcpy(h + 4, &len, 4);
        memcpy(h + 8, &c, 4);
        if (name) strncpy((char *)h + 16, name, NAME);
        ok = esp_partition_write(s_part, (size_t)k * SLOT_SIZE + HDR, src, n) == ESP_OK &&
             esp_partition_write(s_part, (size_t)k * SLOT_SIZE, h, HDR) == ESP_OK; // header last
    }
    xSemaphoreGive(s_lock);
    printf("robots: slot %d %s (%d bytes)\n", (int)k, ok ? "saved" : "write FAILED", (int)n);
    return ok;
}

// ---- tournament standings (Tour.save bytes, src/robots/tourney.cr) ---------------
// NVS namespace "robots": "tourney" = the last tournament on this badge
// (which = 0), "tourney_net" = the last badge-link tournament (which = 1).

static const char *tbl_key(int32_t which) { return which ? "tourney_net" : "tourney"; }

bool cr_robot_tbl_save(int32_t which, const uint8_t *p, int32_t n)
{
    nvs_handle_t h;
    if (n <= 0 || nvs_open("robots", NVS_READWRITE, &h) != ESP_OK) return false;
    bool ok = nvs_set_blob(h, tbl_key(which), p, n) == ESP_OK && nvs_commit(h) == ESP_OK;
    nvs_close(h);
    printf("robots: standings saved (%s, %d bytes)%s\n", tbl_key(which), (int)n, ok ? "" : " FAILED");
    return ok;
}

// The saved standings into p (max bytes); their length, -1 if none.
int32_t cr_robot_tbl_load(int32_t which, uint8_t *p, int32_t max)
{
    nvs_handle_t h;
    if (nvs_open("robots", NVS_READONLY, &h) != ESP_OK) return -1;
    size_t n = max;
    int32_t r = nvs_get_blob(h, tbl_key(which), p, &n) == ESP_OK ? (int32_t)n : -1;
    nvs_close(h);
    return r;
}

#define TBL_HDR 22
#define TBL_ENTRY 28
#define TBL_MAX (TBL_HDR + 48 * TBL_ENTRY)

static int g16(const uint8_t *p) { return p[0] | p[1] << 8; }
static uint32_t g32(const uint8_t *p) { return p[0] | p[1] << 8 | p[2] << 16 | (uint32_t)p[3] << 24; }

// Shell `robot standings [net]`: the saved table on the console.
void cr_robot_tbl_print(int32_t which)
{
    static uint8_t p[TBL_MAX];
    int32_t n = cr_robot_tbl_load(which, p, sizeof p);
    if (n < TBL_HDR || memcmp(p, "RTT1", 4) || n < TBL_HDR + p[4] * TBL_ENTRY) {
        printf("robot: no %stournament saved yet\n", which ? "badge link " : "");
        return;
    }
    printf("%stournament: %d robots, %d battles + final, seed %u, hash %08x\n", which ? "badge link " : "", p[4],
           g16(p + 16), (unsigned)g32(p + 8), (unsigned)g32(p + 12));
    printf("  #  robot             pts    W    D    P  avg dmg\n");
    for (int k = 0; k < p[4]; k++) {
        const uint8_t *e = p + TBL_HDR + k * TBL_ENTRY;
        int pl = g16(e + 20);
        printf("%3d  %-16.16s %5d %4d %4d %4d %8d%s\n", k + 1, (const char *)e, g16(e + 22), g16(e + 16), g16(e + 18),
               pl, pl ? (int)((g32(e + 24) + pl / 2) / pl) : 0, k == p[18] ? "  champion" : "");
    }
}
