/*
 * Copyright (c) 2025 Seeed Technology Co., Ltd.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#ifndef CLIP_BLE_H
#define CLIP_BLE_H

#include <zephyr/bluetooth/bluetooth.h>
#include <zephyr/bluetooth/conn.h>
#include <zephyr/bluetooth/gatt.h>
#include <zephyr/bluetooth/uuid.h>

/* Service UUID: 6E400001-B5A3-F393-E0A9-E50E24DCCA9E */
#define BT_UUID_CLIP_SVC \
    BT_UUID_DECLARE_128(BT_UUID_128_ENCODE(0x6E400001, 0xB5A3, 0xF393, 0xE0A9, 0xE50E24DCCA9E))

/* Characteristic UUID: Command Receive (Write) */
#define BT_UUID_CLIP_CMD_RECV \
    BT_UUID_DECLARE_128(BT_UUID_128_ENCODE(0x6E400002, 0xB5A3, 0xF393, 0xE0A9, 0xE50E24DCCA9E))

/* Characteristic UUID: Response Send (Notify) */
#define BT_UUID_CLIP_RESP_SEND \
    BT_UUID_DECLARE_128(BT_UUID_128_ENCODE(0x6E400003, 0xB5A3, 0xF393, 0xE0A9, 0xE50E24DCCA9E))

/* Characteristic UUID: File Data (Notify) */
#define BT_UUID_CLIP_FILE_DATA \
    BT_UUID_DECLARE_128(BT_UUID_128_ENCODE(0x6E400004, 0xB5A3, 0xF393, 0xE0A9, 0xE50E24DCCA9E))

/* Characteristic UUID: Audio Visualization (Notify) */
#define BT_UUID_CLIP_AUDIO_VIS \
    BT_UUID_DECLARE_128(BT_UUID_128_ENCODE(0x6E400005, 0xB5A3, 0xF393, 0xE0A9, 0xE50E24DCCA9E))

/**
 * @brief BLE context structure
 */
struct ble_context {
    struct bt_conn *conn;
    bool notify_enabled;
    bool file_data_notify_enabled;
    bool audio_vis_notify_enabled;
    char device_name[16];
#ifdef CONFIG_CLIP_THROUGHPUT_TEST
    bool throughput_notify_enabled;
#endif
};

/**
 * @brief Command received callback type
 *
 * @param data Command data
 * @param len Length of data
 * @return 0 on success, negative error code on failure
 */
typedef int (*ble_cmd_callback_t)(const uint8_t *data, uint16_t len);

/**
 * @brief Initialize BLE service
 *
 * @return 0 on success, negative error code on failure
 */
int ble_init(void);

/**
 * @brief Register command callback
 *
 * @param callback Callback function for received commands
 * @return 0 on success, negative error code on failure
 */
int ble_register_cmd_callback(ble_cmd_callback_t callback);

/**
 * @brief Send data via BLE notification (for AT command responses)
 *
 * @param data Data to send
 * @param len Length of data
 * @return 0 on success, negative error code on failure
 */
int ble_send(const uint8_t *data, uint16_t len);

/**
 * @brief Send file data via BLE notification (uses FILE_DATA characteristic)
 *
 * @param data Data to send
 * @param len Length of data
 * @return 0 on success, negative error code on failure
 */
int ble_send_file_data(const uint8_t *data, uint16_t len);

/**
 * @brief Check if BLE is connected
 *
 * @return true if connected, false otherwise
 */
bool ble_is_connected(void);

/**
 * @brief Check if BLE notify is enabled
 *
 * @return true if notify enabled, false otherwise
 */
bool ble_is_notify_enabled(void);

/**
 * @brief Check if file data notify is enabled
 *
 * @return true if file data notify enabled, false otherwise
 */
bool ble_is_file_data_notify_enabled(void);

/**
 * @brief Check if BLE has any bonded devices
 *
 * @return true if at least one bond exists, false otherwise
 */
bool ble_is_bonded(void);

/**
 * @brief Check if audio visualization notifications are subscribed
 *
 * @return true if a BLE client has subscribed to audio_vis characteristic
 */
bool ble_is_audio_vis_subscribed(void);

#ifdef CONFIG_CLIP_THROUGHPUT_TEST
/**
 * @brief Check if the throughput characteristic is subscribed
 */
bool ble_is_throughput_subscribed(void);

/**
 * @brief Run a BLE notify throughput test for @a dur_sec seconds.
 *
 * Streams max-size notifications on the throughput characteristic (the client
 * must have subscribed first) and returns the measured TX rate. Blocks for
 * the duration; call from a non-BLE thread.
 *
 * @param dur_sec Duration in seconds
 * @param out_kbps Output: measured throughput in kbit/s
 * @return 0 on success, negative errno on failure
 */
int ble_run_throughput(uint32_t dur_sec, uint32_t *out_kbps);

/**
 * @brief Send a result string on the throughput characteristic (6E400006).
 *
 * Only delivers if a client is subscribed to it. Used to push the throughput
 * test result on the same characteristic the client streamed on.
 *
 * @param data Result string (e.g. JSON)
 * @param len Length of data
 * @return 0 on success, negative errno on failure
 */
int ble_send_throughput(const char *data, uint16_t len);
#endif

/**
 * @brief Get address of first bonded device
 *
 * @param addr_buf Buffer to hold address string (min 18 bytes)
 * @param len Buffer length
 * @return 0 on success, -ENOENT if no bonds, -EINVAL if buffer too small
 */
int ble_get_bond_addr(char *addr_buf, size_t len);

/**
 * @brief Clear all BLE bonds
 *
 * @return 0 on success, negative error code on failure
 */
int ble_clear_bonds(void);

/**
 * @brief Rotate the BLE identity address (AT+PAIR=reset)
 *
 * Creates a second local identity (id 1) with a new random address on the
 * first call, or resets id 1 to a new address on later calls. Used so a peer
 * that caches a stale bond (iOS) sees a new device and re-pairs fresh.
 *
 * @return 0 on success, negative error code on failure
 */
int ble_rotate_identity(void);

/**
 * @brief Get BLE connection
 *
 * @return Connection pointer or NULL if not connected
 */
struct bt_conn *ble_get_connection(void);

/**
 * @brief Get negotiated ATT MTU
 *
 * @param conn Connection pointer
 * @return MTU value, or 23 (default) if not connected
 */
uint16_t ble_get_mtu(struct bt_conn *conn);

/**
 * @brief Get device name
 *
 * @return Device name string
 */
const char *ble_get_device_name(void);

/**
 * @brief Restart BLE advertising with fast interval
 *
 * Called on button press to make device quickly discoverable.
 * No-op if already connected.
 */
void ble_adv_restart_fast(void);

/**
 * @brief Refresh BLE inactivity timeout
 *
 * Resets the 5-minute inactivity disconnect timer.
 * Called on AT command reception.
 */
void ble_activity_refresh(void);

/* Zero-copy response buffer size */
#define BLE_RESPONSE_BUFFER_SIZE 1024

/**
 * @brief Get zero-copy response buffer
 *
 * @return Pointer to buffer
 */
char *ble_get_response_buffer(void);

/**
 * @brief Get response buffer size
 *
 * @return Buffer size in bytes
 */
size_t ble_get_response_buffer_size(void);

/**
 * @brief Send response from buffer
 *
 * @param len Length of data to send
 * @return 0 on success, negative error code on failure
 */
int ble_send_response_buffer(size_t len);

/**
 * @brief Send audio visualization data via BLE notification
 *
 * @param data Audio visualization data to send
 * @param len Length of data
 * @return 0 on success, negative error code on failure
 */
int ble_send_audio_vis(const uint8_t *data, uint16_t len);

/**
 * @brief Notify recording state change via BLE
 *
 * Sends JSON event: {"event":"state","state":"<state>","session":"<id>"[,"duration":N]}
 *
 * @param state State string (RECORDING, IDLE, PAUSED)
 * @param session_id Session ID string
 * @param duration Duration in seconds, or -1 if not applicable
 * @return 0 on success, negative error code on failure
 */
int ble_notify_state_change(const char *state, const char *session_id, int duration);

/**
 * @brief Notify bookmark mark event via BLE
 *
 * Sends JSON event: {"event":"mark","session":"<id>","mark_count":N}
 *
 * @param session_id Session ID string
 * @param mark_count Current bookmark count
 * @return 0 on success, negative error code on failure
 */
int ble_notify_mark(const char *session_id, int mark_count);

/**
 * @brief Notify a generic event via BLE
 *
 * Sends JSON event: {"event":"<name>","status":"<status>"}
 *
 * @param name Event name (e.g. "usb", "wifi", "ble")
 * @param status Status string (e.g. "on", "off", "connected", "disconnected")
 * @return 0 on success, negative error code on failure
 */
int ble_notify_event(const char *name, const char *status);

#endif /* CLIP_BLE_H */
