/*
 * Copyright (c) 2025 Seeed Technology Co., Ltd.
 *
 * SPDX-License-Identifier: Apache-2.0
 *
 * UDP server for CLIP device.
 * Receives AT commands from client and dispatches to AT server.
 * Receives ACK frames and forwards to transport_udp for sliding window.
 *
 * Protocol: CLIP UDP Transfer Protocol (see docs/udp_protocol.md)
 *
 * Server sends: DATA, FILE_START, FILE_END, TRANSFER_DONE, AT_RESP, HEARTBEAT
 * Server receives: ACK, HEARTBEAT, AT commands (plain text)
 */

#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>
#include <zephyr/net/socket.h>
#include <zephyr/net/net_ip.h>
#include <string.h>
#include <errno.h>
#include "wifi_udp.h"
#include "wifi.h"
#include "at_server.h"
#include "transport.h"
#include "transport_udp.h"

LOG_MODULE_REGISTER(wifi_udp, CONFIG_CLIP_LOG_LEVEL);

/* State */
static K_THREAD_STACK_DEFINE(udp_stack, CONFIG_CLIP_UDP_THREAD_STACK_SIZE);
static struct k_thread udp_thread_data;
static K_SEM_DEFINE(udp_thread_done_sem, 0, 1);

static volatile bool server_running;
static volatile bool client_active;
int server_sock = -1;  /* Shared with transport_udp.c */
struct sockaddr_in client_addr;  /* Shared with transport_udp.c */
socklen_t client_len;  /* Shared with transport_udp.c */

/* Receive buffer */
static uint8_t udp_recv_buf[CONFIG_CLIP_UDP_RECV_BUF_SIZE];

/**
 * @brief Handle incoming UDP packet
 */
static void handle_packet(const uint8_t *buf, size_t len)
{
    if (len < 1) {
        return;
    }

    uint8_t frame_type = buf[0];

    switch (frame_type) {
    case UDP_FRAME_FILE_ACK:
        /* FILE_ACK: [type(1)][result(1)] (legacy, 0x00=OK / 0x01=NACK), or
         * [type(1)][result=0x01][total_seqs(2 LE)][bitmap] (selective NACK:
         * bit i set = seq i missing). Legacy 2-byte ACKs still work — the
         * extra fields are simply absent (whole-file retransmit). */
        if (len >= 2) {
            uint8_t status = buf[1];
            const uint8_t *bitmap = NULL;
            uint16_t bitmap_len = 0;
            uint16_t total_seqs = 0;
            if (status != 0x00 && len >= 4) {
                total_seqs = (uint16_t)(buf[2] | (buf[3] << 8));
                bitmap = &buf[4];
                bitmap_len = (uint16_t)(len - 4);
            }
            transport_udp_notify_file_ack(status, bitmap, bitmap_len, total_seqs);
        }
        break;

    case UDP_FRAME_HEARTBEAT:
        /* Heartbeat from client (now sent every ~200 ms during transfer to
         * keep the phone's WiFi out of power-save). Per-packet log removed. */
        client_active = true;
        break;

    case UDP_FRAME_DATA:
    case UDP_FRAME_FILE_START:
    case UDP_FRAME_FILE_END:
    case UDP_FRAME_TRANSFER_DONE:
    case UDP_FRAME_AT_RESP:
        /* These are server→client frames — ignore if received (echo/loopback) */
        LOG_DBG("Ignored server→client frame 0x%02x", frame_type);
        break;

    default:
        /* Check if it's an AT command (plain text starting with 'A'/'a') */
        if (frame_type == 'A' || frame_type == 'a') {
            char *line = (char *)buf;
            if (len < sizeof(udp_recv_buf)) {
                line[len] = '\0';
                LOG_INF("AT cmd: %s", line);
                at_server_submit_cmd((uint8_t *)line, len, TRANSPORT_TYPE_UDP);
            }
        } else {
            LOG_WRN("Unknown frame type 0x%02x (len=%d)", frame_type, len);
        }
        break;
    }
}

/**
 * @brief UDP server thread
 */
static void udp_server_thread(void *p1, void *p2, void *p3)
{
    ARG_UNUSED(p1);
    ARG_UNUSED(p2);
    ARG_UNUSED(p3);

    struct sockaddr_in addr = {
        .sin_family = AF_INET,
        .sin_port   = htons(WIFI_AP_UDP_PORT),
        .sin_addr   = { .s_addr = INADDR_ANY },
    };

    server_sock = zsock_socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (server_sock < 0) {
        LOG_ERR("socket() failed: %d", errno);
        server_running = false;
        return;
    }

    /* Set receive timeout for periodic checks */
    struct timeval tv = {
        .tv_sec = 1,
        .tv_usec = 0,
    };
    zsock_setsockopt(server_sock, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

    /* Increase socket buffers to reduce packet loss under load */
    int sock_buf = CONFIG_CLIP_UDP_SOCKET_BUF_SIZE;
    zsock_setsockopt(server_sock, SOL_SOCKET, SO_RCVBUF, &sock_buf, sizeof(sock_buf));
    zsock_setsockopt(server_sock, SOL_SOCKET, SO_SNDBUF, &sock_buf, sizeof(sock_buf));

    if (zsock_bind(server_sock, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        LOG_ERR("bind() failed: %d", errno);
        zsock_close(server_sock);
        server_sock = -1;
        server_running = false;
        return;
    }


    while (server_running) {
        memset(udp_recv_buf, 0, sizeof(udp_recv_buf));
        client_len = sizeof(client_addr);
        int ret = zsock_recvfrom(server_sock, udp_recv_buf, sizeof(udp_recv_buf) - 1,
                                 0, (struct sockaddr *)&client_addr, &client_len);

        if (ret < 0) {
            if (errno == EAGAIN || errno == EWOULDBLOCK) {
                continue;
            }
            LOG_ERR("UDP recvfrom error: %d", errno);
            k_sleep(K_MSEC(100));
            continue;
        }
        if (ret > 0) {
            /* Track client address for responses */
            if (client_len > 0) {
                transport_udp_update_client_addr((struct sockaddr *)&client_addr, client_len);
                transport_udp_update_active(true);
                client_active = true;
            }
            handle_packet(udp_recv_buf, ret);
        }
    }

    if (server_sock >= 0) {
        zsock_close(server_sock);
        server_sock = -1;
    }

    server_running = false;
    k_sem_give(&udp_thread_done_sem);
    LOG_INF("UDP server stopped");
}

/* Public API */

int wifi_udp_init(void)
{
    server_running = false;
    client_active = false;
    server_sock = -1;
    client_len = sizeof(client_addr);
    memset(&client_addr, 0, sizeof(client_addr));
    
    return 0;
}

int wifi_udp_start(void)
{
    if (server_running) {
        LOG_DBG("UDP server already running");
        return 0;
    }

    server_running = true;

    k_thread_create(&udp_thread_data, udp_stack,
                    K_THREAD_STACK_SIZEOF(udp_stack),
                    udp_server_thread,
                    NULL, NULL, NULL,
                    CONFIG_CLIP_UDP_THREAD_PRIORITY, 0, K_NO_WAIT);

    k_thread_name_set(&udp_thread_data, "wifi_udp");

    LOG_INF("UDP server starting");
    return 0;
}

void wifi_udp_stop(void)
{
    if (!server_running) {
        return;
    }

    server_running = false;
    client_active = false;

    if (server_sock >= 0) {
        zsock_close(server_sock);
        server_sock = -1;
    }

    /* Wait for UDP server thread to finish */
    k_sem_take(&udp_thread_done_sem, K_SECONDS(2));
    LOG_INF("UDP server stopped");
}

bool wifi_udp_is_running(void)
{
    return server_running;
}

bool wifi_udp_is_active(void)
{
    return client_active;
}
