/*
 * Copyright (c) 2025 Seeed Technology Co., Ltd.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#ifndef DISPLAY_CTRL_H
#define DISPLAY_CTRL_H

#include <zephyr/kernel.h>
#include <stdbool.h>

/* Display dimensions */
#define DISPLAY_WIDTH  88
#define DISPLAY_HEIGHT 48

/* UI state enumeration */
enum ui_state {
	UI_STATE_IDLE,           /* IDLE: Screen off */
	UI_STATE_STATUS_SHOW,    /* IDLE: Show status bar (on click) */
	UI_STATE_RECORDING_INFO, /* Recording: Show time + waveform (first 3s) */
	UI_STATE_RECORDING_DOT,  /* Recording: Show dot (after 3s) */
	UI_STATE_MARKING,        /* Recording: Show cross mark */
	UI_STATE_MESSAGE,        /* Show temporary message */
};

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

/* ========== UI State Machine Functions ========== */

/**
 * @brief Get current UI state (thread-safe)
 *
 * @return Current UI state
 */
enum ui_state ui_get_state(void);

/**
 * @brief Set UI state (thread-safe)
 *
 * @param new_state New UI state
 */
void ui_set_state(enum ui_state new_state);

/**
 * @brief Trigger mark display (bookmark added)
 *
 * Called from button handler when bookmark is added during recording.
 * Transitions to UI_STATE_MARKING for 0.5 seconds, then back to dot.
 */
void ui_trigger_mark(void);

/**
 * @brief Trigger status bar show (button click in IDLE)
 *
 * Called from button handler when button is clicked in IDLE state.
 * Transitions to UI_STATE_STATUS_SHOW for 3 seconds, then back to IDLE.
 */
void ui_trigger_status_show(void);

/**
 * @brief Handle recording state change (start/stop)
 *
 * Called from state machine when recording starts or stops.
 * @param recording true if recording started, false if stopped
 */
void ui_handle_recording_change(bool recording);

/**
 * @brief UI thread main function
 *
 * Runs the UI state machine loop.
 */
void ui_thread_main(void *p1, void *p2, void *p3);

#endif /* DISPLAY_CTRL_H */
