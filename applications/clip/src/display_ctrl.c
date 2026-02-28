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

/* Dot animation: track if animation has played */
static bool dot_animation_played = false;

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

		/* Reset dot animation flag when entering DOT state from other states */
		if (new_state == UI_STATE_RECORDING_DOT) {
			dot_animation_played = false;
		}

		/* Reset dot animation flag when recording stops (leaving to IDLE) */
		if (new_state == UI_STATE_IDLE) {
			dot_animation_played = false;
		}
	}

	ui_current_state = new_state;
	k_mutex_unlock(&ui_state_mutex);
}

/* ========== UI Display Functions (Serial Logging for Verification) ========== */

static void ui_show_recording_info(void)
{
	static bool logged_once = false;

	if (!recording_active) {
		logged_once = false;
		return;
	}

	if (!logged_once) {
		LOG_INF("[UI] REC wave");
		logged_once = true;
	}

	bool enhanced_mode = (g_config.mode == MODE_ENHANCED);
	display_show_recording(enhanced_mode);
}

/* Mark animation configuration */
#define MARK_ANIM_FRAMES        15    /* Number of frames to play (matches MARK_ANIM_FRAMES_FAST) */
#define MARK_ANIM_FRAME_MS      10    /* Duration per frame (ms) */
#define MARK_ANIM_USE_FAST_MODE true  /* Use fast mode */

static void ui_show_mark(void)
{
	LOG_INF("[UI] MARK animation");

	/* Play the mark animation */
	for (int frame = 0; frame < MARK_ANIM_FRAMES; frame++) {
		display_show_mark_animation_frame(frame, MARK_ANIM_USE_FAST_MODE);
		k_sleep(K_MSEC(MARK_ANIM_FRAME_MS));
	}
}

/* Dot circle animation configuration */
#define MARK_CIRCLE_FRAMES      8    /* Number of animation frames */
#define MARK_CIRCLE_FRAME_MS    60   /* Duration per frame (ms) */
#define MARK_STABLE_FRAME       7    /* Stable frame to hold (0.5x scale) */

static void ui_show_recording_dot(void)
{
	/* Track if animation has played once */
	static bool dot_animation_played = false;

	if (!dot_animation_played) {
		LOG_INF("[UI] DOT ● animation (first time)");

		/* Play the circle animation once */
		for (int frame = 0; frame < MARK_CIRCLE_FRAMES; frame++) {
			display_show_dot_circle_frame(frame);
			k_sleep(K_MSEC(MARK_CIRCLE_FRAME_MS));
		}

		dot_animation_played = true;
	} else {
		/* Just show stable frame */
		display_show_dot_circle_frame(MARK_STABLE_FRAME);
	}
}

static void ui_show_status_bar(void)
{
	uint8_t batt_percent;
	bool charging;
	bool ble_connected;
	bool transferring;

	/* Get system status */
	batt_percent = battery_get_level();
	charging = battery_is_charging();
	ble_connected = (ble_svc_get_connection() != NULL);
	transferring = transfer_is_active();

	/* Display on OLED */
	display_show_info(batt_percent, charging, ble_connected, transferring);
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

	/* Show mark during recording (INFO or DOT state) */
	if (current == UI_STATE_RECORDING_INFO || current == UI_STATE_RECORDING_DOT) {
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
		/* Recording stopped - show status page */
		recording_active = false;
		ui_set_state(UI_STATE_STATUS_SHOW);
		LOG_INF("[UI] Recording stopped, showing status");
	}
}

/* ========== UI Thread Main Loop ========== */

#define UI_RECORDING_INFO_DURATION_MS  5000  /* 5 seconds */
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

			/* Check if 5 seconds elapsed, then transition to DOT */
			if (k_uptime_get() - recording_state_start_ms >= UI_RECORDING_INFO_DURATION_MS) {
				ui_set_state(UI_STATE_RECORDING_DOT);
			}

			/* Update every 10ms for smooth animation */
			k_sleep(K_MSEC(10));
			break;

		case UI_STATE_RECORDING_DOT:
			/* Show circle animation */
			ui_show_recording_dot();
			break;

		case UI_STATE_MARKING:
			ui_show_mark();
			/* Return to dot after mark display */
			ui_set_state(UI_STATE_RECORDING_DOT);
			break;

		case UI_STATE_STATUS_SHOW:
			ui_show_status_bar();

			/* Periodically check state change to allow interrupt */
			{
				int64_t show_start = k_uptime_get();
				enum ui_state new_state;

				while (k_uptime_get() - show_start < 60000) {
					/* Check state every 100ms */
					k_sleep(K_MSEC(100));
					new_state = ui_get_state();
					if (new_state != UI_STATE_STATUS_SHOW) {
						/* State changed, break to handle new state */
						break;
					}
				}

				/* Only transition to IDLE if still in STATUS_SHOW after 60s */
				if (ui_get_state() == UI_STATE_STATUS_SHOW) {
					ui_set_state(UI_STATE_IDLE);
				}
			}
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
		LOG_INF("Display controller: OLED mode active");
	}

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
