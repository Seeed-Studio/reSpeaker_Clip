/*
 * Copyright (c) 2025 Seeed Technology Co., Ltd.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#include <zephyr/kernel.h>
#include <zephyr/device.h>
#include <zephyr/drivers/watchdog.h>
#include <zephyr/logging/log.h>

#include "watchdog.h"
#include "clip.h"

LOG_MODULE_REGISTER(watchdog, LOG_LEVEL_INF);

/* Watchdog device */
static const struct device *const wdt_dev = DEVICE_DT_GET(DT_NODELABEL(wdt0));
static int wdt_channel_id;

int watchdog_init(void)
{
	int err;
	struct wdt_timeout_cfg wdt_config;

	if (!device_is_ready(wdt_dev)) {
		LOG_ERR("Watchdog device not ready");
		return -ENODEV;
	}

	/* Configure watchdog timeout */
	wdt_config.window.min = 0;
	wdt_config.window.max = CLIP_WDT_TIMEOUT_MS;
	wdt_config.callback = NULL;  /* No callback, just reset */
	wdt_config.flags = WDT_FLAG_RESET_SOC;

	/* Install timeout */
	wdt_channel_id = wdt_install_timeout(wdt_dev, &wdt_config);
	if (wdt_channel_id < 0) {
		LOG_ERR("Failed to install watchdog timeout: %d", wdt_channel_id);
		return wdt_channel_id;
	}

	/* Start watchdog */
	err = wdt_setup(wdt_dev, 0);
	if (err < 0) {
		LOG_ERR("Failed to start watchdog: %d", err);
		return err;
	}

	LOG_INF("Watchdog started: timeout=%d ms", CLIP_WDT_TIMEOUT_MS);
	return 0;
}

void watchdog_feed(void)
{
	int err;

	err = wdt_feed(wdt_dev, wdt_channel_id);
	if (err < 0) {
		LOG_ERR("Failed to feed watchdog: %d", err);
	}
}
