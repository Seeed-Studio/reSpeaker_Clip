/*
 * Copyright (c) 2026 Seeed Technology Co., Ltd.
 *
 * SPDX-License-Identifier: LicenseRef-Nordic-5-Clause
 *
 * Battery discharge/charge cycle test state machine. Polls the NPM1300
 * charger every few seconds, drives the charger enable to alternate between
 * discharging (WiFi TX load drains the cell) and charging, and keeps the
 * OLED updated with % / state / voltage. The cycle is driven purely by cell
 * voltage (the nRF Fuel Gauge SoC was unreliable under the pulsed WiFi TX
 * load).
 */

#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>
#include <stdio.h>
#include "discharge.h"
#include "pmic.h"
#include "oled.h"
#include "wifi.h"

LOG_MODULE_REGISTER(discharge, LOG_LEVEL_INF);

/* Voltage-hysteresis thresholds (cell voltage, not fuel-gauge SoC):
 *  - DISCHARGE -> CHARGE when the cell sinks to 3.3 V,
 *  - CHARGE    -> DISCHARGE when the cell rises to 4.12 V.
 * The 0.82 V gap prevents oscillation around the switching point. */
#define DISCHARGE_VOLTAGE_MV		3350U	/* start charging at/below */
#define CHARGE_VOLTAGE_MV		4120U	/* start discharging at/above */
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
	printk("Discharging to %u mV, then charging to %u mV, repeat.\n\n",
	       DISCHARGE_VOLTAGE_MV, CHARGE_VOLTAGE_MV);

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
				if (mv <= DISCHARGE_VOLTAGE_MV) {
					LOG_INF("cycle %u: %u mV reached -> CHARGE",
						cycles, mv);
					state = STATE_CHARGE;
					/* Charge with minimal load: WiFi off
					 * (AP down + TX idle) for low power. */
					wifi_discharge_load_enable(false);
					pmic_charger_set(true);
				}
			} else { /* STATE_CHARGE */
				if (mv >= CHARGE_VOLTAGE_MV) {
					cycles++;
					LOG_INF("cycle %u: %u mV reached -> DISCHARGE",
						cycles, mv);
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
