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
 * @brief Show battery status on the OLED (discharge/charge cycle test)
 *
 * Renders three lines: "Bat: NN%", the charge/discharge state with the cycle
 * count (e.g. "DISCHARGE #5"), and the battery voltage in mV.
 *
 * @param pct Battery percentage (0-100)
 * @param charging True if charging
 * @param mv Battery voltage in millivolts
 * @param state State string, e.g. "CHARGE" / "DISCHARGE"
 * @param cycles Completed charge/discharge cycle count
 */
void oled_show_battery(uint8_t pct, bool charging, uint32_t mv,
		       const char *state, uint32_t cycles);

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
