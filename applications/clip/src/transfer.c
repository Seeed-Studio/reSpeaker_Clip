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
#include <stdlib.h>

#include "transfer.h"
#include "storage.h"
#include "ble_svc.h"
#include "clip.h"

LOG_MODULE_REGISTER(transfer, LOG_LEVEL_INF);

/* Transfer state */
static struct transfer_info current_transfer = {0};
static struct k_work transfer_work;
static struct fs_file_t transfer_file;
static bool transfer_file_open = false;

/* Track last successfully transferred file to avoid skipping after refresh */
static char last_transferred_file[32] = {0};

/* Transfer configuration */
/* 240 bytes = 1 BLE notification (MTU 247 - 3 ATT header) for optimal throughput */
#define TRANSFER_CHUNK_SIZE 240

/* Transfer thread stack */
K_THREAD_STACK_DEFINE(transfer_thread_stack, CLIP_TRANSFER_STACK_SIZE);

/* Transfer thread state */
static struct k_thread transfer_thread_data;
static k_tid_t transfer_thread_id;
static K_SEM_DEFINE(transfer_trigger_sem, 0, 1);
static volatile bool transfer_thread_running = false;
static volatile bool transfer_thread_waiting = false;  /* Thread is waiting on semaphore */
static volatile bool transfer_is_resume = false;  /* Is this a resume transfer (not for current recording)? */

/* Forward declarations */
static void transfer_thread_main(void *, void *, void *);
static int transfer_next_file(void);
static int transfer_send_chunk(void);
static void transfer_cleanup(void);

int transfer_init(void)
{
	memset(&current_transfer, 0, sizeof(current_transfer));
	memset(last_transferred_file, 0, sizeof(last_transferred_file));

	/* Set thread running flag BEFORE creating thread */
	transfer_thread_running = true;

	/* Create transfer thread */
	transfer_thread_id = k_thread_create(&transfer_thread_data,
	                                     transfer_thread_stack,
	                                     CLIP_TRANSFER_STACK_SIZE,
	                                     transfer_thread_main,
	                                     NULL, NULL, NULL,
                                     CLIP_TRANSFER_THREAD_PRIORITY,
	                                     0, K_NO_WAIT);
	if (transfer_thread_id == NULL) {
		LOG_ERR("Failed to create transfer thread");
		transfer_thread_running = false;
		return -ENOMEM;
	}

	return 0;
}

int transfer_start(const char *session_id, const char *filename)
{
	int err;

	/* Check if transfer is already active and sending data */
	if (transfer_is_active() && transfer_file_open) {
		return -EBUSY;
	}

	/* Check if this is a different session - if so, cancel old transfer */
	if (transfer_is_active() &&
	    strncmp(current_transfer.session_id, session_id, sizeof(current_transfer.session_id)) != 0) {
		LOG_DBG("Canceling old transfer: %s", current_transfer.session_id);
		transfer_cleanup();
	}

	/* Wait for any previous transfer to complete and clean up */
	int retry_count = 0;
	while (current_transfer.state == TRANSFER_STATE_TRANSMITTING) {
		if (transfer_file_open) {
			return -EBUSY;
		}

		/* No file open - check if all files transferred */
		if (current_transfer.total_files > 0 &&
		    current_transfer.file_index >= current_transfer.total_files) {
			if (++retry_count > 20) {
				LOG_WRN("Transfer cleanup timeout");
				transfer_cleanup();
				break;
			}
			k_sleep(K_MSEC(50));
		} else {
			if (++retry_count > 50) {
				LOG_WRN("Transfer wait timeout");
				transfer_cleanup();
				break;
			}
			k_sleep(K_MSEC(100));
		}
	}

	if (transfer_is_active()) {
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

	/* Clear resume flag - this is a normal transfer, not a resume */
	transfer_is_resume = false;

	/* Initialize transfer state */
	memset(&current_transfer, 0, sizeof(current_transfer));
	memset(last_transferred_file, 0, sizeof(last_transferred_file));
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
		current_transfer.total_bytes = entry.size;
		LOG_INF("Transfer: %s (%u KB)", filename, (uint32_t)entry.size/1024);
	} else {
		/* Transfer entire session */
		err = storage_list_session_files(session_id, current_transfer.file_list,
		                                  TRANSFER_MAX_FILES);
		if (err < 0) {
			LOG_ERR("Failed to list files: %d", err);
			return err;
		}
		current_transfer.total_files = err;
		current_transfer.file_index = 0;
		if (err == 0) {
			LOG_INF("Transfer: %s (empty)", session_id);
		} else {
			LOG_INF("Transfer: %s (%u files)", session_id, current_transfer.total_files);
		}
	}

	/* Start transfer thread */
	transfer_thread_running = true;
	k_sem_give(&transfer_trigger_sem);

	return 0;
}

int transfer_resume_from(const char *session_id, const char *start_file)
{
	int err;

	/* Wait for any previous transfer to complete and clean up */
	int retry_count = 0;
	while (current_transfer.state == TRANSFER_STATE_TRANSMITTING) {
		if (transfer_file_open) {
			return -EBUSY;
		}

		if (++retry_count > 50) {
			LOG_WRN("Transfer cleanup timeout");
			transfer_cleanup();
			break;
		}
		k_sleep(K_MSEC(100));
	}

	if (transfer_is_active()) {
		return -EBUSY;
	}

	/* Wait for transfer thread to be blocked */
	retry_count = 0;
	while (!transfer_thread_waiting) {
		if (++retry_count > 100) {
			LOG_WRN("Thread block timeout");
			return -ETIMEDOUT;
		}
		k_sleep(K_MSEC(10));
	}

	k_sleep(K_MSEC(10));

	transfer_is_resume = true;

	if (!storage_is_mounted()) {
		LOG_ERR("SD card not mounted");
		return -ENODEV;
	}

	if (!session_id || !start_file) {
		return -EINVAL;
	}

	if (!storage_session_exists(session_id)) {
		LOG_ERR("Session not found: %s", session_id);
		return -ENOENT;
	}

	/* Set last_transferred_file to the file BEFORE start_file
	 * This way, the transfer logic will start from start_file
	 * For example, if start_file is "010.opus", we set last_transferred_file
	 * to "009.opus" so the search finds 010.opus as the next file.
	 *
	 * However, since files are sorted alphabetically, we can just set
	 * last_transferred_file to start_file and the logic will find the
	 * first file > start_file. Wait, that would skip start_file.
	 *
	 * Better approach: Set last_transferred_file to a value that's
	 * lexicographically just before start_file. Since we can't do that
	 * easily, let's just set it to start_file and modify the comparison
	 * logic to use >= instead of >.
	 *
	 * Actually, the simplest approach is to set last_transferred_file
	 * to the prefix before start_file. For "010.opus", use "009.opus".
	 * But we don't know the previous file.
	 *
	 * The cleanest solution: set last_transferred_file to start_file
	 * and use a flag to indicate we want to START from this file, not
	 * skip files BEFORE it.
	 *
	 * The simplest solution: directly use the file number as the index
	 */

	/* Initialize transfer state */
	memset(&current_transfer, 0, sizeof(current_transfer));
	current_transfer.state = TRANSFER_STATE_TRANSMITTING;
	current_transfer.direction = TRANSFER_DIR_UPLOAD;
	strncpy(current_transfer.session_id, session_id, sizeof(current_transfer.session_id) - 1);

	/* List all files in session */
	err = storage_list_session_files(session_id, current_transfer.file_list,
	                                  TRANSFER_MAX_FILES);
	if (err < 0) {
		LOG_ERR("Failed to list session files: %d", err);
		return err;
	}

	current_transfer.total_files = err;
	LOG_INF("Session has %u files to transfer", current_transfer.total_files);

	/* Debug: log file list content */
	LOG_INF("File list (first 5): %s, %s, %s, %s, %s",
	        current_transfer.file_list[0],
	        err > 1 ? current_transfer.file_list[1] : "",
	        err > 2 ? current_transfer.file_list[2] : "",
	        err > 3 ? current_transfer.file_list[3] : "",
	        err > 4 ? current_transfer.file_list[4] : "");

	/* Extract number from filename (e.g., "023.opus" -> 23)
	 * Files are numbered from 1, but indices are from 0
	 */
	int start_num = atoi(start_file);
	LOG_INF("Start file: %s (parsed num=%d)", start_file, start_num);
	if (start_num > 0 && start_num <= (int)current_transfer.total_files) {
		/* Start from this file (convert to 0-based index) */
		current_transfer.file_index = start_num - 1;
		LOG_INF("Starting from file %s (index=%u)", start_file, current_transfer.file_index);
	} else if (start_num > (int)current_transfer.total_files) {
		/* Requested file doesn't exist yet, start from last file
		 * This allows transfer to wait for new files during recording
		 */
		current_transfer.file_index = current_transfer.total_files - 1;
		LOG_INF("Start file %s doesn't exist yet (session has %u files), will wait for new files",
		        start_file, current_transfer.total_files);
		/* Set last_transferred_file to the last file so we wait for new ones */
		if (current_transfer.total_files > 0) {
			strncpy(last_transferred_file, current_transfer.file_list[current_transfer.total_files - 1],
			       sizeof(last_transferred_file) - 1);
		}
	} else {
		LOG_WRN("Invalid start file %s (num=%d), starting from beginning",
		        start_file, start_num);
		current_transfer.file_index = 0;
	}

	/* Start transfer thread */
	transfer_thread_running = true;
	k_sem_give(&transfer_trigger_sem);

	LOG_INF("Transfer resumed from: %s", start_file);

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

int transfer_get_current_session(char *session_id, size_t len, char *filename, size_t filename_len)
{
	if (!transfer_is_active()) {
		return -EINVAL;
	}

	if (session_id && len > 0) {
		strncpy(session_id, current_transfer.session_id, len - 1);
		session_id[len - 1] = '\0';
	}

	if (filename && filename_len > 0) {
		if (current_transfer.current_file[0] != '\0') {
			strncpy(filename, current_transfer.current_file, filename_len - 1);
			filename[filename_len - 1] = '\0';
		} else {
			filename[0] = '\0';
		}
	}

	return 0;
}

uint32_t transfer_get_total_files(void)
{
	if (!transfer_is_active()) {
		return 0;
	}

	return current_transfer.total_files;
}

int transfer_get_progress_lite(uint8_t *progress_percent, uint64_t *bytes_transferred,
                               uint64_t *total_bytes, enum transfer_state *state)
{
	if (!transfer_is_active()) {
		return -EINVAL;
	}

	if (progress_percent) {
		*progress_percent = current_transfer.progress_percent;
	}
	if (bytes_transferred) {
		*bytes_transferred = current_transfer.bytes_transferred;
	}
	if (total_bytes) {
		*total_bytes = current_transfer.total_bytes;
	}
	if (state) {
		*state = current_transfer.state;
	}

	return 0;
}

/* Internal functions */
static void transfer_thread_main(void *p1, void *p2, void *p3)
{
	ARG_UNUSED(p1);
	ARG_UNUSED(p2);
	ARG_UNUSED(p3);

	/* Wait for initial transfer start signal */
	transfer_thread_waiting = true;
	k_sem_take(&transfer_trigger_sem, K_FOREVER);
	transfer_thread_waiting = false;

	while (transfer_thread_running) {
		LOG_DBG("Transfer loop: state=%d, file_open=%d",
		         current_transfer.state, transfer_file_open);

		/* Process transfer */
		int ret;
		static int consecutive_file_errors = 0;  /* Track repeated file open failures */
		static int consecutive_empty_refreshes = 0;  /* Track repeated empty file list refreshes */

process_next_file:

		/* Check BLE connection first - if disconnected, stop waiting */
		if (!ble_svc_is_ready()) {
			LOG_INF("BLE disconnected, stopping transfer (process_next_file)");
			transfer_cleanup();
			/* Wait for next transfer */
			transfer_thread_waiting = true;
			k_sem_take(&transfer_trigger_sem, K_FOREVER);
			transfer_thread_waiting = false;
			goto process_next_file;
		}

		/* Check if paused */
		if (current_transfer.state == TRANSFER_STATE_PAUSED) {
			/* If paused due to BLE disconnect, stop transfer (don't wait for reconnect) */
			if (!ble_svc_is_ready()) {
				LOG_INF("BLE disconnected, stopping transfer");
				transfer_cleanup();
				/* Wait for next transfer */
				transfer_thread_waiting = true;
				k_sem_take(&transfer_trigger_sem, K_FOREVER);
				transfer_thread_waiting = false;
				goto process_next_file;
			}

			/* Resume transfer (still connected) */
			current_transfer.state = TRANSFER_STATE_TRANSMITTING;
			LOG_INF("Transfer resumed");
			goto process_next_file;
		}

		/* Open first file if not already open */
		if (!transfer_file_open) {
			ret = transfer_next_file();
			if (ret == 0) {
				consecutive_file_errors = 0;
			}
			if (ret != 0) {
				if (ret == -ENOTCONN) {
					/* BLE disconnected - stop transfer immediately */
					transfer_cleanup();
					/* Wait for next transfer */
					transfer_thread_waiting = true;
					k_sem_take(&transfer_trigger_sem, K_FOREVER);
					transfer_thread_waiting = false;
					goto process_next_file;
				} else if (ret == -ENOENT) {
					/* No more files - check if recording this session */
					extern bool audio_is_recording(void);
					extern const char *audio_get_session_id(void);

					bool is_recording = audio_is_recording();
					bool is_current_session = false;

					if (is_recording) {
						const char *recording_session = audio_get_session_id();
						is_current_session = (strcmp(current_transfer.session_id, recording_session) == 0);
					}

					/* Only wait if actively recording this session */
					if (is_recording && is_current_session) {
						/* Still recording, refresh file list and try again */
						ret = storage_list_session_files(current_transfer.session_id,
						                                 current_transfer.file_list,
						                                 TRANSFER_MAX_FILES);
						if (ret > 0) {
							consecutive_empty_refreshes = 0;

							current_transfer.total_files = ret;
							LOG_DBG("Refresh: %d files", ret);

							/* Find first file that hasn't been transferred yet */
							bool found_next = false;
							for (int i = 0; i < ret; i++) {
								if (current_transfer.file_list[i][0] == '\0') {
									break;
								}
								if (last_transferred_file[0] == '\0' ||
								    strcmp(current_transfer.file_list[i], last_transferred_file) > 0) {
									current_transfer.file_index = i;
									found_next = true;
									break;
								}
							}

							if (!found_next) {
								/* All files in list transferred
								 * Check if we should complete the transfer:
								 * 1. Device not recording -> complete immediately
								 * 2. Downloading old session (not current recording) -> complete immediately
								 * 3. All files for current recording session transferred -> complete immediately
								 */
								extern bool audio_is_recording(void);
								extern const char *audio_get_session_id(void);

								bool is_recording = audio_is_recording();
								bool is_current_session = false;

								if (is_recording) {
									const char *recording_session = audio_get_session_id();
									is_current_session = (strcmp(current_transfer.session_id, recording_session) == 0);
								}

								if (!is_recording || !is_current_session) {
									LOG_INF("Transfer completed: %u files", current_transfer.file_index);
									current_transfer.state = TRANSFER_STATE_COMPLETED;

									ble_svc_send_transfer_complete(current_transfer.session_id,
									                               (int)current_transfer.file_index);

									transfer_cleanup();
									transfer_thread_waiting = true;
									k_sem_take(&transfer_trigger_sem, K_FOREVER);
									transfer_thread_waiting = false;
									goto process_next_file;
								}

								k_sleep(K_MSEC(500));
								goto process_next_file;
							}
							goto process_next_file;
						} else {
							consecutive_empty_refreshes++;

							if (consecutive_empty_refreshes > 10) {
								extern bool audio_is_recording(void);
								if (!audio_is_recording()) {
									LOG_INF("Transfer completed: %u files", current_transfer.file_index);
									current_transfer.state = TRANSFER_STATE_COMPLETED;

									ble_svc_send_transfer_complete(current_transfer.session_id,
									                               (int)current_transfer.file_index);

									transfer_cleanup();
									transfer_thread_waiting = true;
									k_sem_take(&transfer_trigger_sem, K_FOREVER);
									transfer_thread_waiting = false;
									consecutive_empty_refreshes = 0;
									goto process_next_file;
								}
							}

							k_sleep(K_MSEC(500));
							goto process_next_file;
						}
					} else {
						LOG_INF("Transfer completed: %u files", current_transfer.file_index);
						current_transfer.state = TRANSFER_STATE_COMPLETED;

						ble_svc_send_transfer_complete(current_transfer.session_id,
						                               (int)current_transfer.file_index);

						transfer_cleanup();
						transfer_thread_waiting = true;
						k_sem_take(&transfer_trigger_sem, K_FOREVER);
						transfer_thread_waiting = false;
						consecutive_empty_refreshes = 0;  /* Reset for next transfer */
						goto process_next_file;
					}
				} else {
					/* Non-ENOENT error (e.g., file open failed) */
					consecutive_file_errors++;
					LOG_ERR("Transfer error: %d (consecutive errors: %d)", ret, consecutive_file_errors);

					/* If too many consecutive file errors, abort transfer */
					if (consecutive_file_errors > 10) {
						LOG_ERR("Too many consecutive file errors (%d), aborting transfer",
						        consecutive_file_errors);
						current_transfer.state = TRANSFER_STATE_ERROR;
						transfer_cleanup();
						transfer_thread_waiting = true;
						k_sem_take(&transfer_trigger_sem, K_FOREVER);
						transfer_thread_waiting = false;
						consecutive_file_errors = 0;  /* Reset for next transfer */
						goto process_next_file;
					}

					/* Wait a bit before retry */
					k_sleep(K_MSEC(100));
					goto process_next_file;
				}
			}
		}

		/* Send data chunks */
		while (transfer_thread_running &&
		       current_transfer.state == TRANSFER_STATE_TRANSMITTING) {

			/* Check if BLE is connected before sending */
			if (!ble_svc_is_ready()) {
				LOG_INF("BLE disconnected, pausing transfer");
				current_transfer.state = TRANSFER_STATE_PAUSED;
				if (transfer_file_open) {
					fs_close(&transfer_file);
					transfer_file_open = false;
				}
				break;
			}

			ret = transfer_send_chunk();
			if (ret != 0) {
				if (ret == -EOF) {
					/* File complete */
					LOG_DBG("File done: %s (%u KB)",
					        current_transfer.current_file,
					        (uint32_t)(current_transfer.bytes_transferred/1024));

					strncpy(last_transferred_file, current_transfer.current_file,
					       sizeof(last_transferred_file) - 1);
					last_transferred_file[sizeof(last_transferred_file) - 1] = '\0';

					/* Notify client that file transfer is complete */
					ble_svc_send_file_complete(current_transfer.current_file);

					/* Update synced files counter */
					storage_increment_synced(current_transfer.session_id);

					/* Close file */
					fs_close(&transfer_file);
					transfer_file_open = false;
					/* Clear current file to trigger next file load */
					memset(&current_transfer.current_file, 0, sizeof(current_transfer.current_file));
					/* Signal to continue with next file immediately */
					k_sem_give(&transfer_trigger_sem);
					/* Break to let outer loop handle next file */
					break;
				} else if (ret == -ENOTCONN || ret == -EIO) {
					/* BLE connection error, pause and wait for reconnect */
					LOG_INF("BLE connection lost, pausing transfer (error: %d)", ret);
					current_transfer.state = TRANSFER_STATE_PAUSED;
					/* Close file while paused */
					if (transfer_file_open) {
						fs_close(&transfer_file);
						transfer_file_open = false;
					}
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
				/* Close file while paused */
				if (transfer_file_open) {
					fs_close(&transfer_file);
					transfer_file_open = false;
				}
				break;
			}
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
		/* Wait for file to finish writing before opening */
		while (storage_file_is_writing(current_transfer.session_id,
			current_transfer.current_file)) {
			/* Check if BLE disconnected - abort transfer if so */
			if (!ble_svc_is_ready()) {
				LOG_INF("BLE disconnected while waiting for file, aborting transfer");
				return -ENOTCONN;
			}
			LOG_DBG("File %s is being written, waiting...", current_transfer.current_file);
			k_sleep(K_MSEC(500));
		}
		LOG_DBG("File %s is ready, opening for transfer", current_transfer.current_file);

		snprintf(filepath, sizeof(filepath), "/SD:/REC/%s/%s",
			 current_transfer.session_id, current_transfer.current_file);
	} else {
		/* Get next file from file list */
		if (current_transfer.file_index >= current_transfer.total_files) {
			return -ENOENT;
		}

		if (current_transfer.file_list[current_transfer.file_index][0] == '\0') {
			return -ENOENT;
		}

		strncpy(current_transfer.current_file,
		        current_transfer.file_list[current_transfer.file_index],
		        sizeof(current_transfer.current_file) - 1);

		LOG_DBG("Next: %s (%u/%u)", current_transfer.current_file,
		        current_transfer.file_index + 1, current_transfer.total_files);

		/* Wait for file to finish writing */
		while (storage_file_is_writing(current_transfer.session_id,
			current_transfer.current_file)) {
			if (!ble_svc_is_ready()) {
				return -ENOTCONN;
			}
			k_sleep(K_MSEC(500));
		}

		snprintf(filepath, sizeof(filepath), "/SD:/REC/%s/%s",
		         current_transfer.session_id, current_transfer.current_file);
	}

	fs_file_t_init(&transfer_file);
	ret = fs_open(&transfer_file, filepath, FS_O_READ);
	if (ret != 0) {
		LOG_ERR("File open failed: %s (%d)", filepath, ret);
		current_transfer.current_file[0] = '\0';
		return ret;
	}

	current_transfer.file_index++;
	transfer_file_open = true;

	/* Get file size */
	struct fs_dirent entry;
	ret = fs_stat(filepath, &entry);
	if (ret == 0) {
		LOG_DBG("File: %s (%u bytes)", current_transfer.current_file, (uint32_t)entry.size);

		/* Check if file is empty - skip it if so */
		if (entry.size == 0) {
			LOG_WRN("Empty file: %s", current_transfer.current_file);
			fs_close(&transfer_file);
			transfer_file_open = false;

			/* Delete the empty file */
			int del_ret = fs_unlink(filepath);
			if (del_ret != 0) {
				LOG_WRN("Delete failed: %d", del_ret);
			}

			/* Clear current file to try next file */
			current_transfer.current_file[0] = '\0';
			/* Return -ENOENT to trigger file list refresh and check for more files */
			LOG_INF("Empty file deleted, will refresh file list to check for more files");
			return -ENOENT;
		}

		/* Reset total_bytes for this file (not cumulative) */
		current_transfer.total_bytes = entry.size;
	} else {
		LOG_DBG("Opened file: %s (size unknown)", current_transfer.current_file);
		current_transfer.total_bytes = 0;
	}

	return 0;
}

static int transfer_send_chunk(void)
{
	uint8_t chunk[TRANSFER_CHUNK_SIZE];
	ssize_t bytes_read;
	int ret;
	int64_t read_start, read_end, send_start, send_end;

	/* Read chunk from file - file should already be opened, lock is held at file level */
	read_start = k_uptime_get();
	bytes_read = fs_read(&transfer_file, chunk, TRANSFER_CHUNK_SIZE);
	read_end = k_uptime_get();

	if (bytes_read < 0) {
		LOG_ERR("File read error: %zd (file_open=%d, offset=%llu)",
		        bytes_read, transfer_file_open, current_transfer.bytes_transferred);
		return bytes_read;
	}

	if (bytes_read == 0) {
		/* End of file */
		LOG_DBG("End of file reached (total: %llu bytes)", current_transfer.bytes_transferred);
		return -EOF;
	}

	/* Send via BLE */
	send_start = k_uptime_get();
	ret = ble_svc_send_file_data(chunk, bytes_read);
	send_end = k_uptime_get();

	if (ret != 0) {
		LOG_ERR("BLE send error: %d (chunk size: %zd) - NOT COUNTED", ret, bytes_read);
		return ret;
	}

	/* Only increment bytes_transferred if send actually succeeded */
	current_transfer.bytes_transferred += bytes_read;

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
}
