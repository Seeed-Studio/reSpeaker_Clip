/*
 * Copyright (c) 2025 Seeed Technology Co., Ltd.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#ifndef BOOKMARKS_H
#define BOOKMARKS_H

#include <stdint.h>
#include <stdbool.h>
#include <zephyr/kernel.h>

/* Maximum number of bookmarks per session */
#define BOOKMARKS_MAX_COUNT 100

/* Bookmark entry */
struct bookmark {
	uint32_t timestamp;     /* Unix timestamp */
	uint32_t offset_sec;    /* Seconds from session start */
	uint16_t file_index;    /* File index (001.opus = 1) */
	uint32_t file_offset;   /* Byte offset in file */
	char note[64];          /* Optional note text */
};

/**
 * @brief Initialize bookmarks for a session
 *
 * @param session_id Session ID
 * @return 0 on success, negative error code on failure
 */
int bookmarks_init(const char *session_id);

/**
 * @brief Add a bookmark
 *
 * @param session_id Session ID
 * @param bookmark Bookmark entry to add
 * @return 0 on success, negative error code on failure
 */
int bookmarks_add(const char *session_id, const struct bookmark *bookmark);

/**
 * @brief Get all bookmarks for a session
 *
 * @param session_id Session ID
 * @param bookmarks Output array for bookmarks
 * @param max_count Maximum number of bookmarks to return
 * @return Number of bookmarks found, or negative error code
 */
int bookmarks_get_all(const char *session_id, struct bookmark *bookmarks, int max_count);

/**
 * @brief Clear all bookmarks for a session
 *
 * @param session_id Session ID
 * @return 0 on success, negative error code on failure
 */
int bookmarks_clear(const char *session_id);

/**
 * @brief Get bookmark count for a session
 *
 * @param session_id Session ID
 * @return Number of bookmarks, or negative error code
 */
int bookmarks_count(const char *session_id);

/**
 * @brief Save bookmarks to file
 *
 * @param session_id Session ID
 * @return 0 on success, negative error code on failure
 */
int bookmarks_save(const char *session_id);

/**
 * @brief Load bookmarks from file
 *
 * @param session_id Session ID
 * @return 0 on success, negative error code on failure
 */
int bookmarks_load(const char *session_id);

#endif /* BOOKMARKS_H */
