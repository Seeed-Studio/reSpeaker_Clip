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
    bool valid;         /* True if time has been synchronized */
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
 * @brief Initialize clip recorder application
 *
 * @return 0 on success, negative error code on failure
 */
int clip_init(void);

/**
 * @brief Main application loop
 */
void clip_main_loop(void);

#endif /* CLIP_H */
