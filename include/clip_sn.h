/*
 * Copyright (c) 2026 Seeed Studio
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#ifndef CLIP_SN_H_
#define CLIP_SN_H_

#include <stdint.h>
#include <stddef.h>
#include <string.h>

/* Factory SN on-flash record, shared between the application
 * (applications/clip/src/config.c) and the factory firmware SN tool
 * (tests/clip/src/sn_prog.c). Two raw copies live in the sn-a/sn-b
 * 4KB sectors at the tail of the netcore OTA slot; each carries a
 * magic, a per-write sequence number and a CRC32 over the preceding
 * fields. The copy with the highest seq that passes CRC wins. */
#define CLIP_SN_MAGIC      0x31504C43 /* "CLP1" little-endian */
#define CLIP_SN_MAX_LEN    32

struct clip_sn_record {
    uint32_t magic;
    uint32_t seq;                /* increments per write, 0 = none */
    uint32_t len;                /* strlen(sn), 1..CLIP_SN_MAX_LEN */
    char sn[CLIP_SN_MAX_LEN];    /* zero padded */
    uint32_t crc;                /* crc32_ieee() over the fields above */
};

/* Charset check for a NUL-terminated SN: [A-Za-z0-9._-], 1..32 chars.
 * Returns 0 when valid, -1 otherwise. Kept inline so both the app and
 * the factory tool enforce the identical rule. */
static inline int clip_sn_validate(const char *sn)
{
    if (sn == NULL || sn[0] == '\0') {
        return -1;
    }
    size_t len = strlen(sn);
    if (len > CLIP_SN_MAX_LEN) {
        return -1;
    }
    for (size_t i = 0; i < len; i++) {
        char c = sn[i];
        bool ok = (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
                  (c >= '0' && c <= '9') || c == '.' || c == '_' || c == '-';
        if (!ok) {
            return -1;
        }
    }
    return 0;
}

#endif /* CLIP_SN_H_ */
