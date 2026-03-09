/*
 * Copyright (c) 2025 Seeed Technology Co., Ltd.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#include <zephyr/kernel.h>
#include <zephyr/fs/fs.h>
#include <zephyr/logging/log.h>
#include <string.h>
#include <stdio.h>

#include "bookmarks.h"
#include "storage.h"

LOG_MODULE_REGISTER(bookmarks, LOG_LEVEL_INF);

/* File format: binary
 * [Header: 4 bytes magic "BMRK"]
 * [Count: 2 bytes, uint16_t]
 * [Bookmarks: 4 bytes each, uint32_t]
 *   Each bookmark:
 *   [Offset: 4 bytes, uint32_t - seconds from session start]
 */

#define BOOKMARK_MAGIC "BMRK"
#define BOOKMARK_FILE_NAME "marks.bin"

static int bookmarks_get_filepath(const char *session_id, char *filepath, size_t size)
{
	if (!session_id || !filepath) {
		return -EINVAL;
	}

	snprintf(filepath, size, "/SD:/REC/%s/%s", session_id, BOOKMARK_FILE_NAME);

	return 0;
}

int bookmarks_add(const char *session_id, uint32_t offset_sec)
{
	struct fs_file_t file;
	char filepath[128];
	ssize_t written;
	int ret;

	if (!session_id) {
		return -EINVAL;
	}

	/* Get file path */
	ret = bookmarks_get_filepath(session_id, filepath, sizeof(filepath));
	if (ret < 0) {
		return ret;
	}

	/* Open file in append mode (create if doesn't exist) */
	fs_file_t_init(&file);
	ret = fs_open(&file, filepath, FS_O_CREATE | FS_O_WRITE | FS_O_APPEND);
	if (ret < 0) {
		LOG_ERR("Failed to open bookmarks file: %d", ret);
		return ret;
	}

	/* Write bookmark (4 bytes: offset in seconds) */
	written = fs_write(&file, &offset_sec, sizeof(uint32_t));
	if (written != sizeof(uint32_t)) {
		LOG_ERR("Failed to write bookmark: %zd", written);
		fs_close(&file);
		return -EIO;
	}

	fs_close(&file);

	LOG_DBG("Added bookmark at %u seconds", offset_sec);

	return 0;
}

int bookmarks_get_page(const char *session_id, int page, int per_page,
                      struct bookmark *bookmarks, int max_count)
{
	struct fs_file_t file;
	char filepath[128];
	uint8_t header[6];
	ssize_t ret;
	uint16_t count;
	int start_index, end_index;

	if (!session_id || !bookmarks || max_count <= 0) {
		return -EINVAL;
	}

	if (page < 1 || per_page < 1) {
		return -EINVAL;
	}

	/* Get file path */
	ret = bookmarks_get_filepath(session_id, filepath, sizeof(filepath));
	if (ret < 0) {
		return ret;
	}

	/* Open file */
	fs_file_t_init(&file);
	ret = fs_open(&file, filepath, FS_O_READ);
	if (ret < 0) {
		/* File doesn't exist yet - no bookmarks */
		return 0;
	}

	/* Read header */
	ret = fs_read(&file, header, sizeof(header));
	if (ret != sizeof(header)) {
		LOG_ERR("Invalid bookmark file");
		fs_close(&file);
		return -EIO;
	}

	/* Verify magic */
	if (memcmp(header, BOOKMARK_MAGIC, 4) != 0) {
		LOG_ERR("Invalid bookmark magic");
		fs_close(&file);
		return -EIO;
	}

	/* Get count */
	memcpy(&count, &header[4], 2);
	if (count > 10000) {  /* Sanity check */
		LOG_WRN("Bookmark count too large: %u", count);
		count = 0;
	}

	/* Calculate pagination bounds */
	start_index = (page - 1) * per_page;
	if (start_index >= count) {
		/* Page beyond available data */
		fs_close(&file);
		return 0;
	}

	end_index = start_index + per_page;
	if (end_index > count) {
		end_index = count;
	}

	/* Adjust max_count */
	if (max_count < (end_index - start_index)) {
		end_index = start_index + max_count;
	}

	/* Seek to first bookmark in page */
	off_t seek_pos = sizeof(header) + (start_index * sizeof(uint32_t));
	ret = fs_seek(&file, seek_pos, FS_SEEK_SET);
	if (ret < 0) {
		LOG_ERR("Failed to seek to bookmark position");
		fs_close(&file);
		return ret;
	}

	/* Read bookmarks */
	int read_count = 0;
	for (int i = start_index; i < end_index; i++) {
		uint32_t offset_sec;
		ret = fs_read(&file, (uint8_t *)&offset_sec, sizeof(uint32_t));
		if (ret != sizeof(uint32_t)) {
			break;
		}
		bookmarks[read_count].offset_sec = offset_sec;
		read_count++;
	}

	fs_close(&file);

	return read_count;
}

int bookmarks_count(const char *session_id)
{
	struct fs_file_t file;
	char filepath[128];
	uint8_t header[6];
	ssize_t ret;
	uint16_t count = 0;

	if (!session_id) {
		return -EINVAL;
	}

	/* Get file path */
	ret = bookmarks_get_filepath(session_id, filepath, sizeof(filepath));
	if (ret < 0) {
		return ret;
	}

	/* Open file */
	fs_file_t_init(&file);
	ret = fs_open(&file, filepath, FS_O_READ);
	if (ret < 0) {
		/* File doesn't exist yet - no bookmarks */
		return 0;
	}

	/* Read header */
	ret = fs_read(&file, header, sizeof(header));
	if (ret == sizeof(header)) {
		/* Verify magic */
		if (memcmp(header, BOOKMARK_MAGIC, 4) == 0) {
			/* Get count */
			memcpy(&count, &header[4], 2);
		}
	}

	fs_close(&file);

	return count;
}

int bookmarks_clear(const char *session_id)
{
	char filepath[128];
	int ret;

	if (!session_id) {
		return -EINVAL;
	}

	/* Get file path and delete file */
	ret = bookmarks_get_filepath(session_id, filepath, sizeof(filepath));
	if (ret < 0) {
		return ret;
	}

	ret = fs_unlink(filepath);

	LOG_INF("Cleared bookmarks for session: %s", session_id);

	return ret;
}
