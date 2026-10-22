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
#define STORAGE_SESSION_ID_LEN 32
#define STORAGE_FILENAME_MAX_LEN 64
/* Includes the NUL terminator. All storage path builders reject truncation. */
#define STORAGE_PATH_MAX 128

/**
 * @brief Storage statistics
 */
struct storage_stats {
    uint32_t total_chunks;      /* Total chunk files */
    uint64_t total_bytes;       /* Total bytes stored */
    uint32_t free_space_mb;     /* Free space in MB */
    uint32_t total_mb;          /* Total SD capacity in MB */
    bool is_mounted;            /* SD card mounted */
};

/**
 * @brief Chunk file handle (each Opus packet is a separate file)
 */
struct storage_chunk {
    char filename[32];          /* e.g., "000001.opus" */
    uint32_t chunk_index;       /* Chunk number */
    uint32_t bytes_written;     /* Bytes in this chunk */
    bool is_open;
};

/**
 * @brief Session information (matches clip format)
 */
struct storage_session_info {
    char session_id[STORAGE_SESSION_ID_LEN];
    uint32_t file_count;       /* Number of files in session (was chunk_count) */
    uint64_t total_bytes;      /* Total bytes in session */
    uint32_t synced_files;     /* Number of files successfully synced */
    uint32_t duration_sec;     /* Duration in seconds */
    uint8_t channels;          /* 1=mono, 2=stereo */
    uint8_t sample_rate_khz;   /* Sample rate in kHz (e.g., 16 for 16000Hz) */
    char mode[16];             /* "normal" or "enhanced" */
};

/**
 * @brief Initialize storage subsystem
 *
 * @return 0 on success, negative error code on failure
 */
int storage_init(void);

/**
 * @brief Cleanup storage subsystem (unmount the SD)
 *
 * Callers handing the raw card to another owner (USB MSC) must check the
 * result: a failed unmount means the filesystem is still in use and the
 * other owner must not touch the card.
 *
 * @return 0 on success (or already unmounted), negative error code on failure
 */
int storage_cleanup(void);

/**
 * @brief Remount SD card after MSC disable
 *
 * Re-initializes disk and mounts FATFS.
 *
 * @return 0 on success, negative error code on failure
 */
int storage_remount(void);

/**
 * @brief Check if SD card is mounted
 *
 * @return true if mounted, false otherwise
 */
bool storage_is_mounted(void);

/**
 * @brief Power-gate the SD card for idle (unmount + LDO2 off + SPI4 suspend + CS park)
 *
 * Refuses (-EBUSY) if a file is mid-write. Idempotent. Thread-safe.
 *
 * @return 0 on success, -EBUSY if a file is writing, or negative error code
 */
int storage_idle_poweroff(void);

/**
 * @brief Power on and remount the SD card (undo storage_idle_poweroff)
 *
 * @return 0 on success, negative error code on failure
 */
int storage_resume(void);

/**
 * @brief Ensure the SD card is mounted (resume if it was idle-powered-off)
 *
 * Single on-demand chokepoint for any SD access. Also re-arms the idle
 * power-off timer via the registered activity callback.
 *
 * @return 0 when mounted, negative error code otherwise
 */
int storage_ensure_mounted(void);

/**
 * @brief Check if the SD card rail is powered
 *
 * @return true if powered, false otherwise
 */
bool storage_is_sd_powered(void);

/**
 * @brief Check if storage is (near) full
 *
 * Returns true after a write failure latches the full flag, or when SD usage
 * reaches CONFIG_CLIP_STORAGE_FULL_PERCENT. Clears once usage drops back
 * below the threshold.
 *
 * @return true if too full to record, false otherwise
 */
bool storage_is_full(void);

/* Activity callback invoked after any SD access to re-arm idle power-off */
typedef void (*storage_activity_cb_t)(void);

/**
 * @brief Register the SD-activity callback (re-arms idle power-off)
 *
 * @param cb Callback, or NULL to clear
 */
void storage_set_activity_cb(storage_activity_cb_t cb);

/* Busy-check callback: returns true if the SD must NOT be idle-powered-off
 * (e.g. recording/transfer/OTA active). Evaluated under sd_lifecycle_mutex
 * by storage_idle_poweroff(), closing the TOCTOU with the unlocked tick. */
typedef bool (*storage_busy_cb_t)(void);

/**
 * @brief Register the SD-busy callback
 */
void storage_set_busy_cb(storage_busy_cb_t cb);

/**
 * @brief Get storage statistics
 *
 * @param stats Output statistics structure
 * @return 0 on success, negative error code on failure
 */
int storage_get_stats(struct storage_stats *stats);

/**
 * @brief Create a new recording session
 *
 * Creates the timestamp-bucket layout:
 * /SD:/REC/YYYYMMDD/HH/MM/SS/session.json
 * /SD:/REC/YYYYMMDD/HH/MM/SS/marks.bin
 * /SD:/REC/YYYYMMDD/HH/MM/SS/0/0001.opus
 *
 * @param session_id Session ID (14 digits: YYYYMMDDHHMMSS)
 * @param channels Audio channels (1=mono, 2=stereo)
 * @param sample_rate Sample rate in Hz (e.g., 16000)
 * @param mode Recording mode ("normal" or "enhanced")
 * @return 0 on success, negative error code on failure
 */
int storage_create_session(const char *session_id, uint8_t channels,
                          uint32_t sample_rate, const char *mode);

/**
 * @brief Close a recording session
 *
 * Updates session.json with final duration and chunk count.
 *
 * @param session_id Session ID
 * @param duration_sec Recording duration in seconds
 * @param chunk_count Number of chunk files
 * @return 0 on success, negative error code on failure
 */
int storage_close_session(const char *session_id, uint32_t duration_sec,
                         uint32_t chunk_count);

/**
 * @brief Write a chunk (Opus packet) as a separate file
 *
 * Each Opus packet is saved as a separate file: 000001.opus, 000002.opus, ...
 *
 * @param session_id Session ID
 * @param chunk_index Chunk number (1-based)
 * @param data Opus encoded data
 * @param len Length of data
 * @return 0 on success, negative error code on failure
 */
int storage_write_chunk(const char *session_id, uint32_t chunk_index,
                       const uint8_t *data, uint32_t len);

/**
 * @brief Storage file handle for continuous writing
 */
struct storage_file {
    char filename[STORAGE_FILENAME_MAX_LEN];
    char session_id[STORAGE_SESSION_ID_LEN];
    uint32_t chunk_index;
    uint32_t bytes_written;
    uint32_t frames_written;
    bool is_open;
    struct fs_file_t internal_file;  /* Internal file handle */
};

/**
 * @brief Create a new storage file
 *
 * @param file Storage file handle
 * @param session_id Session ID
 * @param chunk_index Chunk number (1-based)
 * @return 0 on success, negative error code on failure
 */
int storage_create_file(struct storage_file *file, const char *session_id, uint32_t chunk_index);

/**
 * @brief Write an Opus frame to storage file (with 2-byte length header)
 *
 * Format: [2-byte little-endian length][Opus data]
 *
 * @param file Storage file handle
 * @param data Opus encoded data
 * @param len Length of data (max 65535)
 * @return 0 on success, negative error code on failure
 */
int storage_write_frame(struct storage_file *file, const uint8_t *data, uint32_t len);

/**
 * @brief Close storage file
 *
 * @param file Storage file handle
 * @return 0 on success, negative error code on failure
 */
int storage_close_file(struct storage_file *file);

/**
 * @brief Read a chunk file
 *
 * @param session_id Session ID
 * @param chunk_index Chunk number (1-based)
 * @param data Buffer to read data into
 * @param len Buffer size
 * @return Number of bytes read, or negative error code on failure
 */
int storage_read_chunk(const char *session_id, uint32_t chunk_index,
                      uint8_t *data, uint32_t len);

/**
 * @brief Delete a chunk file
 *
 * @param session_id Session ID
 * @param chunk_index Chunk number (1-based)
 * @return 0 on success, negative error code on failure
 */
int storage_delete_chunk(const char *session_id, uint32_t chunk_index);

/**
 * @brief Build the on-card path of a session chunk.
 *
 * Builds a path in the fixed timestamp-bucket layout and checks for truncation.
 */
int storage_build_chunk_path(const char *session_id, uint32_t chunk_index,
                             char *path, size_t path_size);

/**
 * @brief Build the on-card session metadata path.
 */
int storage_build_session_metadata_path(const char *session_id,
                                        char *path, size_t path_size);

/**
 * @brief List all sessions
 *
 * @param sessions Output array for session info
 * @param max_sessions Maximum sessions to return
 * @return Number of sessions found, or negative error code
 */
int storage_list_sessions(struct storage_session_info *sessions, int max_sessions);

/**
 * @brief Count total number of sessions (fast, doesn't read session details)
 *
 * @return Total session count, or negative error code
 */
int storage_count_sessions(void);

/**
 * @brief List session IDs only (fast, no session.json reads)
 *
 * Scans timestamp buckets and returns sorted session IDs. Does not read
 * session metadata files.
 * Empty sessions (no .opus files) are automatically deleted.
 *
 * @param ids Output array for session IDs (each at least 16 bytes)
 * @param max_ids Maximum number of IDs to return
 * @return Number of IDs found, or negative error code
 */
int storage_list_session_ids(char ids[][16], int max_ids);

/**
 * @brief List sessions with pagination support
 *
 * @param sessions Output array for session info
 * @param offset Starting offset (0-based)
 * @param limit Maximum number of sessions to return
 * @return Number of sessions returned, or negative error code
 */
int storage_list_sessions_paginated(struct storage_session_info *sessions,
                                   int offset, int limit);

/**
 * @brief Check if there are any sessions with unsynced files
 *
 * @return true if at least one session has synced_files < file_count
 */
bool storage_has_unsynced_sessions(void);

/**
 * @brief Get session information
 *
 * @param session_id Session ID
 * @param info Output session info structure
 * @return 0 on success, negative error code on failure
 */
int storage_get_session_info(const char *session_id, struct storage_session_info *info);

/**
 * @brief Persist the number of synced chunk files in a session metadata file.
 */
int storage_set_synced_files(const char *session_id, uint32_t count);

/**
 * @brief List chunk files in a session
 *
 * @param session_id Session ID
 * @param chunks Output array for chunk indices
 * @param max_chunks Maximum chunks to return
 * @return Number of chunks found, or negative error code
 */
int storage_list_chunks(const char *session_id, uint32_t *chunks, int max_chunks, int skip);

/**
 * @brief Delete a session and all its chunks
 *
 * @param session_id Session ID to delete
 * @return 0 on success, negative error code on failure
 */
int storage_delete_session(const char *session_id);

/* Remove a session created at recording START whose first file create
 * failed (no json-only phantom). Safe for the current session. */
int storage_abort_session(const char *session_id);

/* Boot-time GC: delete sessions with zero audio files. Returns the
 * number removed. (Currently unreferenced — encounter-time cleanup in
 * the transfer path replaced the boot sweep.) */
int storage_sweep_empty_sessions(void);

/* True if the session holds at least one non-empty .opus file. */
int storage_session_has_audio(const char *session_id);

/**
 * @brief Format SD card
 *
 * @return 0 on success, negative error code on failure
 */
int storage_format_card(void);

/* Bookmark support */
/**
 * @brief Bookmark entry
 */
struct storage_bookmark {
    uint32_t offset_sec;    /* Seconds from session start */
};

/**
 * @brief Add a bookmark to a session
 *
 * @param session_id Session ID
 * @param offset_sec Seconds from session start
 * @return 0 on success, negative error code on failure
 */
int storage_add_bookmark(const char *session_id, uint32_t offset_sec);

/**
 * @brief Get bookmarks for a session (with pagination)
 *
 * File format: [4 bytes magic "BMRK"][2 bytes count][N * 4 byte offsets]
 *
 * @param session_id Session ID
 * @param page Page number (1-based)
 * @param per_page Items per page
 * @param bookmarks Output array for bookmarks
 * @param max_count Maximum number of bookmarks to return
 * @return Number of bookmarks found, or negative error code
 */
int storage_get_bookmarks(const char *session_id, int page, int per_page,
                          struct storage_bookmark *bookmarks, int max_count);

/**
 * @brief Get bookmark count for a session
 *
 * @param session_id Session ID
 * @return Number of bookmarks, or negative error code
 */
int storage_count_bookmarks(const char *session_id);

/* File writing state tracking for transfer coordination */

/**
 * @brief Set the current writing file
 *
 * Called by storage_create_file() to mark a file as being written.
 * Transfer thread waits for files to finish writing before transferring.
 *
 * @param session_id Session ID (NULL to clear)
 * @param filename Filename (NULL to clear)
 */
void storage_set_writing_file(const char *session_id, const char *filename);

/**
 * @brief Check if a file is currently being written
 *
 * @param session_id Session ID
 * @param filename Filename
 * @return true if file is being written, false otherwise
 */
bool storage_file_is_writing(const char *session_id, const char *filename);

/**
 * @brief Get the file closed semaphore
 *
 * This semaphore is given when a file is closed and ready for transfer.
 * Transfer thread can wait on this instead of polling storage_file_is_writing().
 *
 * @return Pointer to the semaphore, or NULL if storage not initialized
 */
struct k_sem *storage_get_file_closed_sem(void);

/**
 * @brief Get the current writing file info
 *
 * @param out_session Output buffer for session ID (can be NULL)
 * @param out_filename Output buffer for filename (can be NULL)
 * @param session_size Size of session buffer
 * @param filename_size Size of filename buffer
 * @return true if a file is being written, false otherwise
 */
bool storage_get_writing_file(char *out_session, char *out_filename,
                              size_t session_size, size_t filename_size);

/**
 * @brief Lock session.json for atomic read-modify-write
 *
 * Prevents race between audio thread (update_session_json) and
 * transfer thread (transfer_set_synced_files).
 */
void storage_session_json_lock(void);

/**
 * @brief Unlock session.json
 */
void storage_session_json_unlock(void);

#endif /* STORAGE_H */
