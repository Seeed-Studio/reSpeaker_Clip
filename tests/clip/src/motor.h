/*
 * Copyright (c) 2023 Nordic Semiconductor ASA
 *
 * SPDX-License-Identifier: LicenseRef-Nordic-5-Clause
 */

#ifndef MOTOR_H
#define MOTOR_H

#include <zephyr/kernel.h>
#include <stdbool.h>

/**
 * @brief Initialize vibration motor control
 * @return 0 on success, negative errno on failure
 *
 * Initializes motor control via:
 * - PMIC GPIO2 (preferred, requires I2C)
 * - GPIO1.6 (fallback)
 */
int motor_init(void);

/**
 * @brief Set motor state
 * @param enable true to turn on, false to turn off
 * @return 0 on success, negative errno on failure
 */
int motor_set(bool enable);

/**
 * @brief Get motor running state
 * @return true if motor is on, false otherwise
 */
bool motor_is_running(void);

#endif /* MOTOR_H */
