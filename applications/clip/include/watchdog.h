/*
 * Copyright (c) 2025 Seeed Technology Co., Ltd.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#ifndef WATCHDOG_H_
#define WATCHDOG_H_

/**
 * @brief Initialize the watchdog timer
 *
 * @return 0 on success, negative error code on failure
 */
int watchdog_init(void);

/**
 * @brief Feed the watchdog (kick/reset counter)
 *
 * This should be called periodically to prevent watchdog reset.
 * Recommended to call every 5-10 seconds if timeout is 30 seconds.
 */
void watchdog_feed(void);

#endif /* WATCHDOG_H_ */
