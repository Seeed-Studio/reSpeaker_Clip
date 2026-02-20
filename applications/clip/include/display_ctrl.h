/*
 * Copyright (c) 2025 Seeed Technology Co., Ltd.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#ifndef DISPLAY_CTRL_H
#define DISPLAY_CTRL_H

#include <zephyr/kernel.h>

/* Display dimensions */
#define DISPLAY_WIDTH  88
#define DISPLAY_HEIGHT 48

/**
 * @brief Initialize display controller
 *
 * @return 0 on success, negative error code on failure
 */
int display_init(void);

/**
 * @brief Check if display is ready
 *
 * @return true if ready, false otherwise
 */
bool display_is_ready(void);

/**
 * @brief Clear display
 */
void display_clear(void);

/**
 * @brief Update display with current recording status
 *
 * Shows recording state, time, frames, and mode.
 */
void display_update_status(void);

/**
 * @brief Show message on display
 *
 * @param msg Message to display (max 20 chars)
 */
void display_show_message(const char *msg);

/**
 * @brief Show error on display
 *
 * @param error Error message (max 20 chars)
 */
void display_show_error(const char *error);

/**
 * @brief Show recording indicator
 *
 * @param recording true if recording, false otherwise
 */
void display_set_recording(bool recording);

/**
 * @brief Update battery level display
 *
 * @param percent Battery percentage (0-100)
 */
void display_update_battery(uint8_t percent);

#endif /* DISPLAY_CTRL_H */
