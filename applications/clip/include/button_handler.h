/*
 * Copyright (c) 2025 Seeed Technology Co., Ltd.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#ifndef BUTTON_HANDLER_H
#define BUTTON_HANDLER_H

#include <zephyr/kernel.h>
#include <zephyr/drivers/input/button.h>

/**
 * @brief Initialize button handler
 *
 * @return 0 on success, negative error code on failure
 */
int button_handler_init(void);

/**
 * @brief Check if button handler is ready
 *
 * @return true if ready, false otherwise
 */
bool button_handler_is_ready(void);

#endif /* BUTTON_HANDLER_H */
