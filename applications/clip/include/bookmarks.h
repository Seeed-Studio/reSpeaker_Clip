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

/* Bookmark entry - simplified to only store offset in seconds */
struct bookmark {
	uint32_t offset_sec;    /* Seconds from session start (key timestamp) */
};

/**
 * @brief Add a bookmark (directly writes to file, no cache)
 *
 * @param session_id Session ID
 * @param offset_sec Seconds from session start
 * @return 0 on success, negative error code on failure
 */
int bookmarks_add(const char *session_id, uint32_t offset_sec);

/**
 * @brief Get bookmarks for a session (with pagination)
 *
 * @param session_id Session ID
 * @param page Page number (1-based)
 * @param per_page Items per page
 * @param bookmarks Output array for bookmarks
 * @param max_count Maximum number of bookmarks to return
 * @return Number of bookmarks found, or negative error code
 */
int bookmarks_get_page(const char *session_id, int page, int per_page,
                      struct bookmark *bookmarks, int max_count);

/**
 * @brief Get bookmark count for a session
 *
 * @param session_id Session ID
 * @return Number of bookmarks, or negative error code
 */
int bookmarks_count(const char *session_id);

/**
 * @brief Clear all bookmarks for a session
 *
 * @param session_id Session ID
 * @return 0 on success, negative error code on failure
 */
int bookmarks_clear(const char *session_id);

#endif /* BOOKMARKS_H */
