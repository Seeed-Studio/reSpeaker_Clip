/*
 * Copyright (c) 2025 Seeed Technology Co., Ltd.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#ifndef CLIP_CONFIG_H
#define CLIP_CONFIG_H

#include <stdint.h>
#include <stddef.h>
#include "clip.h"

/* Configuration keys */
#define CONFIG_KEY_MODE          0x03
#define CONFIG_KEY_NOISE         0x04
#define CONFIG_KEY_DEREVERB      0x09
#define CONFIG_KEY_BRIGHTNESS    0x0A
#define CONFIG_KEY_WIFI_PASSWORD 0x0B
#define CONFIG_KEY_DEVICE_NAME   0x0C
#define CONFIG_KEY_WIFI_CHANNEL  0x0D
#define CONFIG_KEY_WIFI_REG_DOMAIN 0x0E


/**
 * @brief Initialize configuration system
 *
 * @return 0 on success, negative error code on failure
 */
int config_init(void);

/**
 * @brief Load configuration from storage
 *
 * @return 0 on success, negative error code on failure
 */
int config_load(void);

/**
 * @brief Save configuration to storage
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
 * @param key   Configuration key
 * @param value Pointer to value
 * @param len   Length of value
 * @return 0 on success, negative error code on failure
 */
int config_set(uint16_t key, const void *value, size_t len);

/**
 * @brief Get configuration value
 *
 * @param key    Configuration key
 * @param value  Output buffer
 * @param len    Length of buffer
 * @return 0 on success, negative error code on failure
 */
int config_get(uint16_t key, void *value, size_t len);

/**
 * @brief Save Unix timestamp to storage
 *
 * @param unix_time Unix timestamp
 * @return 0 on success, negative error code on failure
 */
int config_set_time(int64_t unix_time);

/**
 * @brief Get Unix timestamp from storage
 *
 * @param unix_time Output buffer for Unix timestamp
 * @return 0 on success, negative error code if time not set
 */
int config_get_time(int64_t *unix_time);

/**
 * @brief Set time values (YMDHMS)
 *
 * @param year Year
 * @param month Month (1-12)
 * @param day Day (1-31)
 * @param hour Hour (0-23)
 * @param min Minute (0-59)
 * @param sec Second (0-59)
 * @return 0 on success, negative error code on failure
 */
int config_set_time_ymd(uint16_t year, uint8_t month, uint8_t day,
                        uint8_t hour, uint8_t min, uint8_t sec);

/**
 * @brief Sync time baseline using current compensated time
 *
 * Recalculates current time from uptime compensation, then writes
 * it back as the new baseline. Call periodically (e.g. on recording
 * stop) to prevent long-term drift in the uptime-based clock.
 */
void config_sync_time(void);

/**
 * @brief Product serial number (factory-written, write-once)
 *
 * Stored in the "sn" settings subtree — survives AT+FACTORY (which only
 * resets the config keys) and app reflash (external flash). Charset
 * [A-Za-z0-9._-], max 32 chars.
 */
/** @brief Get the SN ("" when unset) */
const char *config_get_sn(void);

/** @brief True when an SN has been written */
bool config_sn_is_set(void);

/**
 * @brief Write the SN (first write only)
 *
 * @return 0 on success, -EINVAL bad charset/length, -EALREADY already set
 */
int config_set_sn(const char *sn);

/**
 * @brief Write the SN, overwriting an existing value (validated first)
 *
 * Used by the AT+SN rewrite path after the MAC proof has been verified.
 * The new value is validated BEFORE the settings store is touched, so a
 * rejected value leaves the old SN intact.
 *
 * @return 0 on success, -EINVAL bad charset/length, negative on flash error
 */
int config_set_sn_force(const char *sn);

/**
 * @brief Clear the SN (factory rework; AT+SN rewrite uses set_force instead)
 *
 * @return 0 on success, negative error code on failure
 */
int config_clear_sn(void);

/**
 * @brief Set recording mode
 *
 * @param mode Recording mode
 * @return 0 on success, negative error code on failure
 */
int config_set_mode(enum recording_mode mode);

/**
 * @brief Set noise suppression level
 *
 * @param noise Noise suppression in dB
 * @return 0 on success, negative error code on failure
 */
int config_set_noise_suppress(uint8_t noise);

/**
 * @brief Set auto-delete days
 *
 * @param days Days (0-30) or -1 for off
 * @return 0 on success, negative error code on failure
 */

/**
 * @brief Set dereverb enabled
 *
 * @param enabled true to enable, false to disable
 * @return 0 on success, negative error code on failure
 */
int config_set_dereverb_enabled(bool enabled);

/**
 * @brief Set OLED brightness
 *
 * @param brightness Brightness (0-255)
 * @return 0 on success, negative error code on failure
 */
int config_set_oled_brightness(uint8_t brightness);

/**
 * @brief Generate a random WiFi AP password and save to config
 *
 * Generates 8-char alphanumeric password (excluding 0/O/l/1/I).
 *
 * @return 0 on success, negative error code on failure
 */
int config_generate_wifi_password(void);

/**
 * @brief Set WiFi AP password
 *
 * @param password Password string (up to 8 chars)
 * @return 0 on success, negative error code on failure
 */
int config_set_wifi_password(const char *password);

/**
 * @brief Get WiFi AP password
 *
 * @return Password string, or "12345678" if not set
 */
const char *config_get_wifi_password(void);

/**
 * @brief Set device name
 *
 * @param name Device name string (1-32 chars, printable UTF-8)
 * @return 0 on success, negative error code on failure
 */
int config_set_device_name(const char *name);

/**
 * @brief Get device name
 *
 * @return Device name string, or empty string if not set
 */
const char *config_get_device_name(void);

/**
 * @brief Set WiFi AP channel
 *
 * @param channel Channel number (5GHz: 36-165)
 * @return 0 on success, negative error code on failure
 */
int config_set_wifi_channel(uint8_t channel);

/**
 * @brief Get WiFi AP channel
 *
 * @return Channel number
 */
uint8_t config_get_wifi_channel(void);

/**
 * @brief Set WiFi regulatory domain
 *
 * @param reg_domain 2-letter country code
 * @return 0 on success, negative error code on failure
 */
int config_set_wifi_reg_domain(const char *reg_domain);

/**
 * @brief Get WiFi regulatory domain
 *
 * @return 2-letter country code string
 */
const char *config_get_wifi_reg_domain(void);

/**
 * @brief Arm/disarm the settings_load watchdog
 *
 * settings_load can block for ~40s on a corrupt settings file and cannot
 * be interrupted. Arm a watchdog (on the system workqueue thread, which
 * runs independently of the main thread where settings_load executes)
 * before a settings_load_subtree() call; if it hasn't returned within
 * SETTINGS_LOAD_TIMEOUT_MS, the watchdog wipes the file and reboots.
 */
void settings_load_watchdog_arm(void);
void settings_load_watchdog_disarm(void);

#endif /* CLIP_CONFIG_H */
