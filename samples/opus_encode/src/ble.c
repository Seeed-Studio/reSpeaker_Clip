/*
 * Copyright (c) 2024 Seeed Technology Co., Ltd.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>
#include <zephyr/bluetooth/bluetooth.h>
#include <zephyr/bluetooth/hci.h>
#include <zephyr/bluetooth/conn.h>
#include <zephyr/bluetooth/uuid.h>
#include <zephyr/bluetooth/gatt.h>
#include "ble.h"

LOG_MODULE_REGISTER(ble_audio, LOG_LEVEL_INF);

#define DEVICE_NAME CONFIG_BT_DEVICE_NAME
#define DEVICE_NAME_LEN (sizeof(DEVICE_NAME) - 1)

#define MTU_SIZE 247
#define NOTIFY_DATA_SIZE (MTU_SIZE - 3)  /* Account for opcode and handle */

/* GATT service declaration */
static const struct bt_uuid_128 svc_uuid = BT_UUID_INIT_128(
	BT_UUID_128_ENCODE(0x1234, 0x5678, 0x1234, 0x5678, 0x123456789abc));

static const struct bt_uuid_128 data_uuid = BT_UUID_INIT_128(
	BT_UUID_128_ENCODE(0x1234, 0x5678, 0x1234, 0x5678, 0x123456789abd));

/* Connection and notify state */
static struct bt_conn *current_conn;
static volatile bool notify_enabled;
static volatile bool mtu_exchanged;

/* Async send - single frame buffer (send latest, drop old) */
static struct {
	uint8_t data[NOTIFY_DATA_SIZE];
	uint16_t len;
	volatile bool pending;
} send_buffer;

/* Statistics */
static uint64_t total_bytes_sent;
static uint32_t frames_sent;
static uint32_t frames_dropped;

/* Send time statistics */
static int64_t send_time_total;
static int64_t send_time_min;
static int64_t send_time_max;

/* Work queue for async operations */
static struct k_work adv_work;
static struct k_work_delayable mtu_work;
static struct k_work_delayable send_work;

/* Advertising data */
static const struct bt_data ad[] = {
	BT_DATA_BYTES(BT_DATA_FLAGS, (BT_LE_AD_GENERAL | BT_LE_AD_NO_BREDR)),
	BT_DATA(BT_DATA_NAME_COMPLETE, DEVICE_NAME, DEVICE_NAME_LEN),
};

static const struct bt_data sd[] = {
	BT_DATA_BYTES(BT_DATA_UUID128_ALL,
		      0xBC, 0x9A, 0x78, 0x56, 0x34, 0x12, 0x78, 0x56,
		      0x34, 0x12, 0x78, 0x56, 0x34, 0x12, 0xAB, 0xCD),
};

/* Forward declarations */
static void notify_ccc_cfg_changed(const struct bt_gatt_attr *attr, uint16_t value);
static ssize_t read_data(struct bt_conn *conn, const struct bt_gatt_attr *attr,
			 void *buf, uint16_t len, uint16_t offset);

/* GATT attributes */
BT_GATT_SERVICE_DEFINE(opus_svc,
	BT_GATT_PRIMARY_SERVICE(&svc_uuid),
	BT_GATT_CHARACTERISTIC(&data_uuid.uuid,
			       BT_GATT_CHRC_READ | BT_GATT_CHRC_NOTIFY,
			       BT_GATT_PERM_READ,
			       read_data, NULL, NULL),
	BT_GATT_CCC(notify_ccc_cfg_changed,
		    BT_GATT_PERM_READ | BT_GATT_PERM_WRITE),
);

/* CCC callback - triggered when client enables/disables notify */
static void notify_ccc_cfg_changed(const struct bt_gatt_attr *attr, uint16_t value)
{
	bool notify = (value == BT_GATT_CCC_NOTIFY);

	if (notify != notify_enabled) {
		if (notify) {
			notify_enabled = true;
			ble_reset_stats();
			LOG_INF("BLE audio streaming started");
		} else {
			notify_enabled = false;
			float loss_rate = ble_get_packet_loss_rate();
			LOG_INF("BLE audio streaming stopped");
			LOG_INF("Stats: %u frames, %llu bytes, %u dropped, loss_rate=%.2f%%",
				frames_sent, total_bytes_sent, frames_dropped, loss_rate);
		}
	}
}

/* Read callback */
static ssize_t read_data(struct bt_conn *conn, const struct bt_gatt_attr *attr,
			 void *buf, uint16_t len, uint16_t offset)
{
	static const uint8_t dummy_data[1] = {0};
	return bt_gatt_attr_read(conn, attr, buf, len, offset,
				 dummy_data, sizeof(dummy_data));
}

/* Advertising restart work handler */
static void adv_work_handler(struct k_work *work)
{
	bt_le_adv_start(BT_LE_ADV_CONN_FAST_1, ad, ARRAY_SIZE(ad),
			sd, ARRAY_SIZE(sd));
}

/* MTU exchange callback */
static void mtu_exchange_cb(struct bt_conn *conn, uint8_t err,
			     struct bt_gatt_exchange_params *params)
{
	if (!err) {
		mtu_exchanged = true;
		LOG_INF("MTU exchanged, ready for audio streaming");
	}
}

static struct bt_gatt_exchange_params mtu_params = {
	.func = mtu_exchange_cb,
};

/* Delayed MTU exchange handler */
static void mtu_work_handler(struct k_work *work)
{
	if (current_conn) {
		bt_gatt_exchange_mtu(current_conn, &mtu_params);
	}
}

/* Async BLE send work handler */
static void send_work_handler(struct k_work *work)
{
	if (!ble_is_ready() || !send_buffer.pending) {
		return;
	}

	/* Measure send time */
	int64_t start_time = k_uptime_get();

	/* Send the pending frame */
	int err = bt_gatt_notify(current_conn, &opus_svc.attrs[2],
			         send_buffer.data, send_buffer.len);

	/* Calculate elapsed time */
	int64_t elapsed = k_uptime_get() - start_time;

	if (err == 0) {
		total_bytes_sent += send_buffer.len;
		frames_sent++;

		/* Update send time statistics */
		send_time_total += elapsed;
		if (elapsed < send_time_min) {
			send_time_min = elapsed;
		}
		if (elapsed > send_time_max) {
			send_time_max = elapsed;
		}
	} else {
		frames_dropped++;
	}

	/* Clear pending flag */
	send_buffer.pending = false;
}

/* Connection callbacks */
static void connected(struct bt_conn *conn, uint8_t err)
{
	if (err) {
		return;
	}

	current_conn = bt_conn_ref(conn);
	mtu_exchanged = false;
	notify_enabled = false;

	LOG_INF("BLE connected");

	/* Delay MTU exchange by 500ms to ensure ATT channel is ready */
	k_work_schedule(&mtu_work, K_MSEC(500));
}

static void disconnected(struct bt_conn *conn, uint8_t reason)
{
	if (current_conn == conn) {
		bt_conn_unref(current_conn);
		current_conn = NULL;
		notify_enabled = false;

		LOG_INF("BLE disconnected (reason: %u)", reason);

		/* Restart advertising */
		k_work_submit(&adv_work);
	}
}

static void le_param_updated(struct bt_conn *conn, uint16_t interval,
			     uint16_t latency, uint16_t timeout)
{
	/* Connection parameters updated - safe to do MTU exchange now */
	if (!mtu_exchanged && current_conn == conn) {
		bt_gatt_exchange_mtu(conn, &mtu_params);
	}
}

static struct bt_conn_cb conn_callbacks = {
	.connected = connected,
	.disconnected = disconnected,
	.le_param_updated = le_param_updated,
};

int ble_init(void)
{
	int err;

	/* Initialize send buffer */
	send_buffer.pending = false;

	/* Initialize work queue for deferred operations */
	k_work_init(&adv_work, adv_work_handler);
	k_work_init_delayable(&mtu_work, mtu_work_handler);
	k_work_init_delayable(&send_work, send_work_handler);

	/* Enable Bluetooth */
	err = bt_enable(NULL);
	if (err) {
		LOG_ERR("Bluetooth init failed: %d", err);
		return err;
	}

	LOG_INF("Bluetooth initialized");

	/* Register connection callbacks */
	bt_conn_cb_register(&conn_callbacks);

	/* Start advertising */
	err = bt_le_adv_start(BT_LE_ADV_CONN_FAST_1, ad, ARRAY_SIZE(ad),
			      sd, ARRAY_SIZE(sd));
	if (err) {
		LOG_ERR("Advertising start failed: %d", err);
		return err;
	}

	LOG_INF("Advertising started as '%s'", DEVICE_NAME);

	/* Initialize statistics */
	send_time_total = 0;
	send_time_min = INT64_MAX;
	send_time_max = 0;

	/* Start send work handler - will wait for data */
	k_work_schedule(&send_work, K_FOREVER);

	return 0;
}

int ble_send_opus_frame(const uint8_t *data, uint16_t len)
{
	if (!ble_is_ready()) {
		return -ENOTCONN;
	}

	if (len > NOTIFY_DATA_SIZE) {
		len = NOTIFY_DATA_SIZE;
	}

	/* Copy data to send buffer (non-blocking) */
	memcpy(send_buffer.data, data, len);
	send_buffer.len = len;
	send_buffer.pending = true;

	/* Trigger async send - returns immediately */
	k_work_submit(&send_work.work);

	return 0;
}

bool ble_is_ready(void)
{
	return (current_conn != NULL && notify_enabled && mtu_exchanged);
}

void ble_get_stats(uint32_t *frames, uint64_t *bytes, uint32_t *drops,
		    int64_t *time_total, int64_t *time_min, int64_t *time_max)
{
	if (frames) {
		*frames = frames_sent;
	}
	if (bytes) {
		*bytes = total_bytes_sent;
	}
	if (drops) {
		*drops = frames_dropped;
	}
	if (time_total) {
		*time_total = send_time_total;
	}
	if (time_min) {
		*time_min = (send_time_min == INT64_MAX) ? 0 : send_time_min;
	}
	if (time_max) {
		*time_max = send_time_max;
	}
}

/**
 * @brief Calculate BLE packet loss rate
 *
 * Packet loss rate = dropped_frames / (sent_frames + dropped_frames) * 100
 *
 * @return Packet loss rate in percentage (0.0 - 100.0), or -1 if no frames processed
 */
float ble_get_packet_loss_rate(void)
{
	uint32_t total_frames = frames_sent + frames_dropped;

	if (total_frames == 0) {
		return -1.0f;  /* No data */
	}

	return ((float)frames_dropped / (float)total_frames) * 100.0f;
}

/**
 * @brief Reset BLE statistics counters
 *
 * Call this to start a new statistics session.
 */
void ble_reset_stats(void)
{
	total_bytes_sent = 0;
	frames_sent = 0;
	frames_dropped = 0;
	send_time_total = 0;
	send_time_min = INT64_MAX;
	send_time_max = 0;
}
