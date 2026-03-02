/*
 * Copyright (c) 2025 Seeed Technology Co., Ltd.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#include <zephyr/kernel.h>
#include <zephyr/device.h>
#include <zephyr/drivers/sensor.h>
#include <zephyr/drivers/sensor/npm13xx_charger.h>
#include <zephyr/bluetooth/bluetooth.h>
#include <zephyr/bluetooth/hci.h>
#include <zephyr/bluetooth/conn.h>
#include <zephyr/bluetooth/uuid.h>
#include <zephyr/bluetooth/gatt.h>
#include <zephyr/logging/log.h>

#include "battery.h"
#include "clip.h"

LOG_MODULE_REGISTER(battery, LOG_LEVEL_INF);

/* npm1300 charger sensor device */
static const struct device *charger_dev = DEVICE_DT_GET(DT_NODELABEL(npm1300_charger));

/* Charger status bitmasks (BCHGCHARGESTATUS register) */
#define CHG_STATUS_COMPLETE_MASK BIT(1)
#define CHG_STATUS_TRICKLE_MASK  BIT(2)
#define CHG_STATUS_CC_MASK       BIT(3)
#define CHG_STATUS_CV_MASK       BIT(4)

/* Battery state — updated by periodic work */
static uint8_t  battery_level    = 50;   /* 0–100% */
static bool     battery_charging = false;
static uint32_t battery_voltage_mv = 3700;

/* Voltage → SoC lookup table (Li-Ion, discharge curve, mV → %) */
struct volt_soc_entry {
	uint32_t mv;
	uint8_t  soc;
};

/* Voltage → SoC curve for this battery pack:
 *   >= 4150 mV = 100%  (fully charged)
 *      3300 mV =   0%  (cut-off / empty)
 * Mid-points spaced ~85 mV apart across the 850 mV range. */
static const struct volt_soc_entry volt_soc_table[] = {
	{ 4150, 100 },
	{ 4060,  90 },
	{ 3980,  80 },
	{ 3900,  70 },
	{ 3820,  60 },
	{ 3740,  50 },
	{ 3660,  40 },
	{ 3570,  30 },
	{ 3480,  20 },
	{ 3390,  10 },
	{ 3300,   0 },
};

static uint8_t voltage_to_soc(uint32_t mv)
{
	const int n = ARRAY_SIZE(volt_soc_table);

	if (mv >= volt_soc_table[0].mv) {
		return 100;
	}
	if (mv <= volt_soc_table[n - 1].mv) {
		return 0;
	}

	for (int i = 0; i < n - 1; i++) {
		const struct volt_soc_entry *hi = &volt_soc_table[i];
		const struct volt_soc_entry *lo = &volt_soc_table[i + 1];

		if (mv <= hi->mv && mv > lo->mv) {
			/* Linear interpolation */
			uint32_t range_mv  = hi->mv - lo->mv;
			uint32_t offset_mv = mv - lo->mv;
			uint8_t  range_soc = hi->soc - lo->soc;

			return lo->soc + (uint8_t)(offset_mv * range_soc / range_mv);
		}
	}

	return 0;
}

/* Read hardware state and update module variables */
static void battery_hw_update(void)
{
	struct sensor_value val;
	int ret;

	if (!device_is_ready(charger_dev)) {
		LOG_WRN("npm1300 charger not ready");
		return;
	}

	ret = sensor_sample_fetch(charger_dev);
	if (ret < 0) {
		LOG_ERR("sensor_sample_fetch failed: %d", ret);
		return;
	}

	/* Voltage */
	ret = sensor_channel_get(charger_dev, SENSOR_CHAN_GAUGE_VOLTAGE, &val);
	if (ret == 0) {
		/* val.val1 = integer volts, val.val2 = micro-fractional volts */
		uint32_t mv = (uint32_t)(val.val1 * 1000 + val.val2 / 1000);

		battery_voltage_mv = mv;
		battery_level = voltage_to_soc(mv);
	} else {
		LOG_WRN("GAUGE_VOLTAGE read failed: %d", ret);
	}

	/* Charger status */
	ret = sensor_channel_get(charger_dev, SENSOR_CHAN_NPM13XX_CHARGER_STATUS, &val);
	if (ret == 0) {
		int32_t status = val.val1;

		battery_charging = (status & (CHG_STATUS_TRICKLE_MASK |
					      CHG_STATUS_CC_MASK |
					      CHG_STATUS_CV_MASK)) != 0;
	} else {
		LOG_WRN("CHARGER_STATUS read failed: %d", ret);
	}

	LOG_INF("Battery: %u mV → %u%%, charging=%d",
		battery_voltage_mv, battery_level, battery_charging);

	battery_notify();
}

/* Periodic work — polls hardware every BATTERY_POLL_INTERVAL_S seconds */
static void battery_work_handler(struct k_work *work);
static K_WORK_DELAYABLE_DEFINE(battery_work, battery_work_handler);

static void battery_work_handler(struct k_work *work)
{
	battery_hw_update();
	k_work_reschedule(&battery_work, K_SECONDS(BATTERY_POLL_INTERVAL_S));
}

/* ── BLE Battery Service ─────────────────────────────────────────────────── */

/* Battery Service UUID: 0x180F */
static const struct bt_uuid_128 bat_svc_uuid = BT_UUID_INIT_128(
	BT_UUID_128_ENCODE(0x0000180F, 0x0000, 0x1000, 0x8000, 0x00805F9B34FB));

/* Battery Level characteristic UUID: 0x2A19 */
static const struct bt_uuid_128 bat_level_uuid = BT_UUID_INIT_128(
	BT_UUID_128_ENCODE(0x00002A19, 0x0000, 0x1000, 0x8000, 0x00805F9B34FB));

static void battery_ccc_cfg_changed(const struct bt_gatt_attr *attr, uint16_t value)
{
	LOG_INF("Battery level notifications %s",
		value == BT_GATT_CCC_NOTIFY ? "enabled" : "disabled");
}

static ssize_t battery_level_read(struct bt_conn *conn,
				   const struct bt_gatt_attr *attr,
				   void *buf, uint16_t len,
				   uint16_t offset)
{
	LOG_DBG("Battery level read: %u%%", battery_level);
	return bt_gatt_attr_read(conn, attr, buf, len, offset,
				 &battery_level, sizeof(battery_level));
}

BT_GATT_SERVICE_DEFINE(battery_svc,
	BT_GATT_PRIMARY_SERVICE(&bat_svc_uuid),
	BT_GATT_CHARACTERISTIC(&bat_level_uuid.uuid,
			       BT_GATT_CHRC_READ | BT_GATT_CHRC_NOTIFY,
			       BT_GATT_PERM_READ_ENCRYPT,
			       battery_level_read, NULL, NULL),
	BT_GATT_CCC(battery_ccc_cfg_changed,
		    BT_GATT_PERM_READ | BT_GATT_PERM_WRITE_ENCRYPT),
);

/* BLE connection tracking for notifications */
static struct bt_conn *current_conn;

static void connected(struct bt_conn *conn, uint8_t err)
{
	if (!err && !current_conn) {
		current_conn = bt_conn_ref(conn);
	}
}

static void disconnected(struct bt_conn *conn, uint8_t reason)
{
	if (current_conn == conn) {
		bt_conn_unref(current_conn);
		current_conn = NULL;
	}
}

static struct bt_conn_cb conn_callbacks = {
	.connected    = connected,
	.disconnected = disconnected,
};

/* ── Public API ─────────────────────────────────────────────────────────── */

int battery_init(void)
{
	bt_conn_cb_register(&conn_callbacks);

	if (!device_is_ready(charger_dev)) {
		LOG_ERR("npm1300 charger device not ready — battery readings unavailable");
		return -ENODEV;
	}

	/* First reading immediately, then every 5 min */
	battery_hw_update();
	k_work_reschedule(&battery_work, K_SECONDS(BATTERY_POLL_INTERVAL_S));

	LOG_INF("Battery service initialized (Level: %u%%, Charging: %d)",
		battery_level, battery_charging);

	return 0;
}

uint8_t battery_get_level(void)
{
	return battery_level;
}

bool battery_is_charging(void)
{
	return battery_charging;
}

uint32_t battery_get_voltage(void)
{
	return battery_voltage_mv;
}

void battery_request_update(void)
{
	/* Synchronous read — resets the periodic timer */
	battery_hw_update();
	k_work_reschedule(&battery_work, K_SECONDS(BATTERY_POLL_INTERVAL_S));
}

/* These are kept as no-ops for AT+BATT test-injection compatibility */
int battery_set_level(uint8_t level)
{
	ARG_UNUSED(level);
	return 0;
}

int battery_set_charging(bool charging)
{
	ARG_UNUSED(charging);
	return 0;
}

int battery_notify(void)
{
	int err;

	if (!current_conn) {
		return -ENOTCONN;
	}

	err = bt_gatt_notify(current_conn, &battery_svc.attrs[2],
			     &battery_level, sizeof(battery_level));
	if (err == 0) {
		LOG_DBG("Battery level notification sent: %u%%", battery_level);
	}

	return err;
}
