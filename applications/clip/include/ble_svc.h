/*
 * Copyright (c) 2024 Seeed Technology Co., Ltd.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#ifndef BLE_SVC_H
#define BLE_SVC_H

#include <zephyr/bluetooth/bluetooth.h>
#include <zephyr/bluetooth/conn.h>

/* Service UUID: 6E400001-B5A3-F393-E0A9-E50E24DCCA9E */
#define BT_UUID_CLIP_SVC \
    BT_UUID_DECLARE_128(BT_UUID_128_ENCODE(0x6E400001, 0xB5A3, 0xF393, 0xE0A9, 0xE50E24DCCA9E))

/* Characteristic UUID: Command Receive (Write) */
/* UUID: 6E400002-B5A3-F393-E0A9-E50E24DCCA9E */
#define BT_UUID_CLIP_CMD_RECV \
    BT_UUID_DECLARE_128(BT_UUID_128_ENCODE(0x6E400002, 0xB5A3, 0xF393, 0xE0A9, 0xE50E24DCCA9E))

/* Characteristic UUID: Response Send (Notify) */
/* UUID: 6E400003-B5A3-F393-E0A9-E50E24DCCA9E */
#define BT_UUID_CLIP_RESP_SEND \
    BT_UUID_DECLARE_128(BT_UUID_128_ENCODE(0x6E400003, 0xB5A3, 0xF393, 0xE0A9, 0xE50E24DCCA9E))

/* Characteristic UUID: File Data (Notify) */
/* UUID: 6E400004-B5A3-F393-E0A9-E50E24DCCA9E */
#define BT_UUID_CLIP_FILE_DATA \
    BT_UUID_DECLARE_128(BT_UUID_128_ENCODE(0x6E400004, 0xB5A3, 0xF393, 0xE0A9, 0xE50E24DCCA9E))

/**
 * @brief Initialize BLE service for AT commands
 *
 * @return 0 on success, negative error code on failure
 */
int ble_svc_init(void);

/**
 * @brief Send JSON response via BLE
 *
 * @param json JSON string to send
 * @return 0 on success, negative error code on failure
 */
int ble_svc_send_response(const char *json);

/**
 * @brief Send file data via BLE
 *
 * @param data Binary data to send
 * @param len Length of data
 * @return 0 on success, negative error code on failure
 */
int ble_svc_send_file_data(const uint8_t *data, uint16_t len);

/**
 * @brief Send file ready event (when file recording completes and ready for transfer)
 *
 * @param session_id Session ID
 * @param filename Name of the file that is ready
 * @param size File size in bytes
 * @return 0 on success, negative error code on failure
 */
int ble_svc_send_file_ready(const char *session_id, const char *filename, uint64_t size);

/**
 * @brief Send file transfer complete event
 *
 * @param filename Name of the file that completed transfer
 * @return 0 on success, negative error code on failure
 */
int ble_svc_send_file_complete(const char *filename);

/**
 * @brief Send session transfer complete event (all files in session transferred)
 *
 * @param session_id Session ID that completed
 * @param files_count Number of files transferred
 * @return 0 on success, negative error code on failure
 */
int ble_svc_send_transfer_complete(const char *session_id, int files_count);

/**
 * @brief Check if BLE is connected and ready
 *
 * @return true if ready, false otherwise
 */
bool ble_svc_is_ready(void);

/**
 * @brief Get current BLE connection
 *
 * @return Connection pointer or NULL if not connected
 */
struct bt_conn *ble_svc_get_connection(void);

#endif /* BLE_SVC_H */
