/*
 * Copyright (c) 2023 Nordic Semiconductor ASA
 *
 * SPDX-License-Identifier: LicenseRef-Nordic-5-Clause
 */

#include <zephyr/kernel.h>
#include <zephyr/device.h>
#include <zephyr/storage/disk_access.h>
#include <zephyr/fs/fs.h>
#include <ff.h>
#include <zephyr/logging/log.h>
#include <zephyr/shell/shell.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "sdcard.h"

LOG_MODULE_REGISTER(sdcard, LOG_LEVEL_INF);

static FATFS fat_fs;
static struct fs_mount_t mp = {
	.type = FS_FATFS,
	.fs_data = &fat_fs,
};

static const char *disk_mount_pt = "/SD:";
static bool sd_mounted = false;

/* Format SD card */
static int cmd_sd_format(const struct shell *sh, size_t argc, char **argv)
{
	int rc;

	if (sd_mounted) {
		shell_print(sh, "Unmounting SD card first...");
		rc = fs_unmount(&mp);
		if (rc != 0) {
			shell_error(sh, "Failed to unmount: %d", rc);
			return rc;
		}
		sd_mounted = false;
	}

	shell_print(sh, "Formatting SD card (this may take a while)...");

	/* Format the SD card */
	rc = fs_mkfs(FS_FATFS, (uintptr_t)disk_mount_pt, NULL, 0);
	if (rc != 0) {
		shell_error(sh, "Format failed: %d", rc);
		return rc;
	}

	shell_print(sh, "Format complete! Mounting...");

	/* Re-mount after format */
	mp.mnt_point = disk_mount_pt;
	rc = fs_mount(&mp);
	if (rc != 0) {
		shell_error(sh, "Mount failed after format: %d", rc);
		return rc;
	}

	sd_mounted = true;
	shell_print(sh, "SD card ready at %s", mp.mnt_point);

	return 0;
}

/* Speed test */
static int cmd_sd_speed(const struct shell *sh, size_t argc, char **argv)
{
	int rc;
	struct fs_file_t file;
	char *write_buf;
	char *read_buf;
	uint32_t file_size = 1024 * 1024; /* 1MB test file */
	uint32_t chunk_size = 4096;
	uint64_t start_time, end_time, write_time, read_time;

	if (!sd_mounted) {
		shell_error(sh, "SD card not mounted");
		return -ENODEV;
	}

	/* Parse optional file size argument */
	if (argc >= 2) {
		file_size = atoi(argv[1]) * 1024; /* Convert KB to bytes */
		if (file_size < 1024) file_size = 1024;
		if (file_size > 10 * 1024 * 1024) file_size = 10 * 1024 * 1024; /* Max 10MB */
	}

	shell_print(sh, "SD card speed test (file size: %u KB)...", file_size / 1024);

	/* Allocate buffers */
	write_buf = k_malloc(chunk_size);
	read_buf = k_malloc(chunk_size);
	if (!write_buf || !read_buf) {
		shell_error(sh, "Failed to allocate buffers");
		rc = -ENOMEM;
		goto cleanup;
	}

	/* Fill write buffer with pattern */
	for (uint32_t i = 0; i < chunk_size; i++) {
		write_buf[i] = (char)(i & 0xFF);
	}

	/* Write test */
	shell_print(sh, "Write test...");
	fs_file_t_init(&file);
	rc = fs_open(&file, "/SD:/speedtest.tmp", FS_O_CREATE | FS_O_WRITE);
	if (rc != 0) {
		shell_error(sh, "Failed to create file: %d", rc);
		goto cleanup;
	}

	start_time = k_uptime_get();
	uint32_t total_written = 0;
	while (total_written < file_size) {
		uint32_t to_write = chunk_size;
		if (total_written + to_write > file_size) {
			to_write = file_size - total_written;
		}

		rc = fs_write(&file, write_buf, to_write);
		if (rc < 0) {
			shell_error(sh, "Write failed: %d", rc);
			fs_close(&file);
			goto cleanup;
		}
		total_written += rc;
	}
	fs_close(&file);
	end_time = k_uptime_get();

	write_time = end_time - start_time;
	uint32_t write_speed_kb = (file_size / 1024 * 1000) / write_time; /* KB/s */

	/* Read test */
	shell_print(sh, "Read test...");
	rc = fs_open(&file, "/SD:/speedtest.tmp", FS_O_READ);
	if (rc != 0) {
		shell_error(sh, "Failed to open file: %d", rc);
		goto cleanup;
	}

	start_time = k_uptime_get();
	uint32_t total_read = 0;
	while (total_read < file_size) {
		uint32_t to_read = chunk_size;
		if (total_read + to_read > file_size) {
			to_read = file_size - total_read;
		}

		rc = fs_read(&file, read_buf, to_read);
		if (rc < 0) {
			shell_error(sh, "Read failed: %d", rc);
			fs_close(&file);
			goto cleanup;
		}
		total_read += rc;
	}
	fs_close(&file);
	end_time = k_uptime_get();

	read_time = end_time - start_time;
	uint32_t read_speed_kb = (file_size / 1024 * 1000) / read_time; /* KB/s */

	/* Print results */
	shell_print(sh, "");
	shell_print(sh, "=== SD Card Speed Test Results ===");
	shell_print(sh, "File size: %u KB", file_size / 1024);
	shell_print(sh, "Write: %u KB/s (%u ms)", write_speed_kb, (uint32_t)write_time);
	shell_print(sh, "Read:  %u KB/s (%u ms)", read_speed_kb, (uint32_t)read_time);
	shell_print(sh, "================================");

	/* Delete test file */
	fs_unlink("/SD:/speedtest.tmp");
	shell_print(sh, "Test file deleted");

	rc = 0;

cleanup:
	if (write_buf) k_free(write_buf);
	if (read_buf) k_free(read_buf);
	return rc;
}

/* Shell command to show SD card status */
static int cmd_sd_status(const struct shell *sh, size_t argc, char **argv)
{
	if (sd_mounted) {
		shell_print(sh, "SD card status: MOUNTED at %s", disk_mount_pt);
	} else {
		shell_print(sh, "SD card status: NOT MOUNTED");
	}

	return 0;
}

/* Mount SD card */
static int cmd_sd_mount(const struct shell *sh, size_t argc, char **argv)
{
	int rc;

	if (sd_mounted) {
		shell_print(sh, "SD card already mounted at %s", disk_mount_pt);
		return 0;
	}

	shell_print(sh, "Initializing SD card...");
	rc = disk_access_init("SD");
	if (rc != 0) {
		shell_error(sh, "SD card initialization failed: %d", rc);
		return rc;
	}

	shell_print(sh, "Mounting SD card...");
	mp.mnt_point = disk_mount_pt;
	rc = fs_mount(&mp);
	if (rc != 0) {
		shell_error(sh, "Mount failed: %d (not formatted?)", rc);
		shell_print(sh, "Use 'sd format' to format the SD card");
		return rc;
	}

	sd_mounted = true;
	shell_print(sh, "SD card mounted at %s", disk_mount_pt);
	return 0;
}

/* Unmount SD card */
static int cmd_sd_umount(const struct shell *sh, size_t argc, char **argv)
{
	int rc;

	if (!sd_mounted) {
		shell_print(sh, "SD card not mounted");
		return 0;
	}

	shell_print(sh, "Unmounting SD card...");
	rc = fs_unmount(&mp);
	if (rc != 0) {
		shell_error(sh, "Unmount failed: %d", rc);
		return rc;
	}

	sd_mounted = false;
	shell_print(sh, "SD card unmounted");
	return 0;
}

SHELL_STATIC_SUBCMD_SET_CREATE(sd_cmds,
	SHELL_CMD(mount, NULL, "Mount SD card", cmd_sd_mount),
	SHELL_CMD(umount, NULL, "Unmount SD card", cmd_sd_umount),
	SHELL_CMD(format, NULL, "Format SD card as FAT32", cmd_sd_format),
	SHELL_CMD_ARG(speed, NULL, "Speed test [size_kb]", cmd_sd_speed, 1, 1),
	SHELL_CMD(status, NULL, "Show SD card status", cmd_sd_status),
	SHELL_SUBCMD_SET_END
);

SHELL_CMD_REGISTER(sd, &sd_cmds, "SD card commands", NULL);

int sdcard_init(void)
{
	int rc;

	LOG_INF("Initializing SD card (built-in)...");

	/* Initialize SD card disk */
	rc = disk_access_init("SD");
	if (rc != 0) {
		LOG_ERR("SD card initialization failed: %d", rc);
		LOG_ERR("Use 'sd format' to format the SD card");
		return rc;
	}

	/* Try to mount the SD card */
	mp.mnt_point = disk_mount_pt;
	rc = fs_mount(&mp);
	if (rc != 0) {
		LOG_WRN("SD card mount failed: %d (not formatted?)", rc);
		LOG_INF("Use 'sd format' to format the SD card as FAT32");
		/* Don't fail, allow system to boot */
		return 0;
	}

	sd_mounted = true;
	LOG_INF("SD card mounted at %s", mp.mnt_point);
	LOG_INF("Commands: sd status, sd speed [size_kb], sd format");

	return 0;
}
