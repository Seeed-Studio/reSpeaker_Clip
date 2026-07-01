/*
 * Copyright (c) 2026 Seeed Technology Co., Ltd.
 *
 * SPDX-License-Identifier: LicenseRef-Nordic-5-Clause
 */

#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>

#include "button.h"
#include "sdcard.h"
#include "oled.h"
#include "pmic.h"
#include "motor.h"
#include "mic.h"
#include "wifi.h"
#include "ble.h"
#include "re_test.h"
#include "discharge.h"

LOG_MODULE_REGISTER(main, LOG_LEVEL_INF);

int main(void)
{
	int ret;

	printk("=== RE Test Firmware ===\n");
	printk("Auto peripheral reliability test\n\n");

	/* Initialize peripherals */
	ret = button_init();
	if (ret != 0) {
		LOG_WRN("Button init failed: %d", ret);
	}

	ret = sdcard_init();
	if (ret != 0) {
		LOG_WRN("SD card init failed: %d", ret);
	}

	ret = mic_init();
	if (ret != 0) {
		LOG_WRN("MIC init failed: %d", ret);
	}

	ret = oled_init();
	if (ret != 0) {
		LOG_WRN("OLED init failed: %d", ret);
	}

	ret = pmic_init();
	if (ret != 0) {
		LOG_WRN("PMIC init failed: %d", ret);
	}

	ret = motor_init();
	if (ret != 0) {
		LOG_WRN("Motor init failed: %d", ret);
	}

	/* Start WiFi AP */
	ret = wifi_run_test();
	if (ret != 0) {
		LOG_WRN("WiFi init failed: %d", ret);
	}

	/* Start the continuous UDP TX discharge load (auto-starts, waits for AP) */
	wifi_discharge_start();

	/* Start BLE advertising */
	ret = ble_init();
	if (ret != 0) {
		LOG_WRN("BLE init failed: %d", ret);
	}

	printk("All peripherals initialized\n");
	printk("Starting battery discharge/charge cycle test...\n\n");

	/* Run the battery discharge/charge cycle test (never returns) */
	discharge_run();

	return 0;
}
