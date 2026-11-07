// stb_image v2.30 (Sean Barrett, public domain / MIT; main/stb_image.h,
// unchanged) for the content apps: JPEG (baseline and progressive: Hackaday's
// resized images are progressive, which the ROM TJpgDec cannot read) and PNG.
// On the badge every buffer goes to PSRAM.
#ifdef ESP_PLATFORM
#include "esp_heap_caps.h"
#define STBI_MALLOC(n) heap_caps_malloc(n, MALLOC_CAP_SPIRAM)
#define STBI_REALLOC(p, n) heap_caps_realloc(p, n, MALLOC_CAP_SPIRAM)
#define STBI_FREE(p) heap_caps_free(p)
#endif
#define STB_IMAGE_IMPLEMENTATION
#define STBI_ONLY_JPEG
#define STBI_ONLY_PNG
#define STBI_NO_STDIO
#define STBI_NO_LINEAR
#define STBI_NO_HDR
#define STBI_ASSERT(x)
#include "stb_image.h"
