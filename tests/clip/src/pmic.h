/*
 * Copyright (c) 2023 Nordic Semiconductor ASA
 *
 * SPDX-License-Identifier: LicenseRef-Nordic-5-Clause
 */

#ifndef PMIC_H
#define PMIC_H

#include <zephyr/kernel.h>

/**
 * @brief Initialize PMIC (NPM1300)
 * @return 0 on success, negative errno on failure
 */
int pmic_init(void);

/**
 * @brief Get the filtered battery status used by the always-on OLED screen
 */
int pmic_get_battery_status(uint32_t *voltage_mv, uint8_t *percent, bool *charging,
			    int32_t *temp_c);

/**
 * @brief Persist the current nRF Fuel Gauge state before reset or power-off
 *
 * @return 0 on success, negative errno when persistence is unavailable
 */
int pmic_battery_state_save(void);

/**
 * @brief Stop the 1 s periodic battery/OLED refresh work
 *
 * Call before shutting the OLED/I2C2 down or parking in a sleep state,
 * so the handler stops waking the CPU every second and stops writing to
 * a suspended bus / unpowered display.
 *
 * @return k_work_cancel_delayable_sync() result (0 = cancelled)
 */
int pmic_display_work_stop(void);

#endif /* PMIC_H */
