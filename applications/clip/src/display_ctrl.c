/*
 * Copyright (c) 2025 Seeed Technology Co., Ltd.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#include <zephyr/kernel.h>
#include <zephyr/device.h>
#include <zephyr/display/display.h>
#include <zephyr/sys/printk.h>
#include <zephyr/logging/log.h>
#include <stdio.h>
#include <string.h>

#include "display_ctrl.h"
#include "clip.h"
#include "state_machine.h"
#include "audio.h"

LOG_MODULE_REGISTER(display_ctrl, LOG_LEVEL_INF);

/* Display device */
static const struct device *display_dev = DEVICE_DT_GET(DT_CHOSEN(zephyr_display));
static bool display_ready = false;

/* UI state */
static bool recording_indicator = false;
static uint8_t last_battery_percent = 0;

/* Simple 8x8 font for basic character display */
static const uint8_t font_8x8[95][8] = {
	/* Space */
	{0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00},
	/* ! */
	{0x18, 0x18, 0x18, 0x18, 0x00, 0x00, 0x18, 0x00},
	/* " */
	{0x36, 0x36, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00},
	/* # */
	{0x36, 0x36, 0x7F, 0x36, 0x7F, 0x36, 0x36, 0x00},
	/* $ */
	{0x0C, 0x3E, 0x03, 0x1E, 0x30, 0x1F, 0x0C, 0x00},
	/* % */
	{0x00, 0x33, 0x33, 0x18, 0x0C, 0x66, 0x66, 0x00},
	/* & */
	{0x1C, 0x36, 0x1C, 0x6E, 0x3B, 0x33, 0x6E, 0x00},
	/* ' */
	{0x06, 0x06, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00},
	/* ( */
	{0x18, 0x0C, 0x06, 0x06, 0x06, 0x0C, 0x18, 0x00},
	/* ) */
	{0x06, 0x0C, 0x18, 0x18, 0x18, 0x0C, 0x06, 0x00},
	/* * */
	{0x00, 0x66, 0x3C, 0xFF, 0x3C, 0x66, 0x00, 0x00},
	/* + */
	{0x00, 0x0C, 0x0C, 0x3F, 0x0C, 0x0C, 0x00, 0x00},
	/* , */
	{0x00, 0x00, 0x00, 0x00, 0x00, 0x0C, 0x06, 0x00},
	/* - */
	{0x00, 0x00, 0x00, 0x3F, 0x00, 0x00, 0x00, 0x00},
	/* . */
	{0x00, 0x00, 0x00, 0x00, 0x00, 0x0C, 0x0C, 0x00},
	/* / */
	{0x60, 0x30, 0x18, 0x0C, 0x06, 0x03, 0x01, 0x00},
	/* 0-9 digits would continue... */
	/* For simplicity, using ASCII art approach instead */
};

/* Helper function to write text to display */
static int display_write_text(const char *text, uint8_t x, uint8_t y)
{
	if (!display_ready) {
		return -ENODEV;
	}

	/* For now, just log the text */
	LOG_INF("DISPLAY[%u,%u]: %s", x, y, text);

	/* TODO: Implement actual framebuffer drawing with SSD1306 */
	/* The display API requires a graphical buffer implementation */
	/* which is complex. Using logging for initial implementation. */

	return 0;
}

int display_init(void)
{
	int ret;

	if (!device_is_ready(display_dev)) {
		LOG_ERR("Display device not ready");
		return -ENODEV;
	}

	LOG_INF("Initializing display controller...");

	/* Get display instance */
	ret = mb_display_get_device();
	if (ret < 0) {
		LOG_ERR("Failed to get display instance: %d", ret);
		return ret;
	}

	display_ready = true;

	/* Show welcome message */
	display_clear();
	display_write_text("reSpeaker", 0, 0);
	display_write_text("Clip Ready", 0, 16);

	LOG_INF("Display initialized (%dx%d)", DISPLAY_WIDTH, DISPLAY_HEIGHT);

	return 0;
}

bool display_is_ready(void)
{
	return display_ready;
}

void display_clear(void)
{
	if (!display_ready) {
		return;
	}

	struct mb_display *mb_display = mb_display_get_ambient();

	if (mb_display) {
		mb_display_blank(mb_display);
		mb_display_commit(mb_display);
	}
}

void display_update_status(void)
{
	char status[32];
	enum clip_state state;
	uint32_t seconds;

	if (!display_ready) {
		return;
	}

	state = state_get_current();

	/* Build status line based on state */
	switch (state) {
	case CLIP_STATE_IDLE:
		snprintf(status, sizeof(status), "State: IDLE");
		recording_indicator = false;
		break;

	case CLIP_STATE_RECORDING:
		seconds = g_recording_time;
		snprintf(status, sizeof(status), "REC %02u:%02u",
			 seconds / 60, seconds % 60);
		recording_indicator = true;
		break;

	case CLIP_STATE_PAUSED:
		snprintf(status, sizeof(status), "PAUSED");
		recording_indicator = false;
		break;

	case CLIP_STATE_TRANSMITTING:
		snprintf(status, sizeof(status), "SENDING...");
		break;

	case CLIP_STATE_ERROR:
		snprintf(status, sizeof(status), "ERROR!");
		break;

	default:
		snprintf(status, sizeof(status), "UNKNOWN");
		break;
	}

	/* Show status on top line */
	display_write_text(status, 0, 0);

	/* Show mode on bottom line */
	const char *mode_str = (g_config.mode == MODE_NORMAL) ? "NORMAL" : "ENHANCED";
	display_write_text(mode_str, 0, 32);
}

void display_show_message(const char *msg)
{
	if (!display_ready || !msg) {
		return;
	}

	display_clear();
	display_write_text(msg, 0, 16);
}

void display_show_error(const char *error)
{
	if (!display_ready || !error) {
		return;
	}

	display_clear();
	display_write_text("ERROR:", 0, 0);
	display_write_text(error, 0, 16);

	k_sleep(K_SECONDS(2));  /* Show error for 2 seconds */
	display_update_status();
}

void display_set_recording(bool recording)
{
	if (!display_ready) {
		return;
	}

	recording_indicator = recording;

	/* Update display immediately */
	display_update_status();
}

void display_update_battery(uint8_t percent)
{
	if (!display_ready) {
		return;
	}

	if (percent > 100) {
		percent = 100;
	}

	/* Only update if changed significantly */
	if (last_battery_percent / 10 != percent / 10) {
		last_battery_percent = percent;

		/* Show battery briefly on corner (small text) */
		char batt_str[8];
		snprintf(batt_str, sizeof(batt_str), "%u%%", percent);

		/* For now, just log it */
		LOG_INF("Battery: %u%%", percent);
		/* TODO: Show on display corner when display driver supports small fonts */
	}
}
