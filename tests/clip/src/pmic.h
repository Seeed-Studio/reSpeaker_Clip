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

#endif /* PMIC_H */
