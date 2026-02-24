/*
 * Copyright (c) 2025 Seeed Technology Co., Ltd.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>
#include <zephyr/fs/fs.h>
#include <string.h>
#include <stdio.h>

#include "transfer.h"
#include "storage.h"
#include "ble_svc.h"

LOG_MODULE_REGISTER(transfer, LOG_LEVEL_INF);

/* Transfer state */
static struct transfer_info current_transfer = {0};
static struct k_work transfer_work;
static struct fs_file_t transfer_file;
static bool transfer_file_open = false;

/* Transfer configuration */
#define TRANSFER_CHUNK_SIZE 500
#define TRANSFER_STACK_SIZE 4096
#define TRANSFER_PRIORITY 5

/* Forward declarations */
static void transfer_worker(struct k_work *work);
static int transfer_next_file(void);
static int transfer_send_chunk(void);
static void transfer_cleanup(void);

int transfer_init(void)
{
	memset(&current_transfer, 0, sizeof(current_transfer));
	k_work_init(&transfer_work, transfer_worker);

	LOG_INF("Transfer subsystem initialized");

	return 0;
}

int transfer_start(const char *session_id, const char *filename)
{
	int err;

	if (transfer_is_active()) {
		LOG_WRN("Transfer already in progress");
		return -EBUSY;
	}

	if (!storage_is_mounted()) {
		LOG_ERR("SD card not mounted");
		return -ENODEV;
	}

	/* Check if session exists */
	if (!storage_session_exists(session_id)) {
		LOG_ERR("Session not found: %s", session_id);
		return -ENOENT;
	}

	/* Initialize transfer state */
	memset(&current_transfer, 0, sizeof(current_transfer));
	current_transfer.state = TRANSFER_STATE_TRANSMITTING;
	current_transfer.direction = TRANSFER_DIR_UPLOAD;

	strncpy(current_transfer.session_id, session_id, sizeof(current_transfer.session_id) - 1);

	if (filename) {
		/* Transfer single file */
		strncpy(current_transfer.current_file, filename, sizeof(current_transfer.current_file) - 1);
		current_transfer.total_files = 1;
	} else {
		/* Transfer entire session */
		current_transfer.file_index = 0;
		current_transfer.total_files = 0;  /* Will count files */
	}

	/* Start transfer worker */
	k_work_submit(&transfer_work);

	LOG_INF("Transfer started: %s%s%s", session_id, filename ? "/" : "", filename ? filename : "");

	return 0;
}

int transfer_pause(void)
{
	if (!transfer_is_active()) {
		return -EINVAL;
	}

	if (current_transfer.state == TRANSFER_STATE_TRANSMITTING) {
		current_transfer.state = TRANSFER_STATE_PAUSED;
		LOG_INF("Transfer paused");
		return 0;
	}

	return -EINVAL;
}

int transfer_resume(void)
{
	if (current_transfer.state != TRANSFER_STATE_PAUSED) {
		return -EINVAL;
	}

	current_transfer.state = TRANSFER_STATE_TRANSMITTING;
	k_work_submit(&transfer_work);

	LOG_INF("Transfer resumed");

	return 0;
}

int transfer_cancel(void)
{
	if (!transfer_is_active() && current_transfer.state != TRANSFER_STATE_PAUSED) {
		return -EINVAL;
	}

	LOG_INF("Transfer canceled");

	transfer_cleanup();

	return 0;
}

int transfer_get_progress(struct transfer_info *info)
{
	if (!info) {
		return -EINVAL;
	}

	memcpy(info, &current_transfer, sizeof(*info));

	return 0;
}

bool transfer_is_active(void)
{
	return (current_transfer.state == TRANSFER_STATE_TRANSMITTING ||
	        current_transfer.state == TRANSFER_STATE_PAUSED);
}

bool transfer_is_paused(void)
{
	return (current_transfer.state == TRANSFER_STATE_PAUSED);
}

enum transfer_state transfer_get_state(void)
{
	return current_transfer.state;
}

/* Internal functions */
static void transfer_worker(struct k_work *work)
{
	int ret;

	/* Check if paused */
	if (current_transfer.state == TRANSFER_STATE_PAUSED) {
		return;
	}

	/* Open first file if not already open */
	if (!transfer_file_open) {
		ret = transfer_next_file();
		if (ret != 0) {
			if (ret == -ENOENT) {
				/* No more files, transfer complete */
				current_transfer.state = TRANSFER_STATE_COMPLETED;
				LOG_INF("Transfer completed: %llu bytes", current_transfer.bytes_transferred);
				transfer_cleanup();
			} else {
				current_transfer.state = TRANSFER_STATE_ERROR;
				LOG_ERR("Transfer error: %d", ret);
				transfer_cleanup();
			}
			return;
		}
	}

	/* Send data chunks */
	while (current_transfer.state == TRANSFER_STATE_TRANSMITTING) {
		ret = transfer_send_chunk();
		if (ret != 0) {
			if (ret == -EOF) {
				/* File complete, move to next file */
				fs_close(&transfer_file);
				transfer_file_open = false;
				k_work_submit(&transfer_work);
				return;
			} else {
				current_transfer.state = TRANSFER_STATE_ERROR;
				LOG_ERR("Transfer send error: %d", ret);
				transfer_cleanup();
				return;
			}
		}

		/* Update progress */
		if (current_transfer.total_bytes > 0) {
			current_transfer.progress_percent =
				(uint8_t)((current_transfer.bytes_transferred * 100) / current_transfer.total_bytes);
		}

		/* Yield to avoid blocking other tasks */
		k_yield();
	}
}

static int transfer_next_file(void)
{
	char filepath[128];
	int ret;

	/* If filename is already set, open it */
	if (current_transfer.current_file[0] != '\0') {
		snprintf(filepath, sizeof(filepath), "/SD:/REC/%s/%s",
			 current_transfer.session_id, current_transfer.current_file);
	} else {
		/* TODO: Implement file listing and iteration */
		/* For now, just fail */
		return -ENOENT;
	}

	/* Open file */
	fs_file_t_init(&transfer_file);
	ret = fs_open(&transfer_file, filepath, FS_O_READ);
	if (ret != 0) {
		LOG_ERR("Failed to open file: %s (%d)", filepath, ret);
		return ret;
	}

	transfer_file_open = true;

	/* Get file size */
	struct fs_dirent entry;
	ret = fs_stat(filepath, &entry);
	if (ret == 0) {
		current_transfer.total_bytes += entry.size;
	}

	LOG_INF("Opened file: %s (%llu bytes)", current_transfer.current_file, entry.size);

	return 0;
}

static int transfer_send_chunk(void)
{
	uint8_t chunk[TRANSFER_CHUNK_SIZE];
	ssize_t bytes_read;
	int ret;

	/* Read chunk from file */
	bytes_read = fs_read(&transfer_file, chunk, TRANSFER_CHUNK_SIZE);
	if (bytes_read < 0) {
		LOG_ERR("File read error: %zd", bytes_read);
		return bytes_read;
	}

	if (bytes_read == 0) {
		/* End of file */
		return -EOF;
	}

	/* Send via BLE */
	ret = ble_svc_send_file_data(chunk, bytes_read);
	if (ret != 0) {
		LOG_DBG("BLE send error: %d (will retry)", ret);
		return ret;
	}

	current_transfer.bytes_transferred += bytes_read;

	return 0;
}

static void transfer_cleanup(void)
{
	if (transfer_file_open) {
		fs_close(&transfer_file);
		transfer_file_open = false;
	}

	if (current_transfer.state != TRANSFER_STATE_COMPLETED &&
	    current_transfer.state != TRANSFER_STATE_ERROR) {
		current_transfer.state = TRANSFER_STATE_IDLE;
	}

	memset(&current_transfer.current_file, 0, sizeof(current_transfer.current_file));

	LOG_INF("Transfer cleanup complete");
}
