/*
 * Copyright (c) 2025 Seeed Technology Co., Ltd.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>
#include <string.h>
#include "transport.h"

LOG_MODULE_REGISTER(transport, LOG_LEVEL_WRN); /* chatty plumbing logs */

/* Transport registry */
static struct transport *transports[TRANSPORT_TYPE_MAX];
static struct k_mutex transport_lock;

/* Initialize transport layer */
int transport_init(void)
{
    k_mutex_init(&transport_lock);

    for (int i = 0; i < TRANSPORT_TYPE_MAX; i++) {
        transports[i] = NULL;
    }

    LOG_INF("Transport layer initialized");
    return 0;
}

/* Register transport */
int transport_register(struct transport *tp)
{
    if (!tp || tp->type >= TRANSPORT_TYPE_MAX) {
        return -EINVAL;
    }

    k_mutex_lock(&transport_lock, K_FOREVER);

    if (transports[tp->type] != NULL) {
        k_mutex_unlock(&transport_lock);
        LOG_WRN("Transport type %d already registered", tp->type);
        return -EEXIST;
    }

    transports[tp->type] = tp;
    k_mutex_unlock(&transport_lock);

    LOG_INF("Transport %d registered (total %d)", tp->type, TRANSPORT_TYPE_MAX);
    return 0;
}

/* Unregister transport */
int transport_unregister(uint8_t type)
{
    if (type >= TRANSPORT_TYPE_MAX) {
        return -EINVAL;
    }

    k_mutex_lock(&transport_lock, K_FOREVER);
    transports[type] = NULL;
    k_mutex_unlock(&transport_lock);

    LOG_INF("Transport %d unregistered", type);
    return 0;
}

/* Get transport by type */
struct transport *transport_get(uint8_t type)
{
    if (type >= TRANSPORT_TYPE_MAX) {
        return NULL;
    }

    k_mutex_lock(&transport_lock, K_FOREVER);
    struct transport *tp = transports[type];
    k_mutex_unlock(&transport_lock);

    return tp;
}

/* Get active transport (priority: UDP > BLE) */
struct transport *transport_get_active(void)
{
	k_mutex_lock(&transport_lock, K_FOREVER);

	/* Explicit priority order: UDP first (better for large transfers), then BLE */
	static const uint8_t priority[] = {
		TRANSPORT_TYPE_UDP,
		TRANSPORT_TYPE_BLE,
	};
	for (int i = 0; i < (int)ARRAY_SIZE(priority); i++) {
		struct transport *tp = transports[priority[i]];
		if (tp && tp->ready && tp->ops && tp->ops->is_connected()) {
			k_mutex_unlock(&transport_lock);
			return tp;
		}
	}

	k_mutex_unlock(&transport_lock);
	return NULL;
}

/* Send data through specific transport */
int transport_send_to(uint8_t type, const uint8_t *data, uint16_t len)
{
    LOG_DBG("transport_send_to: type=%d, len=%d", type, len);
    if (!data || len == 0) {
        return -EINVAL;
    }

    if (type >= TRANSPORT_TYPE_MAX) {
        LOG_ERR("transport_send_to: type %d >= MAX %d", type, TRANSPORT_TYPE_MAX);
        return -EINVAL;
    }

    k_mutex_lock(&transport_lock, K_FOREVER);
    struct transport *tp = transports[type];
    k_mutex_unlock(&transport_lock);

    if (!tp) {
        LOG_ERR("transport_send_to: %d NULL", type);
        return -ENODEV;
    }

    if (!tp->ops || !tp->ops->send) {
        return -ENOTSUP;
    }

    return tp->ops->send(data, len);
}

/* Send data through active transport */
int transport_send(const uint8_t *data, uint16_t len)
{
    if (!data || len == 0) {
        return -EINVAL;
    }

    struct transport *tp = transport_get_active();
    if (!tp) {
        return -ENOTCONN;
    }

    if (!tp->ops || !tp->ops->send) {
        return -ENOTSUP;
    }

    return tp->ops->send(data, len);
}

/* Send file data through active transport */
int transport_send_file_data(const uint8_t *data, uint16_t len)
{
    if (!data || len == 0) {
        return -EINVAL;
    }

    struct transport *tp = transport_get_active();
    if (!tp) {
        return -ENOTCONN;
    }

    if (!tp->ops || !tp->ops->send_file_data) {
        return -ENOTSUP;
    }

    return tp->ops->send_file_data(data, len);
}

/* Check if any transport is connected */
bool transport_is_connected(void)
{
    return transport_get_active() != NULL;
}

/* Send file start event through active transport */
int transport_send_file_start(const char *session_id, const char *filename, uint32_t size)
{
    struct transport *tp = transport_get_active();
    if (!tp) {
        return -ENOTCONN;
    }

    if (!tp->ops || !tp->ops->send_file_start) {
        return -ENOTSUP;
    }

    return tp->ops->send_file_start(session_id, filename, size);
}

/* Send file end event through active transport */
int transport_send_file_end(const char *filename)
{
    struct transport *tp = transport_get_active();
    if (!tp) {
        return -ENOTCONN;
    }

    if (!tp->ops || !tp->ops->send_file_end) {
        return -ENOTSUP;
    }

    return tp->ops->send_file_end(filename);
}

/* Send transfer done event through active transport */
int transport_send_transfer_done(const char *session_id, uint32_t file_count)
{
    struct transport *tp = transport_get_active();
    if (!tp) {
        return -ENOTCONN;
    }

    if (!tp->ops || !tp->ops->send_transfer_done) {
        return -ENOTSUP;
    }

    return tp->ops->send_transfer_done(session_id, file_count);
}

/* Notify transport event */
void transport_notify_event(uint8_t type, uint8_t event,
                            const uint8_t *data, size_t len)
{
    struct transport *tp = transport_get(type);
    if (!tp) {
        return;
    }

    if (tp->event_cb) {
        tp->event_cb(type, event, data, len, tp->user_data);
    }
}
