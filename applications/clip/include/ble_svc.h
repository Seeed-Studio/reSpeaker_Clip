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

/* Characteristic UUID: Audio Visualization (Notify) */
/* UUID: 6E400005-B5A3-F393-E0A9-E50E24DCCA9E */
#define BT_UUID_CLIP_AUDIO_VIS \
    BT_UUID_DECLARE_128(BT_UUID_128_ENCODE(0x6E400005, 0xB5A3, 0xF393, 0xE0A9, 0xE50E24DCCA9E))

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
 * @brief Check if at least one bonded peer exists in flash
 *
 * @return true if a bond record exists, false otherwise
 */
bool ble_svc_is_bonded(void);

/**
 * @brief Schedule a device reboot after a delay
 *
 * Used by AT+PAIR=reset to reboot after sending the response.
 *
 * @param delay_ms Delay in milliseconds before reboot
 */
void ble_svc_schedule_reboot(uint32_t delay_ms);

/**
 * @brief Get current BLE connection
 *
 * @return Connection pointer or NULL if not connected
 */
struct bt_conn *ble_svc_get_connection(void);

/**
 * @brief Get BLE device name
 *
 * @return Device name string (e.g., "Clip XXXX")
 */
const char *ble_svc_get_device_name(void);

/**
 * @brief Send audio visualization data via BLE
 *
 * Sends audio energy level for real-time audio visualization.
 *
 * @param data Data buffer (typically 1 byte with energy level 0-10)
 * @param len Length of data
 * @return 0 on success, negative error code on failure
 */
int ble_svc_send_audio_vis(const uint8_t *data, uint16_t len);

/**
 * @brief Zero-copy response buffer for AT commands
 *
 * Provides a pre-allocated buffer for building JSON responses
 * without additional memory allocation.
 *
 * @return Pointer to buffer (size: BLE_RESPONSE_BUFFER_SIZE)
 */
char *ble_svc_get_response_buffer(void);

/**
 * @brief Get size of zero-copy response buffer
 *
 * @return Buffer size in bytes
 */
size_t ble_svc_get_response_buffer_size(void);

/**
 * @brief Send response from zero-copy buffer
 *
 * Sends data from the buffer returned by ble_svc_get_response_buffer().
 * No memory allocation or copying required.
 *
 * @param len Length of data to send
 * @return 0 on success, negative error code on failure
 */
int ble_svc_send_response_buffer(size_t len);

/* Zero-copy response buffer size - 1KB sufficient for paginated responses */
#define BLE_RESPONSE_BUFFER_SIZE 1024

#endif /* BLE_SVC_H */
