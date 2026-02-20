/*
 * Copyright (c) 2025 Seeed Technology Co., Ltd.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#ifndef BATTERY_H
#define BATTERY_H

#include <stdint.h>
#include <stdbool.h>

/**
 * @brief Initialize battery service
 *
 * @return 0 on success, negative error code on failure
 */
int battery_init(void);

/**
 * @brief Get current battery level
 *
 * @return Battery percentage (0-100)
 */
uint8_t battery_get_level(void);

/**
 * @brief Set battery level (for simulation)
 *
 * @param level Battery percentage (0-100)
 * @return 0 on success, negative error code on failure
 */
int battery_set_level(uint8_t level);

/**
 * @brief Get charging status
 *
 * @return true if charging, false otherwise
 */
bool battery_is_charging(void);

/**
 * @brief Set charging status (for simulation)
 *
 * @param charging true if charging, false otherwise
 * @return 0 on success, negative error code on failure
 */
int battery_set_charging(bool charging);

/**
 * @brief Get battery voltage in mV
 *
 * @return Voltage in millivolts
 */
uint32_t battery_get_voltage(void);

/**
 * @brief Update battery notification via BLE
 *
 * @return 0 on success, negative error code on failure
 */
int battery_notify(void);

#endif /* BATTERY_H */
