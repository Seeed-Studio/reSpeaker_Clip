/*
 * Copyright (c) 2023 Nordic Semiconductor ASA
 *
 * SPDX-License-Identifier: LicenseRef-Nordic-5-Clause
 */

#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>
#include <zephyr/bluetooth/bluetooth.h>
#include <zephyr/bluetooth/hci.h>
#include <zephyr/bluetooth/conn.h>
#include <zephyr/bluetooth/uuid.h>
#include <zephyr/bluetooth/gatt.h>
#include "ble.h"

LOG_MODULE_REGISTER(ble, LOG_LEVEL_INF);

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
static K_SEM_DEFINE(conn_sem, 0, 1);
static K_SEM_DEFINE(mtu_sem, 0, 1);

/* Throughput test data */
static uint8_t notify_data[NOTIFY_DATA_SIZE];
static uint64_t test_start_time;
static uint64_t total_bytes_sent;
static uint32_t packet_count;
static uint64_t last_stats_time;
static uint64_t last_stats_bytes;
static struct k_thread notify_thread;
static K_THREAD_STACK_DEFINE(notify_stack, 2048);

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

/* Work queue for deferred operations */
static struct k_work adv_work;

/* Advertising restart work handler */
static void adv_work_handler(struct k_work *work)
{
	bt_le_adv_start(BT_LE_ADV_CONN_FAST_1, ad, ARRAY_SIZE(ad),
			sd, ARRAY_SIZE(sd));
}

/* Forward declarations */
static void notify_ccc_cfg_changed(const struct bt_gatt_attr *attr,
				    uint16_t value);
static ssize_t read_data(struct bt_conn *conn,
			 const struct bt_gatt_attr *attr,
			 void *buf, uint16_t len, uint16_t offset);

/* GATT attributes - using BT_GATT_SERVICE_DEFINE for compile-time registration */
BT_GATT_SERVICE_DEFINE(throughput_svc,
	BT_GATT_PRIMARY_SERVICE(&svc_uuid),
	BT_GATT_CHARACTERISTIC(&data_uuid.uuid,
			       BT_GATT_CHRC_READ | BT_GATT_CHRC_NOTIFY,
			       BT_GATT_PERM_READ,
			       read_data, NULL, NULL),
	BT_GATT_CCC(notify_ccc_cfg_changed,
		    BT_GATT_PERM_READ | BT_GATT_PERM_WRITE),
);

/* CCC callback - triggered when phone enables/disables notify */
static void notify_ccc_cfg_changed(const struct bt_gatt_attr *attr,
				    uint16_t value)
{
	bool notify = (value == BT_GATT_CCC_NOTIFY);

	if (notify != notify_enabled) {
		if (notify) {
			notify_enabled = true;

			/* Wait for MTU exchange to complete before starting */
			if (mtu_exchanged) {
				test_start_time = k_uptime_get();
				total_bytes_sent = 0;
				packet_count = 0;
				last_stats_time = test_start_time;
				last_stats_bytes = 0;
				k_wakeup(&notify_thread);
			}
		} else {
			uint64_t elapsed_ms = k_uptime_get() - test_start_time;
			uint32_t throughput_kbps = 0;

			notify_enabled = false;

			if (elapsed_ms > 0) {
				throughput_kbps = (uint32_t)((total_bytes_sent * 8) / elapsed_ms);
			}

			printk("\n=== BLE Throughput Test Results ===\n");
			printk("Packets sent: %u\n", packet_count);
			printk("Bytes sent: %llu\n", total_bytes_sent);
			printk("Time: %llu ms\n", elapsed_ms);
			printk("Throughput: %u kbps (%u.%03u Mbps)\n",
				throughput_kbps,
				throughput_kbps / 1000,
				throughput_kbps % 1000);
			printk("===================================\n");
		}
	}
}

/* Read callback (not used but required) */
static ssize_t read_data(struct bt_conn *conn,
			 const struct bt_gatt_attr *attr,
			 void *buf, uint16_t len, uint16_t offset)
{
	return bt_gatt_attr_read(conn, attr, buf, len, offset,
				 notify_data, sizeof(notify_data));
}

/* Notify thread - continuously sends data when notify is enabled */
static void notify_thread_func(void *p1, void *p2, void *p3)
{
	ARG_UNUSED(p1);
	ARG_UNUSED(p2);
	ARG_UNUSED(p3);

	while (1) {
		if (notify_enabled && current_conn && mtu_exchanged) {
			int err;
			uint64_t now;

			/* Check before sending */
			if (!notify_enabled) {
				break;
			}

			err = bt_gatt_notify(current_conn, &throughput_svc.attrs[2],
					     notify_data, sizeof(notify_data));
			if (err == 0) {
				total_bytes_sent += sizeof(notify_data);
				packet_count++;
			} else if (err == -ENOMEM || err == -EAGAIN) {
				/* Buffer full, wait and retry */
				k_sleep(K_MSEC(1));
				continue;
			} else if (err == -ENOTCONN) {
				notify_enabled = false;
				continue;
			}

			/* Print stats every second */
			now = k_uptime_get();
			if (now - last_stats_time >= 1000) {
				uint64_t bytes_delta = total_bytes_sent - last_stats_bytes;
				uint32_t rate_kbps = (bytes_delta * 8) / 1000;

				printk("BLE: %u kbps (%u.%03u Mbps), Total: %llu bytes\n",
				       rate_kbps, rate_kbps / 1000, rate_kbps % 1000,
				       total_bytes_sent);

				last_stats_time = now;
				last_stats_bytes = total_bytes_sent;
			}

			/* No delay - send as fast as possible, only wait on buffer full */
		} else {
			k_sleep(K_MSEC(10));
		}
	}
}

/* MTU exchange callback */
static void mtu_exchange_cb(struct bt_conn *conn, uint8_t err,
			     struct bt_gatt_exchange_params *params)
{
	if (!err) {
		mtu_exchanged = true;

		/* If notify was already enabled, start the test now */
		if (notify_enabled) {
			test_start_time = k_uptime_get();
			total_bytes_sent = 0;
			packet_count = 0;
			k_wakeup(&notify_thread);
		}
	}
	k_sem_give(&mtu_sem);
}

static struct bt_gatt_exchange_params mtu_params = {
	.func = mtu_exchange_cb,
};

/* Connection callbacks */
static void connected(struct bt_conn *conn, uint8_t err)
{
	if (err) {
		return;
	}

	current_conn = bt_conn_ref(conn);
	mtu_exchanged = false;

	/* Request MTU exchange */
	bt_gatt_exchange_mtu(conn, &mtu_params);

	k_sem_give(&conn_sem);
}

static void disconnected(struct bt_conn *conn, uint8_t reason)
{
	if (current_conn == conn) {
		bt_conn_unref(current_conn);
		current_conn = NULL;
		notify_enabled = false;
		k_sem_reset(&conn_sem);

		/* Schedule advertising restart via work queue */
		k_work_submit(&adv_work);
	}
}

static void le_param_updated(struct bt_conn *conn, uint16_t interval,
			     uint16_t latency, uint16_t timeout)
{
	/* Connection parameters updated - MTU exchange may complete here */
	mtu_exchanged = true;

	if (notify_enabled && test_start_time == 0) {
		test_start_time = k_uptime_get();
		total_bytes_sent = 0;
		packet_count = 0;
		k_wakeup(&notify_thread);
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

	/* Initialize notification data pattern */
	for (size_t i = 0; i < sizeof(notify_data); i++) {
		notify_data[i] = i & 0xFF;
	}

	/* Initialize work queue for deferred operations */
	k_work_init(&adv_work, adv_work_handler);

	/* Enable Bluetooth */
	err = bt_enable(NULL);
	if (err) {
		return err;
	}

	/* Register connection callbacks */
	bt_conn_cb_register(&conn_callbacks);

	/* Start advertising */
	err = bt_le_adv_start(BT_LE_ADV_CONN_FAST_1, ad, ARRAY_SIZE(ad),
			      sd, ARRAY_SIZE(sd));
	if (err) {
		return err;
	}

	/* Create notify thread with lower priority than main thread */
	k_thread_create(&notify_thread, notify_stack,
			K_THREAD_STACK_SIZEOF(notify_stack),
			notify_thread_func,
			NULL, NULL, NULL,
			K_PRIO_COOP(-1), 0, K_NO_WAIT);

	return 0;
}
