/*
 * Copyright (c) 2025 Seeed Technology Co., Ltd.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#include <zephyr/kernel.h>
#include <zephyr/sys/printk.h>
#include <zephyr/logging/log.h>
#include <stdio.h>
#include <string.h>

#include "display_ctrl.h"
#include "display.h"
#include "clip.h"
#include "state_machine.h"
#include "audio.h"
#include "battery.h"
#include "ble_svc.h"
#include "transfer.h"

LOG_MODULE_REGISTER(display_ctrl, LOG_LEVEL_INF);

static bool display_ready = false;

/* ========== Event Queue ========== */

#define UI_EVENT_QUEUE_SIZE  8
K_MSGQ_DEFINE(ui_evt_q, sizeof(enum ui_event), UI_EVENT_QUEUE_SIZE, __alignof__(enum ui_event));

/* ========== Module State ========== */

static enum ui_state ui_current_state = UI_STATE_OFF;

/* REC_WAVE: entry timestamp for 5s -> DOT transition */
static int64_t rec_wave_start_ms;

/* REC_DOT: track if entry animation has played (module-level, no shadowing) */
static bool dot_animation_played;

/* Recording paused state - overlay pause icon without changing recording display */
static bool recording_paused = false;

/* ========== Public API ========== */

void ui_post_event(enum ui_event evt)
{
	if (k_msgq_put(&ui_evt_q, &evt, K_NO_WAIT) != 0) {
		LOG_WRN("[UI] Event queue full, dropping event %d", (int)evt);
	}
}

enum ui_state ui_get_state(void)
{
	return ui_current_state;
}

/* ========== Internal Helpers ========== */

/* Animation configuration */
#define MARK_ANIM_FRAMES         15
#define MARK_ANIM_FRAME_MS       10
#define MARK_ANIM_USE_FAST_MODE  true

#define DOT_CIRCLE_FRAMES        8
#define DOT_CIRCLE_FRAME_MS      60
#define DOT_CIRCLE_STABLE_FRAME  7

/* Timeout configuration */
#define UI_STATUS_BAR_DURATION_MS  3000
#define UI_REC_WAVE_DURATION_MS    5000

static void set_state(enum ui_state new_state)
{
	if (ui_current_state != new_state) {
		LOG_DBG("[UI] State: %d -> %d", (int)ui_current_state, (int)new_state);
	}
	ui_current_state = new_state;
}

static void do_show_status_bar(void)
{
	uint8_t batt = battery_get_level();
	bool charging = battery_is_charging();
	bool ble = (ble_svc_get_connection() != NULL);
	bool xfer = transfer_is_active();

	/* Log only when values change */
	static uint8_t last_batt;
	static bool last_charging, last_ble, last_xfer;
	if (batt != last_batt || charging != last_charging ||
	    ble != last_ble || xfer != last_xfer) {
		LOG_INF("[UI] STATUS_BAR: batt=%u%% charging=%d ble=%d xfer=%d",
			batt, charging, ble, xfer);
		last_batt = batt;
		last_charging = charging;
		last_ble = ble;
		last_xfer = xfer;
	}

	display_show_info(batt, charging, ble, xfer);
}

static void do_show_mark_animation(void)
{
	LOG_INF("[UI] MARK animation");
	for (int f = 0; f < MARK_ANIM_FRAMES; f++) {
		display_show_mark_animation_frame(f, MARK_ANIM_USE_FAST_MODE);
		k_sleep(K_MSEC(MARK_ANIM_FRAME_MS));
	}
}

static void do_show_recording_dot(void)
{
	if (!dot_animation_played) {
		LOG_INF("[UI] DOT ● animation (first time)");
		for (int f = 0; f < DOT_CIRCLE_FRAMES; f++) {
			display_show_dot_circle_frame(f);
			k_sleep(K_MSEC(DOT_CIRCLE_FRAME_MS));
		}
		dot_animation_played = true;
	} else {
		display_show_dot_circle_frame(DOT_CIRCLE_STABLE_FRAME);
	}
}

/* ========== UI Thread Main Loop ========== */

void ui_thread_main(void *p1, void *p2, void *p3)
{
	ARG_UNUSED(p1);
	ARG_UNUSED(p2);
	ARG_UNUSED(p3);

	LOG_INF("[UI] Thread started");

	/* Initial state:
	 *   bonded     -> show status bar 3s then OFF
	 *   not bonded -> show pairing guide immediately
	 */
	int64_t status_bar_start_ms = 0;

	if (ble_svc_is_bonded()) {
		battery_request_update();
		set_state(UI_STATE_STATUS_BAR);
		status_bar_start_ms = k_uptime_get();
		do_show_status_bar();
		LOG_INF("[UI] Initial state: STATUS_BAR (bonded, 3s then OFF)");
	} else {
		set_state(UI_STATE_PAIRING_GUIDE);
		display_show_pairing_guide();
		LOG_INF("[UI] Initial state: PAIRING_GUIDE (not bonded)");
	}

	while (1) {
		enum ui_event evt;
		int ret;
		k_timeout_t timeout;

		/* Poll frequency depends on current state */
		switch (ui_current_state) {
		case UI_STATE_REC_WAVE:
			timeout = K_MSEC(10);   /* Fast: 10ms for smooth waveform */
			break;
		case UI_STATE_STATUS_BAR:
			timeout = K_MSEC(50);   /* Check timeout at 50ms intervals */
			break;
		default:
			timeout = K_MSEC(500);  /* Idle states: 500ms */
			break;
		}

		ret = k_msgq_get(&ui_evt_q, &evt, timeout);

		if (ret == 0) {
			/* ---- Event received ---- */
			switch (evt) {
			case UI_EVT_REC_START:
				LOG_INF("[UI] EVT: REC_START");
				rec_wave_start_ms = k_uptime_get();
				dot_animation_played = false;
				set_state(UI_STATE_REC_WAVE);
				display_show_recording(g_config.mode == MODE_ENHANCED);
				break;

			case UI_EVT_REC_STOP:
                LOG_INF("[UI] EVT: REC_STOP");
                battery_request_update();
                set_state(UI_STATE_STATUS_BAR);
                status_bar_start_ms = k_uptime_get();
                do_show_status_bar();
                break;

        case UI_EVT_REC_PAUSE:
                LOG_INF("[UI] EVT: REC_PAUSE");
                if (ui_current_state == UI_STATE_REC_WAVE ||
                    ui_current_state == UI_STATE_REC_DOT) {
                    /* Switch to paused state */
                    recording_paused = true;
                    set_state(UI_STATE_PAUSED);
                    /* Show pause icon */
                    display_show_pause_icon();
                }
                break;

        case UI_EVT_REC_RESUME:
                LOG_INF("[UI] EVT: REC_RESUME");
                if (ui_current_state == UI_STATE_PAUSED) {
                    /* Clear paused flag */
                    recording_paused = false;
                    /* Reset wave animation timer to show wave animation again */
                    rec_wave_start_ms = k_uptime_get();
                    dot_animation_played = false;
                    set_state(UI_STATE_REC_WAVE);
                    /* Show recording wave animation */
                    display_show_recording(g_config.mode == MODE_ENHANCED);
                }
                break;

			case UI_EVT_MARK:
				LOG_INF("[UI] EVT: MARK");
				if (ui_current_state == UI_STATE_REC_WAVE ||
				    ui_current_state == UI_STATE_REC_DOT) {
					set_state(UI_STATE_MARKING);
					do_show_mark_animation();
					/* After mark: return to REC_DOT stable frame */
					set_state(UI_STATE_REC_DOT);
					display_show_dot_circle_frame(DOT_CIRCLE_STABLE_FRAME);
				}
				break;

			case UI_EVT_STATUS_SHOW:
				LOG_INF("[UI] EVT: STATUS_SHOW");
				if (ui_current_state == UI_STATE_OFF ||
				    ui_current_state == UI_STATE_PAIRING_GUIDE) {
					/* Battery already refreshed by button_status_work */
					set_state(UI_STATE_STATUS_BAR);
					status_bar_start_ms = k_uptime_get();
					do_show_status_bar();
				}
				break;

			case UI_EVT_BONDED:
				LOG_INF("[UI] EVT: BONDED");
				if (ui_current_state == UI_STATE_PAIRING_GUIDE) {
					set_state(UI_STATE_OFF);
					oled_clear();
				}
				break;
			}
		} else {
			/* ---- Timeout: periodic state work ---- */
			switch (ui_current_state) {
			case UI_STATE_REC_WAVE:
				/* If paused, skip waveform update - keep current frame */
				if (recording_paused) {
					break;
				}
				/* Redraw waveform frame */
				display_show_recording(g_config.mode == MODE_ENHANCED);
				/* After 5s, transition to DOT */
				if (k_uptime_get() - rec_wave_start_ms >=
				    UI_REC_WAVE_DURATION_MS) {
					LOG_INF("[UI] REC_WAVE -> REC_DOT");
					set_state(UI_STATE_REC_DOT);
					do_show_recording_dot();
				}
				break;

			case UI_STATE_STATUS_BAR:
				/* Refresh display on every tick so live state changes are visible */
				do_show_status_bar();
				/* Check 3s timeout */
				if (k_uptime_get() - status_bar_start_ms >=
				    UI_STATUS_BAR_DURATION_MS) {
					if (ble_svc_is_bonded()) {
						LOG_INF("[UI] STATUS_BAR timeout -> OFF");
						set_state(UI_STATE_OFF);
						oled_clear();
					} else {
						LOG_INF("[UI] STATUS_BAR timeout -> PAIRING_GUIDE");
						set_state(UI_STATE_PAIRING_GUIDE);
						display_show_pairing_guide();
					}
				}
				break;

			default:
				break;
			}
		}
	}
}

/* ========== UI Thread Management ========== */

/* UI thread configuration */
#define UI_THREAD_STACK_SIZE CLIP_UI_THREAD_STACK_SIZE
#define UI_THREAD_PRIORITY   CLIP_UI_THREAD_PRIORITY

/* UI thread stack and data */
K_THREAD_STACK_DEFINE(ui_thread_stack, UI_THREAD_STACK_SIZE);
static struct k_thread ui_thread_data;
static k_tid_t ui_thread_id;

/* ========== Legacy Display API (for compatibility) ========== */

int display_init(void)
{
	int ret;

	LOG_INF("Initializing display controller...");

	/* Initialize OLED display hardware */
	ret = display_init_hw();
	if (ret) {
		LOG_WRN("OLED display init failed: %d, using serial logging mode", ret);
		display_ready = true;
		LOG_INF("Display controller: Serial logging mode (no OLED device)");
	} else {
		display_ready = true;
		/* Apply saved contrast from NVS */
		oled_set_contrast(g_config.oled_contrast);
		LOG_INF("Display controller: OLED mode active (contrast=%u)", g_config.oled_contrast);
	}

	/* Show welcome message */
	LOG_INF("DISPLAY: reSpeaker Clip Ready");
	LOG_INF("DISPLAY (%dx%d)", DISPLAY_WIDTH, DISPLAY_HEIGHT);

	/* Start UI thread */
	ui_thread_id = k_thread_create(&ui_thread_data,
				       ui_thread_stack,
				       UI_THREAD_STACK_SIZE,
				       ui_thread_main,
				       NULL, NULL, NULL,
				       UI_THREAD_PRIORITY, 0, K_NO_WAIT);
	if (!ui_thread_id) {
		LOG_WRN("Failed to create UI thread, running without UI");
		/* Continue anyway, UI is optional */
	} else {
		k_thread_name_set(&ui_thread_data, "ui_thread");
		LOG_INF("UI thread started");
	}

	LOG_INF("Display initialized");

	return 0;
}

bool display_is_ready(void)
{
	return display_ready;
}

void display_clear(void)
{
	oled_clear();
}

void display_update_status(void)
{
	/* Handled by UI thread now */
}

void display_show_message(const char *msg)
{
	if (msg) {
		LOG_INF("[UI] MSG: %s", msg);
	}
}

void display_show_error(const char *error)
{
	if (error) {
		LOG_ERR("[UI] ERROR: %s", error);
	}
}

void display_set_recording(bool recording)
{
	ui_post_event(recording ? UI_EVT_REC_START : UI_EVT_REC_STOP);
}

void display_set_recording_paused(void)
{
	ui_post_event(UI_EVT_REC_PAUSE);
}

void display_set_recording_resumed(void)
{
	ui_post_event(UI_EVT_REC_RESUME);
}

void display_update_battery(uint8_t percent)
{
	if (!display_ready) {
		return;
	}

	if (percent > 100) {
		percent = 100;
	}

	/* Only log significant changes */
	static uint8_t last_battery_percent = 0;

	if (last_battery_percent / 10 != percent / 10) {
		last_battery_percent = percent;
		LOG_DBG("[UI] Battery: %u%%", percent);
	}
}
