/*
 * Copyright (c) 2025 Seeed Technology Co., Ltd.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#include <zephyr/kernel.h>
#include <zephyr/device.h>
#include <zephyr/drivers/sensor.h>
#include <zephyr/drivers/sensor/npm13xx_charger.h>
#include <zephyr/drivers/gpio.h>
#include <zephyr/drivers/mfd/npm13xx.h>
#include <zephyr/bluetooth/services/bas.h>
#include <zephyr/logging/log.h>
#include <zephyr/sys/crc.h>
#include <nrf_fuel_gauge.h>
#include <zephyr/settings/settings.h>

#include <stddef.h>
#include <string.h>

#include "battery.h"
#include "clip.h"
#include "clip_event.h"
#include "display.h"
#include "ble.h"
#include "transfer.h"
#include "wifi.h"

LOG_MODULE_REGISTER(battery, CONFIG_CLIP_LOG_LEVEL);

/* Charger status bitmasks (BCHGCHARGESTATUS register) */
#define CHG_STATUS_COMPLETE_MASK BIT(1)
#define CHG_STATUS_TRICKLE_MASK  BIT(2)
#define CHG_STATUS_CC_MASK       BIT(3)
#define CHG_STATUS_CV_MASK       BIT(4)

/* Battery full threshold (SoC %) */
#define BATTERY_FULL_THRESHOLD  99

/* Low-battery auto-shutdown removed — unreliable SoC during PMIC I2C
 * failures caused false shutdowns / boot loops. Low battery shows a UI
 * warning only; manual power-off via AT+POWEROFF / button still works. */

/* Low-battery warning threshold (displayed % = actual SoC; no reserve). */
#define BATTERY_LOW_WARNING_THRESHOLD  15

/* Display re-anchor gap (%) and boot-seed floor margin (%).
 *
 * The directional display latch intentionally holds small upward gauge
 * corrections while discharging (anti-churn). But a seed that is far below
 * reality must not be latched forever: if the battery was charged while the
 * device was off (or re-flashed), the coulomb counter never saw the charge,
 * the gauge SoC stays near 0, and the persisted display seed (0) would show
 * "0% at 4.0 V" with no way up until the next charge session.
 *
 * - REANCHOR_THRESHOLD: while discharging, an upward gap this large is a
 *   re-anchor, not churn — catch up at MAX_STEP instead of holding.
 * - SEED_FLOOR_MARGIN: on the first poll after boot, a persisted seed more
 *   than REANCHOR_THRESHOLD below the voltage-curve estimate is raised to
 *   (curve estimate - margin), one-shot. */
#define BATTERY_DISPLAY_REANCHOR_THRESHOLD  20
#define BATTERY_SEED_FLOOR_MARGIN           10

/* High-temperature charge cutoff. The NPM1300 hot threshold
 * (thermistor-hot-millidegrees=45C in DTS) is the autonomous HW safety net
 * (trips even if the MCU hangs, within the 60s poll window). Because the NTC
 * path has no register hysteresis, software latches charging OFF at STOP and
 * only re-enables at RESUME (5C below) to stop rapid on/off oscillation right
 * at the boundary. Defense-in-depth: HW hot threshold + this SW hysteresis. */
#define CHARGE_STOP_TEMP_C     45.0f
#define CHARGE_RESUME_TEMP_C   40.0f   /* 5C hysteresis */
#define CHARGE_CURRENT_MA      220     /* matches DTS current-microamp; any non-zero re-enables */

/* Battery model - using Nordic's preset model */
static const struct battery_model battery_model = {
#include "battery_model.inc"
};

/* Device references */
static const struct device *pmic_dev;
static const struct device *charger_dev;

/* Cached state */
static uint8_t last_percent = 255; /* Sentinel: forces first update to always trigger */
static bool last_charging;
static bool low_battery_warned;
static bool thermal_charge_disabled;  /* sticky: latched hot, held off until resume temp */
static int64_t fg_ref_time;
static float last_wifi_load_a = -1.0f;  /* logs WiFi-comp state transitions */

/* Fuel-gauge state persistence. The library state is only valid with the
 * exact battery model from which it was captured. Keep a small envelope around
 * the opaque library blob so a model or library-state layout change cannot
 * make a new firmware resume an incompatible estimate. */
#define FG_STATE_KEY             "battery/fg_state"
#define FG_STATE_MAGIC           0x46475331U /* "FGS1" */
#define FG_STATE_FORMAT_VERSION  2U
#define FG_STATE_BUF_SIZE        512U

struct fg_state_record {
	uint32_t magic;
	uint16_t format_version;
	uint16_t state_size;
	uint32_t model_crc;
	uint8_t displayed_soc; /* last displayed (directional-smoothed) SoC, for the boot seed */
	uint8_t state[FG_STATE_BUF_SIZE];
};

static struct fg_state_record fg_state_record;
static bool fg_state_loaded;
static uint8_t last_saved_soc = 255U;  /* last SoC% persisted (255 = force first save) */

/* Directional-smoothed display SoC. Persisted across reboot so it resumes from
 * the value shown before reboot (no cross-reboot lag accumulation). 0xFF means
 * "not seeded yet" — the first poll seeds it from the gauge. */
static uint8_t displayed_percent = 0xFF;

static uint32_t fg_model_crc(void)
{
	return crc32_ieee((const uint8_t *)&battery_model, sizeof(battery_model));
}

static void fg_state_reset(void)
{
	memset(&fg_state_record, 0, sizeof(fg_state_record));
	fg_state_loaded = false;
}

static int fg_state_settings_set(const char *key, size_t len,
				 settings_read_cb read_cb, void *cb_arg)
{
	ARG_UNUSED(key);
	const size_t expected_len = offsetof(struct fg_state_record, state) +
				    nrf_fuel_gauge_state_size;

	/* The old raw-blob format deliberately does not pass this check. A raw
	 * blob may have been generated with a different model and is unsafe to
	 * restore after the model update. */
	if (len != expected_len) {
		LOG_WRN("fg state incompatible (size %u)",
			(unsigned int)len);
		fg_state_reset();
		return 0;
	}

	fg_state_reset();
	ssize_t n = read_cb(cb_arg, &fg_state_record, len);
	if (n != (ssize_t)len) {
		LOG_WRN("Fuel-gauge state read failed: %d", (int)n);
		fg_state_reset();
		return 0;
	}

	if (fg_state_record.magic != FG_STATE_MAGIC ||
	    fg_state_record.format_version != FG_STATE_FORMAT_VERSION ||
	    fg_state_record.state_size != nrf_fuel_gauge_state_size ||
	    fg_state_record.model_crc != fg_model_crc()) {
		LOG_WRN("fg state: model/version mismatch, ignored");
		fg_state_reset();
		return 0;
	}

	fg_state_loaded = true;
	return 0;
}
SETTINGS_STATIC_HANDLER_DEFINE(fg_state, "battery/fg_state", NULL,
			      fg_state_settings_set, NULL, NULL);

static void fg_state_load(void)
{
	/* config_init() initializes settings before battery_init(). It only loads
	 * config/time, though, so explicitly load the battery subtree before using
	 * the saved state. */
	fg_state_reset();
	int ret = settings_load_subtree("battery");
	if (ret != 0) {
		LOG_WRN("Fuel-gauge state load failed: %d", ret);
	}
}

/* Fuel gauge state */
static bool fg_initialized;

/* Mutex serializing read_and_update() — called from display_thread and the
 * system workqueue; the nRF Fuel Gauge is non-reentrant and fg_ref_time is
 * shared. */
static K_MUTEX_DEFINE(battery_mutex);

/* 60-second periodic battery level polling */
static struct k_work_delayable battery_level_work;

/* Delayed update after VBUS detection (charger needs time to start) */
static struct k_work_delayable battery_delayed_update_work;

/* True once battery_init() has completed; prevents posting events before
 * the event dispatcher (semaphore) is initialized. */
static bool init_complete;

static void read_and_update_locked(void);
static void read_and_update(void);

void battery_poll(void)
{
	read_and_update();
	LOG_INF("Battery poll: %u%%, charging=%d", last_percent, last_charging);
}

/* Save the fuel gauge state to settings (LittleFS). Call on SoC change + on
 * graceful shutdown/reboot so the SoC is continuous across reboots. */
/* Internal: assumes the caller holds battery_mutex (the nRF Fuel Gauge is
 * non-reentrant, and nrf_fuel_gauge_state_get() here must not race
 * nrf_fuel_gauge_process() in read_and_update_locked()). */
static void battery_save_fg_state_unlocked(void)
{
	const size_t save_len = offsetof(struct fg_state_record, state) +
				nrf_fuel_gauge_state_size;

	if (!fg_initialized) {
		return;
	}
	if (nrf_fuel_gauge_state_size > sizeof(fg_state_record.state)) {
		LOG_WRN("fg_state buf too small (%u < %u)",
			(unsigned)sizeof(fg_state_record.state), (unsigned)nrf_fuel_gauge_state_size);
		return;
	}

	fg_state_record.magic = FG_STATE_MAGIC;
	fg_state_record.format_version = FG_STATE_FORMAT_VERSION;
	fg_state_record.state_size = nrf_fuel_gauge_state_size;
	fg_state_record.model_crc = fg_model_crc();
	fg_state_record.displayed_soc =
		(displayed_percent != 0xFF) ? displayed_percent : (uint8_t)last_percent;

	int ret = nrf_fuel_gauge_state_get(fg_state_record.state,
					   sizeof(fg_state_record.state));
	if (ret != 0) {
		LOG_WRN("fg_state_get failed: %d", ret);
		return;
	}
	ret = settings_save_one(FG_STATE_KEY, &fg_state_record, save_len);
	if (ret) {
		LOG_WRN("fg_state save failed: %d", ret);
	} else {
		fg_state_loaded = true;
	}
}

/* Public: serializes against the battery poll (battery_mutex) so the gauge
 * state_get here can't race nrf_fuel_gauge_process() on another thread. Safe
 * to call from any context (e.g. the power-off work item). */
void battery_save_fg_state(void)
{
	k_mutex_lock(&battery_mutex, K_FOREVER);
	battery_save_fg_state_unlocked();
	k_mutex_unlock(&battery_mutex);
}

static int read_sensors(float *voltage, float *current, float *temp, int32_t *chg_status)
{
	struct sensor_value val;
	int ret;

	ret = sensor_sample_fetch(charger_dev);
	if (ret < 0) {
		LOG_WRN("Battery sensor sample fetch failed: %d", ret);
		return ret;
	}

	sensor_channel_get(charger_dev, SENSOR_CHAN_GAUGE_VOLTAGE, &val);
	*voltage = (float)val.val1 + ((float)val.val2 / 1000000);

	sensor_channel_get(charger_dev, SENSOR_CHAN_GAUGE_TEMP, &val);
	*temp = (float)val.val1 + ((float)val.val2 / 1000000);

	sensor_channel_get(charger_dev, SENSOR_CHAN_GAUGE_AVG_CURRENT, &val);
	*current = (float)val.val1 + ((float)val.val2 / 1000000);

	sensor_channel_get(charger_dev, SENSOR_CHAN_NPM13XX_CHARGER_STATUS, &val);
	*chg_status = val.val1;

	return 0;
}

static int charge_status_inform(int32_t chg_status)
{
	union nrf_fuel_gauge_ext_state_info_data state_info;

	if (chg_status & CHG_STATUS_COMPLETE_MASK) {
		state_info.charge_state = NRF_FUEL_GAUGE_CHARGE_STATE_COMPLETE;
	} else if (chg_status & CHG_STATUS_TRICKLE_MASK) {
		state_info.charge_state = NRF_FUEL_GAUGE_CHARGE_STATE_TRICKLE;
	} else if (chg_status & CHG_STATUS_CC_MASK) {
		state_info.charge_state = NRF_FUEL_GAUGE_CHARGE_STATE_CC;
	} else if (chg_status & CHG_STATUS_CV_MASK) {
		state_info.charge_state = NRF_FUEL_GAUGE_CHARGE_STATE_CV;
	} else {
		state_info.charge_state = NRF_FUEL_GAUGE_CHARGE_STATE_IDLE;
	}

	return nrf_fuel_gauge_ext_state_update(NRF_FUEL_GAUGE_EXT_STATE_INFO_CHARGE_STATE_CHANGE,
					       &state_info);
}

static bool poll_vbus_status(void)
{
	struct sensor_value val;
	int ret = sensor_channel_get(charger_dev, SENSOR_CHAN_NPM13XX_CHARGER_VBUS_STATUS, &val);
	if (ret < 0) {
		return false;
	}
	return val.val1 != 0;
}

/* WiFi radio load the NPM1300 IBAT sense cannot see, in amperes.
 *
 * The nRF7002 main VDD (BUCKVBAT) taps VBAT upstream of the NPM1300, so the
 * radio's TX/RX/internal-buck current never passes through the PMIC's IBAT
 * sense resistor — GAUGE_AVG_CURRENT is blind to it in both charge and
 * discharge states. This returns a state-keyed estimate (AP idle / active
 * UDP transfer / off) so it can be folded into the current fed to
 * nrf_fuel_gauge_process() as extra discharge. Calibrate the two mA values
 * from CLIP_BATTERY_WIFI_*_LOAD_MA against (total_battery - |IBAT|). */
static float wifi_load_estimate_a(void)
{
	if (!IS_ENABLED(CONFIG_CLIP_BATTERY_WIFI_LOAD_COMPENSATION)) {
		return 0.0f;
	}

	int ma = 0;
	if (wifi_ap_is_running()) {
		if (transfer_is_active()) {
			ma = CONFIG_CLIP_BATTERY_WIFI_TX_LOAD_MA;
		} else if (wifi_ap_sta_connected()) {
			ma = CONFIG_CLIP_BATTERY_WIFI_AP_LOAD_MA;
		}
		/* AP beaconing with no station associated: the unseen nRF70
		 * current is far below the AP_LOAD_MA upper bound. Counting
		 * it anyway phantom-drains the coulomb counter (an AP left on
		 * overnight reads the pack empty while the voltage is still
		 * high), so an idle client-less AP contributes nothing. */
	}
	return (float)ma / 1000.0f;
}

/* Piecewise-linear voltage-to-SoC estimate for the HSZ 362123 Li-Po.
 * Coarse (no load/temperature correction) — used as the fallback SoC
 * source and as a sanity reference for the persisted fuel-gauge state. */
static uint8_t voltage_soc_estimate(float voltage)
{
	if (voltage >= 4.15f) {
		return 100;
	} else if (voltage >= 3.75f) {
		/* 3.75-4.15V: 50-100% (upper plateau) */
		return (uint8_t)(50.0f + (voltage - 3.75f) / (4.15f - 3.75f) * 50.0f);
	} else if (voltage >= 3.45f) {
		/* 3.45-3.75V: 10-50% (mid plateau, relatively flat) */
		return (uint8_t)(10.0f + (voltage - 3.45f) / (3.75f - 3.45f) * 40.0f);
	} else if (voltage > 3.3f) {
		/* 3.3-3.45V: 0-10% (steep drop at end) */
		return (uint8_t)((voltage - 3.3f) / (3.45f - 3.3f) * 10.0f);
	}
	return 0;
}

static void read_and_update_locked(void)
{
	struct clip_context *ctx = clip_get_context();
	float voltage, current, temp;
	int32_t chg_status;
	int ret;
	uint8_t percent;
	bool charging;
	bool charger_connected;
	bool vbus_connected;
	bool is_trickle, is_cc, is_cv, charger_complete;

	if (!device_is_ready(charger_dev)) {
		return;
	}

	/* Read sensors */
	ret = read_sensors(&voltage, &current, &temp, &chg_status);
	if (ret < 0) {
		return;
	}

	/* Get VBUS status */
	vbus_connected = poll_vbus_status();

	/* ---- High-temperature charge gating (software hysteresis) ----
	 * The HW hot threshold (45C, thermistor-hot-millidegrees in DTS)
	 * autonomously inhibits charging, but the NTC path has no silicon
	 * hysteresis so a cell resting at ~45C would oscillate charge on/off.
	 * Latch charging OFF once temp hits STOP, and only re-enable once temp
	 * drops to RESUME (5C below). vbus_connected is checked so we never
	 * toggle the charger enable while unplugged. The HW threshold remains
	 * as a safety net if this poll is late. */
	if (vbus_connected) {
		struct sensor_value cur = {0};
		if (temp >= CHARGE_STOP_TEMP_C && !thermal_charge_disabled) {
			cur.val1 = 0;  /* GAUGE_DESIRED_CHARGING_CURRENT=0 -> CHGR_EN_CLR */
			if (sensor_attr_set(charger_dev,
					    SENSOR_CHAN_GAUGE_DESIRED_CHARGING_CURRENT,
					    SENSOR_ATTR_CONFIGURATION, &cur) == 0) {
				thermal_charge_disabled = true;
				LOG_WRN("charge off: temp %dC>=%dC (hot)",
					(int)temp, (int)CHARGE_STOP_TEMP_C);
			} else {
				LOG_ERR("Charge disable failed (temp %dC)", (int)temp);
			}
		} else if (temp < CHARGE_RESUME_TEMP_C && thermal_charge_disabled) {
			/* non-zero -> ERR_CLR + EN_SET; chip uses DTS current (220mA) */
			cur.val1 = CHARGE_CURRENT_MA;
			if (sensor_attr_set(charger_dev,
					    SENSOR_CHAN_GAUGE_DESIRED_CHARGING_CURRENT,
					    SENSOR_ATTR_CONFIGURATION, &cur) == 0) {
				thermal_charge_disabled = false;
				LOG_INF("charge resume: temp %dC<%dC",
					(int)temp, (int)CHARGE_RESUME_TEMP_C);
			}
		}
	}

	/* Parse charger status bits */
	is_trickle = (chg_status & CHG_STATUS_TRICKLE_MASK) != 0;
	is_cc = (chg_status & CHG_STATUS_CC_MASK) != 0;
	is_cv = (chg_status & CHG_STATUS_CV_MASK) != 0;
	charger_complete = (chg_status & CHG_STATUS_COMPLETE_MASK) != 0;

	/* Determine charger connected status */
	charger_connected = vbus_connected && (is_trickle || is_cc || is_cv || charger_complete);

	/* Update VBUS state in fuel gauge */
	if (fg_initialized) {
		ret = nrf_fuel_gauge_ext_state_update(
			vbus_connected ? NRF_FUEL_GAUGE_EXT_STATE_INFO_VBUS_CONNECTED
				       : NRF_FUEL_GAUGE_EXT_STATE_INFO_VBUS_DISCONNECTED,
			NULL);
		if (ret < 0) {
			LOG_WRN("Could not update VBUS state: %d", ret);
		}

		/* Update charge status if changed */
		static int32_t chg_status_prev;
		if (chg_status != chg_status_prev) {
			chg_status_prev = chg_status;
			charge_status_inform(chg_status);
		}

		/* Calculate time delta */
		float delta = (float)k_uptime_delta(&fg_ref_time) / 1000.f;

		/* WiFi compensation: fold in the nRF70 current GAUGE_AVG_CURRENT
		 * cannot see (it bypasses the PMIC on VBAT-direct). Added as extra
		 * discharge (positive in the lib convention) in both charge and
		 * discharge states. current is in amperes (sensor_value_from_micro). */
		float wifi_load_a = wifi_load_estimate_a();
		if (wifi_load_a != last_wifi_load_a) {
			last_wifi_load_a = wifi_load_a;
			LOG_INF("Battery fg: ibat=%d mA, wifi_comp=%d mA",
				(int)(current * 1000.0f), (int)(wifi_load_a * 1000.0f));
		}

		/* nrf_fuel_gauge lib expects negative = charging; GAUGE_AVG_CURRENT
		 * is negative = discharging, so negate. Without this the Coulomb
		 * count runs backwards and SoC jumps (voltage correction fights it). */
		float soc = nrf_fuel_gauge_process(voltage, -current + wifi_load_a,
						  temp, delta, NULL);
		percent = (uint8_t)soc;

		/* Determine charging status for display/BLE:
		 * - Charging if VBUS connected AND (trickle/CC/CV active OR not yet full)
		 * - Not charging only if VBUS disconnected OR (charger_complete AND soc >= 99%)
		 */
		bool battery_full = (percent >= BATTERY_FULL_THRESHOLD);
		charging = charger_connected && (!charger_complete || !battery_full);

		/* Debug log for charging state */
		if (charger_connected && !last_charging) {
			LOG_DBG("Chg: VBUS=%d trk=%d CC=%d CV=%d done=%d SoC=%u%% full=%d",
				vbus_connected, is_trickle, is_cc, is_cv, charger_complete, percent, battery_full);
		}
	} else {
		/* Fallback: piecewise-linear voltage-SoC curve for HSZ 362123 Li-Po */
		percent = voltage_soc_estimate(voltage);
		bool battery_full = (percent >= BATTERY_FULL_THRESHOLD);
		charging = charger_connected && (!charger_complete || !battery_full);
	}

	/* Directional-smoothed display SoC (CLIP_BATTERY_DISPLAY_MAX_STEP).
	 * The gauge already estimates SoC from V/I/T/time; we only smooth the
	 * DISPLAY value so it doesn't churn or jump:
	 *  - charging: move UP toward the gauge only (catch up + track charge),
	 *  - discharging/idle: move DOWN toward the gauge only (track depletion).
	 * So a normal charge/discharge (<= MAX_STEP/poll) tracks with ZERO lag,
	 * and the gauge's voltage-reconciliation up-correction (the ~5-15% jump
	 * on the first reboot after cycling) is HELD while discharging (no upward
	 * creep on a discharging battery) and only corrected on the next charge.
	 * `displayed_percent` is persisted (seed on boot) so there is no
	 * cross-reboot lag accumulation. The raw gauge value (percent) is still
	 * logged as "actual" for calibration. */
	uint8_t display_percent;
	if (vbus_connected && charger_complete) {
		/* Charge complete: force 100% immediately (gauge plateaus ~99%). */
		display_percent = 100;
		displayed_percent = 100;
	} else if (displayed_percent == 0xFF) {
		/* First poll with no persisted seed: start at the gauge value. */
		display_percent = percent;
		displayed_percent = percent;
	} else if (charging) {
		/* Charging: catch up toward the gauge, upward only, rate-limited. */
		int diff = (int)percent - (int)displayed_percent;
		if (diff > CONFIG_CLIP_BATTERY_DISPLAY_MAX_STEP) {
			diff = CONFIG_CLIP_BATTERY_DISPLAY_MAX_STEP;
		} else if (diff < 0) {
			diff = 0;  /* don't decrease while charging */
		}
		displayed_percent = (uint8_t)((int)displayed_percent + diff);
		display_percent = displayed_percent;
	} else {
		/* Discharging/idle: track depletion, downward only, rate-limited.
		 * An upward gauge correction is held until the next charge. */
		int diff = (int)percent - (int)displayed_percent;
		if (diff < -CONFIG_CLIP_BATTERY_DISPLAY_MAX_STEP) {
			diff = -CONFIG_CLIP_BATTERY_DISPLAY_MAX_STEP;
		} else if (diff > 0) {
			/* Re-anchor escape: a LARGE upward gap is the gauge
			 * recovering from a phantom-drained counter (e.g. the
			 * old WiFi over-compensation), not display churn. Let it
			 * catch up at MAX_STEP; small corrections (<= the
			 * threshold) stay held per the anti-churn design. */
			diff = (diff >= BATTERY_DISPLAY_REANCHOR_THRESHOLD)
				       ? CONFIG_CLIP_BATTERY_DISPLAY_MAX_STEP
				       : 0;
		}
		displayed_percent = (uint8_t)((int)displayed_percent + diff);
		display_percent = displayed_percent;
	}

	/* Update battery percent (display value) */
	if (display_percent != last_percent) {
		last_percent = display_percent;
		bt_bas_set_battery_level(display_percent);
		ctx->status.battery_percent = display_percent;
		LOG_INF("Battery: %u%% (actual %u%%, %u mV)",
			display_percent, percent, (uint32_t)(voltage * 1000));

		/* Low battery warning and auto-shutdown use displayed percentage */
		if (!charging) {
			if (display_percent <= BATTERY_LOW_WARNING_THRESHOLD
			    && !low_battery_warned) {
				display_post_event(UI_EVENT_LOW_BATTERY);
				low_battery_warned = true;
			}
		}
	}

	/* Update charging status */
	if (charging != last_charging) {
		last_charging = charging;
		ctx->status.battery_charging = charging;

		if (charging) {
			low_battery_warned = false;
			bt_bas_bls_set_battery_charge_state(
				BT_BAS_BLS_CHARGE_STATE_CHARGING);

			/* Set charge type */
			if (is_trickle) {
				bt_bas_bls_set_battery_charge_type(
					BT_BAS_BLS_CHARGE_TYPE_TRICKLE);
			} else if (is_cv) {
				bt_bas_bls_set_battery_charge_type(
					BT_BAS_BLS_CHARGE_TYPE_CONSTANT_VOLTAGE);
			} else if (is_cc) {
				bt_bas_bls_set_battery_charge_type(
					BT_BAS_BLS_CHARGE_TYPE_CONSTANT_CURRENT);
			} else {
				/* Charger connected but in trickle/termination phase */
				bt_bas_bls_set_battery_charge_type(
					BT_BAS_BLS_CHARGE_TYPE_TRICKLE);
			}

			LOG_INF("Charging: type=%s",
				is_trickle ? "trickle" : is_cv ? "CV" : is_cc ? "CC" : "trickle");
		} else {
			bt_bas_bls_set_battery_charge_state(
				BT_BAS_BLS_CHARGE_STATE_DISCHARGING_ACTIVE);
			LOG_INF("Discharging");
		}
	}

	/* Expose voltage + temp for AT+GSTAT / AT+BATT (refreshed every poll). */
	ctx->status.battery_mv = (uint16_t)(voltage * 1000.0f);
	ctx->status.battery_temp = (int8_t)temp;

	/* Update display with current status */
	struct display_status ds = {
		.battery_percent = last_percent,
		.battery_charging = last_charging,
		.ble_connected = ble_is_connected(),
		.transferring = transfer_is_active(),
	};
	display_update_status(&ds);
}

/* Wrapper: serialize read_and_update_locked() across threads (display_thread
 * and system workqueue both call it; the fuel gauge is non-reentrant). */
static void read_and_update(void)
{
	k_mutex_lock(&battery_mutex, K_FOREVER);
	read_and_update_locked();
	k_mutex_unlock(&battery_mutex);
}

/* NPM1300 event callback — called from system work queue context */
static struct gpio_callback pmic_cb;

static void pmic_event_callback(const struct device *dev, struct gpio_callback *cb,
				uint32_t pins)
{
	/* Don't post events or read sensors before the system is initialized
	 * (event_notify_sem may not be set up yet — battery_init runs before
	 * clip_event_init in main.c). */
	if (!init_complete) {
		return;
	}

	if (pins & BIT(NPM13XX_EVENT_VBUS_DETECTED)) {
		LOG_INF("PMIC event: VBUS detected");
		clip_post_event(CLIP_EVENT_USB_CONNECTED);
		/* Re-read after charger has started (takes ~2-3s) */
		k_work_schedule(&battery_delayed_update_work, K_SECONDS(3));
	}
	if (pins & BIT(NPM13XX_EVENT_VBUS_REMOVED)) {
		LOG_INF("PMIC event: VBUS removed");
	}
	if (pins & BIT(NPM13XX_EVENT_CHG_COMPLETED)) {
		LOG_DBG("PMIC: charge complete");
	}
	if (pins & BIT(NPM13XX_EVENT_CHG_ERROR)) {
		LOG_INF("PMIC event: Charge error");
	}

	/* Read and update battery status on any event */
	read_and_update();
}

/* Delayed re-read after VBUS detection to catch charger start */
static void battery_delayed_update_handler(struct k_work *work)
{
	read_and_update();
}

/* 60-second periodic battery level polling */
static void battery_level_handler(struct k_work *work)
{
	read_and_update();
	/* Persist the fuel-gauge state when its displayed integer SoC changes.
	 * The SoC moves slowly, so this writes infrequently — not every poll —
	 * to avoid wearing the LittleFS settings flash. The graceful shutdown/
	 * reboot paths also save (a fresh copy) via battery_save_fg_state(). */
	if (last_percent != last_saved_soc) {
		battery_save_fg_state_unlocked();  /* already under battery_mutex */
		last_saved_soc = last_percent;
	}
	k_work_schedule(&battery_level_work, K_SECONDS(60));
}

int battery_init(void)
{
	int ret;
	struct nrf_fuel_gauge_init_parameters init_params = {
		.model = &battery_model,
		.opt_params = NULL,
		.state = fg_state_loaded ? fg_state_record.state : NULL,
	};
	float max_charge_current;
	float term_charge_current;
	int32_t chg_status;
	struct sensor_value value;

	pmic_dev = DEVICE_DT_GET(DT_NODELABEL(npm1300));
	charger_dev = DEVICE_DT_GET(DT_NODELABEL(npm1300_charger));

	if (!device_is_ready(charger_dev)) {
		LOG_WRN("NPM1300 charger not ready");
		return -ENODEV;
	}

	/* settings_load_subtree("config") in config_init() does not load this
	 * subtree. Do this before creating the fuel gauge so state is genuinely
	 * resumed instead of silently discarded on every reboot. */
	fg_state_load();

	LOG_INF("Battery: 240mAh, fuel gauge %s", nrf_fuel_gauge_version);

	/* Read initial sensor values */
	ret = read_sensors(&init_params.v0, &init_params.i0, &init_params.t0, &chg_status);
	if (ret < 0) {
		LOG_WRN("fg init: sensor read %d", ret);
		/* Continue with basic battery monitoring */
	} else {
		/* Print initial readings (sensor convention: I negative = discharging) */
		LOG_INF("init: V=%.3f I=%.3f T=%.1f chg=0x%02x",
			init_params.v0, init_params.i0, init_params.t0,
			(unsigned int)chg_status);

		/* Zephyr sensor API: negative = discharging; nrf_fuel_gauge expects
		 * negative = charging -- negate i0 so the fuel gauge starts correct. */
		init_params.i0 = -init_params.i0;

		/* Get charge current limits */
		sensor_channel_get(charger_dev, SENSOR_CHAN_GAUGE_DESIRED_CHARGING_CURRENT, &value);
		max_charge_current = (float)value.val1 + ((float)value.val2 / 1000000);
		term_charge_current = max_charge_current / 10.f;

		/* Initialize fuel gauge */
		ret = nrf_fuel_gauge_init(&init_params, NULL);
		if (ret < 0) {
			LOG_WRN("fuel gauge init %d, using voltage SoC", ret);
		} else {
			fg_initialized = true;

			/* Stale-state heal: if the persisted display seed is far
			 * below what the boot-time (near-relaxed) voltage says,
			 * the restored coulomb counter was phantom-drained (WiFi
			 * over-compensation while the AP ran, bad wake-time
			 * voltage samples ratcheting the model down, or the pack
			 * charged while the device was off). Discard the restored
			 * state — the gauge re-estimates from voltage and the
			 * display seeds from the gauge, consistently. */
			if (fg_state_loaded &&
			    (int)voltage_soc_estimate(init_params.v0) -
					    (int)fg_state_record.displayed_soc >=
				    BATTERY_DISPLAY_REANCHOR_THRESHOLD) {
				LOG_WRN("stale fg state: %.3fV vs seed %u%% -> new estimate",
					init_params.v0,
					(unsigned int)fg_state_record.displayed_soc);
				fg_state_loaded = false;
				init_params.state = NULL;
				displayed_percent = 0xFF;
			}

			LOG_INF("Fuel-gauge state: %s", fg_state_loaded ? "restored" : "new estimate");

			/* Seed the directional-smoothed display from the persisted value so
			 * it resumes from the pre-reboot reading (no cross-reboot lag). */
			if (fg_state_loaded) {
				displayed_percent = fg_state_record.displayed_soc;
			}

			/* Configure charge current limits */
			nrf_fuel_gauge_ext_state_update(NRF_FUEL_GAUGE_EXT_STATE_INFO_CHARGE_CURRENT_LIMIT,
						      &(union nrf_fuel_gauge_ext_state_info_data){
							      .charge_current_limit = max_charge_current});
			nrf_fuel_gauge_ext_state_update(NRF_FUEL_GAUGE_EXT_STATE_INFO_TERM_CURRENT,
						      &(union nrf_fuel_gauge_ext_state_info_data){
							      .charge_term_current = term_charge_current});

			/* Set initial charge status */
			charge_status_inform(chg_status);

			/* Initialize VBUS state */
			bool vbus_connected = poll_vbus_status();
			nrf_fuel_gauge_ext_state_update(
				vbus_connected ? NRF_FUEL_GAUGE_EXT_STATE_INFO_VBUS_CONNECTED
					       : NRF_FUEL_GAUGE_EXT_STATE_INFO_VBUS_DISCONNECTED,
				NULL);

			fg_ref_time = k_uptime_get();
		}
	}

	/* Register PMIC event callbacks for charging-related events */
	gpio_init_callback(&pmic_cb, pmic_event_callback,
			   BIT(NPM13XX_EVENT_VBUS_DETECTED) |
			   BIT(NPM13XX_EVENT_VBUS_REMOVED) |
			   BIT(NPM13XX_EVENT_CHG_COMPLETED) |
			   BIT(NPM13XX_EVENT_CHG_ERROR));

	ret = mfd_npm13xx_add_callback(pmic_dev, &pmic_cb);
	if (ret != 0) {
		LOG_WRN("PMIC cb failed %d (polling)", ret);
		/* Continue with polling only */
	}

	/* Initial read */
	read_and_update();

	/* Start periodic battery level polling */
	k_work_init_delayable(&battery_level_work, battery_level_handler);
	k_work_schedule(&battery_level_work, K_SECONDS(60));

	/* Initialize delayed update work for VBUS detection */
	k_work_init_delayable(&battery_delayed_update_work, battery_delayed_update_handler);

	LOG_INF("Battery init (poll=60s, fg=%s)",
		fg_initialized ? "enabled" : "disabled");

	/* Allow read_and_update to post events now that we return to main. */
	init_complete = true;

	return 0;
}
