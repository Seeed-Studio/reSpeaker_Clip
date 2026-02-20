/*
 * Copyright (c) 2025 Seeed Technology Co., Ltd.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#ifndef STORAGE_H
#define STORAGE_H

#include <stdint.h>
#include <stdbool.h>
#include <zephyr/kernel.h>
#include <zephyr/fs/fs.h>

/* Storage configuration */
#define STORAGE_FILENAME_MAX_LEN 64
#define STORAGE_WRITE_BUFFER_SIZE 4096

/* File handle for recordings */
#define STORAGE_MAX_FILES 999

/**
 * @brief Storage statistics
 */
struct storage_stats {
	uint32_t total_files;
	uint64_t total_bytes;
	uint32_t free_space_mb;
	bool is_mounted;
};

/**
 * @brief Recording file handle
 */
struct storage_file {
	char filename[STORAGE_FILENAME_MAX_LEN];
	uint32_t bytes_written;
	uint32_t frames_written;
	bool is_open;
	struct fs_file_t _internal_file;  /* Internal file handle */
};

/**
 * @brief Initialize storage subsystem
 *
 * @return 0 on success, negative error code on failure
 */
int storage_init(void);

/**
 * @brief Cleanup storage subsystem
 */
void storage_cleanup(void);

/**
 * @brief Check if SD card is mounted
 *
 * @return true if mounted, false otherwise
 */
bool storage_is_mounted(void);

/**
 * @brief Get storage statistics
 *
 * @param stats Output statistics structure
 * @return 0 on success, negative error code on failure
 */
int storage_get_stats(struct storage_stats *stats);

/**
 * @brief Create a new recording file
 *
 * @param file Output file handle structure
 * @param session_id Session ID for filename
 * @param mode Audio mode (normal/enhanced)
 * @return 0 on success, negative error code on failure
 */
int storage_create_file(struct storage_file *file, uint32_t session_id, const char *mode);

/**
 * @brief Write audio frame data to file
 *
 * Uses buffering for efficient SD card writes.
 *
 * @param file File handle
 * @param data Opus encoded audio data
 * @param len Length of data
 * @return 0 on success, negative error code on failure
 */
int storage_write_frame(struct storage_file *file, const uint8_t *data, uint32_t len);

/**
 * @brief Close recording file
 *
 * Flushes any buffered data and closes the file.
 *
 * @param file File handle
 * @return 0 on success, negative error code on failure
 */
int storage_close_file(struct storage_file *file);

/**
 * @brief List all files on SD card
 *
 * @return 0 on success, negative error code on failure
 */
int storage_list_files(void);

/**
 * @brief Delete a file from SD card
 *
 * @param filename Name of file to delete
 * @return 0 on success, negative error code on failure
 */
int storage_delete_file(const char *filename);

/**
 * @brief Format SD card
 *
 * @return 0 on success, negative error code on failure
 */
int storage_format_card(void);

#endif /* STORAGE_H */
