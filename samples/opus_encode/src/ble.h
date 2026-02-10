/*
 * Copyright (c) 2024 Seeed Technology Co., Ltd.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#ifndef BLE_H
#define BLE_H

/* Custom 128-bit UUID for Opus audio streaming service */
#define BT_UUID_OPUS_STREAM \
	BT_UUID_DECLARE_128(BT_UUID_128_ENCODE(0x1234, 0x5678, 0x1234, 0x5678, 0x123456789abc))

/* Characteristic UUIDs */
#define BT_UUID_OPUS_DATA \
	BT_UUID_DECLARE_128(BT_UUID_128_ENCODE(0x1234, 0x5678, 0x1234, 0x5678, 0x123456789abd))

/**
 * @brief Initialize Bluetooth for Opus audio streaming
 *
 * @return 0 on success, negative error code on failure
 */
int ble_init(void);

/**
 * @brief Send Opus frame via BLE notification
 *
 * @param data Opus encoded data
 * @param len Length of data (max MTU-3 bytes)
 * @return 0 on success, negative error code on failure
 */
int ble_send_opus_frame(const uint8_t *data, uint16_t len);

/**
 * @brief Check if BLE client is connected and notifications enabled
 *
 * @return true if ready to send, false otherwise
 */
bool ble_is_ready(void);

/**
 * @brief Get BLE audio statistics
 *
 * @param frames Total frames sent
 * @param bytes Total bytes sent
 * @param drops Dropped frames (buffer full)
 * @param time_total Total send time (ms)
 * @param time_min Minimum send time per frame (ms)
 * @param time_max Maximum send time per frame (ms)
 */
void ble_get_stats(uint32_t *frames, uint64_t *bytes, uint32_t *drops,
		    int64_t *time_total, int64_t *time_min, int64_t *time_max);

/**
 * @brief Calculate BLE packet loss rate
 *
 * Packet loss rate = dropped_frames / (sent_frames + dropped_frames) * 100
 *
 * @return Packet loss rate in percentage (0.0 - 100.0), or -1.0 if no frames processed
 */
float ble_get_packet_loss_rate(void);

/**
 * @brief Reset BLE statistics counters
 *
 * Call this to start a new statistics session.
 */
void ble_reset_stats(void);

#endif /* BLE_H */
