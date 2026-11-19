/*
 * Copyright (c) 2026 Seeed Studio
 *
 * SPDX-License-Identifier: Apache-2.0
 */

/*
 * Factory SN programming tool (tests/clip).
 *
 * The production line flashes this firmware, writes the product serial
 * into the dual raw backup sectors, then flashes the production image.
 * The same record format as applications/clip/src/config.c (shared via
 * include/clip_sn.h).
 *
 * Shell commands:
 *   sn read              - dump both copies (validity, seq, value)
 *   sn set <sn>          - write both copies (charset [A-Za-z0-9._-],
 *                           1-32 chars; refuses to overwrite a valid SN
 *                           unless "force" is given first)
 *   sn force             - allow the next `sn set` to overwrite
 *   sn erase             - erase both sectors (rework path)
 */

#include <zephyr/kernel.h>
#include <zephyr/shell/shell.h>
#include <zephyr/storage/flash_map.h>
#include <zephyr/sys/crc.h>
#include <errno.h>
#include <string.h>

#include "clip_sn.h"

static bool sn_force_next;

static int sn_read_copy(bool slot_a, struct clip_sn_record *rec)
{
    const struct flash_area *fa;
    int rc = flash_area_open(slot_a ? FIXED_PARTITION_ID(sn_a_partition)
                                    : FIXED_PARTITION_ID(sn_b_partition),
                             &fa);
    if (rc != 0) {
        return rc;
    }
    rc = flash_area_read(fa, 0, rec, sizeof(*rec));
    flash_area_close(fa);
    if (rc != 0) {
        return rc;
    }
    if (rec->magic != CLIP_SN_MAGIC || rec->len == 0 ||
        rec->len > CLIP_SN_MAX_LEN || rec->sn[rec->len] != '\0' ||
        rec->crc != crc32_ieee((const uint8_t *)rec,
                                offsetof(struct clip_sn_record, crc))) {
        return -EINVAL;
    }
    return 0;
}

static int sn_write_copy(bool slot_a, const struct clip_sn_record *rec)
{
    const struct flash_area *fa;
    int rc = flash_area_open(slot_a ? FIXED_PARTITION_ID(sn_a_partition)
                                    : FIXED_PARTITION_ID(sn_b_partition),
                             &fa);
    if (rc != 0) {
        return rc;
    }
    rc = flash_area_erase(fa, 0, fa->fa_size);
    if (rc == 0) {
        rc = flash_area_write(fa, 0, rec, sizeof(*rec));
    }
    flash_area_close(fa);
    return rc;
}

static uint32_t sn_best_seq(void)
{
    struct clip_sn_record rec;
    uint32_t best = 0;

    if (sn_read_copy(true, &rec) == 0 && rec.seq > best) {
        best = rec.seq;
    }
    if (sn_read_copy(false, &rec) == 0 && rec.seq > best) {
        best = rec.seq;
    }
    return best;
}

static int cmd_sn_read(const struct shell *sh, size_t argc, char **argv)
{
    ARG_UNUSED(argc);
    ARG_UNUSED(argv);
    struct clip_sn_record rec;

    for (int slot_a = 1; slot_a >= 0; slot_a--) {
        int rc = sn_read_copy(slot_a, &rec);

        if (rc == 0) {
            shell_print(sh, "copy %c: VALID   seq=%u sn=%s",
                        slot_a ? 'A' : 'B', rec.seq, rec.sn);
        } else {
            shell_print(sh, "copy %c: INVALID (rc=%d)", slot_a ? 'A' : 'B', rc);
        }
    }
    return 0;
}

static int cmd_sn_set(const struct shell *sh, size_t argc, char **argv)
{
    if (argc < 2) {
        shell_error(sh, "usage: sn set <sn>");
        return -EINVAL;
    }
    const char *sn = argv[1];

    if (clip_sn_validate(sn) != 0) {
        shell_error(sh, "invalid SN (charset [A-Za-z0-9._-], 1-32 chars)");
        return -EINVAL;
    }

    uint32_t seq = sn_best_seq();
    if (seq != 0 && !sn_force_next) {
        struct clip_sn_record cur;
        const char *cur_sn = "<unreadable>";

        if (sn_read_copy(true, &cur) == 0 || sn_read_copy(false, &cur) == 0) {
            cur_sn = cur.sn;
        }
        shell_error(sh, "SN already set (%s); run 'sn force' to allow rewrite",
                    cur_sn);
        return -EALREADY;
    }
    sn_force_next = false;

    struct clip_sn_record rec = {0};
    rec.magic = CLIP_SN_MAGIC;
    rec.seq = seq + 1;
    rec.len = strlen(sn);
    memcpy(rec.sn, sn, rec.len);
    rec.crc = crc32_ieee((const uint8_t *)&rec,
                          offsetof(struct clip_sn_record, crc));

    int rc_a = sn_write_copy(true, &rec);
    int rc_b = sn_write_copy(false, &rec);
    if (rc_a != 0 || rc_b != 0) {
        shell_error(sh, "write failed (A=%d B=%d)", rc_a, rc_b);
        return rc_a ? rc_a : rc_b;
    }
    shell_print(sh, "SN written: %s (seq=%u, both copies)", sn, rec.seq);
    return 0;
}

static int cmd_sn_force(const struct shell *sh, size_t argc, char **argv)
{
    ARG_UNUSED(argc);
    ARG_UNUSED(argv);
    sn_force_next = true;
    shell_print(sh, "next 'sn set' may overwrite");
    return 0;
}

static int cmd_sn_erase(const struct shell *sh, size_t argc, char **argv)
{
    ARG_UNUSED(argc);
    ARG_UNUSED(argv);
    const struct flash_area *fa;

    for (int slot_a = 0; slot_a <= 1; slot_a++) {
        int rc = flash_area_open(slot_a ? FIXED_PARTITION_ID(sn_a_partition)
                                        : FIXED_PARTITION_ID(sn_b_partition),
                                 &fa);
        if (rc != 0) {
            shell_error(sh, "open %c failed: %d", slot_a ? 'A' : 'B', rc);
            return rc;
        }
        rc = flash_area_erase(fa, 0, fa->fa_size);
        flash_area_close(fa);
        if (rc != 0) {
            shell_error(sh, "erase %c failed: %d", slot_a ? 'A' : 'B', rc);
            return rc;
        }
    }
    sn_force_next = false;
    shell_print(sh, "both SN copies erased");
    return 0;
}

SHELL_STATIC_SUBCMD_SET_CREATE(sub_sn,
    SHELL_CMD_ARG(read, NULL, "Dump both SN backup copies", cmd_sn_read, 1, 0),
    SHELL_CMD_ARG(set, NULL, "Write SN: set <sn> (rewrites need 'force')",
                  cmd_sn_set, 2, 0),
    SHELL_CMD_ARG(force, NULL, "Allow the next set to overwrite", cmd_sn_force, 1, 0),
    SHELL_CMD_ARG(erase, NULL, "Erase both SN sectors (rework)", cmd_sn_erase, 1, 0),
    SHELL_SUBCMD_SET_END
);

SHELL_CMD_REGISTER(sn, &sub_sn, "Factory SN programming", NULL);
