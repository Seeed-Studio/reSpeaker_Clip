/*
 * Copyright (c) 2025 Seeed Technology Co., Ltd.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#include <zephyr/kernel.h>
#include <zephyr/bluetooth/bluetooth.h>
#include <zephyr/bluetooth/hci.h>
#include <zephyr/bluetooth/conn.h>
#include <zephyr/bluetooth/uuid.h>
#include <zephyr/bluetooth/gatt.h>
#include <zephyr/logging/log.h>

#include "battery.h"

LOG_MODULE_REGISTER(battery, LOG_LEVEL_INF);

/* Battery Service UUID: 0x180F */
static const struct bt_uuid_128 bat_svc_uuid = BT_UUID_INIT_128(
    BT_UUID_128_ENCODE(0x0000180F, 0x0000, 0x1000, 0x8000, 0x00805F9B34FB));

/* Battery Level characteristic UUID: 0x2A19 */
static const struct bt_uuid_128 bat_level_uuid = BT_UUID_INIT_128(
    BT_UUID_128_ENCODE(0x00002A19, 0x0000, 0x1000, 0x8000, 0x00805F9B34FB));

/* Battery state (simulated) */
static uint8_t battery_level = 100;  /* 0-100% */
static bool battery_charging = false;
static uint32_t battery_voltage_mv = 4200;  /* 4.2V = 100% */

/* CCC callback */
static void battery_ccc_cfg_changed(const struct bt_gatt_attr *attr, uint16_t value)
{
	LOG_INF("Battery level notifications %s",
	       value == BT_GATT_CCC_NOTIFY ? "enabled" : "disabled");
}

/* Battery level read callback */
static ssize_t battery_level_read(struct bt_conn *conn,
				   const struct bt_gatt_attr *attr,
				   void *buf, uint16_t len,
				   uint16_t offset)
{
	LOG_DBG("Battery level read: %u%%", battery_level);

	return bt_gatt_attr_read(conn, attr, buf, len, offset, &battery_level,
				 sizeof(battery_level));
}

/* Battery Service definition */
BT_GATT_SERVICE_DEFINE(battery_svc,
	BT_GATT_PRIMARY_SERVICE(&bat_svc_uuid),

	/* Battery Level characteristic */
	BT_GATT_CHARACTERISTIC(&bat_level_uuid.uuid,
				BT_GATT_CHRC_READ | BT_GATT_CHRC_NOTIFY,
				BT_GATT_PERM_READ_ENCRYPT,
				battery_level_read, NULL, NULL),
	BT_GATT_CCC(battery_ccc_cfg_changed,
		   BT_GATT_PERM_READ | BT_GATT_PERM_WRITE_ENCRYPT),
);

/* Connection tracking for notifications */
static struct bt_conn *current_conn = NULL;
static struct bt_conn_cb conn_callbacks;

/* Connected callback */
static void connected(struct bt_conn *conn, uint8_t err)
{
	if (err) {
		return;
	}

	/* Store connection reference */
	if (current_conn == NULL) {
		current_conn = bt_conn_ref(conn);
		LOG_INF("Battery service connected");
	}
}

/* Disconnected callback */
static void disconnected(struct bt_conn *conn, uint8_t reason)
{
	if (current_conn == conn) {
		bt_conn_unref(current_conn);
		current_conn = NULL;
		LOG_INF("Battery service disconnected");
	}
}

/* Connection callbacks */
static struct bt_conn_cb conn_callbacks = {
	.connected = connected,
	.disconnected = disconnected,
};

/* Public API implementation */
int battery_init(void)
{
	int err;

	/* Register connection callbacks */
	bt_conn_cb_register(&conn_callbacks);

	LOG_INF("Battery service initialized (Level: %u%%, Charging: %d)",
	       battery_level, battery_charging);

	return 0;
}

uint8_t battery_get_level(void)
{
	return battery_level;
}

int battery_set_level(uint8_t level)
{
	if (level > 100) {
		level = 100;
	}

	battery_level = level;

	/* Simulate voltage based on level */
	/* 3.7V (0%) to 4.2V (100%) */
	battery_voltage_mv = 3700 + (level * 5);  /* 3700 + (500 * level / 100) */

	LOG_DBG("Battery level set to %u%% (%u mV)", level, battery_voltage_mv);

	/* Notify via BLE if connected */
	battery_notify();

	return 0;
}

bool battery_is_charging(void)
{
	return battery_charging;
}

int battery_set_charging(bool charging)
{
	battery_charging = charging;

	LOG_DBG("Charging status set to %d", charging);

	return 0;
}

uint32_t battery_get_voltage(void)
{
	return battery_voltage_mv;
}

int battery_notify(void)
{
	int err;

	if (!current_conn) {
		return -ENOTCONN;
	}

	/* Send notification */
	err = bt_gatt_notify(current_conn, &battery_svc.attrs[2],
			      &battery_level, sizeof(battery_level));
	if (err == 0) {
		LOG_DBG("Battery level notification sent: %u%%", battery_level);
	}

	return err;
}
