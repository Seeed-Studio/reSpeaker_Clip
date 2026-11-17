/*
 * Copyright (c) 2025 Seeed Technology Co., Ltd.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#ifndef CLIP_H
#define CLIP_H

#include <zephyr/kernel.h>
#include <zephyr/device.h>
#include <zephyr/sys/util.h>
#include <app_version.h>
#include <stdint.h>
#include <stdbool.h>

/* Version string: "X.Y.Z" when TWEAK=0, "X.Y.Z+N" when TWEAK>0. */
#if APP_TWEAK > 0
#define CLIP_VERSION APP_VERSION_TWEAK_STRING
#else
#define CLIP_VERSION APP_VERSION_STRING
#endif

/**
 * @brief Clip error codes
 */
#define CLIP_OK           0
#define CLIP_ERR_INVALID -1
#define CLIP_ERR_BUSY    -2
#define CLIP_ERR_NO_MEM  -3
#define CLIP_ERR_IO      -4
#define CLIP_ERR_TIMEOUT -5

/**
 * @brief Device states
 */
enum clip_state {
    CLIP_STATE_UNINITIALIZED = 0,
    CLIP_STATE_IDLE,
    CLIP_STATE_RECORDING,
    CLIP_STATE_TRANSMITTING,
    CLIP_STATE_WIFI_SYNC,
    CLIP_STATE_PAUSED,
    CLIP_STATE_ERROR,
    CLIP_STATE_OTA,
};

/**
 * @brief Recording modes
 */
enum recording_mode {
    MODE_NORMAL = 0,
    MODE_ENHANCED,
};

/**
 * @brief Event handler callback type
 */
typedef void (*event_handler_t)(int event, void *data);

/**
 * @brief Clip context structure
 *
 * Central structure that holds all application state.
 * This replaces global variables and enables better modularity.
 */
struct clip_context {
    /* Configuration */
    struct clip_config {
        uint8_t mode;               /* Recording mode (normal/enhanced) */
        uint8_t noise_suppress;     /* Noise suppression level (dB) */
        bool dereverb_enabled;      /* Dereverberation enabled */
        uint8_t oled_brightness;    /* OLED brightness (0-255) */
        char wifi_password[9];      /* WiFi AP password (8 chars + NUL) */
        char device_name[257];      /* User-defined device name (256 bytes + NUL) */
        uint8_t wifi_channel;       /* WiFi AP channel (default 36) */
        char wifi_reg_domain[3];    /* WiFi regulatory domain (2 chars + NUL, default "US") */
    } config;

    /* Status */
    struct clip_status {
        uint8_t battery_percent;
        uint8_t battery_soc_raw;    /* un-smoothed fuel-gauge SoC, for diagnostics */
        bool battery_charging;
        int8_t battery_temp;        /* Battery temperature (°C, NTC) */
        uint16_t battery_mv;        /* Battery voltage (mV) */
        uint32_t recording_time;
        uint32_t free_space;
        uint16_t session_count;
    } status;

    /* Time sync */
    struct clip_time {
        uint16_t year;
        uint8_t month;
        uint8_t day;
        uint8_t hour;
        uint8_t min;
        uint8_t sec;
        int64_t base_uptime_ms;
        bool valid;
        /* True while the clock was restored from persisted settings at
         * boot and no live AT+TIME sync has arrived since. The board has
         * no RTC, so time across the power-off gap is unknowable — the
         * app should push AT+TIME when it sees this (AT+TIME? reports it
         * as "restored":true). */
        bool restored;
    } time;
};

/**
 * @brief Get the global clip context
 *
 * @return Pointer to the clip context
 */
struct clip_context *clip_get_context(void);

void clip_cpu_boost_acquire(void);
void clip_cpu_boost_release(void);

/**
 * @brief Initialize clip application
 *
 * @return 0 on success, negative error code on failure
 */
int clip_init(void);

/**
 * @brief Main application loop
 */
void clip_main_loop(void);

/**
 * @brief Get current synchronized time
 *
 * @param out_year Output year
 * @param out_month Output month
 * @param out_day Output day
 * @param out_hour Output hour
 * @param out_min Output minute
 * @param out_sec Output second
 * @return true if time is valid, false otherwise
 */
bool clip_get_current_time(uint16_t *out_year, uint8_t *out_month, uint8_t *out_day,
                           uint8_t *out_hour, uint8_t *out_min, uint8_t *out_sec);

/**
 * @brief Convert state to string
 *
 * @param state State to convert
 * @return String representation
 */
const char *clip_state_to_string(enum clip_state state);

#endif /* CLIP_H */
