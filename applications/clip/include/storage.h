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
 * @brief Create a new recording session directory
 *
 * Creates /SD:/REC/<session_id>/ directory
 *
 * @param session_id Session ID (YYYYMMDDHHMMSS format)
 * @return 0 on success, negative error code on failure
 */
int storage_create_session(const char *session_id);

/**
 * @brief Create a new recording file within a session
 *
 * @param file Output file handle structure
 * @param session_id Session ID (YYYYMMDDHHMMSS format)
 * @param file_index File index within session (1, 2, 3...)
 * @return 0 on success, negative error code on failure
 */
int storage_create_file(struct storage_file *file, const char *session_id, uint16_t file_index);

/**
 * @brief Close a recording session and create metadata files
 *
 * Creates session.json and files.lst in the session directory
 *
 * @param session_id Session ID
 * @param duration_sec Recording duration in seconds
 * @param file_count Number of audio files in session
 * @return 0 on success, negative error code on failure
 */
int storage_close_session(const char *session_id, uint32_t duration_sec, uint16_t file_count);

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

/**
 * @brief Session information
 */
struct storage_session_info {
	char session_id[32];      /* Session ID (YYYYMMDD_HHMMSS) */
	uint32_t file_count;      /* Number of files in session */
	uint64_t total_bytes;     /* Total bytes in session */
	uint32_t duration_sec;    /* Duration in seconds */
};

/**
 * @brief List all sessions
 *
 * @param sessions Array to fill with session info
 * @param max_sessions Maximum number of sessions to return
 * @return Number of sessions found, or negative error code
 */
int storage_list_sessions(struct storage_session_info *sessions, int max_sessions);

/**
 * @brief Get session file list
 *
 * @param session_id Session ID
 * @param files Output array for file names
 * @param max_files Maximum files to return
 * @return Number of files found, or negative error code
 */
int storage_list_session_files(const char *session_id, char (*files)[32], int max_files);

/**
 * @brief Delete a session
 *
 * @param session_id Session ID to delete
 * @return 0 on success, negative error code on failure
 */
int storage_delete_session(const char *session_id);

/**
 * @brief Check if session exists
 *
 * @param session_id Session ID to check
 * @return true if exists, false otherwise
 */
bool storage_session_exists(const char *session_id);

/**
 * @brief Check if file is currently being written
 *
 * @param session_id Session ID
 * @param filename File name (e.g., "001.opus")
 * @return true if file is open/writing, false otherwise
 */
bool storage_file_is_writing(const char *session_id, const char *filename);

/**
 * @brief Get currently writing file info (if any)
 *
 * @param out_session Output session ID buffer (can be NULL)
 * @param out_filename Output filename buffer (can be NULL)
 * @param session_size Size of session_id buffer
 * @param filename_size Size of filename buffer
 * @return true if file is being written, false otherwise
 */
bool storage_get_writing_file(char *out_session, char *out_filename,
                              size_t session_size, size_t filename_size);

/**
 * @brief Set current writing file info
 *
 * Called by audio module to track which file is being written.
 *
 * @param session_id Session ID
 * @param filename Filename (e.g., "001.opus")
 */
void storage_set_writing_file(const char *session_id, const char *filename);

#endif /* STORAGE_H */
