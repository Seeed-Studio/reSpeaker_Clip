/*
 * Copyright (c) 2025 Seeed Technology Co., Ltd.
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
#include <string.h>
#include "ble_svc.h"

LOG_MODULE_REGISTER(ble_svc, LOG_LEVEL_INF);

#define DEVICE_NAME CONFIG_BT_DEVICE_NAME
#define DEVICE_NAME_LEN (sizeof(DEVICE_NAME) - 1)
#define MTU_SIZE 247

/* Service UUID: 6E400001-B5A3-F393-E0A9-E50E24DCCA9E */
static const struct bt_uuid_128 svc_uuid = BT_UUID_INIT_128(
    BT_UUID_128_ENCODE(0x6E400001, 0xB5A3F393, 0xE0A9E50E, 0x24DCCA9E, 0x00000000));

/* Characteristic UUIDs */
/* Command Receive: 6E400002-B5A3-F393-E0A9-E50E24DCCA9E */
static const struct bt_uuid_128 cmd_recv_uuid = BT_UUID_INIT_128(
    BT_UUID_128_ENCODE(0x6E400002, 0xB5A3F393, 0xE0A9E50E, 0x24DCCA9E, 0x00000000));

/* Response Send: 6E400003-B5A3-F393-E0A9-E50E24DCCA9E */
static const struct bt_uuid_128 resp_send_uuid = BT_UUID_INIT_128(
    BT_UUID_128_ENCODE(0x6E400003, 0xB5A3F393, 0xE0A9E50E, 0x24DCCA9E, 0x00000000));

/* File Data: 6E400004-B5A3-F393-E0A9-E50E24DCCA9E */
static const struct bt_uuid_128 file_data_uuid = BT_UUID_INIT_128(
    BT_UUID_128_ENCODE(0x6E400004, 0xB5A3F393, 0xE0A9E50E, 0x24DCCA9E, 0x00000000));

/* Connection and notification state */
static struct bt_conn *current_conn;
static volatile bool resp_notify_enabled;
static volatile bool file_data_notify_enabled;
static volatile bool mtu_exchanged;

/* External AT command handler */
extern int at_cmd_execute(const char *cmd_str, char **response);

/* Forward declarations */
static ssize_t cmd_recv_write(struct bt_conn *conn,
                             const struct bt_gatt_attr *attr,
                             const void *buf, uint16_t len,
                             uint16_t offset, uint8_t flags);
static void resp_ccc_cfg_changed(const struct bt_gatt_attr *attr, uint16_t value);
static void file_data_ccc_cfg_changed(const struct bt_gatt_attr *attr, uint16_t value);

/* GATT service definition */
BT_GATT_SERVICE_DEFINE(clip_svc,
    BT_GATT_PRIMARY_SERVICE(&svc_uuid),

    /* Command Receive Characteristic (Write) */
    BT_GATT_CHARACTERISTIC(&cmd_recv_uuid.uuid,
                           BT_GATT_CHRC_WRITE_WITHOUT_RESP,
                           BT_GATT_PERM_WRITE,
                           NULL, cmd_recv_write, NULL),

    /* Response Send Characteristic (Notify) */
    BT_GATT_CHARACTERISTIC(&resp_send_uuid.uuid,
                           BT_GATT_CHRC_NOTIFY,
                           BT_GATT_PERM_READ,
                           NULL, NULL, NULL),
    BT_GATT_CCC(resp_ccc_cfg_changed,
               BT_GATT_PERM_READ | BT_GATT_PERM_WRITE),

    /* File Data Characteristic (Notify) */
    BT_GATT_CHARACTERISTIC(&file_data_uuid.uuid,
                           BT_GATT_CHRC_NOTIFY,
                           BT_GATT_PERM_READ,
                           NULL, NULL, NULL),
    BT_GATT_CCC(file_data_ccc_cfg_changed,
               BT_GATT_PERM_READ | BT_GATT_PERM_WRITE),
);

/* CCC callbacks */
static void resp_ccc_cfg_changed(const struct bt_gatt_attr *attr, uint16_t value)
{
    resp_notify_enabled = (value == BT_GATT_CCC_NOTIFY);
    LOG_INF("Response notify %s", resp_notify_enabled ? "enabled" : "disabled");
}

static void file_data_ccc_cfg_changed(const struct bt_gatt_attr *attr, uint16_t value)
{
    file_data_notify_enabled = (value == BT_GATT_CCC_NOTIFY);
    LOG_INF("File data notify %s", file_data_notify_enabled ? "enabled" : "disabled");
}

/* Write callback for command receive */
static ssize_t cmd_recv_write(struct bt_conn *conn,
                             const struct bt_gatt_attr *attr,
                             const void *buf, uint16_t len,
                             uint16_t offset, uint8_t flags)
{
    char *cmd_str;
    char *response = NULL;
    int err;

    LOG_DBG("Received command: %.*s", len, (char *)buf);

    /* Copy command string */
    cmd_str = k_malloc(len + 1);
    if (!cmd_str) {
        return BT_GATT_ERR(BT_ATT_ERR_INSUFFICIENT_RESOURCES);
    }

    memcpy(cmd_str, buf, len);
    cmd_str[len] = '\0';

    /* Execute command */
    err = at_cmd_execute(cmd_str, &response);

    /* Send response if available */
    if (response) {
        ble_svc_send_response(response);
        k_free(response);
    }

    k_free(cmd_str);

    return (err == 0) ? len : BT_GATT_ERR(BT_ATT_ERR_UNLIKELY);
}

/* Advertising data */
static const struct bt_data ad[] = {
    BT_DATA_BYTES(BT_DATA_FLAGS, (BT_LE_AD_GENERAL | BT_LE_AD_NO_BREDR)),
    BT_DATA(BT_DATA_NAME_COMPLETE, DEVICE_NAME, DEVICE_NAME_LEN),
};

static const struct bt_data sd[] = {
    BT_DATA_BYTES(BT_DATA_UUID128_ALL,
                  0x6E, 0x40, 0x00, 0x01, 0xB5, 0xA3, 0xF3, 0x93,
                  0xE0, 0xA9, 0xE5, 0x0E, 0x24, 0x4D, 0xCC, 0x9E),
};

/* Work queue for operations */
static struct k_work adv_work;
static struct k_work_delayable mtu_work;

/* Advertising restart handler */
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
        LOG_INF("MTU exchanged, ready for communication");
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

/* Connection callbacks */
static void connected(struct bt_conn *conn, uint8_t err)
{
    if (err) {
        return;
    }

    current_conn = bt_conn_ref(conn);
    mtu_exchanged = false;

    LOG_INF("BLE connected");

    /* Delay MTU exchange */
    k_work_schedule(&mtu_work, K_MSEC(500));
}

static void disconnected(struct bt_conn *conn, uint8_t reason)
{
    if (current_conn == conn) {
        bt_conn_unref(current_conn);
        current_conn = NULL;
        resp_notify_enabled = false;
        file_data_notify_enabled = false;

        LOG_INF("BLE disconnected (reason: %u)", reason);

        /* Restart advertising */
        k_work_submit(&adv_work);
    }
}

static void le_param_updated(struct bt_conn *conn, uint16_t interval,
                             uint16_t latency, uint16_t timeout)
{
    if (!mtu_exchanged && current_conn == conn) {
        bt_gatt_exchange_mtu(conn, &mtu_params);
    }
}

static struct bt_conn_cb conn_callbacks = {
    .connected = connected,
    .disconnected = disconnected,
    .le_param_updated = le_param_updated,
};

/* Public API implementation */
int ble_svc_init(void)
{
    int err;

    /* Initialize work queue */
    k_work_init(&adv_work, adv_work_handler);
    k_work_init_delayable(&mtu_work, mtu_work_handler);

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

    return 0;
}

int ble_svc_send_response(const char *json)
{
    if (!ble_svc_is_ready()) {
        return -ENOTCONN;
    }

    return bt_gatt_notify(current_conn, &clip_svc.attrs[4],
                          (const void *)json, strlen(json));
}

int ble_svc_send_file_data(const uint8_t *data, uint16_t len)
{
    if (!file_data_notify_enabled || !current_conn) {
        return -ENOTCONN;
    }

    return bt_gatt_notify(current_conn, &clip_svc.attrs[7],
                          data, len);
}

bool ble_svc_is_ready(void)
{
    return (current_conn != NULL && resp_notify_enabled && mtu_exchanged);
}

struct bt_conn *ble_svc_get_connection(void)
{
    return current_conn;
}
