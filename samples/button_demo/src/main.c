/*
 * GPIO Button Demo for ReSpeaker Lav
 *
 * Copyright (c) 2025 Seeed Technology Co., Ltd.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#include <zephyr/kernel.h>
#include <zephyr/device.h>
#include <zephyr/drivers/gpio.h>
#include <zephyr/drivers/input/button.h>
#include <zephyr/logging/log.h>
#include <zephyr/sys/util.h>

LOG_MODULE_REGISTER(button_demo, LOG_LEVEL_INF);

/* Event counter for statistics */
static uint32_t event_count[BUTTON_EVENT_NUM] = {0};

/* Get timestamp in milliseconds */
static inline int64_t get_timestamp_ms(void)
{
	return k_uptime_get();
}

/* Unified button event callback - handles all events */
static void button_event_cb(const struct device *dev, enum button_action action)
{
	int64_t timestamp = get_timestamp_ms();
	event_count[action]++;

	switch (action) {
	case BUTTON_LONG_PRESS:
		LOG_INF("[%lld ms] Long Press (1 second)", timestamp);
		break;
	case BUTTON_LONG_PRESS_LEVEL_1:
		LOG_INF("[%lld ms] Long Press Level 1 (3 seconds)", timestamp);
		break;
	case BUTTON_SINGLE_CLICK:
		LOG_INF("[%lld ms] Single Click", timestamp);
		break;
	case BUTTON_DOUBLE_CLICK:
		LOG_INF("[%lld ms] Double Click", timestamp);
		break;
	default:
		LOG_INF("[%lld ms] Unknown button event: %d", timestamp, action);
		break;
	}
}

int main(void)
{
	const struct device *button = DEVICE_DT_GET(DT_ALIAS(sw0));
	int ret;

	LOG_INF("=============================================");
	LOG_INF("  ReSpeaker Lav Button Demo");
	LOG_INF("=============================================");
	LOG_INF("Button device: %s", button->name);

	if (!device_is_ready(button)) {
		LOG_ERR("ERROR: Button device not ready!");
		return -ENODEV;
	}

	LOG_INF("");
	LOG_INF("Button Events Configuration:");
	LOG_INF("  - Single Click:     Quick press and release");
	LOG_INF("  - Double Click:     Two quick clicks within 400ms");
	LOG_INF("  - Long Press:       Hold for 1 second");
	LOG_INF("  - Long Press Lv1:   Hold for 3 seconds");
	LOG_INF("");

	/* Register callback for all button events */
	ret = button_callback_register(button, button_event_cb);
	if (ret < 0) {
		LOG_ERR("ERROR: Failed to register button callback");
		return ret;
	}

	LOG_INF(">>> Button test started. Press the button to test events...");
	LOG_INF("");

	/* Main loop - print statistics periodically */
	while (1) {
		k_sleep(K_SECONDS(30));

		/* Print statistics every 30 seconds */
		LOG_INF("");
		LOG_INF("========== Button Event Statistics ==========");
		LOG_INF("Single Click:           %d times", event_count[BUTTON_SINGLE_CLICK]);
		LOG_INF("Double Click:           %d times", event_count[BUTTON_DOUBLE_CLICK]);
		LOG_INF("Long Press (1s):        %d times", event_count[BUTTON_LONG_PRESS]);
		LOG_INF("Long Press Level 1 (3s): %d times", event_count[BUTTON_LONG_PRESS_LEVEL_1]);
		LOG_INF("=============================================");
		LOG_INF("");
	}

	return 0;
}
