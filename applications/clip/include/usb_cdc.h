/*
 * Copyright (c) 2025 Seeed Technology Co., Ltd.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#ifndef CLIP_USB_CDC_H
#define CLIP_USB_CDC_H

#include <zephyr/usb/usbd.h>

/**
 * @brief Initialize USB CDC ACM (virtual serial port for AT commands)
 *
 * Initializes the USB device with CDC ACM + MSC classes.
 * USB starts disabled; use usb_cdc_enable() to activate.
 *
 * @return 0 on success, negative error code on failure
 */
int usb_cdc_init(void);

/**
 * @brief Enable USB (CDC + MSC)
 *
 * Call after BLE AT+USB=on. Makes device visible to USB host.
 *
 * @return 0 on success, negative error code on failure
 */
int usb_cdc_enable(void);

/**
 * @brief Disable USB (CDC + MSC)
 *
 * Call after BLE AT+USB=off. Device disappears from USB host.
 *
 * @return 0 on success, negative error code on failure
 */
int usb_cdc_disable(void);

/**
 * @brief Check if USB is enabled
 *
 * @return true if USB is enabled and active
 */
bool usb_cdc_is_enabled(void);

/**
 * @brief Get shared USB device context (used by MSC module)
 *
 * @return Pointer to usbd_context
 */
struct usbd_context *usb_cdc_get_usbd(void);

/**
 * @brief Send response data to USB CDC host
 *
 * @param data Response data
 * @param len Data length
 * @return Bytes sent, or negative error code
 */
int usb_cdc_send_response(const uint8_t *data, uint16_t len);

/**
 * @brief Check if USB CDC host is connected (DTR set)
 *
 * @return true if connected
 */
bool usb_cdc_is_connected(void);

#endif /* CLIP_USB_CDC_H */
