/*
 * Copyright (c) 2024 Seeed Technology Co., Ltd.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#ifndef CLIP_H
#define CLIP_H

#include <zephyr/kernel.h>
#include <zephyr/device.h>
#include <zephyr/sys/util.h>
#include <stdint.h>

/**
 * @brief Device states
 */
enum clip_state {
    CLIP_STATE_UNINITIALIZED = 0,
    CLIP_STATE_IDLE,
    CLIP_STATE_RECORDING,
    CLIP_STATE_TRANSMITTING,
    CLIP_STATE_PAUSED,
    CLIP_STATE_ERROR,
};

/**
 * @brief Recording modes
 */
enum recording_mode {
    MODE_NORMAL = 0,
    MODE_ENHANCED,
};

/**
 * @brief Battery information
 */
struct battery_info {
    uint8_t percent;    /* Battery percentage (0-100) */
    bool charging;      /* True if charging */
};

/**
 * @brief Synchronized time from BLE
 */
struct synced_time {
    uint16_t year;
    uint8_t month;
    uint8_t day;
    uint8_t hour;
    uint8_t min;
    uint8_t sec;
    int64_t base_uptime_ms;  /* Uptime when time was set */
    bool valid;              /* True if time has been synchronized */
};

/**
 * @brief Device status
 */
struct device_status {
    enum clip_state state;
    struct battery_info battery;
    enum recording_mode mode;
    uint16_t bitrate;
    uint32_t free_space;
    uint32_t session_count;
};

/**
 * @brief Configuration
 */
struct clip_config {
    uint16_t bitrate;        /* Opus bitrate in bps */
    uint8_t complexity;       /* Opus complexity (0-10) */
    enum recording_mode mode; /* Recording mode */
    uint8_t noise_suppress;   /* Noise suppression (dB) */
    uint16_t chunk_size;      /* Transfer chunk size */
    int8_t auto_delete_days;  /* Auto-delete policy: -1=off, 0-30=days */
    uint8_t agc_target;        /* AGC target level (dB) */
    bool agc_enabled;         /* AGC enabled */
    bool dereverb_enabled;    /* Dereverberation enabled */
};

/* Global configuration */
extern struct clip_config g_config;

/* Global status */
extern struct device_status g_status;

/* Recording time (seconds) */
extern uint32_t g_recording_time;

/* Synchronized time from BLE */
extern struct synced_time g_synced_time;

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
 * @brief Initialize clip recorder application
 *
 * @return 0 on success, negative error code on failure
 */
int clip_init(void);

/**
 * @brief Main application loop
 */
void clip_main_loop(void);

/* Thread configuration - configurable via prj.conf or Kconfig */
#ifndef CONFIG_AUDIO_THREAD_PRIORITY
#define CLIP_AUDIO_THREAD_PRIORITY        0
#else
#define CLIP_AUDIO_THREAD_PRIORITY        CONFIG_AUDIO_THREAD_PRIORITY
#endif

#ifndef CONFIG_TRANSFER_THREAD_PRIORITY
#define CLIP_TRANSFER_THREAD_PRIORITY     7
#else
#define CLIP_TRANSFER_THREAD_PRIORITY     CONFIG_TRANSFER_THREAD_PRIORITY
#endif

#ifndef CONFIG_AT_CMD_THREAD_PRIORITY
#define CLIP_AT_CMD_THREAD_PRIORITY       5
#else
#define CLIP_AT_CMD_THREAD_PRIORITY       CONFIG_AT_CMD_THREAD_PRIORITY
#endif

#ifndef CONFIG_BUTTON_WORK_PRIORITY
#define CLIP_BUTTON_WORK_PRIORITY         5
#else
#define CLIP_BUTTON_WORK_PRIORITY         CONFIG_BUTTON_WORK_PRIORITY
#endif

/* Thread stack sizes */
#ifndef CONFIG_AUDIO_STACK_SIZE
#define CLIP_AUDIO_STACK_SIZE             32768
#else
#define CLIP_AUDIO_STACK_SIZE             CONFIG_AUDIO_STACK_SIZE
#endif

#ifndef CONFIG_TRANSFER_STACK_SIZE
#define CLIP_TRANSFER_STACK_SIZE          4096
#else
#define CLIP_TRANSFER_STACK_SIZE          CONFIG_TRANSFER_STACK_SIZE
#endif

#ifndef CONFIG_AT_CMD_STACK_SIZE
#define CLIP_AT_CMD_STACK_SIZE            8192
#else
#define CLIP_AT_CMD_STACK_SIZE            CONFIG_AT_CMD_STACK_SIZE
#endif

#ifndef CONFIG_BUTTON_WORK_STACK_SIZE
#define CLIP_BUTTON_WORK_STACK_SIZE       16384
#else
#define CLIP_BUTTON_WORK_STACK_SIZE       CONFIG_BUTTON_WORK_STACK_SIZE
#endif

/* Audio segmentation - configurable via prj.conf or Kconfig */
#ifndef CONFIG_AUDIO_SEGMENT_DURATION_SYNC
#define CLIP_AUDIO_SEGMENT_DURATION_SYNC      60  /* seconds during sync */
#else
#define CLIP_AUDIO_SEGMENT_DURATION_SYNC      CONFIG_AUDIO_SEGMENT_DURATION_SYNC
#endif

#ifndef CONFIG_AUDIO_SEGMENT_DURATION_NO_SYNC
#define CLIP_AUDIO_SEGMENT_DURATION_NO_SYNC   600 /* seconds when not syncing */
#else
#define CLIP_AUDIO_SEGMENT_DURATION_NO_SYNC   CONFIG_AUDIO_SEGMENT_DURATION_NO_SYNC
#endif

/* Transfer configuration - supports up to 2000 files for 18+ hours recording */
#ifndef CONFIG_TRANSFER_MAX_FILES
#define CLIP_TRANSFER_MAX_FILES            2000
#else
#define CLIP_TRANSFER_MAX_FILES            CONFIG_TRANSFER_MAX_FILES
#endif

#endif /* CLIP_H */
