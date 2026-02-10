/*
 * Copyright (c) 2023 Nordic Semiconductor ASA
 *
 * SPDX-License-Identifier: LicenseRef-Nordic-5-Clause
 */

#ifndef WIFI_H__
#define WIFI_H__

#include <zephyr/kernel.h>

/**
 * @brief Initialize WiFi and wait for connection
 *
 * @return 0 on success, negative errno on failure
 */
int wifi_init_and_connect(void);

/**
 * @brief Start WiFi throughput test
 *
 * @return 0 on success, negative errno on failure
 */
int wifi_start_throughput_test(void);

/**
 * @brief Run WiFi initialization and throughput test
 * This function combines init, connect and test in one call.
 *
 * @return 0 on success, negative errno on failure
 */
int wifi_run_test(void);

#endif /* WIFI_H__ */
