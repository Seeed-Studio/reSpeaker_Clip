/*
 * Copyright (c) 2025 Seeed Technology Co., Ltd.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#include <zephyr/kernel.h>
#include <zephyr/sys/reboot.h>
#include <zephyr/logging/log.h>
#include <zephyr/bluetooth/bluetooth.h>
#include <zephyr/bluetooth/hci.h>
#include <zephyr/bluetooth/conn.h>
#include <zephyr/bluetooth/uuid.h>
#include <zephyr/bluetooth/gatt.h>
#include <hal/nrf_ficr.h>
#include <string.h>
#include <zephyr/settings/settings.h>
#include "ble_svc.h"
#include "at_cmd.h"
#include "json_helper.h"
#include "clip.h"
#include "transfer.h"
#include "display.h"
#include "display_ctrl.h"

LOG_MODULE_REGISTER(ble_svc, LOG_LEVEL_INF);

/* Reboot work item - delays reboot to allow response to be sent */
static struct k_work_delayable reboot_work;

/* Dynamic device name: "Clip XXXX" where XXXX is last 4 hex of device ID */
static char device_name[16];
static uint8_t device_name_len;
static struct bt_data ad[2];
static struct bt_data sd[1];

/* Generate device name from FICR device ID */
static void generate_device_name(void)
{
    uint32_t device_id_low = nrf_ficr_deviceid_get(NRF_FICR, 0);

    /* Get last 16 bits (4 hex digits) of device ID */
    uint16_t id_suffix = device_id_low & 0xFFFF;

    /* Format: "Clip XXXX" */
    snprintf(device_name, sizeof(device_name), "Clip %04X", id_suffix);
    device_name_len = strlen(device_name);

    LOG_INF("Device name: %s", device_name);
}

#define MTU_SIZE 247

/* Zero-copy response buffer for AT command responses */
static char response_buffer[BLE_RESPONSE_BUFFER_SIZE];
static struct k_mutex response_buffer_mutex;

/* Command queue configuration */
#define CMD_QUEUE_SIZE 8
#define CMD_MAX_LEN 256

/* Command queue item */
struct cmd_queue_item {
    char data[CMD_MAX_LEN];
    uint16_t len;
};

/* Command queue */
K_MSGQ_DEFINE(cmd_msgq, sizeof(struct cmd_queue_item), CMD_QUEUE_SIZE, 4);

/* AT command processor thread */
static K_THREAD_STACK_DEFINE(at_thread_stack, CLIP_AT_CMD_STACK_SIZE);
static struct k_thread at_thread_data;
static k_tid_t at_thread_id;

/* Service UUID: 6E400001-B5A3-F393-E0A9-E50E24DCCA9E */
static const struct bt_uuid_128 svc_uuid = BT_UUID_INIT_128(
    BT_UUID_128_ENCODE(0x6E400001, 0xB5A3, 0xF393, 0xE0A9, 0xE50E24DCCA9E));

/* Characteristic UUIDs */
/* Command Receive: 6E400002-B5A3-F393-E0A9-E50E24DCCA9E */
static const struct bt_uuid_128 cmd_recv_uuid = BT_UUID_INIT_128(
    BT_UUID_128_ENCODE(0x6E400002, 0xB5A3, 0xF393, 0xE0A9, 0xE50E24DCCA9E));

/* Response Send: 6E400003-B5A3-F393-E0A9-E50E24DCCA9E */
static const struct bt_uuid_128 resp_send_uuid = BT_UUID_INIT_128(
    BT_UUID_128_ENCODE(0x6E400003, 0xB5A3, 0xF393, 0xE0A9, 0xE50E24DCCA9E));

/* File Data: 6E400004-B5A3-F393-E0A9-E50E24DCCA9E */
static const struct bt_uuid_128 file_data_uuid = BT_UUID_INIT_128(
    BT_UUID_128_ENCODE(0x6E400004, 0xB5A3, 0xF393, 0xE0A9, 0xE50E24DCCA9E));

/* Audio Visualization: 6E400005-B5A3-F393-E0A9-E50E24DCCA9E */
static const struct bt_uuid_128 audio_vis_uuid = BT_UUID_INIT_128(
    BT_UUID_128_ENCODE(0x6E400005, 0xB5A3, 0xF393, 0xE0A9, 0xE50E24DCCA9E));

/* Connection and notification state */
static struct bt_conn *current_conn;
static volatile bool resp_notify_enabled;
static volatile bool file_data_notify_enabled;
static volatile bool audio_vis_notify_enabled;
static volatile bool mtu_exchanged;

/* Forward declarations */
static ssize_t cmd_recv_write(struct bt_conn *conn,
                             const struct bt_gatt_attr *attr,
                             const void *buf, uint16_t len,
                             uint16_t offset, uint8_t flags);
static void resp_ccc_cfg_changed(const struct bt_gatt_attr *attr, uint16_t value);
static void file_data_ccc_cfg_changed(const struct bt_gatt_attr *attr, uint16_t value);
static void audio_vis_ccc_cfg_changed(const struct bt_gatt_attr *attr, uint16_t value);

/* GATT service definition */
BT_GATT_SERVICE_DEFINE(clip_svc,
    BT_GATT_PRIMARY_SERVICE(&svc_uuid),

    /* Command Receive Characteristic (Write) - requires encryption */
    BT_GATT_CHARACTERISTIC(&cmd_recv_uuid.uuid,
                           BT_GATT_CHRC_WRITE_WITHOUT_RESP,
                           BT_GATT_PERM_WRITE_ENCRYPT,
                           NULL, cmd_recv_write, NULL),

    /* Response Send Characteristic (Notify) - requires encryption */
    BT_GATT_CHARACTERISTIC(&resp_send_uuid.uuid,
                           BT_GATT_CHRC_NOTIFY,
                           BT_GATT_PERM_READ,
                           NULL, NULL, NULL),
    BT_GATT_CCC(resp_ccc_cfg_changed,
               BT_GATT_PERM_READ | BT_GATT_PERM_WRITE_ENCRYPT),

    /* File Data Characteristic (Notify) - requires encryption */
    BT_GATT_CHARACTERISTIC(&file_data_uuid.uuid,
                           BT_GATT_CHRC_NOTIFY,
                           BT_GATT_PERM_READ,
                           NULL, NULL, NULL),
    BT_GATT_CCC(file_data_ccc_cfg_changed,
               BT_GATT_PERM_READ | BT_GATT_PERM_WRITE_ENCRYPT),

    /* Audio Visualization Characteristic (Notify) - requires encryption */
    BT_GATT_CHARACTERISTIC(&audio_vis_uuid.uuid,
                           BT_GATT_CHRC_NOTIFY,
                           BT_GATT_PERM_READ,
                           NULL, NULL, NULL),
    BT_GATT_CCC(audio_vis_ccc_cfg_changed,
               BT_GATT_PERM_READ | BT_GATT_PERM_WRITE_ENCRYPT),
);

/* CCC callbacks */
static void resp_ccc_cfg_changed(const struct bt_gatt_attr *attr, uint16_t value)
{
    resp_notify_enabled = (value == BT_GATT_CCC_NOTIFY);
    LOG_DBG("notify: %d", resp_notify_enabled);
}

static void file_data_ccc_cfg_changed(const struct bt_gatt_attr *attr, uint16_t value)
{
    file_data_notify_enabled = (value == BT_GATT_CCC_NOTIFY);
    LOG_DBG("data_notify: %d", file_data_notify_enabled);
}

static void audio_vis_ccc_cfg_changed(const struct bt_gatt_attr *attr, uint16_t value)
{
    audio_vis_notify_enabled = (value == BT_GATT_CCC_NOTIFY);
    LOG_INF("audio_vis_notify: %d", audio_vis_notify_enabled);
}

/* Reboot work handler */
static void reboot_work_handler(struct k_work *work)
{
    sys_reboot(SYS_REBOOT_COLD);
}

/* AT command processor thread */
static void at_thread_main(void *p1, void *p2, void *p3)
{
    struct cmd_queue_item item;
    struct at_command cmd;
    char *response = NULL;
    int err;

    ARG_UNUSED(p1);
    ARG_UNUSED(p2);
    ARG_UNUSED(p3);

    while (1) {
        /* Wait for command from queue */
        if (k_msgq_get(&cmd_msgq, &item, K_FOREVER) != 0) {
            continue;
        }

        LOG_INF("cmd: %s", item.data);

        /* Parse AT command */
        memset(&cmd, 0, sizeof(cmd));
        err = at_cmd_parse(item.data, &cmd);
        if (err != 0) {
            LOG_WRN("parse failed: %d (cmd: %s)", err, item.data);
            /* Send error response instead of silently failing */
            json_create_error("Parse error", &response);
            if (response) {
                ble_svc_send_response(response);
                k_free(response);
                response = NULL;
            }
            continue;
        }

        /* Execute command */
        err = at_cmd_execute(&cmd, &response);
        LOG_DBG("-> %d", err);

        /* Check if this is a REBOOT command */
        bool is_reboot = (strcmp(cmd.name, "REBOOT") == 0);

        /* Send response if available */
        if (response) {
            ble_svc_send_response(response);
            k_free(response);
            response = NULL;
        }

        /* If REBOOT command, schedule reboot after response is sent */
        if (is_reboot) {
            k_work_schedule(&reboot_work, K_MSEC(500));
        }

        /* Cleanup parsed command */
        at_cmd_cleanup(&cmd);
    }
}

/* Write callback for command receive - runs in BLE context, minimal work */
static ssize_t cmd_recv_write(struct bt_conn *conn,
                             const struct bt_gatt_attr *attr,
                             const void *buf, uint16_t len,
                             uint16_t offset, uint8_t flags)
{
    struct cmd_queue_item item;

    ARG_UNUSED(conn);
    ARG_UNUSED(attr);
    ARG_UNUSED(flags);

    /* Ignore offset for now - we expect complete commands in one write */
    if (offset != 0) {
        LOG_WRN("Unexpected offset: %u", offset);
    }

    /* Validate length */
    if (len == 0 || len >= CMD_MAX_LEN) {
        LOG_WRN("Invalid command length: %u", len);
        return BT_GATT_ERR(BT_ATT_ERR_INVALID_PDU);
    }

    /* Copy to queue item */
    memcpy(item.data, buf, len);
    item.data[len] = '\0';
    item.len = len;

    /* Send to queue (non-blocking) */
    if (k_msgq_put(&cmd_msgq, &item, K_NO_WAIT) != 0) {
        LOG_WRN("Command queue full, dropping command");
        return BT_GATT_ERR(BT_ATT_ERR_INSUFFICIENT_RESOURCES);
    }

    return len;
}

static uint8_t svc_uuid_bytes[16];
static struct bt_data sd[1];

/* Work queue for operations */
static struct k_work adv_work;
static struct k_work_delayable mtu_work;
static struct k_work transfer_cancel_work;

/* Bond helper: count stored bonds */
static void count_bond_cb(const struct bt_bond_info *info, void *user_data)
{
    int *count = (int *)user_data;
    (*count)++;
}

/* Bond helper: add each bonded peer address to the Filter Accept List */
static void add_bond_to_fal_cb(const struct bt_bond_info *info, void *user_data)
{
    int err = bt_le_filter_accept_list_add(&info->addr);

    if (err) {
        LOG_WRN("FAL add failed: %d", err);
    }
}

/* Advertising restart handler - dual mode:
 *   No bond  -> open advertising + show pairing guide on display
 *   Bond exists -> FAL-filtered advertising, only bonded device can connect
 */
static void adv_work_handler(struct k_work *work)
{
    int bond_count = 0;
    int err;

    bt_foreach_bond(BT_ID_DEFAULT, count_bond_cb, &bond_count);

    if (bond_count > 0) {
        /* Bonded mode: populate FAL and restrict connections */
        bt_le_filter_accept_list_clear();
        bt_foreach_bond(BT_ID_DEFAULT, add_bond_to_fal_cb, NULL);

        static const struct bt_le_adv_param adv_param_bonded =
            BT_LE_ADV_PARAM_INIT(
                BT_LE_ADV_OPT_CONN | BT_LE_ADV_OPT_FILTER_CONN,
                BT_GAP_ADV_FAST_INT_MIN_2,
                BT_GAP_ADV_FAST_INT_MAX_2,
                NULL);

        err = bt_le_adv_start(&adv_param_bonded, ad, ARRAY_SIZE(ad),
                              sd, ARRAY_SIZE(sd));
        if (err && err != -EALREADY) {
            LOG_ERR("adv_start (bonded): %d", err);
        } else {
            LOG_INF("Advertising: bonded-only mode");
        }
    } else {
        /* Pairing mode: open advertising, show pairing guide */
        display_show_pairing_guide();

        err = bt_le_adv_start(BT_LE_ADV_CONN_FAST_1, ad, ARRAY_SIZE(ad),
                              sd, ARRAY_SIZE(sd));
        if (err && err != -EALREADY) {
            LOG_ERR("adv_start (pairing): %d", err);
        } else {
            LOG_INF("Advertising: pairing mode (no bond)");
        }
    }
}

/* MTU exchange callback */
static void mtu_exchange_cb(struct bt_conn *conn, uint8_t err,
                            struct bt_gatt_exchange_params *params)
{
    if (!err) {
        mtu_exchanged = true;
        LOG_INF("MTU: %u", bt_gatt_get_mtu(conn));
    } else {
        LOG_WRN("MTU fail: %d", err);
        mtu_exchanged = true;
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

/* Transfer cancel work handler - cancel transfer if active */
static void transfer_cancel_work_handler(struct k_work *work)
{
    ARG_UNUSED(work);
    if (transfer_is_active()) {
        transfer_cancel();
    }
}

/* Connection callbacks */
static void connected(struct bt_conn *conn, uint8_t err)
{
    char addr[BT_ADDR_LE_STR_LEN];

    if (err) {
        LOG_WRN("Connection failed: err=%u", err);
        return;
    }

    bt_addr_le_to_str(bt_conn_get_dst(conn), addr, sizeof(addr));
    current_conn = bt_conn_ref(conn);
    mtu_exchanged = false;

    /* Check whether this is a known bonded device or a new one */
    int bond_count = 0;

    bt_foreach_bond(BT_ID_DEFAULT, count_bond_cb, &bond_count);
    if (bond_count > 0) {
        LOG_INF("BLE connected: addr=%s (bonded device, re-encrypting)", addr);
    } else {
        LOG_INF("BLE connected: addr=%s (no bond - waiting for pairing)", addr);
    }

    /* Immediately require encryption. If no bond exists, this triggers
     * SMP pairing. If a bond exists, it triggers re-encryption with
     * the stored LTK. Devices that refuse will be disconnected in
     * security_changed().
     */
    int sec_err = bt_conn_set_security(conn, BT_SECURITY_L2);

    if (sec_err) {
        LOG_WRN("Security request failed: addr=%s err=%d", addr, sec_err);
    }

    /* Delay MTU exchange until after security is established */
    k_work_schedule(&mtu_work, K_MSEC(1000));
}

static void disconnected(struct bt_conn *conn, uint8_t reason)
{
    if (current_conn == conn) {
        char addr[BT_ADDR_LE_STR_LEN];

        bt_addr_le_to_str(bt_conn_get_dst(conn), addr, sizeof(addr));
        bt_conn_unref(current_conn);
        current_conn = NULL;
        resp_notify_enabled = false;
        file_data_notify_enabled = false;

        /* reason=0x05: auth fail  reason=0x08: timeout  reason=0x13: remote user  reason=0x16: local host */
        LOG_INF("BLE disconnected: addr=%s reason=0x%02x", addr, reason);

        /* Clean up any ongoing transfer via work queue to avoid stack overflow
         * in BLE RX thread context (transfer_cancel -> storage_set_synced_files
         * requires significant stack space)
         */
        if (transfer_is_active()) {
            k_work_submit(&transfer_cancel_work);
        }

        /* Restart advertising */
        k_work_submit(&adv_work);
    }
}

static void le_param_updated(struct bt_conn *conn, uint16_t interval,
                             uint16_t latency, uint16_t timeout)
{
    LOG_DBG("LE: int=%u lat=%u to=%u", interval, latency, timeout);

    if (!mtu_exchanged && current_conn == conn) {
        bt_gatt_exchange_mtu(conn, &mtu_params);
        /* After MTU exchange, request faster connection parameters */
        struct bt_le_conn_param fast_params = {
            .interval_min = 6,
            .interval_max = 6,
            .latency = 0,
            .timeout = 200,
        };
        LOG_DBG("fast params");
        bt_conn_le_param_update(conn, &fast_params);
    }
}

/* Reject connection parameters that are too aggressive */
static bool le_param_req(struct bt_conn *conn, struct bt_le_conn_param *param)
{
    /* Require minimum timeout of 200 (2 seconds) for stability */
    if (param->timeout < 200) {
        LOG_WRN("Rejecting params: timeout %u too short, requesting 200",
                param->timeout);
        param->timeout = 200;
        param->interval_min = 30;
        param->interval_max = 50;
        param->latency = 0;
        return false;  /* Reject with our counter-proposal */
    }

    LOG_DBG("accept: int=%u-%u lat=%u to=%u",
            param->interval_min, param->interval_max, param->latency, param->timeout);
    return true;
}

/* Disconnect any connection that did not reach encryption level 2 */
static void security_changed(struct bt_conn *conn, bt_security_t level,
                             enum bt_security_err err)
{
    char addr[BT_ADDR_LE_STR_LEN];

    bt_addr_le_to_str(bt_conn_get_dst(conn), addr, sizeof(addr));

    if (err == BT_SECURITY_ERR_PIN_OR_KEY_MISSING) {
        /* Remote has a stale bond key that we no longer have locally.
         * Do NOT call bt_unpair() here - local bond is already absent,
         * calling it would erase any *other* valid local bonds.
         * Just disconnect; the phone will re-pair on the next connection.
         */
        LOG_WRN("Stale bond from remote (addr=%s), disconnecting to re-pair", addr);
        bt_conn_disconnect(conn, BT_HCI_ERR_PIN_OR_KEY_MISSING);
        return;
    }

    if (err == BT_SECURITY_ERR_AUTH_REQUIREMENT) {
        /* Re-encryption failed. This typically happens when:
         * - The phone deleted the bond but we still have it locally
         * - We try to re-encrypt using the old key, but the phone rejects it
         * Solution: Delete our stale bond and allow re-pairing
         */
        LOG_WRN("Re-encryption failed (addr=%s), clearing stale bond", addr);
        int unpair_err = bt_unpair(BT_ID_DEFAULT, bt_conn_get_dst(conn));
        if (unpair_err) {
            LOG_WRN("bt_unpair failed: %d", unpair_err);
        }
        bt_conn_disconnect(conn, BT_HCI_ERR_AUTH_FAIL);
        return;
    }

    if (err) {
        LOG_WRN("Security failed: addr=%s level=%d err=%d - disconnecting",
                addr, level, err);
        bt_conn_disconnect(conn, BT_HCI_ERR_AUTH_FAIL);
        return;
    }

    if (level < BT_SECURITY_L2) {
        LOG_WRN("Security level too low: addr=%s level=%d - disconnecting",
                addr, level);
        bt_conn_disconnect(conn, BT_HCI_ERR_AUTH_FAIL);
        return;
    }

    LOG_INF("Security established: addr=%s level=%d", addr, level);
}

/* Auto-confirm Just Works pairing (no passkey required) */
static void pairing_confirm(struct bt_conn *conn)
{
    char addr[BT_ADDR_LE_STR_LEN];

    bt_addr_le_to_str(bt_conn_get_dst(conn), addr, sizeof(addr));
    LOG_INF("Pairing confirm: %s", addr);
    bt_conn_auth_pairing_confirm(conn);
}

static struct bt_conn_auth_cb auth_callbacks = {
    .pairing_confirm = pairing_confirm,
};

static void pairing_complete(struct bt_conn *conn, bool bonded)
{
    char addr[BT_ADDR_LE_STR_LEN];

    bt_addr_le_to_str(bt_conn_get_dst(conn), addr, sizeof(addr));
    LOG_INF("Pairing complete: addr=%s bonded=%d", addr, bonded);
    if (bonded) {
        /* CONFIG_BT_SETTINGS_DELAYED_STORE=y defers NVS writes by 1000ms.
         * If an OTA reboot happens within that window the bond is lost.
         * Force an immediate synchronous settings save here so the bond
         * key is on flash before any reboot can occur.
         */
        int err = settings_save();
        if (err) {
            LOG_WRN("settings_save after pairing failed: %d", err);
        } else {
            LOG_INF("Bond saved to NVS");
        }
        ui_post_event(UI_EVT_BONDED);
    }
}

static void pairing_failed(struct bt_conn *conn, enum bt_security_err reason)
{
    char addr[BT_ADDR_LE_STR_LEN];

    bt_addr_le_to_str(bt_conn_get_dst(conn), addr, sizeof(addr));
    LOG_WRN("Pairing failed: addr=%s reason=%d - disconnecting", addr, reason);
    bt_conn_disconnect(conn, BT_HCI_ERR_AUTH_FAIL);
}

static struct bt_conn_auth_info_cb auth_info_callbacks = {
    .pairing_complete = pairing_complete,
    .pairing_failed   = pairing_failed,
};

static struct bt_conn_cb conn_callbacks = {
    .connected        = connected,
    .disconnected     = disconnected,
    .le_param_updated = le_param_updated,
    .le_param_req     = le_param_req,
    .security_changed = security_changed,
};

/* Public API implementation */
int ble_svc_init(void)
{
    int err;

    /* Generate device name from chip ID */
    generate_device_name();

    /* Build advertising data dynamically */
    static uint8_t flags = BT_LE_AD_GENERAL | BT_LE_AD_NO_BREDR;
    ad[0].type = BT_DATA_FLAGS;
    ad[0].data_len = sizeof(flags);
    ad[0].data = &flags;

    ad[1].type = BT_DATA_NAME_COMPLETE;
    ad[1].data_len = device_name_len;
    ad[1].data = (uint8_t *)device_name;

    /* Build service UUID data */
    bt_uuid_to_str(&svc_uuid.uuid, (char *)svc_uuid_bytes, sizeof(svc_uuid_bytes));
    sd[0].type = BT_DATA_UUID128_ALL;
    sd[0].data_len = sizeof(svc_uuid_bytes);
    sd[0].data = svc_uuid_bytes;

    /* Initialize work queue */
    k_work_init(&adv_work, adv_work_handler);
    k_work_init_delayable(&mtu_work, mtu_work_handler);
    k_work_init_delayable(&reboot_work, reboot_work_handler);
    k_work_init(&transfer_cancel_work, transfer_cancel_work_handler);

    /* Initialize response buffer mutex */
    k_mutex_init(&response_buffer_mutex);

    /* Enable Bluetooth */
    err = bt_enable(NULL);
    if (err) {
        LOG_ERR("bt_enable: %d", err);
        return err;
    }

    /* Register connection callbacks */
    bt_conn_cb_register(&conn_callbacks);

    /* Register pairing/authentication callbacks */
    bt_conn_auth_cb_register(&auth_callbacks);
    bt_conn_auth_info_cb_register(&auth_info_callbacks);

    /* Load BT settings (bond keys) that were persisted before the last reboot.
     * Must be called after bt_enable() so the BT settings handlers are
     * registered before settings_load_subtree() is called.
     */
    settings_load_subtree("bt");

    /* Start advertising via work item so bond state is evaluated */
    k_work_submit(&adv_work);

    LOG_INF("BLE ready");

    /* Start AT command processor thread */
    at_thread_id = k_thread_create(&at_thread_data, at_thread_stack,
                                   CLIP_AT_CMD_STACK_SIZE,
                                   at_thread_main, NULL, NULL, NULL,
                                   CLIP_AT_CMD_THREAD_PRIORITY, 0, K_NO_WAIT);
    if (at_thread_id == NULL) {
        LOG_ERR("Failed to create AT command thread");
        return -ENOMEM;
    }
    k_thread_name_set(&at_thread_data, "at_cmd");

    LOG_INF("AT command thread started");

    return 0;
}

int ble_svc_send_response(const char *json)
{
    int err;
    uint16_t max_len;
    size_t total_len;
    size_t offset = 0;
    int chunk_count = 0;

    if (!ble_svc_is_ready()) {
        LOG_ERR("Cannot send response: not ready");
        return -ENOTCONN;
    }

    if (!resp_notify_enabled) {
        LOG_ERR("Cannot send response: notify not enabled");
        return -ENOTCONN;
    }

    /* MTU - 3 bytes ATT header = max notify payload */
    max_len = bt_gatt_get_mtu(current_conn) - 3;
    total_len = strlen(json);

    /* Split into chunks if needed */
    while (offset < total_len) {
        size_t chunk_len = total_len - offset;
        if (chunk_len > max_len) {
            chunk_len = max_len;
        }

        err = bt_gatt_notify(current_conn, &clip_svc.attrs[4],
                              json + offset, chunk_len);
        if (err) {
            LOG_ERR("Notify failed at chunk %d (offset %u): %d",
                    chunk_count, (uint32_t)offset, err);
            return err;
        }

        chunk_count++;
        offset += chunk_len;

        /* No delay - let BLE flow control handle pacing */
    }

    LOG_DBG("Sent %d chunks, total %u bytes", chunk_count, (uint32_t)total_len);

    return 0;
}

int ble_svc_send_file_data(const uint8_t *data, uint16_t len)
{
    int err;
    uint16_t max_len;
    size_t offset = 0;
    int retry_count = 0;
    const int max_retries = 3;
    int64_t notify_start, notify_end;
    static int notify_count = 0;

    if (!file_data_notify_enabled || !current_conn) {
        return -ENOTCONN;
    }

    /* MTU - 3 bytes ATT header = max notify payload */
    max_len = bt_gatt_get_mtu(current_conn) - 3;

    /* Split into chunks if needed */
    while (offset < len) {
        size_t chunk_len = len - offset;
        if (chunk_len > max_len) {
            chunk_len = max_len;
        }

        /* Retry logic for temporary failures */
        retry_count = 0;
        do {
            notify_start = k_uptime_get();
            err = bt_gatt_notify(current_conn, &clip_svc.attrs[7],
                                  data + offset, chunk_len);
            notify_end = k_uptime_get();

            if (err == 0) {
                /* Log timing every 50 notifications */
                notify_count++;
                if (notify_count % 50 == 0) {
                    LOG_DBG("[BLE] notify #%d: %zu bytes took %lldms",
                            notify_count, chunk_len, notify_end - notify_start);
                }
                break;  /* Success */
            }

            /* Retry on temporary errors */
            if (err == -ENOMEM || err == -EAGAIN || err == -EBUSY) {
                retry_count++;
                if (retry_count < max_retries) {
                    LOG_WRN("[BLE] notify failed (offset=%u, err=%d), retrying %d/%d",
                            (uint32_t)offset, err, retry_count, max_retries);
                    k_sleep(K_MSEC(10));  /* Wait before retry */
                    continue;
                }
            }

            /* Fatal error or retries exhausted */
            LOG_ERR("File notify failed at offset %u: %d (retries: %d)",
                    (uint32_t)offset, err, retry_count);
            return err;

        } while (retry_count < max_retries);

        offset += chunk_len;
    }

    return 0;
}

int ble_svc_send_audio_vis(const uint8_t *data, uint16_t len)
{
    int err;

    if (!audio_vis_notify_enabled || !current_conn) {
        return -ENOTCONN;
    }

    if (!data || len == 0) {
        return -EINVAL;
    }

    /* Send audio visualization data (1 byte: energy level 0-10)
     * Audio vis characteristic value is at attrs[10] */
    err = bt_gatt_notify(current_conn, &clip_svc.attrs[10], data, len);

    if (err != 0 && err != -ENOTCONN) {
        LOG_DBG("Audio vis notify failed: %d", err);
    }

    return err;
}

int ble_svc_send_file_ready(const char *session_id, const char *filename, uint64_t size)
{
    char buffer[256];
    int len;

    len = snprintf(buffer, sizeof(buffer),
                   "{\"ok\":true,\"event\":\"file_ready\",\"session\":\"%s\",\"filename\":\"%s\",\"size\":%llu}",
                   session_id, filename, size);
    if (len < 0 || len >= sizeof(buffer)) {
        return -ENOMEM;
    }

    return ble_svc_send_response(buffer);
}

int ble_svc_send_file_complete(const char *filename)
{
    char buffer[256];
    int len;
    int err;
    int retry_count = 0;
    const int max_retries = 5;

    len = snprintf(buffer, sizeof(buffer),
                   "{\"ok\":true,\"event\":\"file_complete\",\"filename\":\"%s\"}",
                   filename);
    if (len < 0 || len >= sizeof(buffer)) {
        return -ENOMEM;
    }

    /* Retry with delay for critical file_complete notification
     * This ensures the final completion event gets through even if
     * BLE stack is busy (e.g., when recording just stopped)
     */
    do {
        err = ble_svc_send_response(buffer);
        if (err == 0) {
            return 0;  /* Success */
        }

        /* Retry on temporary errors */
        if (err == -ENOMEM || err == -EAGAIN || err == -EBUSY || err == -12) {
            retry_count++;
            if (retry_count < max_retries) {
                LOG_DBG("file_complete notify failed (err=%d), retrying %d/%d",
                        err, retry_count, max_retries);
                k_sleep(K_MSEC(50));  /* Wait before retry */
                continue;
            }
        }

        /* Fatal error or retries exhausted */
        LOG_ERR("file_complete notify failed: %d (retries: %d)", err, retry_count);
        return err;

    } while (retry_count < max_retries);

    return err;
}

int ble_svc_send_transfer_complete(const char *session_id, int files_count)
{
    char buffer[256];
    int len;
    int err;
    int retry_count = 0;
    const int max_retries = 5;

    len = snprintf(buffer, sizeof(buffer),
                   "{\"ok\":true,\"event\":\"transfer_complete\",\"session_id\":\"%s\",\"files\":%d}",
                   session_id, files_count);
    if (len < 0 || len >= sizeof(buffer)) {
        return -ENOMEM;
    }

    /* Retry with delay for critical transfer_complete notification
     * This ensures Python client knows the session is complete immediately
     */
    do {
        err = ble_svc_send_response(buffer);
        if (err == 0) {
            LOG_INF("Sent transfer_complete event: session=%s, files=%d", session_id, files_count);
            return 0;  /* Success */
        }

        /* Retry on temporary errors */
        if (err == -ENOMEM || err == -EAGAIN || err == -EBUSY || err == -12) {
            retry_count++;
            if (retry_count < max_retries) {
                LOG_DBG("transfer_complete notify failed (err=%d), retrying %d/%d",
                        err, retry_count, max_retries);
                k_sleep(K_MSEC(50));
                continue;
            }
        }

        /* Fatal error or retries exhausted */
        LOG_ERR("transfer_complete notify failed: %d (retries: %d)", err, retry_count);
        return err;

    } while (retry_count < max_retries);

    return err;
}

bool ble_svc_is_ready(void)
{
    /* For small responses, we only need connection and notification enabled.
     * MTU exchange is optional for optimization.
     */
    return (current_conn != NULL && resp_notify_enabled);
}

bool ble_svc_is_bonded(void)
{
    int count = 0;

    bt_foreach_bond(BT_ID_DEFAULT, count_bond_cb, &count);
    return count > 0;
}

void ble_svc_schedule_reboot(uint32_t delay_ms)
{
    k_work_schedule(&reboot_work, K_MSEC(delay_ms));
}

struct bt_conn *ble_svc_get_connection(void)
{
    return current_conn;
}

const char *ble_svc_get_device_name(void)
{
    return device_name;
}

char *ble_svc_get_response_buffer(void)
{
    return response_buffer;
}

size_t ble_svc_get_response_buffer_size(void)
{
    return sizeof(response_buffer);
}

int ble_svc_send_response_buffer(size_t len)
{
    int err;

    if (len == 0 || len > sizeof(response_buffer)) {
        return -EINVAL;
    }

    /* Null-terminate for safety */
    response_buffer[len] = '\0';

    /* Send the response */
    err = ble_svc_send_response(response_buffer);
    return err;
}
