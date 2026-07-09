/*
 * Copyright (c) 2025 Seeed Technology Co., Ltd.
 *
 * SPDX-License-Identifier: Apache-2.0
 *
 * BLE/WiFi throughput test (temporary, CONFIG_CLIP_THROUGHPUT_TEST).
 * Starts a test from an AT command; the measured rate is reported through a
 * BLE event ("blethru" / "wifithru").
 */

#ifndef CLIP_THROUGHPUT_TEST_H_
#define CLIP_THROUGHPUT_TEST_H_

#ifdef CONFIG_CLIP_THROUGHPUT_TEST

/**
 * @brief Start a BLE notify throughput test.
 *
 * The client must be subscribed to the throughput characteristic. The result
 * is reported asynchronously via ble_notify_event("blethru", ...).
 *
 * @param dur_sec Duration in seconds (0 = default 10s)
 * @return 0 on success, -EBUSY if a test is already running
 */
int throughput_ble_start(uint32_t dur_sec);

/**
 * @brief Start a WiFi UDP TX throughput test.
 *
 * Requires WiFi AP up + a station connected. The result is reported
 * asynchronously via ble_notify_event("wifithru", ...).
 *
 * @param ip Host receiver IP
 * @param port UDP port (0 = default 5001)
 * @param dur_sec Duration in seconds (0 = default 10s)
 * @return 0 on success, -EBUSY if a test is already running
 */
int throughput_wifi_start(const char *ip, uint16_t port, uint32_t dur_sec);

#endif /* CONFIG_CLIP_THROUGHPUT_TEST */

#endif /* CLIP_THROUGHPUT_TEST_H_ */
