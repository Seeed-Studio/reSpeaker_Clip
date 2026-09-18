/*
 * Copyright (c) 2025 Seeed Technology Co., Ltd.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#ifndef CLIP_BATTERY_H
#define CLIP_BATTERY_H

/**
 * @brief Initialize battery monitoring
 *
 * Sets up NPM1300 interrupt callbacks for charging events (VBUS, charge complete)
 * and starts periodic battery level polling (60s interval).
 * Updates BLE Battery Service with level and charging status.
 *
 * @return 0 on success, negative error code on failure
 */
int battery_init(void);

/**
 * @brief Milliseconds since the fuel-gauge state was last persisted
 *        (INT64_MAX when never). Lets shutdown skip a redundant save.
 */
int64_t battery_fg_state_age_ms(void);

/**
 * @brief Poll battery status immediately
 *
 * Reads sensors, updates fuel gauge SoC, and refreshes display/BLE.
 * Call this when the user triggers a status bar display to get fresh readings.
 */
void battery_poll(void);

/**
 * @brief Persist the nRF Fuel Gauge state to settings (LittleFS)
 *
 * Saves the fuel gauge internal state so the SoC is continuous across reboots
 * (without this, every reboot re-estimates SoC from the resting voltage and
 * the displayed % jumps). Called on SoC change (infrequent) + on graceful
 * shutdown/reboot (a fresh copy before power-off).
 */
void battery_save_fg_state(void);

#endif /* CLIP_BATTERY_H */
