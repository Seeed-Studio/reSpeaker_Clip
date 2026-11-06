/*
 * Copyright (c) 2026 Seeed Technology Co., Ltd.
 *
 * SPDX-License-Identifier: LicenseRef-Nordic-5-Clause
 */

#include <zephyr/kernel.h>
#include <zephyr/device.h>
#include <zephyr/drivers/input/button.h>
#include <zephyr/logging/log.h>
#include "button.h"
#include "oled.h"
#include "pmic.h"

LOG_MODULE_REGISTER(button, LOG_LEVEL_INF);

/* Show the power-off page before cutting power, so the gesture has
 * visible feedback (and so a failed ship mode — e.g. USB/charger
 * attached, which the nPM1300 rejects — leaves the page on screen
 * instead of looking like the button did nothing). */
static void button_power_off(void)
{
	LOG_INF("Power off — ship mode");
	oled_show_power_off();
	k_sleep(K_MSEC(800));
	pmic_enter_ship_mode();
	LOG_ERR("Ship mode failed (USB/charger attached?)");
}

static void button_event_cb(const struct device *dev, enum button_action action)
{
	switch (action) {
	case BUTTON_DOUBLE_CLICK:
		button_power_off();
		break;
	case BUTTON_LONG_PRESS_LEVEL_1:
		/* 3 s hold — same gesture as the production app's power-off */
		button_power_off();
		break;
	case BUTTON_SINGLE_CLICK:
		LOG_INF("Button click");
		break;
	default:
		break;
	}
}

int button_init(void)
{
	const struct device *btn = DEVICE_DT_GET(DT_ALIAS(sw0));
	int ret;

	if (!device_is_ready(btn)) {
		LOG_ERR("Button device not ready");
		return -ENODEV;
	}

	ret = button_callback_register(btn, button_event_cb);
	if (ret < 0) {
		LOG_ERR("Button callback register failed: %d", ret);
		return ret;
	}

	LOG_INF("Button ready (double click or 3s hold = ship mode)");

	return 0;
}
