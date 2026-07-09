/*
 * Copyright (c) 2025 Seeed Technology Co., Ltd.
 *
 * SPDX-License-Identifier: Apache-2.0
 *
 * BLE/WiFi throughput test runner. A dedicated thread runs one test at a
 * time (BLE notify stream or WiFi UDP TX) and reports the measured rate via
 * a BLE event. Enabled with CONFIG_CLIP_THROUGHPUT_TEST.
 */

#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>
#include <stdio.h>
#include <string.h>
#include "throughput_test.h"
#include "ble.h"
#include "wifi.h"

LOG_MODULE_REGISTER(throughput_test, CONFIG_CLIP_LOG_LEVEL);

#ifdef CONFIG_CLIP_THROUGHPUT_TEST

#define THRU_DEFAULT_DURATION_SEC	10U
#define THRU_DEFAULT_PORT		5001U

enum thru_mode {
	THRU_BLE,
	THRU_WIFI,
};

struct thru_req {
	enum thru_mode mode;
	char ip[32];
	uint16_t port;
	uint32_t dur_sec;
};

static struct thru_req req;
static K_SEM_DEFINE(thru_sem, 0, 1);
static volatile bool thru_busy;

static void thru_report(int rc, uint32_t kbps, uint32_t dur, const char *ip)
{
	char status[80];
	char result[96];

	if (rc) {
		snprintf(status, sizeof(status), "error:%d", rc);
		snprintf(result, sizeof(result), "{\"error\":%d}", rc);
	} else if (req.mode == THRU_BLE) {
		snprintf(status, sizeof(status),
			 "rate_kbps=%u,duration=%u", kbps, dur);
		snprintf(result, sizeof(result),
			 "{\"rate_kbps\":%u,\"duration\":%u}", kbps, dur);
	} else {
		snprintf(status, sizeof(status),
			 "rate_kbps=%u,duration=%u,ip=%s", kbps, dur, ip);
		snprintf(result, sizeof(result),
			 "{\"rate_kbps\":%u,\"duration\":%u,\"ip\":\"%s\"}",
			 kbps, dur, ip);
	}

	/* Result on resp_send (0003) — the normal AT event channel. */
	int ev = ble_notify_event(req.mode == THRU_BLE ? "blethru" : "wifithru",
				  status);
	/* Also push the result on the throughput char (0006) so a client
	 * subscribed there gets it on a separate channel (not overwritten by
	 * the "started" AT reply on 0003). */
	int tp = ble_send_throughput(result, strlen(result));
	LOG_INF("result: ev=%d tp=%d kbps=%u", ev, tp, kbps);
}

static void throughput_thread(void *a0, void *a1, void *a2)
{
	ARG_UNUSED(a0);
	ARG_UNUSED(a1);
	ARG_UNUSED(a2);

	while (1) {
		k_sem_take(&thru_sem, K_FOREVER);

		/* Let the AT "started" reply go out first (it is sent by the AT
		 * server right after the handler returns; without this delay the
		 * test thread can preempt it and the result lands before the
		 * "started" reply). */
		k_msleep(300);

		uint32_t kbps = 0;
		int rc;

		if (req.mode == THRU_BLE) {
			rc = ble_run_throughput(req.dur_sec, &kbps);
		} else {
			rc = wifi_run_throughput(req.ip, req.port, req.dur_sec, &kbps);
		}

		thru_report(rc, kbps, req.dur_sec, req.ip);
		LOG_INF("test done: mode=%d rc=%d kbps=%u",
			req.mode, rc, kbps);

		thru_busy = false;
	}
}

K_THREAD_DEFINE(throughput_tid, 2048, throughput_thread,
		NULL, NULL, NULL, 10, 0, 0);

int throughput_ble_start(uint32_t dur_sec)
{
	if (thru_busy) {
		return -EBUSY;
	}
	if (dur_sec == 0) {
		dur_sec = THRU_DEFAULT_DURATION_SEC;
	}

	req.mode = THRU_BLE;
	req.dur_sec = dur_sec;
	thru_busy = true;
	k_sem_give(&thru_sem);
	return 0;
}

int throughput_wifi_start(const char *ip, uint16_t port, uint32_t dur_sec)
{
	if (thru_busy) {
		return -EBUSY;
	}
	if (dur_sec == 0) {
		dur_sec = THRU_DEFAULT_DURATION_SEC;
	}
	if (port == 0) {
		port = THRU_DEFAULT_PORT;
	}

	req.mode = THRU_WIFI;
	strncpy(req.ip, ip, sizeof(req.ip) - 1);
	req.ip[sizeof(req.ip) - 1] = '\0';
	req.port = port;
	req.dur_sec = dur_sec;
	thru_busy = true;
	k_sem_give(&thru_sem);
	return 0;
}

#endif /* CONFIG_CLIP_THROUGHPUT_TEST */
