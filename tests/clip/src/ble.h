/*
 * Copyright (c) 2023 Nordic Semiconductor ASA
 *
 * SPDX-License-Identifier: LicenseRef-Nordic-5-Clause
 */

#ifndef BLE_H
#define BLE_H

/* Custom 128-bit UUID for throughput test service */
#define BT_UUID_THROUGHPUT_TEST \
	BT_UUID_DECLARE_128(BT_UUID_128_ENCODE(0x1234, 0x5678, 0x1234, 0x5678, 0x123456789abc))

/* Characteristic UUIDs */
#define BT_UUID_THROUGHPUT_DATA \
	BT_UUID_DECLARE_128(BT_UUID_128_ENCODE(0x1234, 0x5678, 0x1234, 0x5678, 0x123456789abd))

int ble_init(void);

#endif /* BLE_H */
