/*
 * Copyright (c) 2025 Seeed Technology Co., Ltd.
 *
 * SPDX-License-Identifier: Apache-2.0
 *
 * UDP Transport — Fire-and-forget DATA frames with per-file CRC32 verification.
 *
 * Protocol: see docs/udp_protocol.md
 *
 * Memory usage: ~100 bytes static state. No frame buffering.
 */

#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>
#include <zephyr/fs/fs.h>
#include <zephyr/net/socket.h>
#include <zephyr/net/net_ip.h>
#include <zephyr/sys/crc.h>
#include <string.h>
#include <errno.h>
#include "transport.h"
#include "transport_udp.h"
#include "wifi_udp.h"

LOG_MODULE_REGISTER(transport_udp, LOG_LEVEL_WRN); /* chatty plumbing logs */

/* Shared socket from wifi_udp.c */
extern int server_sock;

/* ---- Configuration ---- */
#define MAX_FRAME_SIZE       (UDP_DATA_HEADER_SIZE + UDP_MAX_DATA_PER_FRAME)
#define FILE_ACK_TIMEOUT     2000  /* ms to wait for FILE_ACK after FILE_END */
#define NACK_BITMAP_MAX_BYTES  512  /* 4096 seqs / 8; covers a full 4 MB file */
#define FILE_END_RETRIES     3     /* max FILE_END retransmissions before abort */

/* ---- State ---- */
static struct k_mutex udp_mutex;
static volatile bool udp_ready;
static struct sockaddr_in udp_client_addr;
static socklen_t udp_client_len;

/* Sequence tracking (for frame identification, not ACK) */
static uint16_t next_seq;

/* FILE_ACK signaling: recv thread notifies via notify_file_ack() */
static struct k_sem file_ack_sem;
static volatile int8_t file_ack_result;  /* -1=none, 0=OK, 1=NACK */

/* Selective-repeat: missing-seq bitmap from the last NACK.
 * nack_bitmap_len == 0 means "no bitmap" → caller retransmits whole file. */
static uint8_t  nack_bitmap[NACK_BITMAP_MAX_BYTES];
static uint16_t nack_bitmap_len;
static uint16_t nack_total_seqs;

/* Connection activity tracking (for UDP inactivity timeout) */
static int64_t last_activity_time;

/* Per-file transfer state */
static uint32_t current_file_crc;

/* ---- Forward declarations ---- */
static int udp_send(const uint8_t *data, uint16_t len);
static int udp_send_file_data_impl(const uint8_t *data, uint16_t len);
static int udp_send_file_data_at(uint16_t seq, const uint8_t *data, uint16_t len);
static int udp_repair_missing(struct fs_file_t *file, uint32_t file_size, uint32_t pace_us);
static int udp_send_file_start_impl(const char *session_id, const char *filename, uint32_t size);
static int udp_send_file_end_impl(const char *filename);
static int udp_send_transfer_done_impl(const char *session_id, uint32_t file_count);
static bool udp_is_connected(void);
static void *udp_get_conn(void);
static void update_activity(void);
static int raw_sendto(const void *buf, size_t len);

/* Transport operations (compatible with transport.h) */
static const struct transport_ops udp_ops = {
    .send = udp_send,
    .send_file_data = udp_send_file_data_impl,
    .repair_missing = udp_repair_missing,
    .send_file_start = udp_send_file_start_impl,
    .send_file_end = udp_send_file_end_impl,
    .send_transfer_done = udp_send_transfer_done_impl,
    .is_connected = udp_is_connected,
    .get_conn = udp_get_conn,
};

/* Transport instance */
static struct transport udp_transport = {
    .type = TRANSPORT_TYPE_UDP,
    .ready = false,
    .conn = NULL,
    .ops = &udp_ops,
    .event_cb = NULL,
    .user_data = NULL,
};

/* ========================================================================== */
/* Helpers                                                                     */
/* ========================================================================== */

/** Compute IEEE CRC32 matching binascii.crc32(data) */
static inline uint32_t compute_crc32(const uint8_t *data, size_t len)
{
    return crc32_ieee_update(0, data, len);
}

static void update_activity(void)
{
    last_activity_time = k_uptime_get();
}

/* ========================================================================== */
/* Low-level send                                                              */
/* ========================================================================== */

static int raw_sendto(const void *buf, size_t len)
{
    if (server_sock < 0) {
        return -EBADF;
    }
    if (udp_client_len == 0) {
        return -ENOTCONN;
    }

    k_mutex_lock(&udp_mutex, K_FOREVER);
    int ret = zsock_sendto(server_sock, buf, len, 0,
                           (struct sockaddr *)&udp_client_addr,
                           sizeof(udp_client_addr));
    k_mutex_unlock(&udp_mutex);

    if (ret < 0) {
        LOG_ERR("UDP sendto error: %d", errno);
        return -errno;
    }
    update_activity();
    return ret;
}

/* ========================================================================== */
/* FILE_ACK waiting                                                            */
/* ========================================================================== */

/**
 * Wait for FILE_ACK from client after sending FILE_END.
 * Does NOT read from the socket — waits for notify_file_ack() to signal.
 */
static int wait_for_file_ack(int timeout_ms)
{
    /* Reset state before waiting */
    file_ack_result = -1;
    nack_bitmap_len = 0;
    k_sem_reset(&file_ack_sem);

    if (k_sem_take(&file_ack_sem, K_MSEC(timeout_ms)) != 0) {
        return -ETIMEDOUT;
    }

    if (file_ack_result == 0) {
        return 0;  /* CRC OK */
    }
    return -EAGAIN;  /* NACK */
}

/* ========================================================================== */
/* Frame builders                                                              */
/* ========================================================================== */

/** Build a DATA frame in the provided buffer. Returns total frame length. */
static int build_data_frame(uint8_t *buf, uint16_t seq,
                            const uint8_t *data, uint16_t data_len)
{
    if (data_len > UDP_MAX_DATA_PER_FRAME) {
        data_len = UDP_MAX_DATA_PER_FRAME;
    }

    uint32_t crc = compute_crc32(data, data_len);

    buf[0] = UDP_FRAME_DATA;
    buf[1] = seq & 0xFF;
    buf[2] = (seq >> 8) & 0xFF;
    buf[3] = data_len & 0xFF;
    buf[4] = (data_len >> 8) & 0xFF;
    buf[5] = crc & 0xFF;
    buf[6] = (crc >> 8) & 0xFF;
    buf[7] = (crc >> 16) & 0xFF;
    buf[8] = (crc >> 24) & 0xFF;
    memcpy(&buf[UDP_DATA_HEADER_SIZE], data, data_len);

    return UDP_DATA_HEADER_SIZE + data_len;
}

/** Build FILE_START frame. Returns total frame length. */
static int build_file_start_frame(uint8_t *buf, const char *filename, uint32_t size)
{
    uint8_t fn_len = strlen(filename);
    if (fn_len > 63) fn_len = 63;

    buf[0] = UDP_FRAME_FILE_START;
    buf[1] = fn_len;
    memcpy(&buf[2], filename, fn_len);
    buf[2 + fn_len]     = size & 0xFF;
    buf[2 + fn_len + 1] = (size >> 8) & 0xFF;
    buf[2 + fn_len + 2] = (size >> 16) & 0xFF;
    buf[2 + fn_len + 3] = (size >> 24) & 0xFF;

    return 2 + fn_len + 4;
}

/** Build FILE_END frame. Returns total frame length. */
static int build_file_end_frame(uint8_t *buf, uint32_t crc32)
{
    buf[0] = UDP_FRAME_FILE_END;
    buf[1] = crc32 & 0xFF;
    buf[2] = (crc32 >> 8) & 0xFF;
    buf[3] = (crc32 >> 16) & 0xFF;
    buf[4] = (crc32 >> 24) & 0xFF;
    return 5;
}

/** Build TRANSFER_DONE frame. Returns total frame length. */
static int build_transfer_done_frame(uint8_t *buf, const char *session_id, uint32_t file_count)
{
    uint8_t sid_len = strlen(session_id);
    if (sid_len > 63) sid_len = 63;

    buf[0] = UDP_FRAME_TRANSFER_DONE;
    buf[1] = sid_len;
    memcpy(&buf[2], session_id, sid_len);
    buf[2 + sid_len]     = file_count & 0xFF;
    buf[2 + sid_len + 1] = (file_count >> 8) & 0xFF;
    buf[2 + sid_len + 2] = (file_count >> 16) & 0xFF;
    buf[2 + sid_len + 3] = (file_count >> 24) & 0xFF;

    return 2 + sid_len + 4;
}

/* ========================================================================== */
/* Transport operations                                                        */
/* ========================================================================== */

static int udp_send(const uint8_t *data, uint16_t len)
{
    if (!udp_ready) {
        return -ENOTCONN;
    }
    return raw_sendto(data, len);
}

/**
 * Fire-and-forget DATA send.
 *
 * Sends all data as frames without waiting for per-frame ACK.
 * Slices data > UDP_MAX_DATA_PER_FRAME into multiple frames. On a sendto
 * failure, backs off briefly (CLIP_UDP_SEND_BACKOFF_US) before continuing.
 */
static int udp_send_file_data_impl(const uint8_t *data, uint16_t len)
{
    if (!udp_ready) {
        return -ENOTCONN;
    }

    uint16_t offset = 0;
    while (offset < len) {
        uint16_t data_len = len - offset;
        if (data_len > UDP_MAX_DATA_PER_FRAME) {
            data_len = UDP_MAX_DATA_PER_FRAME;
        }

        /* CRC always covers the FULL file, independent of send success, so
         * FILE_END's CRC matches the complete file the client reassembles.
         * A frame whose sendto fails is later repaired by selective repeat. */
        current_file_crc = crc32_ieee_update(current_file_crc, data + offset, data_len);

        uint8_t frame[MAX_FRAME_SIZE];
        uint16_t seq = next_seq;
        int frame_len = build_data_frame(frame, seq, data + offset, data_len);

        int ret = raw_sendto(frame, frame_len);
        if (ret < 0) {
            if (!udp_ready) {
                return -ENOTCONN;
            }
            /* Transient send error — skip this frame (selective repeat will
             * repair it). Back off briefly before the next frame. */
            LOG_WRN("DATA seq %d send error, continuing", seq);
            if (CONFIG_CLIP_UDP_SEND_BACKOFF_US > 0) {
                k_usleep(CONFIG_CLIP_UDP_SEND_BACKOFF_US);
            }
        }

        next_seq = (seq + 1) & (UDP_SEQ_MODULO - 1);
        offset += data_len;
    }

    return len;
}

/**
 * Send a single DATA frame at an EXPLICIT sequence number (selective retransmit).
 * Used by the transfer layer to repair only the frames the client reported
 * missing. Does NOT touch current_file_crc (the file CRC is already final).
 */
static int udp_send_file_data_at(uint16_t seq, const uint8_t *data, uint16_t len)
{
    if (!udp_ready) {
        return -ENOTCONN;
    }
    if (len > UDP_MAX_DATA_PER_FRAME) {
        len = UDP_MAX_DATA_PER_FRAME;
    }
    uint8_t frame[MAX_FRAME_SIZE];
    int frame_len = build_data_frame(frame, seq, data, len);
    return raw_sendto(frame, frame_len);
}

/**
 * Selective-repeat repair: retransmit only the DATA frames the client reported
 * missing in the last NACK bitmap (bit i set = seq i missing). Reads each
 * missing frame by seq from the open file and resends it at its original seq,
 * with @p pace_us between frames. Does not touch current_file_crc (already
 * final). Returns the number of frames retransmitted, or a negative error.
 */
static int udp_repair_missing(struct fs_file_t *file, uint32_t file_size, uint32_t pace_us)
{
    if (!udp_ready) {
        return -ENOTCONN;
    }
    if (nack_bitmap_len == 0) {
        return 0;  /* no bitmap → caller falls back to whole-file retransmit */
    }

    static uint8_t fbuf[UDP_MAX_DATA_PER_FRAME];  /* single transfer thread */
    int resent = 0;

    for (uint16_t seq = 0; seq < nack_total_seqs; seq++) {
        uint16_t byte = seq >> 3;
        uint8_t  bit  = seq & 0x7;
        if (byte >= nack_bitmap_len || !(nack_bitmap[byte] & (1u << bit))) {
            continue;  /* not reported missing */
        }

        uint32_t off = (uint32_t)seq * UDP_MAX_DATA_PER_FRAME;
        if (off >= file_size) {
            break;  /* seq beyond file */
        }
        uint16_t flen = UDP_MAX_DATA_PER_FRAME;
        if (off + flen > file_size) {
            flen = (uint16_t)(file_size - off);  /* last (short) frame */
        }

        if (fs_seek(file, off, FS_SEEK_SET) != 0) {
            return -EIO;
        }
        ssize_t n = fs_read(file, fbuf, flen);
        if (n <= 0) {
            return -EIO;
        }

        int ret = udp_send_file_data_at(seq, fbuf, (uint16_t)n);
        if (ret < 0) {
            return ret;
        }
        resent++;

        if (pace_us > 0) {
            k_usleep(pace_us);  /* repair pacing (递减 per round, set by caller) */
        }
    }

    LOG_INF("selective repair: resent %d frame(s)", resent);
    return resent;
}

static int udp_send_file_start_impl(const char *session_id, const char *filename, uint32_t size)
{
    ARG_UNUSED(session_id);

    if (!udp_ready) {
        return -ENOTCONN;
    }

    /* Reset file state */
    transport_udp_reset_file_state();

    /* Build and send frame (fire-and-forget) */
    uint8_t frame[128];
    int frame_len = build_file_start_frame(frame, filename, size);
    return raw_sendto(frame, frame_len);
}

/**
 * Send FILE_END and wait for FILE_ACK from client.
 *
 * Returns:
 *   0        — client confirmed CRC OK
 *   -EAGAIN  — client reported CRC mismatch (NACK), caller should retransmit file
 *   -ETIMEDOUT — no FILE_ACK received after retries
 */
static int udp_send_file_end_impl(const char *filename)
{
    ARG_UNUSED(filename);

    if (!udp_ready) {
        return -ENOTCONN;
    }

    /* Drain pause: UDP has no ordering guarantee, so a FILE_END sent
     * immediately after the last DATA frame can overtake it and make the
     * client CRC-check an incomplete file (NACK). Let in-flight DATA land
     * first. */
    if (CONFIG_CLIP_UDP_FILE_END_DELAY_US > 0) {
        k_usleep(CONFIG_CLIP_UDP_FILE_END_DELAY_US);
    }

    uint32_t final_crc = current_file_crc;

    /* Build FILE_END frame */
    uint8_t frame[8];
    int frame_len = build_file_end_frame(frame, final_crc);

    /* Retry loop: send FILE_END and wait for FILE_ACK */
    for (int retry = 0; retry < FILE_END_RETRIES; retry++) {
        int ret = raw_sendto(frame, frame_len);
        if (ret < 0) {
            if (!udp_ready) {
                return -ENOTCONN;
            }
            k_msleep(100);
            continue;
        }

        int ack_ret = wait_for_file_ack(FILE_ACK_TIMEOUT);
        if (ack_ret == 0) {
            return 0;  /* CRC OK */
        }
        if (ack_ret == -EAGAIN) {
            LOG_WRN("FILE_ACK NACK (retry %d/%d)", retry + 1, FILE_END_RETRIES);
            return -EAGAIN;  /* Let caller retransmit entire file */
        }
        /* Timeout — retry FILE_END */
        LOG_WRN("FILE_ACK timeout (retry %d/%d)", retry + 1, FILE_END_RETRIES);
    }

    LOG_ERR("FILE_ACK timeout after %d retries", FILE_END_RETRIES);
    return -ETIMEDOUT;
}

static int udp_send_transfer_done_impl(const char *session_id, uint32_t file_count)
{
    if (!udp_ready) {
        return -ENOTCONN;
    }

    uint8_t frame[128];
    int frame_len = build_transfer_done_frame(frame, session_id, file_count);
    return raw_sendto(frame, frame_len);
}

static bool udp_is_connected(void)
{
    if (udp_ready) {
        int64_t elapsed = k_uptime_get() - last_activity_time;
        if (elapsed > CONFIG_CLIP_UDP_CONNECTION_TIMEOUT_MS) {
            LOG_WRN("Connection timeout (%u ms)", (unsigned int)elapsed);
            udp_ready = false;
            udp_transport.ready = false;
        }
    }
    return udp_ready;
}

static void *udp_get_conn(void)
{
    return (void *)&udp_client_addr;
}

/* ========================================================================== */
/* Public API                                                                  */
/* ========================================================================== */

int transport_udp_init(void)
{
    udp_ready = false;
    memset(&udp_client_addr, 0, sizeof(udp_client_addr));
    udp_client_len = 0;
    k_mutex_init(&udp_mutex);

    /* FILE_ACK signaling */
    next_seq = 0;
    file_ack_result = -1;
    k_sem_init(&file_ack_sem, 0, 1);

    last_activity_time = k_uptime_get();

    /* File state */
    current_file_crc = 0;

    LOG_INF("UDP transport init (per-file CRC)");
    return 0;
}

void transport_udp_reset_file_state(void)
{
    next_seq = 0;
    file_ack_result = -1;
    k_sem_reset(&file_ack_sem);

    current_file_crc = 0;
}

int transport_udp_send(const uint8_t *data, uint16_t len)
{
    return udp_send(data, len);
}

int transport_udp_send_file_data(const uint8_t *data, uint16_t len)
{
    return udp_send_file_data_impl(data, len);
}

int transport_udp_send_file_start(const char *filename, uint32_t file_size)
{
    return udp_send_file_start_impl(NULL, filename, file_size);
}

int transport_udp_send_file_end(void)
{
    return udp_send_file_end_impl(NULL);
}

int transport_udp_send_transfer_done(const char *session_id, uint32_t file_count)
{
    return udp_send_transfer_done_impl(session_id, file_count);
}

int transport_udp_send_response(const uint8_t *data, uint16_t len)
{
    if (server_sock < 0) {
        return -EBADF;
    }
    if (udp_client_len == 0) {
        return -ENOTCONN;
    }

    /* Build AT_RESP frame: type(1) + len(2) + data */
    uint8_t frame[3 + len];
    frame[0] = UDP_FRAME_AT_RESP;
    frame[1] = len & 0xFF;
    frame[2] = (len >> 8) & 0xFF;
    memcpy(&frame[3], data, len);

    return raw_sendto(frame, sizeof(frame));
}

bool transport_udp_is_active(void)
{
    return udp_ready;
}

void transport_udp_update_active(bool active)
{
    udp_ready = active;
    udp_transport.ready = active;

    if (!active) {
        transport_udp_reset_file_state();
        /* Wake transfer thread if blocked waiting for FILE_ACK */
        file_ack_result = -1;
        k_sem_give(&file_ack_sem);
    }
    update_activity();
}

void transport_udp_update_client_addr(const struct sockaddr *addr, socklen_t len)
{
    if (addr && len > 0) {
        k_mutex_lock(&udp_mutex, K_FOREVER);
        memcpy(&udp_client_addr, addr, len < sizeof(udp_client_addr) ? len : sizeof(udp_client_addr));
        udp_client_len = len;
        k_mutex_unlock(&udp_mutex);
        update_activity();
    }
}

void transport_udp_notify_file_ack(uint8_t result, const uint8_t *bitmap,
				   uint16_t bitmap_len, uint16_t total_seqs)
{
    update_activity();
    file_ack_result = (result == 0x00) ? 0 : 1;
    /* On NACK, keep the missing-seq bitmap for selective retransmit (if the
     * client provided one). No bitmap → caller falls back to whole-file send. */
    if (file_ack_result == 1 && bitmap && bitmap_len > 0 &&
        bitmap_len <= NACK_BITMAP_MAX_BYTES) {
        memcpy(nack_bitmap, bitmap, bitmap_len);
        nack_bitmap_len = bitmap_len;
        nack_total_seqs = total_seqs;
    } else {
        nack_bitmap_len = 0;
    }
    k_sem_give(&file_ack_sem);
}

struct transport *transport_udp_get(void)
{
    return &udp_transport;
}
