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
#define TRANSFER_THREAD_STACK_SIZE 4096
#define TRANSFER_THREAD_PRIORITY 5

/* Transfer thread stack */
K_THREAD_STACK_DEFINE(transfer_thread_stack, TRANSFER_THREAD_STACK_SIZE);

/* Transfer thread state */
static struct k_thread transfer_thread_data;
static k_tid_t transfer_thread_id;
static K_SEM_DEFINE(transfer_trigger_sem, 0, 1);
static volatile bool transfer_thread_running = false;

/* Forward declarations */
static void transfer_thread_main(void *, void *, void *);
static int transfer_next_file(void);
static int transfer_send_chunk(void);
static void transfer_cleanup(void);

int transfer_init(void)
{
	memset(&current_transfer, 0, sizeof(current_transfer));

	/* Set thread running flag BEFORE creating thread */
	transfer_thread_running = true;

	/* Create transfer thread */
	transfer_thread_id = k_thread_create(&transfer_thread_data,
	                                     transfer_thread_stack,
	                                     TRANSFER_THREAD_STACK_SIZE,
	                                     transfer_thread_main,
	                                     NULL, NULL, NULL,
                                     TRANSFER_THREAD_PRIORITY,
	                                     0, K_NO_WAIT);
	if (transfer_thread_id == NULL) {
		LOG_ERR("Failed to create transfer thread");
		transfer_thread_running = false;
		return -ENOMEM;
	}

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
		/* Transfer single file - check if file exists */
		char filepath[128];
		struct fs_dirent entry;

		snprintf(filepath, sizeof(filepath), "/SD:/REC/%s/%s", session_id, filename);
		if (fs_stat(filepath, &entry) != 0) {
			LOG_ERR("File not found: %s", filepath);
			return -ENOENT;
		}

		/* Check if file is being written */
		if (storage_file_is_writing(session_id, filename)) {
			LOG_ERR("File is currently being written: %s/%s", session_id, filename);
			return -EBUSY;
		}
		/* Transfer single file */
		strncpy(current_transfer.current_file, filename, sizeof(current_transfer.current_file) - 1);
		current_transfer.total_files = 1;
		/* Set total bytes for progress reporting */
		current_transfer.total_bytes = entry.size;
		LOG_INF("Single file transfer: %s (%u bytes)", filename, (uint32_t)entry.size);
	} else {
		/* Transfer entire session - list all files */
		err = storage_list_session_files(session_id, current_transfer.file_list,
		                                  TRANSFER_MAX_FILES);
		if (err < 0) {
			LOG_ERR("Failed to list session files: %d", err);
			return err;
		}
		current_transfer.total_files = err;
		current_transfer.file_index = 0;
		LOG_INF("Session has %u files to transfer", current_transfer.total_files);
		for (int i = 0; i < err; i++) {
			LOG_DBG("  File %d: %s", i, current_transfer.file_list[i]);
		}
	}

	/* Start transfer thread */
	transfer_thread_running = true;
	k_sem_give(&transfer_trigger_sem);

	LOG_INF("Transfer started: %s%s%s", session_id, filename ? "/" : "", filename ? filename : "");

	/* Small delay to ensure filesystem is ready */
	k_sleep(K_MSEC(100));

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
	k_sem_give(&transfer_trigger_sem);

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
static void transfer_thread_main(void *p1, void *p2, void *p3)
{
	ARG_UNUSED(p1);
	ARG_UNUSED(p2);
	ARG_UNUSED(p3);

	while (transfer_thread_running) {
		/* Wait for transfer start signal */
		k_sem_take(&transfer_trigger_sem, K_FOREVER);

		LOG_INF("Transfer thread woken: state=%d, file_open=%d",
		         current_transfer.state, transfer_file_open);

		if (!transfer_thread_running) {
			break;
		}

		/* Process transfer */
		int ret;

		/* Check if paused */
		if (current_transfer.state == TRANSFER_STATE_PAUSED) {
			continue;
		}

		/* Open first file if not already open */
		if (!transfer_file_open) {
			ret = transfer_next_file();
			if (ret != 0) {
				if (ret == -ENOENT) {
					/* No more files, transfer complete */
					current_transfer.state = TRANSFER_STATE_COMPLETED;
					LOG_INF("Transfer completed: %u bytes", (uint32_t)current_transfer.bytes_transferred);
					transfer_cleanup();
					continue;  /* Wait for next transfer */
				} else {
					current_transfer.state = TRANSFER_STATE_ERROR;
					LOG_ERR("Transfer error: %d", ret);
					transfer_cleanup();
					continue;
				}
			}
		}

		/* Send data chunks */
		while (transfer_thread_running &&
		       current_transfer.state == TRANSFER_STATE_TRANSMITTING) {
			ret = transfer_send_chunk();
			if (ret != 0) {
				if (ret == -EOF) {
					/* File complete, move to next file */
					fs_close(&transfer_file);
					transfer_file_open = false;
					/* Clear current file to trigger next file load */
					memset(&current_transfer.current_file, 0, sizeof(current_transfer.current_file));
					/* Break to let outer loop handle next file */
					break;
				} else {
					current_transfer.state = TRANSFER_STATE_ERROR;
					LOG_ERR("Transfer send error: %d", ret);
					transfer_cleanup();
					break;
				}
			}

			/* Update progress */
			if (current_transfer.total_bytes > 0) {
				current_transfer.progress_percent =
					(uint8_t)((current_transfer.bytes_transferred * 100) / current_transfer.total_bytes);
			}

			/* Check if paused */
			if (current_transfer.state == TRANSFER_STATE_PAUSED) {
				break;
			}

			/* Small delay to avoid blocking other tasks */
			k_sleep(K_MSEC(10));
		}
	}

	LOG_INF("Transfer thread exiting");
}

static int transfer_next_file(void)
{
	char filepath[128];
	int ret;

	LOG_DBG("transfer_next_file: current_file='%s', file_index=%u/%u",
	         current_transfer.current_file, current_transfer.file_index, current_transfer.total_files);

	/* If filename is already set, open it */
	if (current_transfer.current_file[0] != '\0') {
		/* Check if file is being written before opening */
		if (storage_file_is_writing(current_transfer.session_id,
			current_transfer.current_file)) {
			LOG_WRN("File is being written, skipping: %s/%s",
				 current_transfer.session_id, current_transfer.current_file);
			/* Clear current file and signal next file */
			current_transfer.current_file[0] = '\0';
			/* Try to get next file */
			return transfer_next_file();
		}

		snprintf(filepath, sizeof(filepath), "/SD:/REC/%s/%s",
			 current_transfer.session_id, current_transfer.current_file);
	} else {
		/* Get next file from file list */
		if (current_transfer.file_index >= current_transfer.total_files) {
			/* No more files */
			return -ENOENT;
		}

		/* Copy next filename from list */
		strncpy(current_transfer.current_file,
		        current_transfer.file_list[current_transfer.file_index],
		        sizeof(current_transfer.current_file) - 1);
		current_transfer.file_index++;

		/* Now open the file */
		snprintf(filepath, sizeof(filepath), "/SD:/REC/%s/%s",
		         current_transfer.session_id, current_transfer.current_file);
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
		LOG_INF("Opened file: %s (%u bytes, total: %u)",
		         current_transfer.current_file, (uint32_t)entry.size,
		         (uint32_t)current_transfer.total_bytes);
	} else {
		LOG_INF("Opened file: %s (size unknown)", current_transfer.current_file);
	}

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
		LOG_ERR("File read error: %zd (file_open=%d, offset=%llu)",
		        bytes_read, transfer_file_open, current_transfer.bytes_transferred);
		return bytes_read;
	}

	if (bytes_read == 0) {
		/* End of file */
		LOG_INF("End of file reached (total: %llu bytes)", current_transfer.bytes_transferred);
		return -EOF;
	}

	/* Send via BLE */
	ret = ble_svc_send_file_data(chunk, bytes_read);
	if (ret != 0) {
		LOG_ERR("BLE send error: %d (chunk size: %zd) - NOT COUNTED", ret, bytes_read);
		return ret;
	}

	/* Only increment bytes_transferred if send actually succeeded */
	current_transfer.bytes_transferred += bytes_read;
	LOG_DBG("Sent chunk: %zd bytes, total: %llu", bytes_read, current_transfer.bytes_transferred);

	return 0;
}

static void transfer_cleanup(void)
{
	if (transfer_file_open) {
		fs_close(&transfer_file);
		transfer_file_open = false;
	}

	/* Always reset state to IDLE after cleanup */
	current_transfer.state = TRANSFER_STATE_IDLE;
	memset(&current_transfer.current_file, 0, sizeof(current_transfer.current_file));
	current_transfer.file_index = 0;
	current_transfer.total_files = 0;
	current_transfer.bytes_transferred = 0;
	current_transfer.total_bytes = 0;
	current_transfer.progress_percent = 0;

	LOG_INF("Transfer cleanup complete");
}
