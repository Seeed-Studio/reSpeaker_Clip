/*
 * Copyright (c) 2024 Seeed Technology Co., Ltd.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#ifndef CONFIG_H
#define CONFIG_H

#include <stdint.h>
#include <stddef.h>
#include <stdint.h>
#include "clip.h"

/* NVS keys for configuration (for future use) */
#define NVS_KEY_BITRATE     0x01
#define NVS_KEY_COMPLEXITY  0x02
#define NVS_KEY_MODE        0x03
#define NVS_KEY_NOISE       0x04
#define NVS_KEY_CHUNK_SIZE  0x05
#define NVS_KEY_AUTODEL     0x06
#define NVS_KEY_AGC_ENABLE  0x07
#define NVS_KEY_AGC_TARGET  0x08
#define NVS_KEY_DEREVERB    0x09

/**
 * @brief Initialize configuration manager
 *
 * @return 0 on success, negative error code on failure
 */
int config_init(void);

/**
 * @brief Load configuration from NVS
 *
 * @return 0 on success, negative error code on failure
 */
int config_load(void);

/**
 * @brief Save configuration to NVS
 *
 * @return 0 on success, negative error code on failure
 */
int config_save(void);

/**
 * @brief Reset configuration to factory defaults
 *
 * @return 0 on success, negative error code on failure
 */
int config_factory_reset(void);

/**
 * @brief Set configuration value
 *
 * @param key   NVS key
 * @param value Value to set
 * @param len   Length of value
 * @return 0 on success, negative error code on failure
 */
int config_set(uint16_t key, const void *value, size_t len);

/**
 * @brief Get configuration value
 *
 * @param key    NVS key
 * @param value  Output buffer
 * @param len    Length of buffer
 * @return 0 on success, negative error code on failure
 */
int config_get(uint16_t key, void *value, size_t len);

/**
 * @brief Save Unix timestamp to NVS for time persistence
 *
 * @param unix_time Pointer to Unix timestamp (int64_t)
 * @return 0 on success, negative error code on failure
 */
int config_set_time(const int64_t *unix_time);

/**
 * @brief Get current Unix timestamp from synced time
 *
 * @param unix_time Output buffer for Unix timestamp (int64_t)
 * @return 0 on success, negative error code if time not set
 */
int config_get_time(int64_t *unix_time);

#endif /* CONFIG_H */
