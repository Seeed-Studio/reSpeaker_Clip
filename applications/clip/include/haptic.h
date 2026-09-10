/*
 * Copyright (c) 2025 Seeed Technology Co., Ltd.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#ifndef CLIP_HAPTIC_H
#define CLIP_HAPTIC_H

#include <zephyr/kernel.h>
#include <stdbool.h>

/**
 * @brief Haptic feedback patterns
 */
enum haptic_pattern {
	HAPTIC_SHORT = 0,      /* Short tap: 100ms */
	HAPTIC_DOUBLE,         /* Double tap: 100ms on, 100ms off, 100ms on */
	HAPTIC_LONG,           /* Long: 500ms on */
	HAPTIC_ALERT,          /* Alert: 2 short, 1 long */
};

/**
 * @brief Initialize haptic motor control
 *
 * Initializes the vibration motor control via GPIO1.6.
 *
 * @return 0 on success, negative error code on failure
 */
int haptic_init(void);

/**
 * @brief Set motor state directly
 *
 * @param enable true to turn on, false to turn off
 * @return 0 on success, negative error code on failure
 */
int haptic_set_motor(bool enable);

/**
 * @brief Trigger haptic feedback pattern
 *
 * This function blocks while executing the pattern.
 *
 * @param pattern Haptic pattern to trigger
 * @return 0 on success, negative error code on failure
 */
int haptic_play_pattern(enum haptic_pattern pattern);

/**
 * @brief Check if motor is currently running
 *
 * @return true if motor is on, false otherwise
 */
bool haptic_is_running(void);

/**
 * @brief True while a haptic pattern is queued or the motor is running.
 *
 * Audio capture waits for this to clear before opening the mics: the
 * motor's mechanical noise couples into the PDM microphones and would be
 * recorded at the start of the session.
 */
bool haptic_is_busy(void);

#endif /* CLIP_HAPTIC_H */
