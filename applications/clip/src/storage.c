/*
 * Copyright (c) 2025 Seeed Technology Co., Ltd.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#include <zephyr/kernel.h>
#include <zephyr/device.h>
#include <zephyr/storage/disk_access.h>
#include <zephyr/fs/fs.h>
#include <ff.h>
#include <zephyr/logging/log.h>
#include <string.h>
#include <stdio.h>
#include <stdlib.h>

#include "storage.h"
#include "json_helper.h"

LOG_MODULE_REGISTER(storage, LOG_LEVEL_INF);

/* SD Card and File System */
static FATFS fat_fs;
static struct fs_mount_t mp = {
	.type = FS_FATFS,
	.fs_data = &fat_fs,
	.mnt_point = "/SD:",
};
static bool sd_mounted = false;

/* Current session directory */
static char current_session_dir[64] = {0};

/* Write buffer for efficient SD card operations */
static uint8_t write_buffer[STORAGE_WRITE_BUFFER_SIZE];
static uint32_t buffer_pos = 0;
static struct fs_file_t *current_file_ptr = NULL;

/* Statistics */
static uint32_t total_files = 0;
static uint64_t total_bytes = 0;

/* Internal functions */
static int flush_write_buffer(void);
static int update_free_space(void);
static int cleanup_invalid_sessions(void);

static uint32_t free_space_mb = 0;

int storage_init(void)
{
	int rc;

	rc = disk_access_init("SD");
	if (rc != 0) {
		LOG_WRN("SD init failed: %d", rc);
		return rc;
	}

	rc = fs_mount(&mp);
	if (rc != 0) {
		LOG_WRN("SD mount failed: %d", rc);
		sd_mounted = false;
		return 0;
	}

	sd_mounted = true;
	LOG_INF("SD card ready");

	update_free_space();

	/* Clean up invalid sessions (empty/corrupted sessions from old firmware) */
	cleanup_invalid_sessions();

	return 0;
}

void storage_cleanup(void)
{
	if (sd_mounted) {
		fs_unmount(&mp);
		sd_mounted = false;
	}
}

bool storage_is_mounted(void)
{
	return sd_mounted;
}

int storage_get_stats(struct storage_stats *stats)
{
	if (!stats) {
		return -EINVAL;
	}

	memset(stats, 0, sizeof(*stats));
	stats->is_mounted = sd_mounted;
	stats->total_files = total_files;
	stats->total_bytes = total_bytes;

	if (sd_mounted) {
		update_free_space();
		stats->free_space_mb = free_space_mb;
	}

	return 0;
}

int storage_create_session(const char *session_id, uint8_t channels, uint32_t sample_rate, const char *mode)
{
	char dir_path[64];
	char filepath[128];
	struct fs_dirent entry;
	struct fs_file_t file;
	int rc;

	if (!sd_mounted) {
		return -ENODEV;
	}

	if (!session_id) {
		return -EINVAL;
	}

	/* Check and create REC directory if not exists */
	rc = fs_stat("/SD:/REC", &entry);
	if (rc != 0 || entry.type != FS_DIR_ENTRY_DIR) {
		rc = fs_mkdir("/SD:/REC");
		if (rc != 0 && rc != -EEXIST) {
			LOG_ERR("Failed to create REC directory: %d", rc);
			return rc;
		}
	}

	/* Check and create session directory */
	snprintf(dir_path, sizeof(dir_path), "/SD:/REC/%s", session_id);
	LOG_INF("storage_create_session: session_id='%s', dir_path='%s'", session_id, dir_path);
	rc = fs_stat(dir_path, &entry);
	if (rc != 0 || entry.type != FS_DIR_ENTRY_DIR) {
		rc = fs_mkdir(dir_path);
		if (rc != 0 && rc != -EEXIST) {
			LOG_ERR("Failed to create session directory: %d", rc);
			return rc;
		}

		/* Small delay to ensure filesystem metadata is written to SD card */
		k_msleep(50);

		/* Create empty marks.bin file for bookmarks */
		char marks_path[128];
		struct fs_file_t marks_file;
		snprintf(marks_path, sizeof(marks_path), "%s/marks.bin", dir_path);
		LOG_INF("Creating marks.bin: path='%s'", marks_path);
		fs_file_t_init(&marks_file);
		rc = fs_open(&marks_file, marks_path, FS_O_CREATE | FS_O_WRITE);
		if (rc == 0) {
			/* Write empty bookmark header */
			char header[6] = "BMRK";
			memset(&header[4], 0, 2);  /* count = 0 */
			fs_write(&marks_file, header, 6);
			fs_close(&marks_file);
			LOG_INF("Created marks.bin successfully");
		} else {
			LOG_WRN("Could not create marks.bin: %d", rc);
		}
	}

	/* Create session.json with initial values */
	snprintf(filepath, sizeof(filepath), "%s/session.json", dir_path);
	fs_file_t_init(&file);
	rc = fs_open(&file, filepath, FS_O_CREATE | FS_O_WRITE);
	if (rc == 0) {
		char json_buf[300];
		int len = snprintf(json_buf, sizeof(json_buf),
			"{\"id\":\"%s\",\"duration\":0,\"files\":0,\"synced\":0,"
			"\"channels\":%u,\"sample_rate\":%u,\"mode\":\"%s\"}\n",
			session_id, channels, sample_rate, mode ? mode : "normal");
		fs_write(&file, json_buf, len);
		fs_close(&file);
		LOG_INF("Created session.json for %s", session_id);
	} else {
		LOG_WRN("Could not create session.json: %d", rc);
	}

	/* Store current session directory */
	strncpy(current_session_dir, dir_path, sizeof(current_session_dir) - 1);
	current_session_dir[sizeof(current_session_dir) - 1] = '\0';

	LOG_INF("Created session directory: %s", dir_path);
	return 0;
}

int storage_create_file(struct storage_file *file, const char *session_id, uint16_t file_index)
{
	int rc;
	char filepath[128];

	if (!sd_mounted) {
		return -ENODEV;
	}

	if (!file || !session_id) {
		return -EINVAL;
	}

	/* Check if a file is already open */
	if (current_file_ptr != NULL) {
		return -EBUSY;
	}

	/* Generate filename: NNNN.opus */
	snprintf(file->filename, sizeof(file->filename), "%04u.opus", file_index);

	snprintf(filepath, sizeof(filepath), "/SD:/REC/%s/%s", session_id, file->filename);

	/* Allocate file structure */
	file->is_open = false;
	file->bytes_written = 0;
	file->frames_written = 0;

	buffer_pos = 0;
	current_file_ptr = &file->_internal_file;

	/* Try to open file with retry for filesystem timing */
	fs_file_t_init(current_file_ptr);
	for (int retry = 0; retry < 3; retry++) {
		rc = fs_open(current_file_ptr, filepath, FS_O_CREATE | FS_O_WRITE);

		if (rc == 0) {
			break;  /* Success */
		}

		if (retry < 2) {
			/* Wait a bit before retry */
			k_msleep(50);
			/* Re-initialize file handle before retry */
			fs_file_t_init(current_file_ptr);
		}
	}

	if (rc != 0) {
		LOG_ERR("File create failed after retries: %s (rc=%d)", file->filename, rc);
		current_file_ptr = NULL;
		return rc;
	}

	file->is_open = true;
	total_files++;

	/* Sync immediately to ensure directory entry is flushed to filesystem.
	 * This allows the transfer thread to see the new file immediately.
	 */
	rc = fs_sync(current_file_ptr);
	if (rc != 0) {
		LOG_WRN("File sync failed after create: %d", rc);
		/* Continue anyway - file is still valid */
	}

	/* Mark this file as being written */
	storage_set_writing_file(session_id, file->filename);

	LOG_INF("Recording file created: %s", file->filename);
	return 0;
}

int storage_write_frame(struct storage_file *file, const uint8_t *data, uint32_t len)
{
	int rc;
	uint8_t frame_len[2];

	if (!sd_mounted || !file || !file->is_open) {
		return -EINVAL;
	}

	if (len > 65535) {
		LOG_ERR("Frame too large: %u", len);
		return -EINVAL;
	}

	/* Write frame length as 2-byte little-endian */
	frame_len[0] = len & 0xFF;
	frame_len[1] = (len >> 8) & 0xFF;

	/* Write length to buffer */
	if (buffer_pos + 2 > STORAGE_WRITE_BUFFER_SIZE) {
		rc = flush_write_buffer();
		if (rc != 0) {
			return rc;
		}
	}

	write_buffer[buffer_pos++] = frame_len[0];
	write_buffer[buffer_pos++] = frame_len[1];

	/* Write frame data */
	uint32_t remaining = len;
	uint32_t offset = 0;

	while (remaining > 0) {
		uint32_t space = STORAGE_WRITE_BUFFER_SIZE - buffer_pos;
		uint32_t to_copy = (remaining < space) ? remaining : space;

		memcpy(&write_buffer[buffer_pos], &data[offset], to_copy);
		buffer_pos += to_copy;
		offset += to_copy;
		remaining -= to_copy;

		/* Flush buffer when full */
		if (buffer_pos >= STORAGE_WRITE_BUFFER_SIZE) {
			rc = flush_write_buffer();
			if (rc != 0) {
				return rc;
			}
		}
	}

	file->bytes_written += len + 2;  /* +2 for length header */
	file->frames_written++;

	return 0;
}

int storage_close_file(struct storage_file *file)
{
	int rc;

	if (!file || !file->is_open) {
		return -EINVAL;
	}

	/* Flush any remaining data in buffer */
	if (buffer_pos > 0) {
		rc = flush_write_buffer();
		if (rc != 0) {
			LOG_ERR("Failed to flush buffer: %d", rc);
		}
	}

	/* Sync file to ensure data is written to SD card */
	rc = fs_sync(current_file_ptr);
	if (rc != 0) {
		LOG_WRN("File sync failed: %d", rc);
	}

	/* Close file */
	rc = fs_close(current_file_ptr);
	if (rc != 0) {
		LOG_ERR("Failed to close file: %d", rc);
	}

	current_file_ptr = NULL;
	file->is_open = false;

	/* Check if file is empty (0 bytes written) - delete it to avoid issues */
	if (file->bytes_written == 0) {
		char filepath[128];
		snprintf(filepath, sizeof(filepath), "%s/%s",
		         current_session_dir, file->filename);

		rc = fs_unlink(filepath);
		if (rc == 0) {
			LOG_INF("Deleted empty file: %s", filepath);
		} else {
			LOG_WRN("Failed to delete empty file %s: %d", filepath, rc);
		}

		/* Clear writing file status */
		storage_set_writing_file(NULL, NULL);
		return 0;
	}

	total_bytes += file->bytes_written;

	storage_set_writing_file(NULL, NULL);

	update_free_space();

	LOG_INF("File: %s %uKB", file->filename, file->bytes_written/1024);

	return 0;
}

int storage_close_session(const char *session_id, uint32_t duration_sec, uint16_t file_count,
                          uint8_t channels, uint32_t sample_rate, const char *mode)
{
	char filepath[128];
	char session_path[64];
	struct fs_file_t file;
	struct fs_dir_t dirp;
	struct fs_dirent entry;
	int rc;
	uint32_t synced = 0;
	uint16_t actual_opus_count = 0;

	if (!sd_mounted) {
		return -ENODEV;
	}

	if (!session_id) {
		return -EINVAL;
	}

	snprintf(session_path, sizeof(session_path), "/SD:/REC/%s", session_id);

	/* Count actual opus files in the session directory */
	fs_dir_t_init(&dirp);
	if (fs_opendir(&dirp, session_path) == 0) {
		while (fs_readdir(&dirp, &entry) == 0 && entry.name[0] != 0) {
			if (entry.type == FS_DIR_ENTRY_FILE &&
			    strstr(entry.name, ".opus") != NULL &&
			    entry.size > 0) {
				actual_opus_count++;
			}
		}
		fs_closedir(&dirp);
	}

	/* If no valid opus files, delete the entire session directory */
	if (actual_opus_count == 0) {
		LOG_INF("Session %s has no valid opus files, deleting", session_id);
		storage_delete_session(session_id);
		memset(current_session_dir, 0, sizeof(current_session_dir));
		return 0;
	}

	/* Read current synced value before overwriting */
	synced = (uint32_t)storage_get_synced_files(session_id);

	/* Update session.json with final values */
	snprintf(filepath, sizeof(filepath), "/SD:/REC/%s/session.json", session_id);
	fs_file_t_init(&file);
	rc = fs_open(&file, filepath, FS_O_CREATE | FS_O_WRITE);
	if (rc == 0) {
		char json_buf[300];
		int len = snprintf(json_buf, sizeof(json_buf),
			"{\"id\":\"%s\",\"duration\":%u,\"files\":%u,\"synced\":%u,"
			"\"channels\":%u,\"sample_rate\":%u,\"mode\":\"%s\"}\n",
			session_id, duration_sec, actual_opus_count, synced, channels, sample_rate,
			mode ? mode : "normal");
		fs_write(&file, json_buf, len);
		fs_sync(&file);  /* Ensure metadata is flushed to SD card */
		fs_close(&file);
	}

	/* Create files.lst */
	snprintf(filepath, sizeof(filepath), "/SD:/REC/%s/files.lst", session_id);
	fs_file_t_init(&file);
	rc = fs_open(&file, filepath, FS_O_CREATE | FS_O_WRITE);
	if (rc == 0) {
		fs_dir_t_init(&dirp);

		if (fs_opendir(&dirp, session_path) == 0) {
			while (fs_readdir(&dirp, &entry) == 0 && entry.name[0] != 0) {
				if (entry.type == FS_DIR_ENTRY_FILE &&
				    strstr(entry.name, ".opus") != NULL) {
					char line[64];
					int len = snprintf(line, sizeof(line), "%s %u\n",
						entry.name, (uint32_t)entry.size);
					fs_write(&file, line, len);
				}
			}
			fs_closedir(&dirp);
		}
		fs_sync(&file);  /* Ensure file list is flushed to SD card */
		fs_close(&file);
	}

	/* Sync the entire filesystem to ensure all metadata is flushed */
	rc = fs_sync(&mp);
	if (rc != 0 && rc != -134) {
		/* Only log if it's not a common SD card transient error (-134 = FR_DISK_ERR) */
		LOG_WRN("Filesystem sync failed: %d", rc);
	} else if (rc == -134) {
		LOG_DBG("Filesystem sync transient error (data already written)");
	}

	memset(current_session_dir, 0, sizeof(current_session_dir));

	LOG_INF("Session: %s %u files", session_id, actual_opus_count);
	return 0;
}

int storage_list_files(void)
{
	struct fs_dir_t dirp;
	struct fs_dirent entry;
	int rc;

	if (!sd_mounted) {
		printf("[SD: Not mounted]\n");
		return -ENODEV;
	}

	fs_dir_t_init(&dirp);
	rc = fs_opendir(&dirp, "/SD:");
	if (rc != 0) {
		printf("[SD: Failed to open directory: %d]\n", rc);
		return rc;
	}

	printf("\n[SD File List:]\n");

	uint32_t file_count = 0;
	uint64_t total_size = 0;

	while (1) {
		rc = fs_readdir(&dirp, &entry);
		if (rc != 0 || entry.name[0] == 0) {
			break;
		}

		/* Skip directories */
		if (entry.type == FS_DIR_ENTRY_DIR) {
			continue;
		}

		file_count++;
		total_size += entry.size;

		/* Format size */
		if (entry.size < 1024) {
			printf("  %s: %u B\n", entry.name, (uint32_t)entry.size);
		} else if (entry.size < 1024 * 1024) {
			printf("  %s: %u KB\n", entry.name, (uint32_t)(entry.size / 1024));
		} else {
			printf("  %s: %u MB\n", entry.name, (uint32_t)(entry.size / (1024 * 1024)));
		}
	}

	fs_closedir(&dirp);

	if (file_count > 0) {
		printf("Total: %u files, ", file_count);
		if (total_size < 1024) {
			printf("%u B\n", (uint32_t)total_size);
		} else if (total_size < 1024 * 1024) {
			printf("%u KB\n", (uint32_t)(total_size / 1024));
		} else {
			printf("%u MB\n", (uint32_t)(total_size / (1024 * 1024)));
		}
	} else {
		printf("  (empty)\n");
	}

	printf("[SD End]\n");

	return 0;
}

int storage_delete_file(const char *filename)
{
	int rc;
	char filepath[128];

	if (!sd_mounted) {
		return -ENODEV;
	}

	if (!filename) {
		return -EINVAL;
	}

	snprintf(filepath, sizeof(filepath), "/SD:/%s", filename);

	rc = fs_unlink(filepath);
	if (rc != 0) {
		LOG_ERR("Failed to delete file: %d", rc);
		return rc;
	}

	LOG_INF("Deleted file: %s", filename);

	return 0;
}

int storage_format_card(void)
{
	int rc;
	MKFS_PARM opt;
	char work[4096] __aligned(8);  /* Larger, aligned work area */

	if (!sd_mounted) {
		return -ENODEV;
	}

	LOG_INF("Formatting SD card...");

	/* Check if any file is open */
	if (current_file_ptr != NULL) {
		LOG_ERR("Cannot format: file still open");
		return -EBUSY;
	}

	/* Flush any pending writes */
	if (buffer_pos > 0) {
		LOG_WRN("Flushing pending writes before format");
		flush_write_buffer();
	}

	LOG_INF("Unmounting...");
	rc = fs_unmount(&mp);
	if (rc != 0) {
		LOG_WRN("Unmount failed: %d", rc);
	}
	sd_mounted = false;

	/* Work around: force FatFS to unmount by mounting NULL */
	/* This requires the ff.h header */
	f_mount(NULL, "0:", 0);

	k_sleep(K_MSEC(200));

	LOG_INF("Re-initializing disk...");
	rc = disk_access_init("SD");
	if (rc != 0) {
		LOG_ERR("Disk re-init failed: %d", rc);
		return rc;
	}

	k_sleep(K_MSEC(100));

	/* Prepare mkfs options */
	LOG_INF("Calling f_mkfs with work area...");
	memset(&opt, 0, sizeof(opt));
	opt.fmt = FM_ANY | FM_SFD;  /* Auto-detect, default to FAT16 */
	opt.align = 0;               /* Get sector size via diskio query */
	opt.n_root = 512;            /* Number of root directory entries */
	opt.au_size = 0;             /* Auto calculate cluster size */

	/* Use work area for formatting */
	int mkfs_rc = f_mkfs("0:", &opt, work, sizeof(work));
	LOG_INF("f_mkfs returned: %d", mkfs_rc);

	if (mkfs_rc != 0) {
		/* Try with FAT32 explicitly */
		LOG_WRN("f_mkfs failed: %d, trying with FAT32...", mkfs_rc);
		opt.fmt = FM_FAT32;
		mkfs_rc = f_mkfs("0:", &opt, work, sizeof(work));
		LOG_INF("f_mkfs (FAT32) returned: %d", mkfs_rc);
	}

	if (mkfs_rc == 0) {
		LOG_INF("Format successful!");
	} else {
		LOG_ERR("f_mkfs failed after all attempts: %d", mkfs_rc);
	}

	/* Try to remount regardless of result */
	rc = fs_mount(&mp);
	if (rc != 0) {
		LOG_ERR("Remount failed: %d", rc);
		sd_mounted = false;
		return rc;
	}

	sd_mounted = true;
	total_files = 0;
	total_bytes = 0;

	if (mkfs_rc == 0) {
		LOG_INF("SD card formatted successfully");
		return 0;
	} else {
		LOG_ERR("SD card format failed (code %d), but card is usable", mkfs_rc);
		return -EIO;
	}
}

/* Internal functions */
static int flush_write_buffer(void)
{
	ssize_t written;
	int retry_count = 0;
	const int max_retries = 5;

	if (buffer_pos == 0 || !current_file_ptr) {
		return 0;
	}

	/* Retry write on failure - FATFS handles thread safety internally */
	while (retry_count < max_retries) {
		written = fs_write(current_file_ptr, write_buffer, buffer_pos);

		if (written >= 0) {
			/* Success */
			if (written != buffer_pos) {
				LOG_WRN("SD partial write: %zd/%u", written, buffer_pos);
			}
			buffer_pos = 0;
			return 0;
		}

		/* Write failed, retry immediately */
		retry_count++;
		if (retry_count < max_retries) {
			LOG_WRN("SD write failed: %zd, retrying (%d/%d)...",
				written, retry_count, max_retries);
		}
	}

	LOG_ERR("SD write error after %d retries: %zd", max_retries, written);
	return written;
}

static int update_free_space(void)
{
	uint32_t tot_sectors, free_sectors;
	FATFS *fat_fs_p;
	int rc;

	if (!sd_mounted) {
		free_space_mb = 0;
		return -ENODEV;
	}

	/* Get free space from FatFS - use FatFS native path */
	rc = f_getfree("0:", &free_sectors, &fat_fs_p);
	if (rc != 0) {
		LOG_WRN("Failed to get free space: %d", rc);
		free_space_mb = 0;
		return rc;
	}

	tot_sectors = fat_fs_p->n_fatent - 2;

	/* Calculate free space in MB (sector size is typically 512 bytes) */
	uint64_t free_bytes = (uint64_t)free_sectors * fat_fs_p->csize * 512;
	free_space_mb = free_bytes / (1024 * 1024);

	return 0;
}

/* Session management functions */

/**
 * @brief Get current session ID (if recording is active)
 *
 * @param out_session_id Buffer to store session ID (must be at least 32 bytes)
 * @return 0 on success, -ENODEV if no session is active
 */
int storage_get_current_session(char *out_session_id)
{
	if (!out_session_id) {
		return -EINVAL;
	}

	if (current_session_dir[0] == '\0') {
		return -ENODEV;  /* No active session */
	}

	/* Extract session ID from current_session_dir path */
	/* Format: "/SD:/REC/YYYYMMDDHHMMSS" */
	const char *session_start = strrchr(current_session_dir, '/');
	if (session_start) {
		session_start++;  /* Skip the '/' */
	} else {
		session_start = current_session_dir;
	}

	strncpy(out_session_id, session_start, 31);
	out_session_id[31] = '\0';

	return 0;
}

/**
 * @brief Delete an empty session directory (internal helper)
 *
 * @param session_id Session ID to delete
 * @return 0 on success, negative error code on failure
 */
static int storage_delete_empty_session(const char *session_id)
{
	char session_path[64];
	char filepath[320];
	struct fs_dir_t dirp;
	struct fs_dirent entry;
	int rc;

	snprintf(session_path, sizeof(session_path), "/SD:/REC/%s", session_id);

	/* Delete all files in the session directory */
	fs_dir_t_init(&dirp);
	rc = fs_opendir(&dirp, session_path);
	if (rc != 0) {
		return rc;
	}

	while (1) {
		rc = fs_readdir(&dirp, &entry);
		if (rc != 0 || entry.name[0] == 0) {
			break;
		}

		if (entry.type == FS_DIR_ENTRY_FILE) {
			snprintf(filepath, sizeof(filepath), "/SD:/REC/%s/%s", session_id, entry.name);
			fs_unlink(filepath);
		}
	}

	fs_closedir(&dirp);

	/* Delete the directory itself */
	rc = fs_unlink(session_path);
	if (rc == 0) {
		LOG_INF("Deleted empty session: %s", session_id);
	}

	return rc;
}

int storage_list_sessions(struct storage_session_info *sessions, int max_sessions)
{
	struct fs_dir_t dirp;
	struct fs_dirent entry;
	int rc;
	int count = 0;

	if (!sd_mounted) {
		return -ENODEV;
	}

	if (!sessions || max_sessions <= 0) {
		return -EINVAL;
	}

	fs_dir_t_init(&dirp);
	rc = fs_opendir(&dirp, "/SD:/REC");
	if (rc != 0) {
		/* REC directory doesn't exist yet - no sessions */
		return 0;
	}

	/* Scan for session directories */
	while (count < max_sessions) {
		rc = fs_readdir(&dirp, &entry);
		if (rc != 0 || entry.name[0] == 0) {
			break;
		}

		/* Only look for directories */
		if (entry.type != FS_DIR_ENTRY_DIR) {
			continue;
		}

		/* Check if directory name matches session format:
		 * - YYYYMMDDHHMMSS (14 chars, all digits)
		 * - REC_XXXXXX (starts with "REC_", 7+ chars)
		 */
		size_t len = strlen(entry.name);
		bool is_timestamp = (len == 14);
		bool is_rec_prefix = (len >= 7 && strncmp(entry.name, "REC_", 4) == 0);

		if (!is_timestamp && !is_rec_prefix) {
			continue;
		}

		/* Count files and calculate size in this session */
		char session_path[280];  /* /SD:/REC/ + 255 char filename + null */
		struct fs_dir_t session_dir;
		struct fs_dirent file_entry;
		uint16_t file_count = 0;
		uint64_t total_bytes = 0;

		snprintf(session_path, sizeof(session_path), "/SD:/REC/%s", entry.name);
		fs_dir_t_init(&session_dir);

		rc = fs_opendir(&session_dir, session_path);
		if (rc == 0) {
			while (1) {
				rc = fs_readdir(&session_dir, &file_entry);
				if (rc != 0 || file_entry.name[0] == 0) {
					break;
				}

				if (file_entry.type == FS_DIR_ENTRY_FILE &&
				    strstr(file_entry.name, ".opus") != NULL) {
					file_count++;
					total_bytes += file_entry.size;
				}
			}

			fs_closedir(&session_dir);
		}

		/* Skip and delete empty sessions (no files or no data) */
		if (file_count == 0 || total_bytes == 0) {
			/* Check if this is the current recording session */
			if (current_session_dir[0] != '\0') {
				const char *session_start = strrchr(current_session_dir, '/');
				if (session_start) {
					session_start++;
				} else {
					session_start = current_session_dir;
				}
				/* Don't delete current recording session */
				if (strcmp(session_start, entry.name) == 0) {
					continue;
				}
			}
			/* Delete empty session directory */
			storage_delete_empty_session(entry.name);
			continue;
		}

		/* Copy session info to output array */
		strncpy(sessions[count].session_id, entry.name, sizeof(sessions[count].session_id) - 1);
		sessions[count].session_id[sizeof(sessions[count].session_id) - 1] = '\0';
		sessions[count].file_count = file_count;
		sessions[count].total_bytes = total_bytes;

		/* Calculate duration (rough estimate: bytes / bitrate / 8) */
		sessions[count].duration_sec = total_bytes / 3000;  /* ~24kbps */

		count++;
	}

	fs_closedir(&dirp);

	return count;
}

/* Simple string comparison for sorting */
static int compare_filenames(const void *a, const void *b)
{
	return strcmp((const char *)a, (const char *)b);
}

int storage_list_session_files(const char *session_id, char (*files)[32], int max_files)
{
	char session_path[64];
	struct fs_dir_t dirp;
	struct fs_dirent entry;
	int rc;
	int count = 0;

	if (!sd_mounted) {
		return -ENODEV;
	}

	if (!session_id || !files || max_files <= 0) {
		return -EINVAL;
	}

	snprintf(session_path, sizeof(session_path), "/SD:/REC/%s", session_id);

	fs_dir_t_init(&dirp);
	rc = fs_opendir(&dirp, session_path);
	if (rc != 0) {
		LOG_ERR("Failed to open session directory: %d", rc);
		return -ENOENT;
	}

	while (count < max_files) {
		rc = fs_readdir(&dirp, &entry);
		if (rc != 0 || entry.name[0] == 0) {
			break;
		}

		/* Only list .opus files */
		if (entry.type == FS_DIR_ENTRY_FILE &&
		    strstr(entry.name, ".opus") != NULL) {
			strncpy(files[count], entry.name, 31);
			files[count][31] = '\0';
			count++;
		}
	}

	fs_closedir(&dirp);

	/* Sort files by name to ensure correct transfer order */
	if (count > 0) {
		qsort(files, count, 32, compare_filenames);
	}

	return count;
}

int storage_get_session_info(const char *session_id, struct storage_session_info *info)
{
	char session_path[64];
	char filepath[128];
	struct fs_dir_t dirp;
	struct fs_dirent entry;
	struct fs_file_t file;
	int rc;

	if (!sd_mounted) {
		return -ENODEV;
	}

	if (!session_id || !info) {
		return -EINVAL;
	}

	/* Initialize output with defaults */
	memset(info, 0, sizeof(*info));
	strncpy(info->session_id, session_id, sizeof(info->session_id) - 1);
	info->channels = 1;        /* Default: mono */
	info->sample_rate_khz = 16; /* Default: 16kHz */
	strcpy(info->mode, "normal"); /* Default: normal */

	snprintf(session_path, sizeof(session_path), "/SD:/REC/%s", session_id);

	fs_dir_t_init(&dirp);
	rc = fs_opendir(&dirp, session_path);
	if (rc != 0) {
		LOG_ERR("Failed to open session directory: %d", rc);
		return -ENOENT;
	}

	/* Count files and calculate total size */
	while (true) {
		rc = fs_readdir(&dirp, &entry);
		if (rc != 0 || entry.name[0] == 0) {
			break;
		}

		/* Only count .opus files */
		if (entry.type == FS_DIR_ENTRY_FILE &&
		    strstr(entry.name, ".opus") != NULL) {
			info->file_count++;
			info->total_bytes += entry.size;
		}
	}

	fs_closedir(&dirp);

	/* Read session.json for metadata (duration, channels, sample_rate) */
	snprintf(filepath, sizeof(filepath), "/SD:/REC/%s/session.json", session_id);
	fs_file_t_init(&file);
	rc = fs_open(&file, filepath, FS_O_READ);
	if (rc == 0) {
		char json_buf[256];
		ssize_t bytes_read = fs_read(&file, json_buf, sizeof(json_buf) - 1);
		fs_close(&file);

		if (bytes_read > 0) {
			json_buf[bytes_read] = '\0';

			/* Parse channels (simple string search) */
			char *ch = strstr(json_buf, "\"channels\":");
			if (ch) {
				info->channels = (uint8_t)atoi(ch + 11);
				if (info->channels < 1 || info->channels > 2) {
					info->channels = 1;
				}
			}

			/* Parse sample_rate */
			char *sr = strstr(json_buf, "\"sample_rate\":");
			if (sr) {
				uint32_t rate = (uint32_t)atoi(sr + 14);
				info->sample_rate_khz = (uint8_t)(rate / 1000);
				if (info->sample_rate_khz == 0) {
					info->sample_rate_khz = 16;
				}
			}

			/* Parse duration */
			char *dur = strstr(json_buf, "\"duration\":");
			if (dur) {
				info->duration_sec = (uint32_t)atoi(dur + 11);
			}

			/* Parse mode */
			char *mode_start = strstr(json_buf, "\"mode\":\"");
			if (mode_start) {
				mode_start += 8;  /* Skip "mode":" */
				char *mode_end = strchr(mode_start, '"');
				if (mode_end && (mode_end - mode_start) < sizeof(info->mode)) {
					memcpy(info->mode, mode_start, mode_end - mode_start);
					info->mode[mode_end - mode_start] = '\0';
				}
			}
		}
	}

	/* Get synced files count */
	info->synced_files = (uint32_t)storage_get_synced_files(session_id);

	return 0;
}

int storage_delete_session(const char *session_id)
{
	char session_path[64];
	struct fs_dir_t dirp;
	struct fs_dirent entry;
	int rc;
	int deleted_count = 0;

	if (!sd_mounted) {
		return -ENODEV;
	}

	if (!session_id) {
		return -EINVAL;
	}

	/* PROTECTION: Prevent deleting current recording session directory */
	if (current_session_dir[0] != '\0') {
		/* Extract session ID from current_session_dir path */
		/* Format: "/SD:/REC/YYYYMMDDHHMMSS" */
		const char *session_start = strrchr(current_session_dir, '/');
		if (session_start) {
			session_start++;  /* Skip the '/' */
		} else {
			session_start = current_session_dir;
		}

		/* Check if the session being deleted matches the current session */
		if (strcmp(session_start, session_id) == 0) {
			LOG_ERR("Cannot delete current recording session: %s", session_id);
			return -EBUSY;  /* Return busy to indicate active session */
		}
	}

	snprintf(session_path, sizeof(session_path), "/SD:/REC/%s", session_id);
	LOG_INF("Deleting session: %s (path: %s)", session_id, session_path);

	/* First, delete all files in the session directory */
	fs_dir_t_init(&dirp);
	rc = fs_opendir(&dirp, session_path);
	if (rc == 0) {
		while (1) {
			rc = fs_readdir(&dirp, &entry);
			if (rc != 0 || entry.name[0] == 0) {
				break;
			}

			if (entry.type == FS_DIR_ENTRY_FILE) {
				char filepath[540];  /* /SD:/REC/ + 255 + / + 255 + null */
				snprintf(filepath, sizeof(filepath), "/SD:/REC/%s/%s", session_id, entry.name);
				rc = fs_unlink(filepath);
				if (rc == 0) {
					deleted_count++;
					LOG_INF("Deleted file: %s", entry.name);
				} else {
					LOG_WRN("Failed to delete file %s: %d", entry.name, rc);
				}
			}
		}
		fs_closedir(&dirp);
		LOG_INF("Deleted %d files from session %s", deleted_count, session_id);
	} else {
		LOG_ERR("Failed to open session directory: %d", rc);
		return rc;
	}

	/* Then delete the directory */
	rc = fs_unlink(session_path);
	if (rc != 0) {
		LOG_ERR("Failed to delete session directory %s: %d", session_path, rc);
		return rc;
	}

	LOG_INF("Deleted session: %s", session_id);

	return 0;
}

bool storage_session_exists(const char *session_id)
{
	char session_path[64];
	struct fs_dirent entry;
	int rc;

	if (!sd_mounted || !session_id) {
		return false;
	}

	snprintf(session_path, sizeof(session_path), "/SD:/REC/%s", session_id);

	rc = fs_stat(session_path, &entry);

	return (rc == 0 && entry.type == FS_DIR_ENTRY_DIR);
}

/* Track current writing file info */
static char writing_session[32] = {0};
static char writing_filename[32] = {0};

void storage_set_writing_file(const char *session_id, const char *filename)
{
	if (session_id && filename) {
		strncpy(writing_session, session_id, sizeof(writing_session) - 1);
		writing_session[sizeof(writing_session) - 1] = '\0';
		strncpy(writing_filename, filename, sizeof(writing_filename) - 1);
		writing_filename[sizeof(writing_filename) - 1] = '\0';
		LOG_INF("Writing file set: %s/%s", writing_session, writing_filename);
	} else {
		/* Clear writing file info */
		writing_session[0] = '\0';
		writing_filename[0] = '\0';
		LOG_INF("Writing file cleared");
	}
}

bool storage_file_is_writing(const char *session_id, const char *filename)
{
	if (!session_id || !filename) {
		return false;
	}

	/* Check if session and filename match current writing file */
	return (strcmp(writing_session, session_id) == 0 &&
	        strcmp(writing_filename, filename) == 0);
}

bool storage_get_writing_file(char *out_session, char *out_filename,
                              size_t session_size, size_t filename_size)
{
	bool is_writing = (writing_session[0] != '\0');

	if (is_writing) {
		if (out_session && session_size > 0) {
			strncpy(out_session, writing_session, session_size - 1);
			out_session[session_size - 1] = '\0';
		}
		if (out_filename && filename_size > 0) {
			strncpy(out_filename, writing_filename, filename_size - 1);
			out_filename[filename_size - 1] = '\0';
		}
	}

	return is_writing;
}

bool storage_session_is_closed(const char *session_id)
{
	char filepath[128];
	struct fs_dirent entry;
	int rc;

	if (!sd_mounted || !session_id) {
		return false;
	}

	/* Session is closed if session.json exists */
	snprintf(filepath, sizeof(filepath), "/SD:/REC/%s/session.json", session_id);
	rc = fs_stat(filepath, &entry);

	return (rc == 0);
}

int storage_set_synced_files(const char *session_id, uint32_t count)
{
	char filepath[128];
	struct fs_file_t file;
	int rc;
	char json_buf[256];
	int json_len;

	if (!sd_mounted) {
		return -ENODEV;
	}

	if (!session_id) {
		return -EINVAL;
	}

	/* Check if session.json exists before trying to open it */
	snprintf(filepath, sizeof(filepath), "/SD:/REC/%s/session.json", session_id);
	struct fs_dirent entry;
	bool file_exists = (fs_stat(filepath, &entry) == 0);

	/* Read existing session.json if it exists */
	fs_file_t_init(&file);
	rc = -ENOENT;  /* Default to file not existing */
	if (file_exists) {
		rc = fs_open(&file, filepath, FS_O_READ);
	}
	if (rc != 0) {
		return -ENOENT;
	}

	json_len = fs_read(&file, json_buf, sizeof(json_buf) - 1);
	fs_close(&file);
	if (json_len <= 0) {
		return -EIO;
	}
	json_buf[json_len] = '\0';

	/* Parse and update synced field */
	char synced_str[32];
	if (json_parse_helper(json_buf, "synced", synced_str, sizeof(synced_str))) {
		/* Field exists, update in-place */
		uint32_t synced = atoi(synced_str);
		if (count > synced) {
			/* Only update if new value is greater */
			char new_synced_str[16];
			snprintf(new_synced_str, sizeof(new_synced_str), "%u", count);

			/* Find and replace "synced":XXX */
			char *synced_pos = strstr(json_buf, "\"synced\":");
			if (synced_pos) {
				char *value_start = strchr(synced_pos, ':');
				if (value_start) {
					value_start++;  /* Skip ':' */
					char *value_end = strchr(value_start, ',');
					char *end = strchr(value_start, '}');

					if (value_end) {
						/* Found comma, replace value */
						int prefix_len = value_start - json_buf;
						int suffix_len = strlen(value_end);
						char new_json[256];

						snprintf(new_json, sizeof(new_json),
							"%.*s%s%.*s",
							prefix_len, json_buf,
							new_synced_str,
							suffix_len, value_end);
						json_len = strlen(new_json);

						/* Write updated file */
						fs_file_t_init(&file);
						rc = fs_open(&file, filepath, FS_O_WRITE | FS_O_TRUNC);
						if (rc == 0) {
							fs_write(&file, new_json, json_len);
							fs_close(&file);
							LOG_INF("Updated synced files: %s -> %u", session_id, count);
							return 0;
						}
					} else if (end) {
						/* End of object, replace value */
						int prefix_len = value_start - json_buf;
						char new_json[256];

						snprintf(new_json, sizeof(new_json),
							"%.*s%s}",
							prefix_len, json_buf,
							new_synced_str);
						json_len = strlen(new_json);

						/* Write updated file */
						fs_file_t_init(&file);
						rc = fs_open(&file, filepath, FS_O_WRITE | FS_O_TRUNC);
						if (rc == 0) {
							fs_write(&file, new_json, json_len);
							fs_close(&file);
							LOG_INF("Updated synced files: %s -> %u", session_id, count);
							return 0;
						}
					}
				}
			}
		}
	}

	/* Field doesn't exist or parse failed, recreate file */
	snprintf(filepath, sizeof(filepath), "/SD:/REC/%s/session.json", session_id);
	fs_file_t_init(&file);
	rc = fs_open(&file, filepath, FS_O_CREATE | FS_O_WRITE);
	if (rc == 0) {
		/* Keep existing fields, add synced */
		char new_json[256];
		snprintf(new_json, sizeof(new_json),
			"{\"id\":\"%s\",\"duration\":%u,\"files\":%u,\"synced\":%u}\n",
			session_id, 0, 0, count);
		json_len = strlen(new_json);
		fs_write(&file, new_json, json_len);
		fs_close(&file);
		return 0;
	}

	return -EIO;
}

int storage_get_synced_files(const char *session_id)
{
	char filepath[128];
	struct fs_dirent entry;
	int rc;

	if (!sd_mounted) {
		return -ENODEV;
	}

	if (!session_id) {
		return -EINVAL;
	}

	/* Check if session.json exists */
	snprintf(filepath, sizeof(filepath), "/SD:/REC/%s/session.json", session_id);
	rc = fs_stat(filepath, &entry);
	if (rc != 0) {
		return 0;  /* No synced files if session.json doesn't exist */
	}

	/* Read session.json and parse synced field */
	struct fs_file_t file;
	fs_file_t_init(&file);
	rc = fs_open(&file, filepath, FS_O_READ);
	if (rc == 0) {
		char json_buf[256];
		char synced_str[32];
		int json_len = fs_read(&file, json_buf, sizeof(json_buf) - 1);
		fs_close(&file);
		if (json_len > 0) {
			json_buf[json_len] = '\0';
			if (json_parse_helper(json_buf, "synced", synced_str, sizeof(synced_str))) {
				uint32_t synced = atoi(synced_str);
				return (int)synced;
			}
		}
	}

	return 0;  /* Default to 0 if field not found */
}

int storage_increment_synced(const char *session_id)
{
	int current = storage_get_synced_files(session_id);
	if (current < 0) {
		return current;
	}
	return storage_set_synced_files(session_id, (uint32_t)(current + 1));
}

/* Clean up invalid sessions (empty or corrupted sessions from old firmware) */
static int cleanup_invalid_sessions(void)
{
	struct fs_dir_t dirp;
	struct fs_dirent entry;
	char session_path[128];
	int rc;
	int cleaned_count = 0;

	if (!sd_mounted) {
		return 0;
	}

	/* Open REC directory */
	fs_dir_t_init(&dirp);
	rc = fs_opendir(&dirp, "/SD:/REC");
	if (rc != 0) {
		/* REC directory doesn't exist yet - nothing to clean */
		return 0;
	}

	/* Scan each session directory */
	while (fs_readdir(&dirp, &entry) == 0 && entry.name[0] != 0) {
		/* Only look for directories (skip . and ..) */
		if (entry.type != FS_DIR_ENTRY_DIR) {
			continue;
		}

		/* Skip special entries */
		if (strcmp(entry.name, ".") == 0 || strcmp(entry.name, "..") == 0) {
			continue;
		}

		/* Build session path */
		snprintf(session_path, sizeof(session_path), "/SD:/REC/%s", entry.name);

		/* Check if session has valid content */
		struct fs_dir_t session_dirp;
		struct fs_dirent session_entry;
		int file_count = 0;
		bool has_opus = false;

		fs_dir_t_init(&session_dirp);
		if (fs_opendir(&session_dirp, session_path) == 0) {
			/* Count files and check for .opus files */
			while (fs_readdir(&session_dirp, &session_entry) == 0 && session_entry.name[0] != 0) {
				if (session_entry.type == FS_DIR_ENTRY_FILE) {
					file_count++;
					if (strstr(session_entry.name, ".opus") != NULL) {
						has_opus = true;
					}
				}
			}
			fs_closedir(&session_dirp);
		}

		/* Delete session if:
		 * 1. No files at all (completely empty)
		 * 2. No .opus files (corrupted or incomplete)
		 * AND not the current recording session
		 */
		bool is_current_session = false;
		if (current_session_dir[0] != '\0') {
			const char *session_start = strrchr(current_session_dir, '/');
			if (session_start) {
				session_start++;  /* Skip the '/' */
			} else {
				session_start = current_session_dir;
			}
			if (strcmp(session_start, entry.name) == 0) {
				is_current_session = true;
			}
		}

		if (!is_current_session && (file_count == 0 || !has_opus)) {
			LOG_INF("Cleaning up invalid session: %s (files=%d, has_opus=%d)",
				entry.name, file_count, has_opus);

			/* Delete the session directory */
			storage_delete_session(entry.name);
			cleaned_count++;
		}
	}

	fs_closedir(&dirp);

	if (cleaned_count > 0) {
		LOG_INF("Cleaned up %d invalid session(s)", cleaned_count);
	}

	return 0;
}
