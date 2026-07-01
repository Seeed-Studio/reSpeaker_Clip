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
 * @brief Get battery status
 * @param voltage_mv Pointer to store voltage in mV
 * @param percent Pointer to store battery percentage
 * @param charging Pointer to store charging state
 * @return 0 on success, negative errno on failure
 */
int pmic_get_battery_status(uint32_t *voltage_mv, uint8_t *percent, bool *charging);

/**
 * @brief Enable or disable battery charging at runtime
 *
 * Disabling makes the device run on battery (used to force a discharge).
 * Re-enabling resumes charging if VBUS is present.
 *
 * @param enable true to charge, false to stop charging
 * @return 0 on success, negative errno on failure
 */
int pmic_charger_set(bool enable);

/**
 * @brief Check whether the charger reports charge-complete
 * @return true if the NPM1300 reports the COMPLETE status bit
 */
bool pmic_is_charge_complete(void);

/**
 * @brief Enter ship mode (power off)
 * @return 0 on success, negative errno on failure
 */
int pmic_enter_ship_mode(void);

#endif /* PMIC_H */
