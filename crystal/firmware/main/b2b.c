// Badge-to-badge update over USB-C (C side of src/apps/b2b.cr).
//
// This badge turns its USB-C port into a USB host (ESP32-S3 USB OTG on
// GPIO19/20, the same pins as the USB-Serial/JTAG console), waits for
// another badge on a USB-C to USB-C cable, and copies its own firmware onto it
// through the target's ROM serial loader:
//   bootloader 0x0..0x8000, partition table 0x8000..0x9000, the running app
//   -> the target's ota_0 (0x20000), otadata (0xF000..0x11000) erased so
//   the target boots ota_0. NVS (0x9000) is left alone: the target keeps its
//   settings.
//
// Idea and flash plan after yigitabi5444's badge os (main/app_update.c, which
// uses esp-serial-flasher). This is our own small implementation of the
// ROM loader protocol (SLIP framed commands, as in esptool) on top of the
// vendored USB host CDC-ACM driver (components/usb_host_cdc_acm).
//
// Hardware (schematic power.kicad_sch): USB-C CC1/CC2 have 5.1k pull-downs
// (sink only) and VBUS feeds only the charger and, through a Schottky diode, the
// LDO. The host badge cannot power the target, so BOTH badges must run on
// battery. The target's USB-Serial/JTAG needs no VBUS.
// A target on our firmware (console on USB-Serial/JTAG) is reset into its
// ROM loader through the DTR/RTS lines, as esptool does. A target whose
// firmware uses USB OTG (stock MicroPython) needs BOOT held while RESET is tapped.
//
// usb_host_install takes the PHY away from USB-Serial/JTAG until reboot,
// so once started, the console is gone and leaving the app restarts the badge.
#include <stdint.h>
#include <stdbool.h>
#include <string.h>
#include <stdio.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/stream_buffer.h"
#include "esp_err.h"
#include "esp_log.h"
#include "esp_flash.h"
#include "esp_partition.h"
#include "esp_ota_ops.h"
#include "esp_image_format.h"
#include "esp_system.h"
#include "esp_intr_alloc.h"
#include "esp_rom_md5.h"
#include "usb/usb_host.h"
#include "usb/cdc_acm_host.h"

#define TAG "b2b"

// cr_b2b_state() values; keep in sync with src/apps/b2b.cr.
enum {
    ST_IDLE = 0,     // not started
    ST_WAIT = 1,     // waiting for a badge on the cable
    ST_SYNC = 2,     // resetting it into its ROM loader, syncing
    ST_COPY = 3,     // writing (cr_b2b_pct)
    ST_VERIFY = 4,   // MD5 check
    ST_DONE = 5,     // target written and reset
    ST_FAIL = 6,     // cr_b2b_msg says why; another try starts on cr_b2b_start
};

#define APP_DST     0x20000
#define OTADATA     0xF000
#define OTADATA_LEN 0x2000
#define BLK         0x400 // ROM loader flash block

static volatile int32_t s_state = ST_IDLE;
static volatile int32_t s_pct;
static volatile bool s_host;     // USB host installed (PHY taken)
static volatile bool s_go;       // start request
static char s_msg[64] = "";
static StreamBufferHandle_t s_rx;
static cdc_acm_dev_hdl_t s_dev;
static volatile bool s_gone;     // the device disconnected
static uint32_t s_done, s_total;

static void fail(const char *m)
{
    snprintf(s_msg, sizeof s_msg, "%s", m);
    ESP_LOGW(TAG, "%s", m);
}

// ---- USB ------------------------------------------------------------------

static void usb_lib_task(void *arg)
{
    for (;;) {
        uint32_t flags;
        usb_host_lib_handle_events(portMAX_DELAY, &flags);
        if (flags & USB_HOST_LIB_EVENT_FLAGS_NO_CLIENTS) usb_host_device_free_all();
    }
}

static bool rx_cb(const uint8_t *data, size_t len, void *arg)
{
    xStreamBufferSend(s_rx, data, len, 0);
    return true;
}

static void ev_cb(const cdc_acm_host_dev_event_data_t *ev, void *arg)
{
    if (ev->type == CDC_ACM_HOST_DEVICE_DISCONNECTED) {
        s_gone = true;
        cdc_acm_host_close(ev->data.cdc_hdl);
        if (ev->data.cdc_hdl == s_dev) s_dev = NULL;
    }
}

static bool dev_open(uint32_t timeout_ms)
{
    cdc_acm_host_device_config_t cfg = {
        .connection_timeout_ms = timeout_ms,
        .out_buffer_size = 4096,
        .in_buffer_size = 512,
        .event_cb = ev_cb,
        .data_cb = rx_cb,
        .user_arg = NULL,
    };
    s_gone = false;
    cdc_acm_dev_hdl_t h = NULL;
    if (cdc_acm_host_open_v1_dispatch(CDC_HOST_ANY_VID, CDC_HOST_ANY_PID, 0, &cfg, &h) != ESP_OK) return false;
    s_dev = h;
    xStreamBufferReset(s_rx);
    return true;
}

static void dev_close(void)
{
    if (s_dev) cdc_acm_host_close(s_dev);
    s_dev = NULL;
}

static void lines(bool dtr, bool rts)
{
    if (s_dev) cdc_acm_host_set_control_line_state(s_dev, dtr, rts);
}

// esptool's USB-Serial/JTAG reset into the ROM loader.
static void reset_to_loader(void)
{
    lines(false, false);
    vTaskDelay(pdMS_TO_TICKS(100));
    lines(true, false);
    vTaskDelay(pdMS_TO_TICKS(100));
    lines(false, true);
    vTaskDelay(pdMS_TO_TICKS(100));
    lines(false, false);
}

// Normal reset (RTS pulse, boot pin released).
static void reset_run(void)
{
    lines(false, true);
    vTaskDelay(pdMS_TO_TICKS(100));
    lines(false, false);
}

// ---- ROM loader protocol (SLIP) ---------------------------------------------

static uint8_t s_frame[BLK + 64];
static uint8_t s_tx[2 * (BLK + 64) + 4];
static uint8_t s_resp[128];

static bool slip_send(const uint8_t *p, size_t n)
{
    size_t k = 0;
    s_tx[k++] = 0xC0;
    for (size_t i = 0; i < n; i++) {
        if (p[i] == 0xC0) { s_tx[k++] = 0xDB; s_tx[k++] = 0xDC; }
        else if (p[i] == 0xDB) { s_tx[k++] = 0xDB; s_tx[k++] = 0xDD; }
        else s_tx[k++] = p[i];
    }
    s_tx[k++] = 0xC0;
    if (!s_dev) return false;
    return cdc_acm_host_data_tx_blocking(s_dev, s_tx, k, 1000) == ESP_OK;
}

// One SLIP frame into s_resp; returns its length or -1 on timeout.
static int slip_recv(uint32_t timeout_ms)
{
    TickType_t end = xTaskGetTickCount() + pdMS_TO_TICKS(timeout_ms);
    int n = 0;
    bool in = false, esc = false;
    for (;;) {
        TickType_t now = xTaskGetTickCount();
        if ((int32_t)(end - now) <= 0) return -1;
        uint8_t c;
        if (xStreamBufferReceive(s_rx, &c, 1, end - now) != 1) return -1;
        if (!in) {
            if (c == 0xC0) { in = true; n = 0; }
            continue;
        }
        if (c == 0xC0) {
            if (n == 0) continue; // back-to-back delimiters
            return n;
        }
        if (esc) {
            c = c == 0xDC ? 0xC0 : (c == 0xDD ? 0xDB : c);
            esc = false;
        } else if (c == 0xDB) {
            esc = true;
            continue;
        }
        if (n < (int)sizeof s_resp) s_resp[n++] = c;
    }
}

static void put32(uint8_t *p, uint32_t v)
{
    p[0] = v; p[1] = v >> 8; p[2] = v >> 16; p[3] = v >> 24;
}

// Sends command `op` with `data` (n bytes, `chk` checksum); waits for its
// response. Returns true on status OK; the response body is in s_resp+8.
static int s_body_len;
static bool command(uint8_t op, const uint8_t *data, size_t n, uint32_t chk, uint32_t timeout_ms)
{
    s_frame[0] = 0x00;
    s_frame[1] = op;
    s_frame[2] = n;
    s_frame[3] = n >> 8;
    put32(s_frame + 4, chk);
    if (n) memcpy(s_frame + 8, data, n);
    if (!slip_send(s_frame, 8 + n)) return false;
    for (int tries = 0; tries < 16; tries++) {
        int r = slip_recv(timeout_ms);
        if (r < 0) return false;
        if (r < 8 || s_resp[0] != 0x01 || s_resp[1] != op) continue; // stale reply
        int len = s_resp[2] | (s_resp[3] << 8);
        if (len > r - 8) len = r - 8;
        s_body_len = len;
        // ROM loader: 4 status bytes at the end (stub: 2); status 0 = OK.
        int st = len >= 4 ? len - 4 : (len >= 2 ? len - 2 : -1);
        if (st < 0) return false;
        return s_resp[8 + st] == 0;
    }
    return false;
}

static bool sync_loader(void)
{
    uint8_t d[36] = {0x07, 0x07, 0x12, 0x20};
    memset(d + 4, 0x55, 32);
    for (int i = 0; i < 10; i++) {
        if (command(0x08, d, sizeof d, 0, 200)) {
            vTaskDelay(pdMS_TO_TICKS(50));
            xStreamBufferReset(s_rx); // the ROM answers SYNC several times
            return true;
        }
        if (s_gone) return false;
    }
    return false;
}

static bool flash_begin(uint32_t off, uint32_t size)
{
    uint8_t d[20];
    uint32_t blocks = (size + BLK - 1) / BLK;
    put32(d, size);
    put32(d + 4, blocks);
    put32(d + 8, BLK);
    put32(d + 12, off);
    put32(d + 16, 0); // not encrypted (ESP32-S3 ROM takes this 5th word)
    // the ROM erases the whole region here: ~30 s per MB worst case
    return command(0x02, d, sizeof d, 0, 3000 + size / 1024 * 40);
}

static uint8_t s_blk[16 + BLK];

static bool flash_block(const uint8_t *p, uint32_t n, uint32_t seq)
{
    put32(s_blk, BLK);
    put32(s_blk + 4, seq);
    put32(s_blk + 8, 0);
    put32(s_blk + 12, 0);
    memcpy(s_blk + 16, p, n);
    memset(s_blk + 16 + n, 0xFF, BLK - n);
    uint32_t chk = 0xEF;
    for (int i = 0; i < BLK; i++) chk ^= s_blk[16 + i];
    for (int r = 0; r < 3; r++)
        if (command(0x03, s_blk, sizeof s_blk, chk, 3000)) return true;
    return false;
}

static void progress(uint32_t n)
{
    s_done += n;
    s_pct = s_total ? (int32_t)((uint64_t)s_done * 100 / s_total) : 0;
    if (s_pct > 100) s_pct = 100;
}

// Our flash [src, src+len) -> target [dst, dst+len); len 0 with fill =
// write 0xFF (erase) instead.
static uint8_t s_buf[BLK];

static bool copy(uint32_t src, uint32_t dst, uint32_t len, bool erase_only)
{
    if (!flash_begin(dst, len)) { fail("flash begin failed"); return false; }
    uint32_t seq = 0;
    for (uint32_t off = 0; off < len; off += BLK) {
        uint32_t n = len - off < BLK ? len - off : BLK;
        if (erase_only) memset(s_buf, 0xFF, n);
        else if (esp_flash_read(NULL, s_buf, src + off, n) != ESP_OK) { fail("local flash read failed"); return false; }
        if (!flash_block(s_buf, n, seq++)) { fail("write failed (cable?)"); return false; }
        progress(n);
        if (s_gone) { fail("badge disconnected"); return false; }
    }
    return true;
}

// MD5 of the target's [addr, addr+len) against ours.
static bool verify(uint32_t addr_here, uint32_t addr_there, uint32_t len)
{
    uint8_t d[16];
    put32(d, addr_there);
    put32(d + 4, len);
    put32(d + 8, 0);
    put32(d + 12, 0);
    if (!command(0x13, d, sizeof d, 0, 5000 + len / 1024 * 10)) return false;
    if (s_body_len < 32) return false;
    md5_context_t ctx;
    esp_rom_md5_init(&ctx);
    for (uint32_t off = 0; off < len; off += BLK) {
        uint32_t n = len - off < BLK ? len - off : BLK;
        if (esp_flash_read(NULL, s_buf, addr_here + off, n) != ESP_OK) return false;
        esp_rom_md5_update(&ctx, s_buf, n);
    }
    uint8_t dig[16];
    esp_rom_md5_final(dig, &ctx);
    char hex[33];
    for (int i = 0; i < 16; i++) snprintf(hex + 2 * i, 3, "%02x", dig[i]);
    // ROM replies 32 hex chars, the stub 16 raw bytes
    return memcmp(hex, s_resp + 8, 32) == 0;
}

static bool run_once(void)
{
    const esp_partition_t *app = esp_ota_get_running_partition();
    esp_partition_pos_t pos = {.offset = app->address, .size = app->size};
    esp_image_metadata_t img;
    if (esp_image_verify(ESP_IMAGE_VERIFY_SILENT, &pos, &img) != ESP_OK) {
        fail("own app image invalid");
        return false;
    }
    uint32_t app_len = (img.image_len + 0xFFF) & ~0xFFFu;

    s_state = ST_WAIT;
    s_msg[0] = 0;
    while (!dev_open(1000))
        if (!s_go) return false; // cancelled
    s_state = ST_SYNC;
    ESP_LOGI(TAG, "device connected, resetting it into the ROM loader");
    // Our firmware: DTR/RTS reset into the loader; the device re-enumerates.
    // A badge already in its loader (BOOT + RESET) just answers SYNC.
    bool synced = sync_loader();
    if (!synced) {
        reset_to_loader();
        for (int i = 0; i < 30 && !s_gone; i++) vTaskDelay(pdMS_TO_TICKS(50));
        if (s_gone) {
            vTaskDelay(pdMS_TO_TICKS(300));
            int k = 0;
            while (!dev_open(1000) && ++k < 5) {}
        }
        synced = s_dev && sync_loader();
    }
    if (!synced) {
        fail("no ROM loader: hold BOOT, tap RESET");
        dev_close();
        return false;
    }
    uint8_t att[8] = {0};
    if (!command(0x0D, att, sizeof att, 0, 3000)) { fail("SPI attach failed"); dev_close(); return false; }
    uint8_t par[24];
    put32(par, 0);
    put32(par + 4, 8 * 1024 * 1024);
    put32(par + 8, 64 * 1024);
    put32(par + 12, 4096);
    put32(par + 16, 256);
    put32(par + 20, 0xFFFF);
    command(0x0B, par, sizeof par, 0, 3000); // flash geometry (8 MB)

    s_state = ST_COPY;
    s_done = 0;
    s_total = 0x8000 + 0x1000 + app_len + OTADATA_LEN;
    s_pct = 0;
    bool ok = copy(0x0, 0x0, 0x8000, false) &&          // bootloader
              copy(0x8000, 0x8000, 0x1000, false) &&    // partition table
              copy(app->address, APP_DST, app_len, false) && // app -> ota_0
              copy(0, OTADATA, OTADATA_LEN, true);      // otadata erased: boot ota_0
    if (ok) {
        s_state = ST_VERIFY;
        ok = verify(0x0, 0x0, 0x9000) && verify(app->address, APP_DST, app_len);
        if (!ok) fail("verify (MD5) failed");
    }
    if (ok) {
        uint8_t stay[4] = {1, 0, 0, 0};
        command(0x04, stay, 4, 0, 1000); // FLASH_END, stay in the loader
        reset_run();                     // then a normal reset: it boots the new image
    }
    vTaskDelay(pdMS_TO_TICKS(200));
    dev_close();
    ESP_LOGI(TAG, "%s, %u bytes", ok ? "done" : "failed", (unsigned)s_done);
    return ok;
}

static void b2b_task(void *arg)
{
    for (;;) {
        while (!s_go) vTaskDelay(pdMS_TO_TICKS(50));
        bool ok = run_once();
        if (!s_go && !ok) {
            s_state = ST_IDLE;
            continue;
        }
        s_go = false;
        s_state = ok ? ST_DONE : ST_FAIL;
    }
}

// Starts (or retries) an update. The first call installs the USB host.
int32_t cr_b2b_start(void)
{
    if (!s_host) {
        s_rx = xStreamBufferCreate(2048, 1);
        if (!s_rx) return -1;
        usb_host_config_t hc = {.skip_phy_setup = false, .intr_flags = ESP_INTR_FLAG_LEVEL1};
        if (usb_host_install(&hc) != ESP_OK) return -2;
        s_host = true;
        xTaskCreate(usb_lib_task, "usb_lib", 4096, NULL, 20, NULL);
        cdc_acm_host_driver_config_t dc = {.driver_task_stack_size = 4096, .driver_task_priority = 10,
                                           .xCoreID = 0, .new_dev_cb = NULL};
        if (cdc_acm_host_install(&dc) != ESP_OK) return -3;
        xTaskCreate(b2b_task, "b2b", 6144, NULL, 5, NULL);
    }
    s_msg[0] = 0;
    s_go = true;
    return 0;
}

void cr_b2b_stop(void) { s_go = false; }
int32_t cr_b2b_state(void) { return s_state; }
int32_t cr_b2b_pct(void) { return s_pct; }
bool cr_b2b_host(void) { return s_host; }
const char *cr_b2b_msg(void) { return s_msg; }
void cr_b2b_restart(void) { esp_restart(); }
