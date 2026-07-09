/*
 * Copyright (c) 2025 Seeed Technology Co., Ltd.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>
#include <zephyr/sys/reboot.h>
#include <string.h>
#include <stdio.h>
#include <zephyr/settings/settings.h>
#include <hal/nrf_ficr.h>

#include "ble.h"
#include "clip.h"
#include "at_server.h"
#include "transport.h"
#include "transport_ble.h"
#include "transfer.h"
#include "display.h"
#include "config.h"
#include "clip_event.h"

LOG_MODULE_REGISTER(ble, CONFIG_CLIP_LOG_LEVEL);

/* BLE context */
static struct ble_context ble_ctx = {
    .conn = NULL,
    .notify_enabled = false,
    .file_data_notify_enabled = false,
    .audio_vis_notify_enabled = false,
    .device_name = "Clip",
#ifdef CONFIG_CLIP_THROUGHPUT_TEST
    .throughput_notify_enabled = false,
#endif
};

/* Command callback */
static ble_cmd_callback_t cmd_callback = NULL;

/* Response buffer */
static char response_buffer[BLE_RESPONSE_BUFFER_SIZE];

/* Service UUID: 6E400001-B5A3-F393-E0A9-E50E24DCCA9E */
static const struct bt_uuid_128 svc_uuid = BT_UUID_INIT_128(
    BT_UUID_128_ENCODE(0x6E400001, 0xB5A3, 0xF393, 0xE0A9, 0xE50E24DCCA9E));

/* Characteristic UUIDs */
static const struct bt_uuid_128 cmd_recv_uuid = BT_UUID_INIT_128(
    BT_UUID_128_ENCODE(0x6E400002, 0xB5A3, 0xF393, 0xE0A9, 0xE50E24DCCA9E));

static const struct bt_uuid_128 resp_send_uuid = BT_UUID_INIT_128(
    BT_UUID_128_ENCODE(0x6E400003, 0xB5A3, 0xF393, 0xE0A9, 0xE50E24DCCA9E));

/* File Data UUID: 6E400004-B5A3-F393-E0A9-E50E24DCCA9E */
static const struct bt_uuid_128 file_data_uuid = BT_UUID_INIT_128(
    BT_UUID_128_ENCODE(0x6E400004, 0xB5A3, 0xF393, 0xE0A9, 0xE50E24DCCA9E));

/* Audio Visualization UUID: 6E400005-B5A3-F393-E0A9-E50E24DCCA9E */
static const struct bt_uuid_128 audio_vis_uuid = BT_UUID_INIT_128(
    BT_UUID_128_ENCODE(0x6E400005, 0xB5A3, 0xF393, 0xE0A9, 0xE50E24DCCA9E));

#ifdef CONFIG_CLIP_THROUGHPUT_TEST
/* Throughput Test UUID: 6E400006-B5A3-F393-E0A9-E50E24DCCA9E */
static const struct bt_uuid_128 throughput_uuid = BT_UUID_INIT_128(
    BT_UUID_128_ENCODE(0x6E400006, 0xB5A3, 0xF393, 0xE0A9, 0xE50E24DCCA9E));
#endif

/* Advertising data - dynamically built */
static struct bt_data ad[2];
static struct bt_data sd[1];
static uint8_t adv_flags = BT_LE_AD_GENERAL | BT_LE_AD_NO_BREDR;
static uint8_t svc_uuid_bytes[16];

/* Bond count before current connection (for detecting new pairing) */
static int prev_bond_count;

/* Work queue for advertising restart */
static struct k_work adv_work;

/* Track current advertising speed */
static bool is_fast_adv;

/*
 * Active BLE identity. Defaults to BT_ID_DEFAULT (0). AT+PAIR=reset rotates it
 * to a second identity (id 1) with a new random address so iOS (which caches
 * bonds and has no API to remove them) sees a new device and re-pairs fresh.
 * Derived at boot from bt_id_get() (count>1 ⟺ id 1 exists ⟺ rotated).
 */
static uint8_t ble_active_id = BT_ID_DEFAULT;

/* Fast advertising: for initial pairing discovery (100-150ms) */
static const struct bt_le_adv_param adv_param_fast =
    BT_LE_ADV_PARAM_INIT(BT_LE_ADV_OPT_CONN, BT_GAP_ADV_FAST_INT_MIN_1,
                         BT_GAP_ADV_FAST_INT_MAX_1, NULL);

/* "Slow" advertising: ~100-150ms — a middle ground. Connection-friendly
 * (a scanning phone connects within ~1 adv interval) but ~2x slower than
 * the 30-60ms fast bug. 1-2s was too slow to connect reliably. */
static const struct bt_le_adv_param adv_param_slow =
    BT_LE_ADV_PARAM_INIT(BT_LE_ADV_OPT_CONN,
                         BT_GAP_ADV_FAST_INT_MIN_2,
                         BT_GAP_ADV_FAST_INT_MAX_2, NULL);

/* Start advertising on the active identity (copies the const param, sets .id). */
static int ble_adv_start_on_active(const struct bt_le_adv_param *base)
{
    struct bt_le_adv_param p = *base;
    p.id = ble_active_id;
    return bt_le_adv_start(&p, ad, ARRAY_SIZE(ad), sd, ARRAY_SIZE(sd));
}

#define ADV_FAST_TIMEOUT_MS  CONFIG_CLIP_ADV_FAST_TIMEOUT_MS   /* Switch to slow advertising after N ms */
#define BLE_INACTIVITY_TIMEOUT_MS (5 * 60 * 1000)  /* 5 minutes */

static struct k_work_delayable adv_timeout_work;
static struct k_work_delayable inactivity_work;

/* Work for security timeout */
static struct k_work_delayable security_timeout_work;

/* Work for requesting security */
static struct k_work_delayable security_request_work;

/* Work for transfer cancel on disconnect */
static struct k_work transfer_cancel_work;

/* Security request handler - called from work queue */
static void security_request_handler(struct k_work *work)
{
    if (ble_ctx.conn) {
        char addr[BT_ADDR_LE_STR_LEN];
        bt_addr_le_to_str(bt_conn_get_dst(ble_ctx.conn), addr, sizeof(addr));
        LOG_INF("sec req: %s", addr);

        int sec_err = bt_conn_set_security(ble_ctx.conn, BT_SECURITY_L2);
        if (sec_err) {
            LOG_ERR("Security request failed: %d", sec_err);
        } else {
            LOG_INF("sec req sent");
            /* Start 10 second timeout for security establishment */
            k_work_schedule(&security_timeout_work, K_SECONDS(10));
        }
    }
}

/* MTU exchange */
static volatile bool mtu_exchanged;
static struct k_work_delayable mtu_work;

/* MTU exchange callback */
static void mtu_exchange_cb(struct bt_conn *conn, uint8_t err,
                            struct bt_gatt_exchange_params *params)
{
    if (!err) {
        mtu_exchanged = true;
        LOG_DBG("MTU: %u", bt_gatt_get_mtu(conn));
    } else {
        LOG_WRN("MTU fail: %d", err);
        mtu_exchanged = true;
    }
}

/* MTU exchange params */
static struct bt_gatt_exchange_params mtu_params = {
    .func = mtu_exchange_cb,
};

/* Delayed MTU exchange handler */
static void mtu_work_handler(struct k_work *work)
{
    if (ble_ctx.conn) {
        bt_gatt_exchange_mtu(ble_ctx.conn, &mtu_params);
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

/* LE parameters updated callback */
static void le_param_updated(struct bt_conn *conn, uint16_t interval,
                             uint16_t latency, uint16_t timeout)
{
    if (!mtu_exchanged && ble_ctx.conn == conn) {
        bt_gatt_exchange_mtu(conn, &mtu_params);
        /* After MTU exchange, request faster connection parameters */
        /* Coexistence-friendly params: moderate interval + long supervision
         * timeout (8s) so a WiFi-AP cold start (~8s) doesn't supervise the
         * BLE link out. Was interval=6/timeout=500 -> disconnects on WiFi-on. */
        struct bt_le_conn_param fast_params = {
            .interval_min = 15,
            .interval_max = 30,
            .latency = 0,
            .timeout = 800,
        };
        bt_conn_le_param_update(conn, &fast_params);
    }
}

/* Reject connection parameters that are too aggressive */
static bool le_param_req(struct bt_conn *conn, struct bt_le_conn_param *param)
{
    /* Require a coexistence-friendly minimum so WiFi AP bring-up (~5-8s,
     * monopolizes the radio) can't supervise the link out. */
    if (param->timeout < 800) {
        LOG_WRN("Clamping conn params: timeout %u", param->timeout);
        param->timeout = 800;
        param->interval_min = 30;
        param->interval_max = 50;
        param->latency = 0;
        return true; /* accept the clamped counter-proposal (false = reject) */
    }

    LOG_DBG("accept: int=%u-%u lat=%u to=%u",
            param->interval_min, param->interval_max, param->latency, param->timeout);
    return true;
}

/* Security timeout handler */
static void security_timeout_handler(struct k_work *work)
{
    if (ble_ctx.conn) {
        char addr[BT_ADDR_LE_STR_LEN];
        bt_addr_le_to_str(bt_conn_get_dst(ble_ctx.conn), addr, sizeof(addr));
        LOG_WRN("sec timeout: %s", addr);
        bt_conn_disconnect(ble_ctx.conn, BT_HCI_ERR_AUTH_FAIL);
    }
}

/* Forward declarations */
static ssize_t cmd_recv_write(struct bt_conn *conn,
                              const struct bt_gatt_attr *attr,
                              const void *buf, uint16_t len,
                              uint16_t offset, uint8_t flags);
static void resp_ccc_cfg_changed(const struct bt_gatt_attr *attr, uint16_t value);
static void file_data_ccc_cfg_changed(const struct bt_gatt_attr *attr, uint16_t value);
static void audio_vis_ccc_cfg_changed(const struct bt_gatt_attr *attr, uint16_t value);
#ifdef CONFIG_CLIP_THROUGHPUT_TEST
static void throughput_ccc_cfg_changed(const struct bt_gatt_attr *attr, uint16_t value);
#endif

/* GATT service definition */
BT_GATT_SERVICE_DEFINE(clip_svc,
    /* Primary Service */
    BT_GATT_PRIMARY_SERVICE(&svc_uuid.uuid),

    /* Command Receive Characteristic (Write) */
    BT_GATT_CHARACTERISTIC(&cmd_recv_uuid.uuid,
                           BT_GATT_CHRC_WRITE_WITHOUT_RESP,
                           BT_GATT_PERM_WRITE_ENCRYPT,
                           NULL, cmd_recv_write, NULL),

    /* Response Send Characteristic (Notify) */
    BT_GATT_CHARACTERISTIC(&resp_send_uuid.uuid,
                           BT_GATT_CHRC_NOTIFY,
                           BT_GATT_PERM_READ,
                           NULL, NULL, NULL),
    BT_GATT_CCC(resp_ccc_cfg_changed,
                BT_GATT_PERM_READ | BT_GATT_PERM_WRITE_ENCRYPT),

    /* File Data Characteristic (Notify) */
    BT_GATT_CHARACTERISTIC(&file_data_uuid.uuid,
                           BT_GATT_CHRC_NOTIFY,
                           BT_GATT_PERM_READ,
                           NULL, NULL, NULL),
    BT_GATT_CCC(file_data_ccc_cfg_changed,
                BT_GATT_PERM_READ | BT_GATT_PERM_WRITE_ENCRYPT),

    /* Audio Visualization Characteristic (Notify) */
    BT_GATT_CHARACTERISTIC(&audio_vis_uuid.uuid,
                           BT_GATT_CHRC_NOTIFY,
                           BT_GATT_PERM_READ,
                           NULL, NULL, NULL),
    BT_GATT_CCC(audio_vis_ccc_cfg_changed,
                BT_GATT_PERM_READ | BT_GATT_PERM_WRITE_ENCRYPT),
#ifdef CONFIG_CLIP_THROUGHPUT_TEST
    /* Throughput Test Characteristic (Notify) — value at attrs[13] */
    BT_GATT_CHARACTERISTIC(&throughput_uuid.uuid,
                           BT_GATT_CHRC_NOTIFY,
                           BT_GATT_PERM_READ,
                           NULL, NULL, NULL),
    BT_GATT_CCC(throughput_ccc_cfg_changed,
                BT_GATT_PERM_READ | BT_GATT_PERM_WRITE_ENCRYPT),
#endif
);

/* CCC callback */
static void resp_ccc_cfg_changed(const struct bt_gatt_attr *attr, uint16_t value)
{
    ble_ctx.notify_enabled = (value & BT_GATT_CCC_NOTIFY);
    LOG_DBG("Notify: %d", ble_ctx.notify_enabled);

    /* Update transport when connection and notification are both ready */
    if (ble_ctx.notify_enabled && ble_ctx.conn) {
        transport_ble_update_connection(ble_ctx.conn, true);
        LOG_DBG("BLE transport: connection and notification ready");
    } else if (!ble_ctx.notify_enabled && ble_ctx.conn) {
        /* Notification disabled - clear transport */
        transport_ble_update_connection(ble_ctx.conn, false);
        LOG_DBG("BLE transport: notification disabled");
    }
    /* Note: if CCC is written before connection, transport will be set in connected() callback */
}

static void file_data_ccc_cfg_changed(const struct bt_gatt_attr *attr, uint16_t value)
{
    ble_ctx.file_data_notify_enabled = (value & BT_GATT_CCC_NOTIFY);
    LOG_DBG("File data notify: %d", ble_ctx.file_data_notify_enabled);
}

static void audio_vis_ccc_cfg_changed(const struct bt_gatt_attr *attr, uint16_t value)
{
    ble_ctx.audio_vis_notify_enabled = (value & BT_GATT_CCC_NOTIFY);
    LOG_DBG("Audio vis notify: %d", ble_ctx.audio_vis_notify_enabled);
}

#ifdef CONFIG_CLIP_THROUGHPUT_TEST
static void throughput_ccc_cfg_changed(const struct bt_gatt_attr *attr, uint16_t value)
{
    ble_ctx.throughput_notify_enabled = (value & BT_GATT_CCC_NOTIFY);
    LOG_DBG("Throughput notify: %d", ble_ctx.throughput_notify_enabled);
}
#endif

/* Generate device name from FICR device ID */
static void generate_device_name(void)
{
    uint32_t device_id_low = nrf_ficr_deviceid_get(NRF_FICR, 0);
    uint16_t id_suffix = device_id_low & 0xFFFF;
    snprintf(ble_ctx.device_name, sizeof(ble_ctx.device_name),
             "Clip %04X", id_suffix);
    LOG_INF("Device name: %s", ble_ctx.device_name);
}

/* Advertising fast→slow timeout handler */
static void adv_timeout_handler(struct k_work *work)
{
	/* Skip if already connected (no advertising active) */
	if (ble_is_connected()) {
		return;
	}

	/* Drop to slow advertising when idle — applies to bonded AND unbonded.
	 * Slow adv is still discoverable/connitable (just ~1-2s to find vs
	 * instant); staying fast forever wastes too much idle current. */
	enum clip_state state = clip_event_get_state();
	if (state != CLIP_STATE_IDLE) {
		k_work_reschedule(&adv_timeout_work, K_MSEC(ADV_FAST_TIMEOUT_MS));
		return;
	}

	LOG_INF("slow adv");
	is_fast_adv = false;
	bt_le_adv_stop();
	int err = ble_adv_start_on_active(&adv_param_slow);
	if (err && err != -EALREADY) {
		LOG_ERR("Slow advertising start failed: %d", err);
	}
}

/* BLE inactivity timeout handler - disconnect after 5 minutes idle */
static void inactivity_timeout_handler(struct k_work *work)
{
	if (ble_ctx.conn) {
		LOG_INF("BLE inactivity, disconnecting");
		bt_conn_disconnect(ble_ctx.conn,
				   BT_HCI_ERR_REMOTE_USER_TERM_CONN);
	}
}

/* Advertising restart handler */
static void adv_work_handler(struct k_work *work)
{
	int err;
	const struct bt_le_adv_param *param = ble_is_bonded()
		? &adv_param_slow : &adv_param_fast;

	err = ble_adv_start_on_active(param);
	if (err && err != -EALREADY) {
		LOG_ERR("Advertising restart failed: %d", err);
	} else {
		/* Schedule switch to slow advertising after timeout */
		k_work_reschedule(&adv_timeout_work,
				  K_MSEC(ADV_FAST_TIMEOUT_MS));
		is_fast_adv = true;
	}
}

/* Bond count callback for checking existing bonds */
static void count_bond_cb(const struct bt_bond_info *info, void *user_data)
{
    int *count = (int *)user_data;
    (*count)++;
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
    ble_ctx.conn = bt_conn_ref(conn);
    mtu_exchanged = false;

    /* Update transport layer with new connection */
    /* Check if CCC was already written (it might have been written before connection callback) */
    if (ble_ctx.notify_enabled) {
        /* CCC already enabled - set transport as ready */
        transport_ble_update_connection(conn, true);
        LOG_INF("BLE transport ready (CCC pre-enabled)");
    } else {
        /* CCC not yet written - set transport but not ready */
        transport_ble_update_connection(conn, false);
        LOG_DBG("BLE transport: waiting for CCC");
    }

    /* Check whether this is a known bonded device or a new one */
    int bond_count = 0;
    bt_foreach_bond(ble_active_id, count_bond_cb, &bond_count);
    prev_bond_count = bond_count;

    if (bond_count > 0) {
        LOG_INF("conn: %s (bonded)", addr);
        /* Already bonded: notify display immediately (no pairing_complete
         * callback will fire for re-encryption of an existing bond). */
        display_post_event(UI_EVENT_BONDED);
    } else {
        LOG_INF("conn: %s (new)", addr);
    }

    ble_notify_event("ble", "connected");

    /* Immediately require encryption. If no bond exists, this triggers
     * SMP pairing. If a bond exists, it triggers re-encryption with
     * the stored LTK. Devices that refuse will be disconnected in
     * security_changed().
     * Use work queue to avoid blocking in the connection callback.
     */
    k_work_schedule(&security_request_work, K_NO_WAIT);

    /* Delay MTU exchange until after security is established */
    k_work_schedule(&mtu_work, K_MSEC(1000));

    /* Start BLE inactivity timeout */
    k_work_reschedule(&inactivity_work,
		      K_MSEC(BLE_INACTIVITY_TIMEOUT_MS));
}

static void disconnected(struct bt_conn *conn, uint8_t reason)
{
    if (ble_ctx.conn == conn) {
        char addr[BT_ADDR_LE_STR_LEN];

        bt_addr_le_to_str(bt_conn_get_dst(conn), addr, sizeof(addr));
        bt_conn_unref(ble_ctx.conn);
        ble_ctx.conn = NULL;
        ble_ctx.notify_enabled = false;
        ble_ctx.file_data_notify_enabled = false;
        ble_ctx.audio_vis_notify_enabled = false;

        /* Cancel security timeout */
        k_work_cancel_delayable(&security_timeout_work);
        k_work_cancel_delayable(&inactivity_work);
        k_work_cancel_delayable(&adv_timeout_work);

        LOG_INF("disc: %s r=0x%02x", addr, reason);

        /* Clear transport layer */
        transport_ble_update_connection(NULL, false);

        /* Notify display that BLE disconnected */
        display_post_event(UI_EVENT_BLE_DISCONNECTED);

        /* Cancel OTA if in progress */
        clip_event_ota_cancel();

        ble_notify_event("ble", "disconnected");

        /* Clean up any ongoing transfer via work queue to avoid stack overflow
         * in BLE RX thread context (transfer_cancel -> storage_set_synced_files
         * requires significant stack space)
         */
        if (transfer_is_active()) {
            k_work_submit(&transfer_cancel_work);
        }

        /* Restart advertising via work queue */
        k_work_submit(&adv_work);
    }
}

/* Disconnect any connection that did not reach encryption level 2 */
static void security_changed(struct bt_conn *conn, bt_security_t level,
                             enum bt_security_err err)
{
    char addr[BT_ADDR_LE_STR_LEN];

    bt_addr_le_to_str(bt_conn_get_dst(conn), addr, sizeof(addr));

    /* Cancel security timeout */
    k_work_cancel_delayable(&security_timeout_work);

    LOG_INF("sec: %s lv=%d err=%d", addr, level, err);

    if (err == BT_SECURITY_ERR_PIN_OR_KEY_MISSING) {
        /* Remote has a stale bond key that we no longer have locally.
         * Do NOT call bt_unpair() here - local bond is already absent,
         * calling it would erase any *other* valid local bonds.
         * Just disconnect; the phone will re-pair on the next connection.
         */
        LOG_WRN("stale bond: %s", addr);
        bt_conn_disconnect(conn, BT_HCI_ERR_PIN_OR_KEY_MISSING);
        return;
    }

    if (err == BT_SECURITY_ERR_AUTH_REQUIREMENT) {
        /* Re-encryption failed. This typically happens when:
         * - The phone deleted the bond but we still have it locally
         * - We try to re-encrypt using the old key, but the phone rejects it
         * Solution: Delete our stale bond and allow re-pairing
         */
        LOG_WRN("re-enc fail: %s", addr);
        int unpair_err = bt_unpair(ble_active_id, bt_conn_get_dst(conn));
        if (unpair_err) {
            LOG_WRN("bt_unpair failed: %d", unpair_err);
        }
        bt_conn_disconnect(conn, BT_HCI_ERR_AUTH_FAIL);
        return;
    }

    if (err) {
        LOG_WRN("sec fail: %s lv=%d err=%d",
                addr, level, err);
        bt_conn_disconnect(conn, BT_HCI_ERR_AUTH_FAIL);
        return;
    }

    if (level < BT_SECURITY_L2) {
        LOG_WRN("sec low: %s lv=%d",
                addr, level);
        bt_conn_disconnect(conn, BT_HCI_ERR_AUTH_FAIL);
        return;
    }

    LOG_INF("sec ok: %s lv=%d", addr, level);
}

/* Auto-confirm Just Works pairing */
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

/* Pairing info callbacks */
static void pairing_complete(struct bt_conn *conn, bool bonded)
{
    char addr[BT_ADDR_LE_STR_LEN];

    bt_addr_le_to_str(bt_conn_get_dst(conn), addr, sizeof(addr));
    LOG_INF("paired: %s b=%d", addr, bonded);

    if (bonded) {
        LOG_INF("saving bond keys");
        int err = settings_save();
        if (err) {
            LOG_WRN("settings_save after pairing failed: %d", err);
        } else {
            LOG_INF("keys saved");
        }

        /* Check if this is a new device (bond count increased) */
        int new_bond_count = 0;
        bt_foreach_bond(ble_active_id, count_bond_cb, &new_bond_count);
        if (new_bond_count != prev_bond_count) {
            LOG_INF("new device, regen WiFi pw");
            config_generate_wifi_password();
        }

        display_post_event(UI_EVENT_BONDED);
    }
}

static void pairing_failed(struct bt_conn *conn, enum bt_security_err reason)
{
    char addr[BT_ADDR_LE_STR_LEN];

    bt_addr_le_to_str(bt_conn_get_dst(conn), addr, sizeof(addr));
    LOG_WRN("pair fail: %s r=%d", addr, reason);
    bt_conn_disconnect(conn, BT_HCI_ERR_AUTH_FAIL);
}

static struct bt_conn_auth_info_cb auth_info_callbacks = {
    .pairing_complete = pairing_complete,
    .pairing_failed = pairing_failed,
};

static struct bt_conn_cb conn_callbacks = {
    .connected = connected,
    .disconnected = disconnected,
    .le_param_updated = le_param_updated,
    .le_param_req = le_param_req,
    .security_changed = security_changed,
};

/* Write callback for command receive */
static ssize_t cmd_recv_write(struct bt_conn *conn,
                              const struct bt_gatt_attr *attr,
                              const void *buf, uint16_t len,
                              uint16_t offset, uint8_t flags)
{
    ARG_UNUSED(conn);
    ARG_UNUSED(attr);
    ARG_UNUSED(flags);

    /* Ignore offset for now */
    if (offset != 0) {
        LOG_WRN("Unexpected offset: %u", offset);
    }

    /* Validate length */
    if (len == 0 || len >= 256) {
        LOG_WRN("Invalid command length: %u", len);
        return BT_GATT_ERR(BT_ATT_ERR_INVALID_PDU);
    }

    /* Submit to AT server queue */
    int ret = at_server_submit_cmd(buf, len, TRANSPORT_TYPE_BLE);
    if (ret != 0) {
        LOG_WRN("AT server submit failed: %d", ret);
        return BT_GATT_ERR(BT_ATT_ERR_INSUFFICIENT_RESOURCES);
    }

    /* Refresh BLE inactivity timeout on activity */
    ble_activity_refresh();

    return len;
}

/* Public API implementation */
int ble_init(void)
{
    int err;

    /* Generate device name */
    generate_device_name();

    /* Set GAP device name (shown after connection) */
    err = bt_set_name(ble_ctx.device_name);
    if (err) {
        LOG_ERR("bt_set_device_name failed: %d", err);
        return err;
    }

    /* Build advertising data dynamically */
    adv_flags = BT_LE_AD_GENERAL | BT_LE_AD_NO_BREDR;
    ad[0].type = BT_DATA_FLAGS;
    ad[0].data_len = sizeof(adv_flags);
    ad[0].data = &adv_flags;

    ad[1].type = BT_DATA_NAME_COMPLETE;
    ad[1].data_len = strlen(ble_ctx.device_name);
    ad[1].data = (uint8_t *)ble_ctx.device_name;

    /* Build scan response data with service UUID */
    bt_uuid_to_str(&svc_uuid.uuid, (char *)svc_uuid_bytes, sizeof(svc_uuid_bytes));
    sd[0].type = BT_DATA_UUID128_ALL;
    sd[0].data_len = sizeof(svc_uuid_bytes);
    sd[0].data = svc_uuid_bytes;

    /* Initialize work queues */
    k_work_init(&adv_work, adv_work_handler);
    k_work_init_delayable(&security_timeout_work, security_timeout_handler);
    k_work_init_delayable(&security_request_work, security_request_handler);
    k_work_init_delayable(&mtu_work, mtu_work_handler);
    k_work_init(&transfer_cancel_work, transfer_cancel_work_handler);
    k_work_init_delayable(&adv_timeout_work, adv_timeout_handler);
    k_work_init_delayable(&inactivity_work, inactivity_timeout_handler);

    /* Register connection callbacks */
    bt_conn_cb_register(&conn_callbacks);

    /* Register pairing/authentication callbacks */
    bt_conn_auth_cb_register(&auth_callbacks);
    bt_conn_auth_info_cb_register(&auth_info_callbacks);

    /* Enable Bluetooth */
    err = bt_enable(NULL);
    if (err) {
        LOG_ERR("bt_enable: %d", err);
        return err;
    }

    /* Load BT settings (bond keys). Guard with the watchdog: a corrupt
     * settings file (e.g. from repeated pair/unpair) blocks ~40s. */
    settings_load_watchdog_arm();
    settings_load_subtree("bt");
    settings_load_watchdog_disarm();

    /* Derive the active identity: if a rotated identity (id 1) exists from a
     * prior AT+PAIR=reset, advertise/bond on it (new address). */
    {
        bt_addr_le_t ids[CONFIG_BT_ID_MAX];
        size_t id_count = ARRAY_SIZE(ids);

        bt_id_get(ids, &id_count);
        ble_active_id = (id_count > 1) ? 1 : BT_ID_DEFAULT;
        LOG_INF("active identity: %u (id_count=%u)", ble_active_id, (unsigned)id_count);
    }

    /* If not bonded, switch display to pairing guide */
    if (!ble_is_bonded()) {
        display_post_event(UI_EVENT_PAIRING_SHOW);
    }

    /* Start advertising - always fast initially */
    err = ble_adv_start_on_active(&adv_param_fast);
    if (err) {
        if (err != -EALREADY) {
            LOG_ERR("Advertising start failed: %d", err);
        }
    }

    /* Schedule switch to slow advertising (stays fast if unbonded) */
    k_work_schedule(&adv_timeout_work, K_MSEC(ADV_FAST_TIMEOUT_MS));
    is_fast_adv = true;

    LOG_INF("BLE ready, device: %s", ble_ctx.device_name);

    return 0;
}

int ble_register_cmd_callback(ble_cmd_callback_t callback)
{
    if (callback) {
        cmd_callback = callback;
        return 0;
    }
    return -EINVAL;
}

int ble_send(const uint8_t *data, uint16_t len)
{
    int err;
    uint16_t max_len;
    size_t offset = 0;
    int chunk_count = 0;

    if (!ble_ctx.conn || !ble_ctx.notify_enabled) {
        return -ENOTCONN;
    }

    /* Refresh inactivity timeout on outgoing data */
    ble_activity_refresh();

    /* MTU - 3 bytes ATT header = max notify payload */
    max_len = bt_gatt_get_mtu(ble_ctx.conn) - 3;

    /* Split into chunks if needed */
    while (offset < len)
    {
        size_t chunk_len = len - offset;
        if (chunk_len > max_len) {
            chunk_len = max_len;
        }

        /* Response Send characteristic value is at attrs[4] */
        err = bt_gatt_notify(ble_ctx.conn, &clip_svc.attrs[4],
                             data + offset, chunk_len);
        if (err) {
            LOG_ERR("Notify failed at chunk %d (offset %u): %d",
                    chunk_count, (uint32_t)offset, err);
            return err;
        }

        chunk_count++;
        offset += chunk_len;

        /* Small delay between chunks to allow controller to process */
        if (offset < len) {
            k_yield();
        }
    }

    LOG_DBG("Sent %d chunks, total %u bytes", chunk_count, (uint32_t)len);

    return 0;
}

int ble_notify_state_change(const char *state, const char *session_id, int duration)
{
    char buf[128];
    int len;

    if (!ble_ctx.conn || !ble_ctx.notify_enabled) {
        return -ENOTCONN;
    }

    if (duration >= 0) {
        len = snprintf(buf, sizeof(buf),
                       "{\"event\":\"state\",\"state\":\"%s\","
                       "\"session\":\"%s\",\"duration\":%d}",
                       state, session_id, duration);
    } else {
        len = snprintf(buf, sizeof(buf),
                       "{\"event\":\"state\",\"state\":\"%s\","
                       "\"session\":\"%s\"}",
                       state, session_id);
    }

    LOG_INF("Event: state=%s session=%s duration=%d", state, session_id, duration);
    return ble_send(buf, len);
}

int ble_notify_mark(const char *session_id, int mark_count)
{
    char buf[96];
    int len;

    if (!ble_ctx.conn || !ble_ctx.notify_enabled) {
        return -ENOTCONN;
    }

    len = snprintf(buf, sizeof(buf),
                   "{\"event\":\"mark\",\"session\":\"%s\","
                   "\"mark_count\":%d}",
                   session_id, mark_count);

    LOG_INF("Event: mark session=%s count=%d", session_id, mark_count);
    return ble_send(buf, len);
}

int ble_notify_event(const char *name, const char *status)
{
    char buf[96];
    int len;

    if (!ble_ctx.conn || !ble_ctx.notify_enabled) {
        return -ENOTCONN;
    }

    len = snprintf(buf, sizeof(buf),
                   "{\"event\":\"%s\",\"status\":\"%s\"}",
                   name, status);

    LOG_INF("Event: %s=%s", name, status);
    return ble_send(buf, len);
}

int ble_send_file_data(const uint8_t *data, uint16_t len)
{
    int err;
    int retry_count = 0;
    const int max_retries = 3;
    static uint32_t total_sent = 0;
    static int64_t last_log_time = 0;

    if (!ble_ctx.conn) {
        LOG_ERR("BLE file: no conn");
        return -ENOTCONN;
    }
    if (!ble_ctx.file_data_notify_enabled) {
        LOG_ERR("BLE file: notify off");
        return -ENOTCONN;
    }

    /* Refresh inactivity timeout on outgoing file data */
    ble_activity_refresh();

    /* Log progress every 100KB */
    total_sent += len;
    int64_t now = k_uptime_get();
    if (now - last_log_time >= 1000) {  /* Every 1 second */
        LOG_INF("BLE sending: %u KB total", total_sent / 1024);
        last_log_time = now;
    }

    /* Send as a single notification — protocol frames must not be split */
    retry_count = 0;
    do
    {
        /* File Data characteristic value is at attrs[7] */
        err = bt_gatt_notify(ble_ctx.conn, &clip_svc.attrs[7],
                             data, len);

        if (err == 0) {
            /* Yield to let higher-priority audio thread run */
            k_yield();
            break; /* Success */
        }

        /* Retry on temporary errors */
        if (err == -ENOMEM || err == -EAGAIN || err == -EBUSY) {
            retry_count++;
            if (retry_count < max_retries) {
                LOG_WRN("File notify failed (len=%u, err=%d), retrying %d/%d",
                        len, err, retry_count, max_retries);
                continue;
            }
        }

        /* Fatal error or retries exhausted */
        LOG_ERR("File notify failed: %d (retries: %d)", err, retry_count);
        return err;

    } while (retry_count < max_retries);

    return 0;
}

bool ble_is_connected(void)
{
    return ble_ctx.conn != NULL;
}

bool ble_is_notify_enabled(void)
{
    return ble_ctx.notify_enabled;
}

bool ble_is_file_data_notify_enabled(void)
{
    return ble_ctx.file_data_notify_enabled;
}

bool ble_is_bonded(void)
{
    int bond_count = 0;
    bt_foreach_bond(ble_active_id, count_bond_cb, &bond_count);
    return bond_count > 0;
}

bool ble_is_audio_vis_subscribed(void)
{
    return ble_ctx.audio_vis_notify_enabled;
}

#ifdef CONFIG_CLIP_THROUGHPUT_TEST
bool ble_is_throughput_subscribed(void)
{
    return ble_ctx.throughput_notify_enabled;
}

int ble_run_throughput(uint32_t dur_sec, uint32_t *out_kbps)
{
    static uint8_t payload[512];

    if (!ble_ctx.conn || !ble_ctx.throughput_notify_enabled) {
        return -ENOTCONN;
    }

    /* Notify payload = ATT_MTU - 3 (1 opcode + 2 handle) */
    uint16_t mtu = bt_gatt_get_mtu(ble_ctx.conn);
    uint16_t len = (mtu > 3) ? (mtu - 3) : 20;
    if (len > sizeof(payload)) {
        len = sizeof(payload);
    }
    memset(payload, 0xA5, sizeof(payload));

    ble_activity_refresh();
    int64_t start = k_uptime_get();
    int64_t deadline = start + (int64_t)dur_sec * 1000;
    uint32_t bytes = 0;

    while (k_uptime_get() < deadline) {
        /* Throughput characteristic value is at attrs[13] */
        int err = bt_gatt_notify(ble_ctx.conn, &clip_svc.attrs[13], payload, len);
        if (err == 0) {
            bytes += len;
        } else if (err == -ENOMEM || err == -EAGAIN || err == -EBUSY) {
            /* TX buffers full: sleep briefly so the BLE host thread can
             * drain (k_yield busy-loops and can starve the BLE thread,
             * risking a supervision-timeout disconnect). */
            k_msleep(1);
        } else {
            LOG_WRN("throughput notify err: %d", err);
            return err;
        }
        ble_activity_refresh();
    }

    uint32_t elapsed_ms = (uint32_t)(k_uptime_get() - start);
    *out_kbps = (elapsed_ms > 0) ? (uint32_t)((uint64_t)bytes * 8U / elapsed_ms) : 0;
    LOG_INF("BLE throughput: %u kbps (%u B in %u ms)", *out_kbps, bytes, elapsed_ms);
    return 0;
}

int ble_send_throughput(const char *data, uint16_t len)
{
    if (!ble_ctx.conn || !ble_ctx.throughput_notify_enabled) {
        return -ENOTCONN;
    }

    int err;
    int retries = 0;

    do {
        /* Throughput characteristic value is at attrs[13] */
        err = bt_gatt_notify(ble_ctx.conn, &clip_svc.attrs[13], data, len);
        if (err == 0) {
            return 0;
        }
        if (err == -ENOMEM || err == -EAGAIN || err == -EBUSY) {
            if (retries++ < 10) {
                k_msleep(5);
                continue;
            }
        }
        LOG_WRN("throughput result notify err: %d", err);
        return err;
    } while (retries < 10);

    return err;
}
#endif

static void get_bond_addr_cb(const struct bt_bond_info *info, void *user_data)
{
    char *buf = (char *)user_data;
    if (buf[0] == '\0') {
        bt_addr_le_to_str(&info->addr, buf, 18);
    }
}

int ble_get_bond_addr(char *addr_buf, size_t len)
{
    if (len < 18) {
        return -EINVAL;
    }
    addr_buf[0] = '\0';
    bt_foreach_bond(ble_active_id, get_bond_addr_cb, addr_buf);
    return addr_buf[0] ? 0 : -ENOENT;
}

int ble_clear_bonds(void)
{
    /* Clear bonds on both the default and the active (rotated) identity so the
     * old bond is removed on the first rotation too. */
    int err = bt_unpair(BT_ID_DEFAULT, NULL);
    if (ble_active_id != BT_ID_DEFAULT) {
        int err2 = bt_unpair(ble_active_id, NULL);
        if (err == 0) {
            err = err2;
        }
    }
    return err;
}

int ble_rotate_identity(void)
{
    /* Rotate the BLE identity address so a peer that caches a stale bond
     * (notably iOS, which has no API to remove bonds) sees a new device and
     * re-pairs fresh. The first call creates a second identity (id 1); later
     * calls reset id 1 to a new random address. The address persists across
     * reboots via settings; ble_init() re-derives ble_active_id from it. */
    int id;
    if (ble_active_id == BT_ID_DEFAULT) {
        id = bt_id_create(NULL, NULL);
        if (id < 0) {
            LOG_ERR("bt_id_create failed: %d", id);
            return id;
        }
        ble_active_id = (uint8_t)id;
    } else {
        int err = bt_id_reset(ble_active_id, NULL, NULL);
        if (err) {
            LOG_ERR("bt_id_reset failed: %d", err);
            return err;
        }
    }
    LOG_INF("identity rotated: active_id=%u", ble_active_id);
    return 0;
}

struct bt_conn *ble_get_connection(void)
{
    return ble_ctx.conn;
}

uint16_t ble_get_mtu(struct bt_conn *conn)
{
    if (!conn) {
        return 23;  /* Default BLE ATT MTU */
    }
    return bt_gatt_get_mtu(conn);
}

const char *ble_get_device_name(void)
{
    return ble_ctx.device_name;
}

char *ble_get_response_buffer(void)
{
    return response_buffer;
}

size_t ble_get_response_buffer_size(void)
{
    return sizeof(response_buffer);
}

int ble_send_response_buffer(size_t len)
{
    if (len == 0 || len > sizeof(response_buffer)) {
        return -EINVAL;
    }

    /* Null-terminate for safety */
    response_buffer[len] = '\0';

    return ble_send((uint8_t *)response_buffer, len);
}

int ble_send_audio_vis(const uint8_t *data, uint16_t len)
{
    int err;
    uint16_t max_len;

    if (!ble_ctx.conn) {
        return -ENOTCONN;
    }
    if (!ble_ctx.audio_vis_notify_enabled) {
        return -ENOTCONN;
    }

    /* Refresh inactivity timeout on outgoing audio vis data */
    ble_activity_refresh();

    /* MTU - 3 bytes ATT header = max notify payload */
    max_len = bt_gatt_get_mtu(ble_ctx.conn) - 3;

    if (len > max_len) {
        len = max_len;
    }

    /* Audio Visualization characteristic value is at attrs[10] */
    err = bt_gatt_notify(ble_ctx.conn, &clip_svc.attrs[10], data, len);
    if (err) {
        return err;
    }

    return 0;
}

void ble_adv_restart_fast(void)
{
    if (ble_is_connected()) {
	return;
    }

    /* If already fast advertising, just extend the timeout */
    if (is_fast_adv) {
	k_work_reschedule(&adv_timeout_work, K_MSEC(ADV_FAST_TIMEOUT_MS));
	LOG_INF("fast adv (extend)");
	return;
    }

    bt_le_adv_stop();
    int err = ble_adv_start_on_active(&adv_param_fast);
    if (err && err != -EALREADY) {
	LOG_ERR("Fast advertising restart failed: %d", err);
    } else {
	LOG_INF("fast adv (button)");
	is_fast_adv = true;
    }

    /* Re-schedule switch to slow advertising */
    k_work_reschedule(&adv_timeout_work, K_MSEC(ADV_FAST_TIMEOUT_MS));
}

void ble_activity_refresh(void)
{
    if (ble_ctx.conn) {
	k_work_reschedule(&inactivity_work,
			  K_MSEC(BLE_INACTIVITY_TIMEOUT_MS));
    }
}
