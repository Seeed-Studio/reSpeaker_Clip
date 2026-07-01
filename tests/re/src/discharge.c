/*
 * Copyright (c) 2026 Seeed Technology Co., Ltd.
 *
 * SPDX-License-Identifier: LicenseRef-Nordic-5-Clause
 *
 * Battery discharge/charge cycle test state machine. Polls the NPM1300
 * charger every few seconds, drives the charger enable to alternate between
 * discharging (WiFi TX load drains the cell) and charging, and keeps the
 * OLED updated with % / state / voltage.
 */

#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>
#include <stdio.h>
#include "discharge.h"
#include "pmic.h"
#include "oled.h"
#include "wifi.h"

LOG_MODULE_REGISTER(discharge, LOG_LEVEL_INF);

#define DISCHARGE_THRESHOLD_PCT		1U	/* start charging at/below 1% */
#define POLL_INTERVAL_MS		5000U

enum cycle_state {
	STATE_DISCHARGE,
	STATE_CHARGE,
};

void discharge_run(void)
{
	enum cycle_state state = STATE_DISCHARGE;
	uint32_t cycles = 0U;
	uint8_t pct = 0U;
	uint32_t mv = 0U;
	bool charging = false;

	printk("\n=== Battery discharge/charge cycle test ===\n");
	printk("Discharging to %u%%, then charging to full, repeat.\n\n",
	       DISCHARGE_THRESHOLD_PCT);

	/* Start in DISCHARGE: charger off, WiFi AP + TX load on. */
	pmic_charger_set(false);
	wifi_discharge_load_enable(true);

	for (;;) {
		int ret = pmic_get_battery_status(&mv, &pct, &charging);
		const char *label = (state == STATE_DISCHARGE) ?
				    "DISCHARGE" : "CHARGE";

		if (ret == 0) {
			oled_show_battery(pct, charging, mv, label, cycles);

			if (state == STATE_DISCHARGE) {
				if (pct <= DISCHARGE_THRESHOLD_PCT) {
					LOG_INF("cycle %u: %u%% reached -> CHARGE",
						cycles, pct);
					state = STATE_CHARGE;
					/* Charge with minimal load: WiFi off
					 * (AP down + TX idle) for low power. */
					wifi_discharge_load_enable(false);
					pmic_charger_set(true);
				}
			} else { /* STATE_CHARGE */
				if (pmic_is_charge_complete()) {
					cycles++;
					LOG_INF("cycle %u: charge complete -> DISCHARGE",
						cycles);
					state = STATE_DISCHARGE;
					pmic_charger_set(false);
					wifi_discharge_load_enable(true);
				}
			}
		} else {
			LOG_WRN("battery read failed: %d", ret);
		}

		k_sleep(K_MSEC(POLL_INTERVAL_MS));
	}
}
