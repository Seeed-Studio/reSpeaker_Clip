/*
 * Copyright (c) 2023 Nordic Semiconductor ASA
 *
 * SPDX-License-Identifier: LicenseRef-Nordic-5-Clause
 */

#ifndef WIFI_H__
#define WIFI_H__

#include <zephyr/kernel.h>

/**
 * @brief Initialize WiFi AP mode
 *
 * Generates SSID from chip ID and registers event callbacks.
 * Use 'wifi on' shell command to actually start the AP.
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
 * @brief Run WiFi initialization
 * This function initializes WiFi AP mode.
 *
 * @return 0 on success, negative errno on failure
 */
int wifi_run_test(void);

/**
 * @brief Enable the continuous UDP broadcast TX discharge load
 *
 * The TX thread is auto-started and waits for the AP to come up, then streams
 * UDP broadcast packets continuously (the discharge load). This call is a
 * no-op marker.
 *
 * @return 0
 */
int wifi_discharge_start(void);

/**
 * @brief Enable or disable the WiFi discharge load (and the AP)
 *
 * When enabled, the AP is brought up and the TX thread streams broadcast UDP
 * (the discharge load). When disabled, the TX thread idles and the AP is
 * brought down for minimum power (used during the charge phase).
 *
 * @param enable true to load (discharge), false to idle + AP down (charge)
 * @return 0
 */
int wifi_discharge_load_enable(bool enable);

bool wifi_ap_is_running(void);

#endif /* WIFI_H__ */
