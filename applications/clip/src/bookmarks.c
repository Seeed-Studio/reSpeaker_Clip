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

/* In-memory bookmark storage */
static struct bookmark bookmark_cache[BOOKMARKS_MAX_COUNT];
static int bookmark_cache_count = 0;
static char current_session_id[32] = {0};

/* File format: binary
 * [Header: 4 bytes magic "BMRK"]
 * [Count: 2 bytes, uint16_t]
 * [Bookmarks: variable]
 *   Each bookmark:
 *   [Timestamp: 4 bytes, uint32_t]
 *   [Offset: 4 bytes, uint32_t]
 *   [File index: 2 bytes, uint16_t]
 *   [File offset: 4 bytes, uint32_t]
 *   [Note: 64 bytes, null-terminated string]
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

int bookmarks_init(const char *session_id)
{
	if (!session_id) {
		return -EINVAL;
	}

	/* Check if session changed */
	if (strcmp(current_session_id, session_id) != 0) {
		/* Save previous session bookmarks */
		if (current_session_id[0] != '\0' && bookmark_cache_count > 0) {
			bookmarks_save(current_session_id);
		}

		/* Clear cache */
		memset(bookmark_cache, 0, sizeof(bookmark_cache));
		bookmark_cache_count = 0;

		/* Set new session */
		strncpy(current_session_id, session_id, sizeof(current_session_id) - 1);

		/* Load bookmarks for new session */
		bookmarks_load(session_id);
	}

	return 0;
}

int bookmarks_add(const char *session_id, const struct bookmark *bookmark)
{
	if (!session_id || !bookmark) {
		return -EINVAL;
	}

	/* Check if session changed */
	if (strcmp(current_session_id, session_id) != 0) {
		bookmarks_init(session_id);
	}

	/* Check if cache is full */
	if (bookmark_cache_count >= BOOKMARKS_MAX_COUNT) {
		LOG_WRN("Bookmark cache full (%d)", BOOKMARKS_MAX_COUNT);
		return -ENOMEM;
	}

	/* Add to cache */
	memcpy(&bookmark_cache[bookmark_cache_count], bookmark, sizeof(*bookmark));
	bookmark_cache_count++;

	LOG_DBG("Added bookmark %d: offset=%u sec", bookmark_cache_count, bookmark->offset_sec);

	return 0;
}

int bookmarks_get_all(const char *session_id, struct bookmark *bookmarks, int max_count)
{
	if (!session_id || !bookmarks || max_count <= 0) {
		return -EINVAL;
	}

	/* Load from file if different session */
	if (strcmp(current_session_id, session_id) != 0) {
		bookmarks_init(session_id);
	}

	/* Copy bookmarks */
	int count = (bookmark_cache_count < max_count) ? bookmark_cache_count : max_count;
	memcpy(bookmarks, bookmark_cache, count * sizeof(struct bookmark));

	return count;
}

int bookmarks_clear(const char *session_id)
{
	if (!session_id) {
		return -EINVAL;
	}

	/* Check if this is the current session */
	if (strcmp(current_session_id, session_id) == 0) {
		memset(bookmark_cache, 0, sizeof(bookmark_cache));
		bookmark_cache_count = 0;
	}

	/* Delete the marks.bin file */
	char filepath[128];
	bookmarks_get_filepath(session_id, filepath, sizeof(filepath));
	fs_unlink(filepath);

	LOG_INF("Cleared bookmarks for session: %s", session_id);

	return 0;
}

int bookmarks_count(const char *session_id)
{
	if (!session_id) {
		return -EINVAL;
	}

	/* Load from file if different session */
	if (strcmp(current_session_id, session_id) != 0) {
		bookmarks_init(session_id);
	}

	return bookmark_cache_count;
}

int bookmarks_save(const char *session_id)
{
	char filepath[128];
	struct fs_file_t file;
	ssize_t written;
	int ret;

	if (!session_id) {
		return -EINVAL;
	}

	if (bookmark_cache_count == 0) {
		LOG_DBG("No bookmarks to save");
		return 0;
	}

	/* Get file path */
	ret = bookmarks_get_filepath(session_id, filepath, sizeof(filepath));
	if (ret != 0) {
		return ret;
	}

	/* Open file for writing */
	fs_file_t_init(&file);
	ret = fs_open(&file, filepath, FS_O_CREATE | FS_O_WRITE);
	if (ret != 0) {
		LOG_ERR("Failed to open bookmark file: %d", ret);
		return ret;
	}

	/* Write header */
	char header[6] = BOOKMARK_MAGIC;
	memcpy(&header[4], &bookmark_cache_count, 2);

	written = fs_write(&file, header, 6);
	if (written < 6) {
		LOG_ERR("Failed to write header: %zd", written);
		fs_close(&file);
		return -EIO;
	}

	/* Write bookmarks */
	for (int i = 0; i < bookmark_cache_count; i++) {
		uint8_t buffer[76];  /* 4+4+2+4+64 = 78 bytes, but let's use 76 for alignment */
		uint8_t *ptr = buffer;

		/* Timestamp */
		memcpy(ptr, &bookmark_cache[i].timestamp, 4);
		ptr += 4;

		/* Offset */
		memcpy(ptr, &bookmark_cache[i].offset_sec, 4);
		ptr += 4;

		/* File index */
		memcpy(ptr, &bookmark_cache[i].file_index, 2);
		ptr += 2;

		/* File offset */
		memcpy(ptr, &bookmark_cache[i].file_offset, 4);
		ptr += 4;

		/* Note */
		memset(ptr, 0, 64);
		strncpy((char *)ptr, bookmark_cache[i].note, 63);
		ptr += 64;

		written = fs_write(&file, buffer, 76);
		if (written < 76) {
			LOG_ERR("Failed to write bookmark %d: %zd", i, written);
			fs_close(&file);
			return -EIO;
		}
	}

	fs_close(&file);

	LOG_INF("Saved %d bookmarks for session: %s", bookmark_cache_count, session_id);

	return 0;
}

int bookmarks_load(const char *session_id)
{
	char filepath[128];
	struct fs_file_t file;
	ssize_t bytes_read;
	int ret;

	if (!session_id) {
		return -EINVAL;
	}

	/* Clear cache */
	memset(bookmark_cache, 0, sizeof(bookmark_cache));
	bookmark_cache_count = 0;

	/* Get file path */
	ret = bookmarks_get_filepath(session_id, filepath, sizeof(filepath));
	if (ret != 0) {
		return ret;
	}

	/* Open file for reading */
	fs_file_t_init(&file);
	ret = fs_open(&file, filepath, FS_O_READ);
	if (ret != 0) {
		/* File doesn't exist yet - create empty file */
		fs_file_t_init(&file);
		ret = fs_open(&file, filepath, FS_O_CREATE | FS_O_WRITE);
		if (ret != 0) {
			/* Still can't create, log but don't fail */
			LOG_DBG("Could not create bookmark file: %d", ret);
			return 0;
		}

		/* Write empty header */
		char header[6] = BOOKMARK_MAGIC;
		memset(&header[4], 0, 2);  /* count = 0 */
		ssize_t written = fs_write(&file, header, 6);
		fs_close(&file);

		if (written < 6) {
			LOG_WRN("Failed to write empty bookmark header");
		}

		LOG_DBG("Created empty bookmark file for session: %s", session_id);
		return 0;
	}

	/* Read header */
	char header[6];
	bytes_read = fs_read(&file, header, 6);
	if (bytes_read < 6) {
		LOG_WRN("Failed to read bookmark header");
		fs_close(&file);
		return -EIO;
	}

	/* Verify magic */
	if (memcmp(header, BOOKMARK_MAGIC, 4) != 0) {
		LOG_WRN("Invalid bookmark file magic");
		fs_close(&file);
		return -EINVAL;
	}

	/* Get count */
	memcpy(&bookmark_cache_count, &header[4], 2);
	if (bookmark_cache_count > BOOKMARKS_MAX_COUNT) {
		LOG_WRN("Bookmark count exceeds maximum: %d", bookmark_cache_count);
		bookmark_cache_count = BOOKMARKS_MAX_COUNT;
	}

	/* Read bookmarks */
	for (int i = 0; i < bookmark_cache_count; i++) {
		uint8_t buffer[76];
		uint8_t *ptr = buffer;

		bytes_read = fs_read(&file, buffer, 76);
		if (bytes_read < 76) {
			LOG_WRN("Failed to read bookmark %d", i);
			break;
		}

		/* Timestamp */
		memcpy(&bookmark_cache[i].timestamp, ptr, 4);
		ptr += 4;

		/* Offset */
		memcpy(&bookmark_cache[i].offset_sec, ptr, 4);
		ptr += 4;

		/* File index */
		memcpy(&bookmark_cache[i].file_index, ptr, 2);
		ptr += 2;

		/* File offset */
		memcpy(&bookmark_cache[i].file_offset, ptr, 4);
		ptr += 4;

		/* Note */
		memset(bookmark_cache[i].note, 0, 64);
		strncpy(bookmark_cache[i].note, (char *)ptr, 63);
		ptr += 64;
	}

	fs_close(&file);

	LOG_INF("Loaded %d bookmarks for session: %s", bookmark_cache_count, session_id);

	return 0;
}
