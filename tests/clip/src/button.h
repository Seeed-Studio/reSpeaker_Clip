/*
 * Copyright (c) 2023 Nordic Semiconductor ASA
 *
 * SPDX-License-Identifier: LicenseRef-Nordic-5-Clause
 */

#ifndef BUTTON_H_
#define BUTTON_H_

#include <zephyr/kernel.h>

/**
 * @brief Initialize Button module
 *
 * @return 0 on success, negative errno code on failure
 */
int button_init(void);

#endif /* BUTTON_H_ */
