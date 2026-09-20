/*
 * Copyright (c) 2025 Seeed Technology Co., Ltd.
 *
 * SPDX-License-Identifier: Apache-2.0
 *
 * Central event dispatcher for CLIP device.
 *
 * Button presses and AT commands post events here.
 * The event handler validates state transitions, updates state,
 * and triggers all side effects (audio, haptic, display).
 */

#ifndef CLIP_EVENT_H
#define CLIP_EVENT_H

#include <zephyr/kernel.h>
#include "clip.h"

/**
 * @brief Device-level events from user input or AT commands.
 */
enum clip_event {
    CLIP_EVENT_START = 0,
    CLIP_EVENT_STOP,
    CLIP_EVENT_PAUSE,
    CLIP_EVENT_RESUME,
    CLIP_EVENT_MARK,
    CLIP_EVENT_WIFI_ON,
    CLIP_EVENT_WIFI_OFF,
    CLIP_EVENT_POWER_OFF_SHOW,
    CLIP_EVENT_POWER_OFF_EXEC,
    CLIP_EVENT_STATUS_SHOW,
    CLIP_EVENT_USB_CONNECTED,
    CLIP_EVENT_OTA_START,
    CLIP_EVENT_OTA_DONE,
    CLIP_EVENT_COUNT,
};

/**
 * @brief Event result codes
 */
enum clip_event_result {
    CLIP_EVENT_OK = 0,
    CLIP_EVENT_INVALID,
    CLIP_EVENT_BUSY,
    CLIP_EVENT_ERROR,
};

/**
 * @brief Event handler result info (for sync callers)
 */
struct clip_event_result_info {
    enum clip_event_result result;
    int error_code;
};

/**
 * @brief Post an event (non-blocking, for button presses)
 */
int clip_post_event(enum clip_event event);

/**
 * @brief Post an event and wait for result (blocking, for AT commands)
 */
int clip_post_event_sync(enum clip_event event,
                         struct clip_event_result_info *info);

/**
 * @brief Get current device state (thread-safe)
 */
enum clip_state clip_event_get_state(void);

/**
 * @brief True while an MCUmgr DFU upload is in progress.
 *
 * Set at DFU STARTED; cleared at DFU PENDING (upload complete, image
 * awaiting reboot), DFU STOPPED/cancelled, and BLE disconnect during
 * upload. Input gating uses this flag because the state machine stays
 * in its current state during OTA — CLIP_STATE_OTA is not entered via
 * the transition table.
 */
bool clip_event_ota_in_progress(void);

/**
 * @brief Wake the dedicated shutdown thread (bypasses the event queue).
 *
 * Called from the button callback on the confirming release. Safe from
 * any thread context; the semaphore has capacity 1 so repeat calls
 * coalesce.
 */
void clip_request_shutdown(void);

/**
 * @brief Initialize the event dispatcher
 */
int clip_event_init(void);

/**
 * @brief Notify SD activity (re-arms the idle SD power-off timer)
 */
void clip_storage_activity_notify(void);

/**
 * @brief Check if the FS log backend is currently active (AT+LOG on)
 *
 * When active, idle SD power-off is suppressed (logs write to SD).
 */
bool clip_log_fs_active(void);

/**
 * @brief Wait for events (called by main loop)
 *
 * Blocks until an event is posted or timeout expires.
 *
 * @param timeout Timeout in milliseconds
 */
void clip_event_wait(k_timeout_t timeout);

/**
 * @brief Process all pending events (called by main loop)
 *
 * Must be called after clip_event_wait() returns.
 * Executes all queued events in order.
 */
void clip_event_process(void);

/**
 * @brief Cancel ongoing OTA (e.g., on BLE disconnect)
 */
void clip_event_ota_cancel(void);

#endif /* CLIP_EVENT_H */
