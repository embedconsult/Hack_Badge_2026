// Host test helpers for the content apps (test/apps/run.sh).
#pragma once
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
static int s_fail;
#define CHECK(c) do { if (!(c)) { printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #c); s_fail++; } } while (0)
static char *slurp(const char *path, int *n)
{
    FILE *f = fopen(path, "rb");
    if (!f) { printf("missing %s\n", path); exit(2); }
    fseek(f, 0, SEEK_END);
    *n = (int)ftell(f);
    fseek(f, 0, SEEK_SET);
    char *b = malloc(*n + 1);
    if (fread(b, 1, *n, f) != (size_t)*n) exit(2);
    b[*n] = 0;
    fclose(f);
    return b;
}
// plane (960x672, 1 = ink) -> PBM (P4: 1 = black too)
static void write_pbm(const char *path, const uint8_t *p)
{
    FILE *f = fopen(path, "wb");
    fprintf(f, "P4\n960 672\n");
    fwrite(p, 1, 120 * 672, f);
    fclose(f);
}
