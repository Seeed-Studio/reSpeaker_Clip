/*
 * Copyright (c) 2023 Nordic Semiconductor ASA
 *
 * SPDX-License-Identifier: LicenseRef-Nordic-5-Clause
 */

#ifndef OLED_H
#define OLED_H

#include <zephyr/kernel.h>

/**
 * @brief Initialize OLED display
 * @return 0 on success, negative errno on failure
 */
int oled_init(void);

/**
 * @brief Test 1: Clear display
 */
void oled_test_clear(void);

/**
 * @brief Test 2: Fill display
 */
void oled_test_fill(void);

/**
 * @brief Test 3: Display test pattern
 */
void oled_test_pattern(void);

/**
 * @brief Test 4: Circle animation (breathing effect)
 */
void oled_test_circle_anim(void);

/**
 * @brief Test 5: Pixel manipulation test (checkerboard)
 */
void oled_test_pixels(void);

/**
 * @brief Run all OLED tests sequentially
 */
void oled_run_all_tests(void);

#endif /* OLED_H */
