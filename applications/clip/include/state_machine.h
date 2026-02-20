/*
 * Copyright (c) 2024 Seeed Technology Co., Ltd.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#ifndef STATE_MACHINE_H
#define STATE_MACHINE_H

#include "clip.h"

/**
 * @brief State change callback function type
 *
 * @param old_state Previous state
 * @param new_state New state
 */
typedef void (*state_change_callback_t)(enum clip_state old_state,
                                       enum clip_state new_state);

/**
 * @brief Initialize state machine
 *
 * @return 0 on success, negative error code on failure
 */
int state_init(void);

/**
 * @brief Get current device state
 *
 * @return Current device state
 */
enum clip_state state_get_current(void);

/**
 * @brief Convert state to string
 *
 * @param state Device state
 * @return String representation
 */
const char *state_to_string(enum clip_state state);

/**
 * @brief Transition to new state
 *
 * @param new_state Target state
 * @return 0 on success, negative error code on failure (invalid transition)
 */
int state_transition(enum clip_state new_state);

/**
 * @brief Register state change callback
 *
 * @param callback Callback function
 * @return 0 on success, negative error code on failure
 */
int state_register_callback(state_change_callback_t callback);

#endif /* STATE_MACHINE_H */
