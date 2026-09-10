/*
 * Copyright (c) 2025 Seeed Technology Co., Ltd.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#ifndef CLIP_DISPLAY_H
#define CLIP_DISPLAY_H

#include <zephyr/kernel.h>
#include <stdint.h>
#include <stdbool.h>

/**
 * @file display.h
 * @brief UI display module for clip
 *
 * Event-driven UI system with state machine for display management.
 */

/* =============================================================================
 * UI States
 * ============================================================================= */

/**
 * @brief UI display states
 */
enum ui_state {
	UI_STATE_OFF = 0,              /**< Display off */
	UI_STATE_PAIRING_GUIDE,        /**< Pairing guide (BLE not bonded) */
	UI_STATE_STATUS_BAR,           /**< Status bar with battery/connection */
	UI_STATE_REC_WAVE,             /**< Recording with wave animation */
	UI_STATE_REC_DOT,              /**< Recording with dot animation */
	UI_STATE_MARKING,              /**< Bookmark animation */
	UI_STATE_PAUSED,               /**< Paused recording */
	UI_STATE_POWER_OFF,            /**< Power-off confirmation */
	UI_STATE_USB_CONNECTED,        /**< USB plugged in */
	UI_STATE_OTA,                  /**< OTA update in progress */
	UI_STATE_OTA_PROGRESS,         /**< OTA with progress bar */
	UI_STATE_ERROR,                /**< Error message display */
	UI_STATE_LOW_BATTERY,          /**< Low battery warning */
	UI_STATE_WIFI_BLOCKED,         /**< WiFi active, cannot record */
	UI_STATE_USB_BLOCKED,          /**< USB MSC active, cannot record */
};

/* =============================================================================
 * UI Events
 * ============================================================================= */

/**
 * @brief UI events for state transitions
 */
enum ui_event {
	UI_EVENT_REC_START = 0,        /**< Recording started */
	UI_EVENT_REC_STOP,             /**< Recording stopped */
	UI_EVENT_REC_PAUSE,            /**< Recording paused */
	UI_EVENT_REC_RESUME,           /**< Recording resumed */
	UI_EVENT_MARK,                 /**< Bookmark added */
	UI_EVENT_STATUS_SHOW,          /**< Show status bar */
	UI_EVENT_BONDED,               /**< BLE bonded */
	UI_EVENT_PAIRING_SHOW,        /**< Show pairing guide */
	UI_EVENT_POWER_OFF_SHOW,       /**< Show power-off screen */
	UI_EVENT_USB_CONNECTED,        /**< USB cable plugged in */
	UI_EVENT_OTA_START,            /**< OTA update started */
	UI_EVENT_OTA_DONE,             /**< OTA update completed */
	UI_EVENT_TIMEOUT,              /**< State timeout */
	UI_EVENT_ERROR_SHOW,           /**< Show error message */
	UI_EVENT_STATUS_REFRESH,       /**< Re-render current state (posted by
	                                       * non-display threads; rendering must
	                                       * stay single-writer on the display
	                                       * thread — cross-thread render+flush
	                                       * races tear the frame) */
	UI_EVENT_LOW_BATTERY,          /**< Low battery warning */
	UI_EVENT_BLE_DISCONNECTED,     /**< BLE disconnected */
	UI_EVENT_WIFI_BLOCKED,         /**< WiFi active, cannot record */
	UI_EVENT_USB_BLOCKED,          /**< USB MSC active, cannot record */
	UI_EVENT_ANIM_TICK,            /**< Animation frame tick (internal) */
};

/* =============================================================================
 * Display Status Structure
 * ============================================================================= */

/**
 * @brief Display status information
 */
struct display_status {
	uint8_t battery_percent;       /**< Battery percentage (0-100) */
	bool battery_charging;         /**< Battery charging status */
	bool ble_connected;            /**< BLE connected */
	bool wifi_running;             /**< WiFi AP running */
	bool wifi_sta_connected;       /**< WiFi station (client) connected */
	uint32_t free_space_mb;        /**< Free storage space in MB */
	bool transferring;             /**< File transfer in progress */
};

/* =============================================================================
 * Public API
 * ============================================================================= */

/**
 * @brief Initialize display module
 * @return 0 on success, negative errno on failure
 */
int display_init(void);

/**
 * @brief Get current UI state
 * @return Current UI display state
 */
enum ui_state display_get_state(void);

/**
 * @brief Check if display is ready
 * @return true if display device is ready
 */
bool display_is_ready(void);

/**
 * @brief Post event to UI queue
 * @param event Event to post
 * @return 0 on success, negative errno on failure
 */
int display_post_event(enum ui_event event);

/**
 * @brief Update display status
 * @param status New status information
 * @return 0 on success, negative errno on failure
 */
int display_update_status(const struct display_status *status);

/**
 * @brief Set recording mode display
 * @param recording True if recording, false otherwise
 * @param enhanced_mode True for enhanced mode (fast animation)
 * @return 0 on success, negative errno on failure
 */
int display_set_recording(bool recording, bool enhanced_mode);

/**
 * @brief Clear display (turn off)
 * @return 0 on success, negative errno on failure
 */
int display_turn_off(void);

/**
 * @brief Set OTA upload progress
 * @param percent Progress percentage (0-100)
 */
void display_set_ota_progress(uint8_t percent);

/**
 * @brief Show error message on display
 *
 * Displays an error message for 5 seconds then returns to OFF state.
 * If already showing an error, replaces the message.
 *
 * @param msg Error message string (max 23 chars)
 */
void display_post_error(const char *msg);

/**
 * @brief Set display brightness
 * @param brightness Brightness value (0-255)
 * @return 0 on success, negative errno on failure
 */
int clip_display_set_brightness(uint8_t brightness);

void display_clear_untransferred(void);

/**
 * @brief Check storage for unsynced sessions and update display
 *
 * Called after storage_init() completes (SD card mounted).
 * Refreshes status bar if the untransferred state changed.
 */
void display_check_untransferred(void);

/**
 * @brief Start boot animation in a background thread
 *
 * Plays "seeed studio" reveal animation while main init continues.
 * After animation completes, starts normal UI (status bar).
 * Must be called after display_init().
 */
void display_boot_animation_start(void);

/**
 * @brief Update transfer status and refresh display immediately
 * @param transferring true if transfer is active, false when done
 */
void display_set_transferring(bool transferring);

#endif /* CLIP_DISPLAY_H */
