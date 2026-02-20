/*
 * Copyright (c) 2025 Seeed Technology Co., Ltd.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#ifndef TRANSFER_H
#define TRANSFER_H

#include <stdint.h>
#include <stdbool.h>
#include <zephyr/kernel.h>

/* Transfer states */
enum transfer_state {
	TRANSFER_STATE_IDLE = 0,
	TRANSFER_STATE_TRANSMITTING,
	TRANSFER_STATE_PAUSED,
	TRANSFER_STATE_COMPLETED,
	TRANSFER_STATE_ERROR
};

/* Transfer direction */
enum transfer_direction {
	TRANSFER_DIR_NONE = 0,
	TRANSFER_DIR_UPLOAD,   /* Device -> App (download) */
	TRANSFER_DIR_DOWNLOAD  /* App -> Device (upload) */
};

/* Transfer information */
struct transfer_info {
	enum transfer_state state;
	enum transfer_direction direction;
	char session_id[32];      /* Session being transferred */
	char current_file[64];    /* Current file being transferred */
	uint32_t file_index;      /* Current file index in session */
	uint32_t total_files;     /* Total files to transfer */
	uint64_t bytes_transferred;  /* Bytes transferred so far */
	uint64_t total_bytes;     /* Total bytes to transfer */
	uint8_t progress_percent; /* 0-100 */
};

/**
 * @brief Initialize transfer subsystem
 *
 * @return 0 on success, negative error code on failure
 */
int transfer_init(void);

/**
 * @brief Start file transfer (device to app)
 *
 * @param session_id Session ID to transfer, or NULL for entire session
 * @param filename Specific filename, or NULL for all files in session
 * @return 0 on success, negative error code on failure
 */
int transfer_start(const char *session_id, const char *filename);

/**
 * @brief Pause ongoing transfer
 *
 * @return 0 on success, negative error code on failure
 */
int transfer_pause(void);

/**
 * @brief Resume paused transfer
 *
 * @return 0 on success, negative error code on failure
 */
int transfer_resume(void);

/**
 * @brief Cancel ongoing transfer
 *
 * @return 0 on success, negative error code on failure
 */
int transfer_cancel(void);

/**
 * @brief Get transfer progress
 *
 * @param info Output transfer information
 * @return 0 on success, negative error code on failure
 */
int transfer_get_progress(struct transfer_info *info);

/**
 * @brief Check if transfer is active
 *
 * @return true if transferring, false otherwise
 */
bool transfer_is_active(void);

/**
 * @brief Check if transfer is paused
 *
 * @return true if paused, false otherwise
 */
bool transfer_is_paused(void);

/**
 * @brief Get current transfer state
 *
 * @return Current transfer state
 */
enum transfer_state transfer_get_state(void);

#endif /* TRANSFER_H */
