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

#include "storage.h"

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

static uint32_t free_space_mb = 0;

int storage_init(void)
{
	int rc;

	LOG_INF("Initializing SD card storage...");

	/* Initialize SD card disk */
	rc = disk_access_init("SD");
	if (rc != 0) {
		LOG_WRN("SD card init failed: %d", rc);
		return rc;
	}

	/* Try to mount the SD card */
	rc = fs_mount(&mp);
	if (rc != 0) {
		LOG_WRN("SD card mount failed: %d (not formatted?)", rc);
		LOG_INF("SD card functions disabled");
		sd_mounted = false;
		return 0;
	}

	sd_mounted = true;
	LOG_INF("SD card mounted at %s", mp.mnt_point);

	/* Update free space */
	update_free_space();

	return 0;
}

void storage_cleanup(void)
{
	if (sd_mounted) {
		/* Unmount SD card */
		fs_unmount(&mp);
		sd_mounted = false;
		LOG_INF("SD card unmounted");
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

int storage_create_session(const char *session_id)
{
	char dir_path[64];
	struct fs_dirent entry;
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
	rc = fs_stat(dir_path, &entry);
	if (rc != 0 || entry.type != FS_DIR_ENTRY_DIR) {
		rc = fs_mkdir(dir_path);
		if (rc != 0 && rc != -EEXIST) {
			LOG_ERR("Failed to create session directory: %d", rc);
			return rc;
		}
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
		LOG_ERR("File already open");
		return -EBUSY;
	}

	/* Generate filename: NNN.opus */
	snprintf(file->filename, sizeof(file->filename), "%03u.opus", file_index);

	/* Full path: /SD:/REC/<session_id>/<NNN.opus> */
	snprintf(filepath, sizeof(filepath), "/SD:/REC/%s/%s", session_id, file->filename);

	LOG_INF("Creating file: %s", filepath);

	/* Allocate file structure */
	file->is_open = false;
	file->bytes_written = 0;
	file->frames_written = 0;

	/* Reset write buffer */
	buffer_pos = 0;
	current_file_ptr = &file->_internal_file;

	/* Open file for writing */
	fs_file_t_init(current_file_ptr);
	rc = fs_open(current_file_ptr, filepath, FS_O_CREATE | FS_O_WRITE);
	if (rc != 0) {
		LOG_ERR("Failed to create file: %d", rc);
		current_file_ptr = NULL;
		return rc;
	}

	file->is_open = true;
	total_files++;

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

	/* Close file */
	rc = fs_close(current_file_ptr);
	if (rc != 0) {
		LOG_ERR("Failed to close file: %d", rc);
	}

	current_file_ptr = NULL;
	file->is_open = false;
	total_bytes += file->bytes_written;

	/* Update free space */
	update_free_space();

	LOG_INF("File closed: %s (%u bytes, %u frames)",
		file->filename, file->bytes_written, file->frames_written);

	return 0;
}

int storage_close_session(const char *session_id, uint32_t duration_sec, uint16_t file_count)
{
	char filepath[128];
	struct fs_file_t file;
	int rc;

	if (!sd_mounted) {
		return -ENODEV;
	}

	if (!session_id) {
		return -EINVAL;
	}

	/* Create session.json */
	snprintf(filepath, sizeof(filepath), "/SD:/REC/%s/session.json", session_id);
	fs_file_t_init(&file);
	rc = fs_open(&file, filepath, FS_O_CREATE | FS_O_WRITE);
	if (rc == 0) {
		char json_buf[256];
		int len = snprintf(json_buf, sizeof(json_buf),
			"{\"id\":\"%s\",\"duration\":%u,\"files\":%u}\n",
			session_id, duration_sec, file_count);
		fs_write(&file, json_buf, len);
		fs_close(&file);
		LOG_INF("Created session.json");
	}

	/* Create files.lst */
	snprintf(filepath, sizeof(filepath), "/SD:/REC/%s/files.lst", session_id);
	fs_file_t_init(&file);
	rc = fs_open(&file, filepath, FS_O_CREATE | FS_O_WRITE);
	if (rc == 0) {
		/* List all .opus files in session directory */
		char session_path[64];
		struct fs_dir_t dirp;
		struct fs_dirent entry;

		snprintf(session_path, sizeof(session_path), "/SD:/REC/%s", session_id);
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
		fs_close(&file);
		LOG_INF("Created files.lst");
	}

	/* Clear current session directory */
	memset(current_session_dir, 0, sizeof(current_session_dir));

	LOG_INF("Session closed: %s", session_id);
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

	if (!sd_mounted) {
		return -ENODEV;
	}

	LOG_INF("Formatting SD card...");

	/* Unmount first */
	fs_unmount(&mp);
	sd_mounted = false;

	/* Format the card */
	rc = fs_mkfs(FS_FATFS, "/SD:", NULL, 0);
	if (rc != 0) {
		LOG_ERR("Format failed: %d", rc);
		/* Try to remount */
		fs_mount(&mp);
		sd_mounted = true;
		return rc;
	}

	/* Remount */
	rc = fs_mount(&mp);
	if (rc != 0) {
		LOG_ERR("Remount failed: %d", rc);
		sd_mounted = false;
		return rc;
	}

	sd_mounted = true;
	total_files = 0;
	total_bytes = 0;

	LOG_INF("SD card formatted successfully");

	return 0;
}

/* Internal functions */
static int flush_write_buffer(void)
{
	ssize_t written;

	if (buffer_pos == 0 || !current_file_ptr) {
		return 0;
	}

	written = fs_write(current_file_ptr, write_buffer, buffer_pos);

	if (written < 0) {
		LOG_ERR("SD write error: %zd", written);
		return written;
	}

	if (written != buffer_pos) {
		LOG_WRN("SD partial write: %zd/%u", written, buffer_pos);
	}

	buffer_pos = 0;
	return 0;
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

		/* Check if directory name matches session format (YYYYMMDDHHMMSS or REC_XXXXXX) */
		size_t len = strlen(entry.name);
		if (len != 14 && len != 13) {  /* YYYYMMDDHHMMSS=14 or REC_XXXXXX=13 */
			continue;
		}

		/* Copy session ID */
		strncpy(sessions[count].session_id, entry.name, sizeof(sessions[count].session_id) - 1);
		sessions[count].session_id[sizeof(sessions[count].session_id) - 1] = '\0';

		/* Count files and calculate size in this session */
		char session_path[64];
		struct fs_dir_t session_dir;
		struct fs_dirent file_entry;

		snprintf(session_path, sizeof(session_path), "/SD:/REC/%s", entry.name);
		fs_dir_t_init(&session_dir);

		rc = fs_opendir(&session_dir, session_path);
		if (rc == 0) {
			sessions[count].file_count = 0;
			sessions[count].total_bytes = 0;

			while (1) {
				rc = fs_readdir(&session_dir, &file_entry);
				if (rc != 0 || file_entry.name[0] == 0) {
					break;
				}

				if (file_entry.type == FS_DIR_ENTRY_FILE &&
				    strstr(file_entry.name, ".opus") != NULL) {
					sessions[count].file_count++;
					sessions[count].total_bytes += file_entry.size;
				}
			}

			fs_closedir(&session_dir);
		}

		/* Calculate duration (rough estimate: bytes / bitrate / 8) */
		sessions[count].duration_sec = sessions[count].total_bytes / 3000;  /* ~24kbps */

		count++;
	}

	fs_closedir(&dirp);

	return count;
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

	return count;
}

int storage_delete_session(const char *session_id)
{
	char session_path[64];
	struct fs_dir_t dirp;
	struct fs_dirent entry;
	int rc;

	if (!sd_mounted) {
		return -ENODEV;
	}

	if (!session_id) {
		return -EINVAL;
	}

	snprintf(session_path, sizeof(session_path), "/SD:/REC/%s", session_id);

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
				char filepath[128];
				snprintf(filepath, sizeof(filepath), "/SD:/REC/%s/%s", session_id, entry.name);
				fs_unlink(filepath);
			}
		}
		fs_closedir(&dirp);
	}

	/* Then delete the directory */
	rc = fs_unlink(session_path);
	if (rc != 0) {
		LOG_ERR("Failed to delete session directory: %d", rc);
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
