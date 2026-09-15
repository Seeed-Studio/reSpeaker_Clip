/*
 * Copyright (c) 2025 Seeed Technology Co., Ltd.
 *
 * SPDX-License-Identifier: Apache-2.0
 *
 * BLE Transport — Binary frame protocol over File Data characteristic.
 *
 * Uses the same frame types as UDP transport:
 *   FILE_START (0x10): type(1) + fn_len(1) + filename(N) + file_size(4)
 *   DATA      (0x01): type(1) + seq(2) + len(2) + data(N)    — no per-frame CRC (BLE link layer handles it)
 *   FILE_END  (0x11): type(1) + crc32(4)                      — full-file CRC for end-to-end check
 *   TRANSFER_DONE (0x12): type(1) + sid_len(1) + session_id(N) + file_count(4)
 *
 * No ACK needed — BLE link layer guarantees delivery.
 */

#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>
#include <zephyr/sys/crc.h>
#include <string.h>
#include "transport_ble.h"
#include "ble.h"

LOG_MODULE_REGISTER(transport_ble, CONFIG_CLIP_LOG_LEVEL);

/* ---- Frame types (same as UDP) ---- */
#define FRAME_DATA          0x01
#define FRAME_FILE_START    0x10
#define FRAME_FILE_END      0x11
#define FRAME_TRANSFER_DONE 0x12

/* RTC live-stream frames (BLE only; UDP/WiFi streaming is not supported) */
#define FRAME_STREAM_START  0x13  /* type(1) + sid_len(1) + session_id(N) */
#define FRAME_STREAM_DATA   0x14  /* type(1) + seq(2) + len(2) + opus(N) */
#define FRAME_STREAM_END    0x15  /* type(1) + reason(1) */

/* DATA frame header: type(1) + seq(2) + len(2) = 5 bytes (no per-frame CRC for BLE) */
#define BLE_DATA_HEADER_SIZE 5

/* Max data payload per BLE DATA frame (computed from actual negotiated MTU) */
static uint16_t max_data_payload;

/* Sequence counter for RTC STREAM_DATA frames (independent of file seq) */
static uint16_t stream_seq;

/* ---- Per-file state ---- */
static uint16_t next_seq;
static uint32_t current_file_crc;

/* ---- Frame builders ---- */

static int build_data_frame(uint8_t *buf, uint16_t seq,
			    const uint8_t *data, uint16_t data_len)
{
	buf[0] = FRAME_DATA;
	buf[1] = seq & 0xFF;
	buf[2] = (seq >> 8) & 0xFF;
	buf[3] = data_len & 0xFF;
	buf[4] = (data_len >> 8) & 0xFF;
	memcpy(&buf[BLE_DATA_HEADER_SIZE], data, data_len);
	return BLE_DATA_HEADER_SIZE + data_len;
}

static int build_file_start_frame(uint8_t *buf,
				  const char *filename, uint32_t size)
{
	uint8_t fn_len = (uint8_t)strlen(filename);
	if (fn_len > 63) {
		fn_len = 63;
	}

	buf[0] = FRAME_FILE_START;
	buf[1] = fn_len;
	memcpy(&buf[2], filename, fn_len);
	buf[2 + fn_len]     = size & 0xFF;
	buf[2 + fn_len + 1] = (size >> 8) & 0xFF;
	buf[2 + fn_len + 2] = (size >> 16) & 0xFF;
	buf[2 + fn_len + 3] = (size >> 24) & 0xFF;

	return 2 + fn_len + 4;
}

static int build_file_end_frame(uint8_t *buf, uint32_t crc32)
{
	buf[0] = FRAME_FILE_END;
	buf[1] = crc32 & 0xFF;
	buf[2] = (crc32 >> 8) & 0xFF;
	buf[3] = (crc32 >> 16) & 0xFF;
	buf[4] = (crc32 >> 24) & 0xFF;
	return 5;
}

static int build_transfer_done_frame(uint8_t *buf,
				     const char *session_id,
				     uint32_t file_count)
{
	uint8_t sid_len = (uint8_t)strlen(session_id);
	if (sid_len > 63) {
		sid_len = 63;
	}

	buf[0] = FRAME_TRANSFER_DONE;
	buf[1] = sid_len;
	memcpy(&buf[2], session_id, sid_len);
	buf[2 + sid_len]     = file_count & 0xFF;
	buf[2 + sid_len + 1] = (file_count >> 8) & 0xFF;
	buf[2 + sid_len + 2] = (file_count >> 16) & 0xFF;
	buf[2 + sid_len + 3] = (file_count >> 24) & 0xFF;

	return 2 + sid_len + 4;
}

static int build_stream_start_frame(uint8_t *buf, const char *session_id)
{
	uint8_t sid_len = (uint8_t)strlen(session_id);
	if (sid_len > 63) {
		sid_len = 63;
	}

	buf[0] = FRAME_STREAM_START;
	buf[1] = sid_len;
	memcpy(&buf[2], session_id, sid_len);

	return 2 + sid_len;
}

static int build_stream_data_frame(uint8_t *buf, uint16_t seq,
				   const uint8_t *data, uint16_t data_len)
{
	buf[0] = FRAME_STREAM_DATA;
	buf[1] = seq & 0xFF;
	buf[2] = (seq >> 8) & 0xFF;
	buf[3] = data_len & 0xFF;
	buf[4] = (data_len >> 8) & 0xFF;
	memcpy(&buf[BLE_DATA_HEADER_SIZE], data, data_len);

	return BLE_DATA_HEADER_SIZE + data_len;
}

static int build_stream_end_frame(uint8_t *buf, uint8_t reason)
{
	buf[0] = FRAME_STREAM_END;
	buf[1] = reason;
	return 2;
}

/* BLE Transport Context */
static struct {
    struct transport tp;
    transport_event_cb_t event_cb;
    void *user_data;
} ble_ctx = {
    .tp = {
        .type = TRANSPORT_TYPE_BLE,
        .ready = false,
        .conn = NULL,
        .ops = NULL,
    },
};

/* BLE Transport Operations */
static int ble_transport_send(const uint8_t *data, uint16_t len)
{
    return ble_send(data, len);
}

static int ble_transport_send_file_data(const uint8_t *data, uint16_t len)
{
    /* Dynamically compute max payload from negotiated MTU.
     * notify payload = MTU - 3 (ATT header)
     * data payload = notify payload - 5 (frame header) */
    void *conn = ble_get_connection();
    if (conn) {
	uint16_t mtu = ble_get_mtu(conn);
	uint16_t notify_max = (mtu > 3) ? mtu - 3 : 20;
	max_data_payload = (notify_max > BLE_DATA_HEADER_SIZE) ?
			   notify_max - BLE_DATA_HEADER_SIZE : 15;
    }

    /* Slice into BLE-sized DATA frames */
    uint16_t offset = 0;

    while (offset < len) {
	uint16_t chunk = len - offset;
	if (chunk > max_data_payload) {
		chunk = max_data_payload;
	}

	uint8_t frame[BLE_DATA_HEADER_SIZE + 512];
	int frame_len = build_data_frame(frame, next_seq,
					 data + offset, chunk);

	int ret = ble_send_file_data(frame, frame_len);
	if (ret < 0) {
		LOG_WRN("DATA frame send error: %d (seq=%u)", ret, next_seq);
		return ret;
	}

	/* Accumulate file CRC */
	current_file_crc = crc32_ieee_update(current_file_crc,
					      data + offset, chunk);
	next_seq++;
	offset += chunk;
    }

    return len;
}

static bool ble_transport_is_connected(void)
{
    bool conn = ble_is_connected();
    bool notify = ble_is_notify_enabled();
    bool file_data_notify = ble_is_file_data_notify_enabled();

    return conn && notify && file_data_notify;
}

static void *ble_transport_get_conn(void)
{
    return ble_get_connection();
}

static int ble_transport_send_file_start(const char *session_id,
                                          const char *filename, uint32_t size)
{
    ARG_UNUSED(session_id);

    /* Reset per-file state */
    next_seq = 0;
    current_file_crc = 0;

    uint8_t frame[128];
    int frame_len = build_file_start_frame(frame, filename, size);

    LOG_INF("FILE_START: %s (%u bytes)", filename, size);
    return ble_send_file_data(frame, frame_len);
}

static int ble_transport_send_file_end(const char *filename)
{
    ARG_UNUSED(filename);

    uint8_t frame[5];
    int frame_len = build_file_end_frame(frame, current_file_crc);

    LOG_INF("FILE_END: crc=0x%08x", current_file_crc);    return ble_send_file_data(frame, frame_len);
}

static int ble_transport_send_transfer_done(const char *session_id,
                                             uint32_t file_count)
{
    uint8_t frame[128];
    int frame_len = build_transfer_done_frame(frame, session_id, file_count);

    LOG_INF("TRANSFER_DONE: %s (%u files)", session_id, file_count);
    return ble_send_file_data(frame, frame_len);
}

static const struct transport_ops ble_transport_ops = {
    .send = ble_transport_send,
    .send_file_data = ble_transport_send_file_data,
    .send_file_start = ble_transport_send_file_start,
    .send_file_end = ble_transport_send_file_end,
    .send_transfer_done = ble_transport_send_transfer_done,
    .is_connected = ble_transport_is_connected,
    .get_conn = ble_transport_get_conn,
};

/* BLE command callback wrapper */
static int ble_cmd_callback(const uint8_t *data, uint16_t len)
{
    LOG_DBG("BLE received: %u bytes", len);

    /* Notify transport layer */
    if (ble_ctx.event_cb) {
        ble_ctx.event_cb(TRANSPORT_TYPE_BLE, TRANSPORT_EVT_DATA_RECEIVED,
                        data, len, ble_ctx.user_data);
    }

    return 0;
}

/* Initialize BLE transport */
int transport_ble_init(void)
{
    ble_ctx.tp.ops = &ble_transport_ops;
    ble_ctx.tp.ready = false;
    ble_ctx.tp.conn = NULL;

    next_seq = 0;
    current_file_crc = 0;
    max_data_payload = 20;  /* Safe default, updated on first send */

    LOG_INF("BLE transport init (binary frame)");
    return 0;
}

/* Register BLE event callback */
int transport_ble_register_callback(transport_event_cb_t callback)
{
    ble_ctx.tp.event_cb = callback;
    ble_ctx.tp.user_data = &ble_ctx.tp;
    ble_ctx.event_cb = callback;
    ble_ctx.user_data = &ble_ctx.tp;

    /* Register BLE command callback */
    return ble_register_cmd_callback(ble_cmd_callback);
}

/* Update BLE connection status */
void transport_ble_update_connection(void *conn, bool ready)
{
    bool was_ready = ble_ctx.tp.ready;

    ble_ctx.tp.conn = conn;
    ble_ctx.tp.ready = ready;

    if (ready && !was_ready) {
        LOG_INF("BLE transport ready");
        if (ble_ctx.event_cb) {
            ble_ctx.event_cb(TRANSPORT_TYPE_BLE, TRANSPORT_EVT_READY,
                           NULL, 0, ble_ctx.user_data);
        }
    } else if (!ready && was_ready) {
        LOG_INF("BLE transport not ready");
        if (ble_ctx.event_cb) {
            ble_ctx.event_cb(TRANSPORT_TYPE_BLE, TRANSPORT_EVT_NOT_READY,
                           NULL, 0, ble_ctx.user_data);
        }
    }
}

/* Get BLE transport structure */
struct transport *transport_ble_get(void)
{
    return &ble_ctx.tp;
}

/* ========================================================================== */
/* RTC live-stream frames (BLE only)                                          */
/* ========================================================================== */

/* Max notify payload = negotiated MTU - 3 (ATT header). Returns a safe
 * default when no connection is up. */
static uint16_t stream_notify_max(void)
{
    void *conn = ble_get_connection();
    uint16_t mtu = conn ? ble_get_mtu(conn) : 23;

    return (mtu > 3) ? (uint16_t)(mtu - 3) : 20;
}

int transport_ble_send_stream_start(const char *session_id)
{
    uint8_t frame[2 + 63];
    int frame_len = build_stream_start_frame(frame, session_id);

    stream_seq = 0;
    LOG_INF("STREAM_START: %s", session_id);
    return ble_send_stream_data(frame, (uint16_t)frame_len);
}

int transport_ble_send_stream_data(const uint8_t *data, uint16_t len)
{
    /* One Opus frame per STREAM_DATA frame (no slicing). Reject anything
     * that cannot fit in a single notification. */
    uint16_t notify_max = stream_notify_max();

    if ((uint16_t)(BLE_DATA_HEADER_SIZE + len) > notify_max) {
        return -EMSGSIZE;
    }

    uint8_t frame[BLE_DATA_HEADER_SIZE + CONFIG_CLIP_RTC_FRAME_MAX_BYTES];
    int frame_len = build_stream_data_frame(frame, stream_seq, data, len);

    int ret = ble_send_stream_data(frame, (uint16_t)frame_len);
    if (ret == 0) {
        stream_seq++;
    }
    return ret;
}

int transport_ble_send_stream_end(uint8_t reason)
{
    uint8_t frame[2];
    int frame_len = build_stream_end_frame(frame, reason);

    LOG_INF("STREAM_END: reason=%u", reason);
    return ble_send_stream_data(frame, (uint16_t)frame_len);
}
