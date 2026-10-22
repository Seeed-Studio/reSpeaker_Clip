/*
 * Copyright (c) 2025 Seeed Technology Co., Ltd.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#ifndef CLIP_WIFI_H
#define CLIP_WIFI_H

#include <stdbool.h>
#include <zephyr/kernel.h>   /* k_timeout_t for wifi_wait_ops_done */

/**
 * @brief WiFi AP configuration
 */
#define WIFI_AP_SSID_PREFIX "ClipAP_"
#define WIFI_AP_PASSWORD "12345678"
#define WIFI_AP_CHANNEL 36          /* 5GHz channel */
#define WIFI_AP_MAX_CLIENTS 1
#define WIFI_AP_REG_DOMAIN "US"

/**
 * @brief UDP file transfer server configuration
 */
#define WIFI_AP_UDP_PORT 8089

/**
 * @brief Initialize WiFi module
 *
 * Initializes the WiFi subsystem and generates AP SSID.
 * Must be called before any other WiFi functions.
 *
 * @return 0 on success, negative error code on failure
 */
int wifi_init(void);

/**
 * @brief Queue an AP on/off request on the WiFi worker thread
 *
 * The actual bring-up/teardown blocks for seconds (nRF70 RPU boot,
 * AP-enable round trips and retries) and must never run on the event
 * dispatcher — the worker exists so buttons/UI stay responsive during
 * it. Callers that need the old synchronous timing (AT+WIFI) follow up
 * with wifi_wait_ops_done().
 *
 * @param on true to start the AP, false to stop it
 *
 * @return 0 once queued, negative error code if the request queue is full
 */
int wifi_request_async(bool on);

/**
 * @brief Block until every queued WiFi operation has finished
 *
 * Worst-case bring-up is ~3 s ready wait + 3 x 5 s AP-enable retries —
 * pass a timeout >= 25 s for "on" requests.
 *
 * @param timeout maximum wait
 *
 * @return 0 if the last operation succeeded
 * @return negative error code from the operation, or -EAGAIN on timeout
 */
int wifi_wait_ops_done(k_timeout_t timeout);

/**
 * @brief Check whether an AP bring-up is queued or in flight
 *
 * Lets the event dispatcher distinguish a stale failure-revert WIFI_OFF
 * (a newer ON supersedes it) and see through the ap_running window while
 * an ON is still mid-flight.
 *
 * @return true if at least one ON request has not executed yet
 */
bool wifi_on_pending(void);

/**
 * @brief Check if WiFi interface is up
 *
 * @return true if interface is up (radio powered on), false otherwise
 */
bool wifi_is_interface_up(void);

/**
 * @brief Check if WiFi AP is running
 *
 * @return true if AP is running, false otherwise
 */
bool wifi_ap_is_running(void);

/**
 * @brief Get AP SSID
 *
 * @return Pointer to SSID string (static buffer)
 */
const char *wifi_get_ssid(void);

/**
 * @brief Get AP password
 *
 * @return Pointer to password string
 */
const char *wifi_get_password(void);

/**
 * @brief Get AP IP address
 *
 * @return Pointer to IP address string
 */
const char *wifi_get_ip_address(void);

/**
 * @brief Check if a station is connected to the AP
 *
 * @return true if a station is connected, false otherwise
 */
bool wifi_is_sta_connected(void);

#endif /* CLIP_WIFI_H */
