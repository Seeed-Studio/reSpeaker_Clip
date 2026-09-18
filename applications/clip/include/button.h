/*
 * Copyright (c) 2025 Seeed Technology Co., Ltd.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#ifndef CLIP_BUTTON_H
#define CLIP_BUTTON_H

#include <zephyr/kernel.h>
#include <zephyr/device.h>
#include <zephyr/drivers/input/button.h>

/**
 * @brief Button event callback
 *
 * Called in button driver thread context - must not block.
 * Use work queue for heavy operations.
 *
 * @param action Button action that occurred
 * @param user_data User data pointer
 */
typedef void (*button_callback_t)(enum button_action action, void *user_data);

/**
 * @brief Initialize button subsystem
 *
 * @return 0 on success, negative error code on failure
 */
int button_init(void);

/**
 * @brief Ignore all button input from now on (shutdown committed).
 *
 * Called at POWER_OFF_EXEC entry; only a reboot clears it.
 */
void button_shutdown_lockout(void);

/**
 * @brief Register button event callback
 *
 * @param callback Callback function
 * @param user_data User data pointer passed to callback
 * @return 0 on success, negative error code on failure
 */
int button_register_callback(button_callback_t callback, void *user_data);

/**
 * @brief Check if button module is ready
 *
 * @return true if ready, false otherwise
 */
bool button_is_ready(void);

#endif /* CLIP_BUTTON_H */
