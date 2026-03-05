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

/**
 * @brief UI state enumeration (exposed for debugging)
 */
enum ui_state {
	UI_STATE_OFF,            /**< Screen off (pixels cleared) */
	UI_STATE_PAIRING_GUIDE,  /**< Show pairing guide (not bonded) */
	UI_STATE_STATUS_BAR,     /**< Show status info (3s timeout) */
	UI_STATE_REC_WAVE,       /**< Recording: waveform animation (first 5s) */
	UI_STATE_REC_DOT,        /**< Recording: stable dot (stays on) */
	UI_STATE_MARKING,        /**< Recording: mark animation (~150ms) */
};

/**
 * @brief UI event enumeration
 *
 * Post events via ui_post_event() from any thread or ISR.
 */
enum ui_event {
	UI_EVT_REC_START,    /**< Recording started */
	UI_EVT_REC_STOP,     /**< Recording stopped */
	UI_EVT_REC_PAUSE,    /**< Recording paused */
	UI_EVT_REC_RESUME,    /**< Recording resumed */
	UI_EVT_MARK,         /**< Bookmark added during recording */
	UI_EVT_STATUS_SHOW,  /**< Single click in idle -> show status bar */
	UI_EVT_BONDED,       /**< BLE pairing completed -> hide pairing guide */
};

/**
 * @brief Post an event to the UI state machine (thread-safe, ISR-safe)
 *
 * @param evt Event to post
 */
void ui_post_event(enum ui_event evt);

/**
 * @brief Get current UI state (for debugging)
 *
 * @return Current UI state
 */
enum ui_state ui_get_state(void);

/**
 * @brief Initialize display controller and start UI thread
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
 * @brief Clear display (calls oled_clear)
 */
void display_clear(void);

/**
 * @brief Update display with current recording status (no-op, handled by UI thread)
 */
void display_update_status(void);

/**
 * @brief Show message on display (log only)
 *
 * @param msg Message to display
 */
void display_show_message(const char *msg);

/**
 * @brief Show error on display (log only)
 *
 * @param error Error message
 */
void display_show_error(const char *error);

/**
 * @brief Notify recording state change
 *
 * Posts UI_EVT_REC_START or UI_EVT_REC_STOP.
 * @param recording true if recording started, false if stopped
 */
void display_set_recording(bool recording);

/**
 * @brief Notify recording pause state change
 *
 * Posts UI_EVT_REC_PAUSE.
 */
void display_set_recording_paused(void);

/**
 * @brief Notify recording resumed from pause
 *
 * Posts UI_EVT_REC_RESUME to restore recording display.
 */
void display_set_recording_resumed(void);

/**
 * @brief Update battery level (log only)
 *
 * @param percent Battery percentage (0-100)
 */
void display_update_battery(uint8_t percent);

/**
 * @brief UI thread main function
 *
 * Runs the UI event loop. Started by display_init().
 */
void ui_thread_main(void *p1, void *p2, void *p3);

#endif /* DISPLAY_CTRL_H */
