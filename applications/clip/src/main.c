/*
 * Copyright (c) 2025 Seeed Technology Co., Ltd.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>

#include <nrfx_clock.h>

#include "clip.h"
#include "state_machine.h"
#include "ble_svc.h"
#include "at_cmd.h"
#include "config.h"
#include "json_helper.h"
#include "audio.h"
#include "storage.h"
#include "button_handler.h"
#include "transfer.h"
#include "battery.h"
/* #include "display_ctrl.h" */

LOG_MODULE_REGISTER(main, LOG_LEVEL_INF);

/* Global variables */
struct clip_config g_config;
struct device_status g_status;
uint32_t g_recording_time = 0;
struct synced_time g_synced_time = {0};

/* Get current synchronized time based on uptime offset */
bool clip_get_current_time(uint16_t *out_year, uint8_t *out_month, uint8_t *out_day,
                           uint8_t *out_hour, uint8_t *out_min, uint8_t *out_sec)
{
    uint32_t sec;

    if (!g_synced_time.valid) {
        return false;
    }

    /* Calculate elapsed time since sync */
    int64_t current_uptime = k_uptime_get();
    int64_t elapsed_ms = current_uptime - g_synced_time.base_uptime_ms;

    if (elapsed_ms < 0) {
        elapsed_ms = 0;
    }

    /* Convert to seconds */
    uint32_t elapsed_sec = (uint32_t)(elapsed_ms / 1000);

    /* Start from synced time */
    uint16_t year = g_synced_time.year;
    uint8_t month = g_synced_time.month;
    uint8_t day = g_synced_time.day;
    uint8_t hour = g_synced_time.hour;
    uint8_t min = g_synced_time.min;
    sec = g_synced_time.sec;

    /* Add elapsed seconds */
    sec += elapsed_sec;

    /* Handle overflow */
    while (sec >= 60) {
        sec -= 60;
        min++;
    }
    while (min >= 60) {
        min -= 60;
        hour++;
    }
    while (hour >= 24) {
        hour -= 24;
        day++;
    }

    /* Simple day overflow handling (assumes 30 days per month for simplicity) */
    uint8_t days_in_month[] = {31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31};
    /* Simple leap year check */
    if ((year % 4 == 0 && year % 100 != 0) || (year % 400 == 0)) {
        days_in_month[1] = 29;
    }

    while (day > days_in_month[month - 1]) {
        day -= days_in_month[month - 1];
        month++;
        if (month > 12) {
            month = 1;
            year++;
        }
    }

    *out_year = year;
    *out_month = month;
    *out_day = day;
    *out_hour = hour;
    *out_min = min;
    *out_sec = (uint8_t)sec;

    return true;
}

/* Audio recording thread */
#define AUDIO_STACK_SIZE 32768
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
    if (err)
    {
        LOG_ERR("State machine init failed: %d", err);
        return err;
    }

    /* Register state change callback */
    state_register_callback(state_change_handler);

    /* Initialize configuration */
    err = config_init();
    if (err)
    {
        LOG_WRN("Config init failed: %d, using defaults", err);
        /* Continue with defaults */
    }

    /* Initialize AT command parser */
    err = at_cmd_init();
    if (err)
    {
        LOG_ERR("AT command init failed: %d", err);
        return err;
    }

    /* Initialize BLE service */
    err = ble_svc_init();
    if (err)
    {
        LOG_ERR("BLE service init failed: %d", err);
        return err;
    }

    /* Initialize audio subsystem */
    err = audio_init();
    if (err)
    {
        LOG_WRN("Audio init failed: %d, audio features disabled", err);
        /* Continue anyway, audio is optional */
    }

    /* Initialize storage subsystem */
    err = storage_init();
    if (err)
    {
        LOG_WRN("Storage init failed: %d, SD card features disabled", err);
        /* Continue anyway, SD card is optional */
    }

    /* Initialize button handler */
    err = button_handler_init();
    if (err)
    {
        LOG_WRN("Button handler init failed: %d, button features disabled", err);
        /* Continue anyway, button is optional */
    }

    /* Initialize transfer subsystem */
    err = transfer_init();
    if (err)
    {
        LOG_WRN("Transfer init failed: %d, transfer features disabled", err);
        /* Continue anyway, transfer is optional */
    }

    /* Initialize battery subsystem */
    err = battery_init();
    if (err)
    {
        LOG_WRN("Battery init failed: %d, battery features disabled", err);
        /* Continue anyway, battery is optional */
    }

    /* Initialize display (disabled for now) */
    /* err = display_init(); */

    /* Transition to idle state */
    err = state_transition(CLIP_STATE_IDLE);
    if (err)
    {
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
    if (ble_svc_is_ready())
    {
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

    while (true)
    {
        /* Sleep to save power */
        k_sleep(K_MSEC(1000));

        /* Update recording time if recording */
        if (state_get_current() == CLIP_STATE_RECORDING)
        {
            g_recording_time++;

            /* TODO: Update display every second */
        }
    }
}

int main(void)
{

#ifdef CLOCK_FEATURE_HFCLK_DIVIDE_PRESENT
    nrfx_clock_divider_set(NRF_CLOCK_DOMAIN_HFCLK, NRF_CLOCK_HFCLK_DIV_1);
#endif

    int err;

    /* Initialize application */
    err = clip_init();
    if (err)
    {
        LOG_ERR("Application init failed: %d", err);
        return err;
    }

    /* Enter main loop */
    clip_main_loop();

    return 0;
}
