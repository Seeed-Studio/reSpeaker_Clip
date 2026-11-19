/*
 * Copyright (c) 2026 Seeed Studio
 *
 * SPDX-License-Identifier: Apache-2.0
 */

/*
 * Factory SN programming tool (tests/clip).
 *
 * The production line flashes this firmware, writes the product serial
 * into the fixed .sn_backup section (0xFE000, app-slot tail, outside
 * the linked image — same records as applications/clip/src/config.c,
 * shared via include/clip_sn.h), then flashes the production image.
 *
 * Shell commands:
 *   sn read              - dump both records (validity, seq, value)
 *   sn set <sn>          - write both records (charset [A-Za-z0-9._-],
 *                           1-32 chars; refuses to overwrite a valid SN
 *                           unless "force" was given first)
 *   sn force             - allow the next `sn set` to overwrite
 *   sn erase             - erase the backup sector (rework path)
 */

#include <zephyr/kernel.h>
#include <zephyr/shell/shell.h>
#include <zephyr/sys/crc.h>
#include <zephyr/device.h>
#include <zephyr/devicetree.h>
#include <zephyr/drivers/flash.h>
#include <zephyr/fs/fs.h>
#include <zephyr/settings/settings.h>
#include <errno.h>
#include <string.h>

#include "clip_sn.h"

/* Must match linker/sn_reserve.ld in the application. This factory
 * image has no such section (different link base), so the address is a
 * plain constant here. */
#define SN_SECTOR_ADDR 0xFE000UL
#define SN_SLOT_OFF_A  0
#define SN_SLOT_OFF_B  0x100

/* Mirrors of the application's other two copies: an independent
 * LittleFS file and the settings key. The factory firmware mounts /lfs
 * and initializes the settings file backend in pmic.c (fg_storage_init)
 * with the same paths as the application, so writes land in exactly
 * the places the application reads. */
#define SN_FILE_PATH  "/lfs/sn.bin"
#define SN_SETTINGS_KEY "sn/value"

static bool sn_force_next;

static const struct device *sn_flash_dev(void)
{
	const struct device *dev = DEVICE_DT_GET(DT_CHOSEN(zephyr_flash_controller));

	if (!device_is_ready(dev)) {
		return NULL;
	}
	return dev;
}

static int sn_read_slot(struct clip_sn_record *rec, uint32_t off)
{
	memcpy(rec, (const void *)(SN_SECTOR_ADDR + off), sizeof(*rec));
	if (rec->magic != CLIP_SN_MAGIC || rec->len == 0 ||
	    rec->len > CLIP_SN_MAX_LEN || rec->sn[rec->len] != '\0' ||
	    rec->crc != crc32_ieee((const uint8_t *)rec,
				    offsetof(struct clip_sn_record, crc))) {
		return -EINVAL;
	}
	return 0;
}

static int sn_write_both(const struct clip_sn_record *rec)
{
	const struct device *dev = sn_flash_dev();
	int rc;

	if (dev == NULL) {
		return -ENODEV;
	}
	rc = flash_erase(dev, SN_SECTOR_ADDR, 0x1000);
	if (rc != 0) {
		return rc;
	}
	rc = flash_write(dev, SN_SECTOR_ADDR + SN_SLOT_OFF_A, rec, sizeof(*rec));
	if (rc != 0) {
		return rc;
	}
	return flash_write(dev, SN_SECTOR_ADDR + SN_SLOT_OFF_B, rec, sizeof(*rec));
}

static uint32_t sn_best_seq(char *cur_sn, size_t cur_len)
{
	struct clip_sn_record rec;
	uint32_t best = 0;

	if (sn_read_slot(&rec, SN_SLOT_OFF_A) == 0 && rec.seq >= best) {
		best = rec.seq;
		strncpy(cur_sn, rec.sn, cur_len - 1);
		cur_sn[cur_len - 1] = '\0';
	}
	if (sn_read_slot(&rec, SN_SLOT_OFF_B) == 0 && rec.seq >= best) {
		best = rec.seq;
		strncpy(cur_sn, rec.sn, cur_len - 1);
		cur_sn[cur_len - 1] = '\0';
	}
	return best;
}

static int sn_file_write(const struct clip_sn_record *rec)
{
	struct fs_file_t f;
	int rc;

	fs_file_t_init(&f);
	rc = fs_open(&f, SN_FILE_PATH, FS_O_CREATE | FS_O_WRITE | FS_O_TRUNC);
	if (rc != 0) {
		return rc;
	}
	rc = fs_write(&f, rec, sizeof(*rec));
	if (rc != (ssize_t)sizeof(*rec)) {
		rc = -EIO;
	} else {
		rc = 0;
	}
	fs_close(&f);
	return rc;
}

static int cmd_sn_read(const struct shell *sh, size_t argc, char **argv)
{
	ARG_UNUSED(argc);
	ARG_UNUSED(argv);
	struct clip_sn_record rec;

	for (int i = 0; i < 2; i++) {
		uint32_t off = i == 0 ? SN_SLOT_OFF_A : SN_SLOT_OFF_B;
		int rc = sn_read_slot(&rec, off);

		if (rc == 0) {
			shell_print(sh, "record %c: VALID   seq=%u sn=%s",
				    i == 0 ? 'A' : 'B', rec.seq, rec.sn);
		} else {
			shell_print(sh, "record %c: INVALID (rc=%d)",
				    i == 0 ? 'A' : 'B', rc);
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

	char cur_sn[CLIP_SN_MAX_LEN + 1] = "";
	uint32_t seq = sn_best_seq(cur_sn, sizeof(cur_sn));
	if (seq != 0 && !sn_force_next) {
		shell_error(sh, "SN already set (%s); run 'sn force' to allow rewrite",
			    cur_sn[0] ? cur_sn : "<unreadable>");
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

	int rc = sn_write_both(&rec);
	if (rc != 0) {
		shell_error(sh, "write failed: %d", rc);
		return rc;
	}
	/* Mirror into the LittleFS file and the settings key so the SN
	 * survives even a full app-core erase (the application heals the
	 * fixed-section pair from these on next boot). */
	if (sn_file_write(&rec) != 0) {
		shell_warn(sh, "sn.bin mirror write failed");
	}
	if (settings_save_one(SN_SETTINGS_KEY, sn, strlen(sn)) != 0) {
		shell_warn(sh, "settings mirror write failed");
	}
	shell_print(sh, "SN written: %s (seq=%u, all 3 copies)", sn, rec.seq);
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
	const struct device *dev = sn_flash_dev();
	int rc;

	if (dev == NULL) {
		shell_error(sh, "flash device unavailable");
		return -ENODEV;
	}
	rc = flash_erase(dev, SN_SECTOR_ADDR, 0x1000);
	if (rc != 0) {
		shell_error(sh, "erase failed: %d", rc);
		return rc;
	}
	(void)fs_unlink(SN_FILE_PATH);
	(void)settings_delete(SN_SETTINGS_KEY);
	sn_force_next = false;
	shell_print(sh, "SN backup sector, sn.bin and settings key erased");
	return 0;
}

SHELL_STATIC_SUBCMD_SET_CREATE(sub_sn,
	SHELL_CMD_ARG(read, NULL, "Dump both SN backup records", cmd_sn_read, 1, 0),
	SHELL_CMD_ARG(set, NULL, "Write SN: set <sn> (rewrites need 'force')",
		      cmd_sn_set, 2, 0),
	SHELL_CMD_ARG(force, NULL, "Allow the next set to overwrite", cmd_sn_force, 1, 0),
	SHELL_CMD_ARG(erase, NULL, "Erase the SN sector (rework)", cmd_sn_erase, 1, 0),
	SHELL_SUBCMD_SET_END
);

SHELL_CMD_REGISTER(sn, &sub_sn, "Factory SN programming", NULL);
