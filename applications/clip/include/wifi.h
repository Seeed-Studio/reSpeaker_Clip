/*
 * Copyright (c) 2025 Seeed Technology Co., Ltd.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#ifndef CLIP_WIFI_H
#define CLIP_WIFI_H

#include <stdbool.h>

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
 * @brief Power on WiFi interface and start AP
 *
 * Brings up the WiFi network interface and starts AP mode.
 *
 * @return 0 on success, negative error code on failure
 */
int wifi_on(void);

/**
 * @brief Power off WiFi interface
 *
 * Stops AP mode and powers off the radio.
 *
 * @return 0 on success, negative error code on failure
 */
int wifi_off(void);

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
