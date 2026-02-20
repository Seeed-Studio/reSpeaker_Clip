/*
 * Copyright (c) 2025 Seeed Technology Co., Ltd.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>
#include "clip.h"
#include "state_machine.h"
#include "ble_svc.h"
#include "at_cmd.h"
#include "config.h"
#include "json_helper.h"
#include "audio.h"
#include "storage.h"
#include "button_handler.h"
/* #include "display_ctrl.h" */

LOG_MODULE_REGISTER(main, LOG_LEVEL_INF);

/* Global variables */
struct clip_config g_config;
struct device_status g_status;
uint32_t g_recording_time = 0;

/* Audio recording thread */
#define AUDIO_STACK_SIZE 8192
#define AUDIO_PRIORITY 5
K_THREAD_DEFINE(audio_thread, AUDIO_STACK_SIZE,
		audio_recording_thread, NULL, NULL, NULL,
		AUDIO_PRIORITY, 0, 0);

/* Forward declarations */
static void state_change_handler(enum clip_state old_state,
                                enum clip_state new_state);

int clip_init(void)
{
    int err;

    LOG_INF("Initializing reSpeaker Clip...");

    /* Initialize state machine */
    err = state_init();
    if (err) {
        LOG_ERR("State machine init failed: %d", err);
        return err;
    }

    /* Register state change callback */
    state_register_callback(state_change_handler);

    /* Initialize configuration */
    err = config_init();
    if (err) {
        LOG_WRN("Config init failed: %d, using defaults", err);
        /* Continue with defaults */
    }

    /* Initialize AT command parser */
    err = at_cmd_init();
    if (err) {
        LOG_ERR("AT command init failed: %d", err);
        return err;
    }

    /* Initialize BLE service */
    err = ble_svc_init();
    if (err) {
        LOG_ERR("BLE service init failed: %d", err);
        return err;
    }

    /* Initialize audio subsystem */
    err = audio_init();
    if (err) {
        LOG_WRN("Audio init failed: %d, audio features disabled", err);
        /* Continue anyway, audio is optional */
    }

    /* Initialize storage subsystem */
    err = storage_init();
    if (err) {
        LOG_WRN("Storage init failed: %d, SD card features disabled", err);
        /* Continue anyway, SD card is optional */
    }

    /* Initialize button handler */
    err = button_handler_init();
    if (err) {
        LOG_WRN("Button handler init failed: %d, button features disabled", err);
        /* Continue anyway, button is optional */
    }

    /* Initialize display (disabled for now) */
    /* err = display_init(); */

    /* Transition to idle state */
    err = state_transition(CLIP_STATE_IDLE);
    if (err) {
        LOG_ERR("Failed to transition to IDLE: %d", err);
        return err;
    }

    LOG_INF("reSpeaker Clip initialized successfully");
    LOG_INF("Device ready, waiting for BLE connection...");

    return 0;
}

static void state_change_handler(enum clip_state old_state,
                                enum clip_state new_state)
{
    LOG_INF("State change: %s -> %s",
           state_to_string(old_state),
           state_to_string(new_state));

    /* Update status */
    g_status.state = new_state;

    /* Update display (disabled for now) */
    /* display_update_status(); */

    /* Send state change notification via BLE if connected */
    if (ble_svc_is_ready()) {
        char *response;

        /* Build state change event */
        char event_data[128];
        snprintf(event_data, sizeof(event_data),
                "{\"event\":\"state_change\",\"old\":\"%s\",\"new\":\"%s\"}",
                state_to_string(old_state),
                state_to_string(new_state));

        json_create_success(event_data, &response);
        ble_svc_send_response(response);
        json_free(response);
    }

    /* TODO: Add haptic feedback */
}

void clip_main_loop(void)
{
    LOG_INF("Entering main loop");

    while (true) {
        /* Sleep to save power */
        k_sleep(K_MSEC(1000));

        /* Update recording time if recording */
        if (state_get_current() == CLIP_STATE_RECORDING) {
            g_recording_time++;

            /* TODO: Update display every second */
        }
    }
}

int main(void)
{
    int err;

    /* Initialize application */
    err = clip_init();
    if (err) {
        LOG_ERR("Application init failed: %d", err);
        return err;
    }

    /* Enter main loop */
    clip_main_loop();

    return 0;
}
