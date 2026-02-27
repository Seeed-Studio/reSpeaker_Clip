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
#include "clip.h"
#include "state_machine.h"
#include "audio.h"
#include "battery.h"
#include "ble_svc.h"

LOG_MODULE_REGISTER(display_ctrl, LOG_LEVEL_INF);

/* Display device - Serial logging mode only for now */
/* OLED display integration will be added later */
static bool display_ready = false;

/* Recording time tracking */
static int64_t recording_start_time_ms;
static bool recording_active = false;

/* ========== UI State Machine ========== */

/* UI state (thread-safe) */
static K_MUTEX_DEFINE(ui_state_mutex);
static enum ui_state ui_current_state = UI_STATE_IDLE;

/* Recording info state: track when to transition to dot */
static int64_t recording_state_start_ms;

/* Waveform frames (8 frames loop) - Unicode block elements */
static const char *waveform_frames[] = {
	"▂▃▅▇▅▃▂",
	"▃▅▇█▇▅▃",
	"▅▇█▇█▇▅",
	"▇█▇▅▇█▇",
	"█▇▅▃▅▇█",
	"▇▅▃▂▃▅▇",
	"▅▃▂ ▂▃▅",
	"▃▂   ▂▃",
};
static int waveform_frame_index = 0;

/* ========== Thread-Safe State Access ========== */

enum ui_state ui_get_state(void)
{
	enum ui_state state;

	k_mutex_lock(&ui_state_mutex, K_FOREVER);
	state = ui_current_state;
	k_mutex_unlock(&ui_state_mutex);

	return state;
}

void ui_set_state(enum ui_state new_state)
{
	k_mutex_lock(&ui_state_mutex, K_FOREVER);

	if (ui_current_state != new_state) {
		LOG_DBG("[UI] State: %d -> %d", ui_current_state, new_state);

		/* Track when we enter certain states */
		if (new_state == UI_STATE_RECORDING_INFO) {
			recording_state_start_ms = k_uptime_get();
		}
	}

	ui_current_state = new_state;
	k_mutex_unlock(&ui_state_mutex);
}

/* ========== UI Display Functions (Serial Logging for Verification) ========== */

static void ui_show_recording_info(void)
{
	uint32_t seconds;
	uint8_t hours, mins, secs;

	if (!recording_active) {
		return;
	}

	/* Calculate elapsed time */
	int64_t elapsed_ms = k_uptime_get() - recording_start_time_ms;
	seconds = elapsed_ms / 1000;

	/* Format as HH:MM:SS */
	hours = seconds / 3600;
	mins = (seconds % 3600) / 60;
	secs = seconds % 60;

	/* Show recording time */
	LOG_INF("[UI] REC %02u:%02u:%02u", hours, mins, secs);

	/* Show waveform animation */
	LOG_INF("[UI] WAVE: %s", waveform_frames[waveform_frame_index]);

	/* Advance waveform frame for next time */
	waveform_frame_index = (waveform_frame_index + 1) % ARRAY_SIZE(waveform_frames);
}

static void ui_show_recording_dot(void)
{
	/* Reset waveform index for next recording start */
	waveform_frame_index = 0;
	LOG_INF("[UI] REC ●");
}

static void ui_show_mark_cross(void)
{
	LOG_INF("[UI] MARK ✚");
}

static void ui_show_status_bar(void)
{
	uint8_t batt_percent;
	bool ble_connected;

	batt_percent = battery_get_level();
	ble_connected = (ble_svc_get_connection() != NULL);

	LOG_INF("[UI] BAT:%u%% BLE:%s",
		batt_percent, ble_connected ? "OK" : "--");
}

static void ui_screen_off(void)
{
	/* Only log once when transitioning to screen off */
	static enum ui_state last_logged_state = UI_STATE_IDLE;
	enum ui_state current = ui_get_state();

	if (current == UI_STATE_IDLE && last_logged_state != UI_STATE_IDLE) {
		LOG_INF("[UI] SCREEN_OFF");
	}
	last_logged_state = current;
}

/* ========== External Trigger Functions ========== */

void ui_trigger_mark(void)
{
	enum ui_state current = ui_get_state();

	/* Only show mark during recording (dot state) */
	if (current == UI_STATE_RECORDING_DOT) {
		ui_set_state(UI_STATE_MARKING);
	}
}

void ui_trigger_status_show(void)
{
	enum ui_state current = ui_get_state();

	/* Only show status bar in IDLE state */
	if (current == UI_STATE_IDLE) {
		ui_set_state(UI_STATE_STATUS_SHOW);
	}
}

void ui_handle_recording_change(bool recording)
{
	if (recording) {
		/* Recording started */
		recording_active = true;
		recording_start_time_ms = k_uptime_get();
		waveform_frame_index = 0;
		ui_set_state(UI_STATE_RECORDING_INFO);
		LOG_INF("[UI] Recording started");
	} else {
		/* Recording stopped */
		recording_active = false;
		ui_set_state(UI_STATE_IDLE);
		LOG_INF("[UI] Recording stopped");
	}
}

/* ========== UI Thread Main Loop ========== */

#define UI_RECORDING_INFO_DURATION_MS  3000  /* 3 seconds */
#define UI_MARKING_DURATION_MS         500   /* 0.5 seconds */
#define UI_STATUS_SHOW_DURATION_MS     3000  /* 3 seconds */
#define UI_IDLE_POLL_MS                100   /* Low power polling */

void ui_thread_main(void *p1, void *p2, void *p3)
{
	ARG_UNUSED(p1);
	ARG_UNUSED(p2);
	ARG_UNUSED(p3);

	LOG_INF("[UI] Thread started");

	while (1) {
		enum ui_state current = ui_get_state();

		switch (current) {
		case UI_STATE_RECORDING_INFO:
			ui_show_recording_info();

			/* Check if 3 seconds elapsed */
			if (k_uptime_get() - recording_state_start_ms >= UI_RECORDING_INFO_DURATION_MS) {
				ui_set_state(UI_STATE_RECORDING_DOT);
			}

			/* Update every ~200ms for smooth animation */
			k_sleep(K_MSEC(200));
			break;

		case UI_STATE_RECORDING_DOT:
			ui_show_recording_dot();
			/* Update every 500ms (dot doesn't animate) */
			k_sleep(K_MSEC(500));
			break;

		case UI_STATE_MARKING:
			ui_show_mark_cross();
			k_sleep(K_MSEC(UI_MARKING_DURATION_MS));
			/* Return to dot after mark display */
			ui_set_state(UI_STATE_RECORDING_DOT);
			break;

		case UI_STATE_STATUS_SHOW:
			ui_show_status_bar();
			k_sleep(K_MSEC(UI_STATUS_SHOW_DURATION_MS));
			/* Screen off after 3 seconds */
			ui_set_state(UI_STATE_IDLE);
			break;

		case UI_STATE_MESSAGE:
			/* Message display is temporary, handled by caller */
			k_sleep(K_MSEC(100));
			break;

		case UI_STATE_IDLE:
		default:
			ui_screen_off();
			/* Low power polling */
			k_sleep(K_MSEC(UI_IDLE_POLL_MS));
			break;
		}

		k_yield();
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
	LOG_INF("Initializing display controller...");

	/* Serial logging mode - no display device needed */
	display_ready = true;
	LOG_INF("Display controller: Serial logging mode (no OLED device)");

	/* Show welcome message */
	LOG_INF("DISPLAY: reSpeaker Clip Ready");
	LOG_INF("DISPLAY (%dx%d)", DISPLAY_WIDTH, DISPLAY_HEIGHT);

	/* Initialize UI state */
	ui_set_state(UI_STATE_IDLE);

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
	/* For serial logging mode, just log clear action */
	LOG_DBG("[UI] CLEAR");
}

void display_update_status(void)
{
	/* Handled by UI thread now */
}

void display_show_message(const char *msg)
{
	if (!display_ready || !msg) {
		return;
	}

	display_clear();
	LOG_INF("[UI] MSG: %s", msg);
}

void display_show_error(const char *error)
{
	if (!display_ready || !error) {
		return;
	}

	display_clear();
	LOG_INF("[UI] ERROR: %s", error);
}

void display_set_recording(bool recording)
{
	if (!display_ready) {
		return;
	}

	ui_handle_recording_change(recording);
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
