/*
 * Copyright (c) 2025 Seeed Technology Co., Ltd.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#ifndef CLIP_TRANSPORT_BLE_H
#define CLIP_TRANSPORT_BLE_H

#include <zephyr/kernel.h>
#include <stdint.h>
#include "transport.h"

/**
 * @brief Initialize BLE transport
 *
 * @return 0 on success, negative error code on failure
 */
int transport_ble_init(void);

/**
 * @brief Register BLE command callback
 *
 * When data is received from BLE, this callback will be invoked.
 *
 * @param callback Callback function
 * @return 0 on success, negative error code on failure
 */
int transport_ble_register_callback(transport_event_cb_t callback);

/**
 * @brief Update BLE connection status
 *
 * Called by BLE module when connection state changes.
 *
 * @param conn Connection pointer (NULL if disconnected)
 * @param ready True if ready for data transfer
 */
void transport_ble_update_connection(void *conn, bool ready);

/**
 * @brief Send data via BLE transport
 *
 * @param data Data to send
 * @param len Data length
 * @return Bytes sent on success, negative error code on failure
 */
int transport_ble_send(const uint8_t *data, uint16_t len);

/**
 * @brief Check if BLE transport is connected
 *
 * @return true if connected, false otherwise
 */
bool transport_ble_is_connected(void);

/**
 * @brief Get BLE connection pointer
 *
 * @return Connection pointer or NULL if not connected
 */
void *transport_ble_get_conn(void);

/**
 * @brief Get BLE transport structure
 *
 * @return Pointer to BLE transport structure
 */
struct transport *transport_ble_get(void);

/**
 * @brief Send an RTC STREAM_START frame (0x13) and reset the stream seq
 *
 * @param session_id Session ID being streamed
 * @return 0 on success, negative error code on failure
 */
int transport_ble_send_stream_start(const char *session_id);

/**
 * @brief Send one encoded Opus frame as an RTC STREAM_DATA frame (0x14)
 *
 * The frame must fit in a single BLE notification; oversized frames are
 * rejected with -EMSGSIZE. Sequence advances only on success.
 *
 * @param data Encoded frame payload
 * @param len Payload length
 * @return 0 on success, negative error code on failure
 */
int transport_ble_send_stream_data(const uint8_t *data, uint16_t len);

/**
 * @brief Send an RTC STREAM_END frame (0x15)
 *
 * @param reason RTC_END_REASON_* code
 * @return 0 on success, negative error code on failure
 */
int transport_ble_send_stream_end(uint8_t reason);

#endif /* CLIP_TRANSPORT_BLE_H */
