/*
 * Copyright (c) 2025 Seeed Technology Co., Ltd.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#include <zephyr/kernel.h>
#include <zephyr/device.h>
#include <zephyr/drivers/gpio.h>
#include <zephyr/logging/log.h>
#include <zephyr/sys/util.h>

#include "button_handler.h"
#include "state_machine.h"
#include "audio.h"
#include "clip.h"
#include "display_ctrl.h"

LOG_MODULE_REGISTER(button_handler, LOG_LEVEL_INF);

/* Button device from device tree */
static const struct device *button_dev = DEVICE_DT_GET(DT_NODELABEL(usr_btn));

/* Work queue for deferred button actions (needs larger stack for audio operations) */
static K_THREAD_STACK_DEFINE(button_work_stack, CLIP_BUTTON_WORK_STACK_SIZE);
static struct k_work_q button_work_q;
static struct k_work button_start_work;
static struct k_work button_stop_work;
static struct k_work button_bookmark_work;

/* Forward declarations */
static void button_event_callback(const struct device *dev,
				   enum button_action action);
static void button_start_work_handler(struct k_work *work);
static void button_stop_work_handler(struct k_work *work);
static void button_bookmark_work_handler(struct k_work *work);

int button_handler_init(void)
{
	int ret;

	if (!device_is_ready(button_dev)) {
		LOG_ERR("Button device not ready");
		return -ENODEV;
	}

	LOG_INF("Initializing button handler...");

	/* Initialize work queue for button actions */
	k_work_queue_start(&button_work_q, button_work_stack,
			   CLIP_BUTTON_WORK_STACK_SIZE, CLIP_BUTTON_WORK_PRIORITY, NULL);

	/* Initialize work items */
	k_work_init(&button_start_work, button_start_work_handler);
	k_work_init(&button_stop_work, button_stop_work_handler);
	k_work_init(&button_bookmark_work, button_bookmark_work_handler);

	/* Register callback for all button events */
	ret = button_callback_register(button_dev, button_event_callback);
	if (ret < 0) {
		LOG_ERR("Failed to register button callback: %d", ret);
		return ret;
	}

	LOG_INF("Button handler initialized");
	LOG_INF("Short press: Add bookmark (during recording)");
	LOG_INF("Long press (1s): Toggle recording start/stop");

	return 0;
}

bool button_handler_is_ready(void)
{
	return device_is_ready(button_dev);
}

/* Work handlers - run in work queue with larger stack */
static void button_start_work_handler(struct k_work *work)
{
	enum audio_mode mode;
	int err;

	ARG_UNUSED(work);

	/* Check if audio is actually recording (more accurate than state machine) */
	if (audio_is_recording()) {
		LOG_WRN("Button: Start work but audio is recording, ignoring");
		return;
	}

	/* Mode mapping: NORMAL=stereo, ENHANCED=mono+DSP */
	mode = (g_config.mode == MODE_NORMAL) ? AUDIO_MODE_STEREO : AUDIO_MODE_MERGE;
	err = audio_start_recording(mode);
	if (err == 0) {
		state_transition(CLIP_STATE_RECORDING);
		LOG_INF("Button: Started recording");
	} else if (err == -EBUSY) {
		LOG_WRN("Button: Audio module busy (stopping previous recording), ignoring");
	} else {
		LOG_ERR("Button: Failed to start recording: %d", err);
	}
}

static void button_stop_work_handler(struct k_work *work)
{
	int err;

	ARG_UNUSED(work);

	/* Check if audio is actually recording (more accurate than state machine) */
	if (!audio_is_recording()) {
		LOG_WRN("Button: Stop work but audio is not recording, ignoring");
		return;
	}

	/* Stop recording - state transition will be handled by audio thread */
	err = audio_stop_recording();
	if (err == 0) {
		LOG_INF("Button: Stop requested, audio thread will transition to IDLE");
	} else if (err == -EBUSY) {
		LOG_WRN("Button: Audio module busy (stopping previous recording)");
	} else {
		LOG_ERR("Button: Failed to stop recording: %d", err);
	}
}

static void button_bookmark_work_handler(struct k_work *work)
{
	int err;

	ARG_UNUSED(work);

	err = audio_add_bookmark(NULL);
	if (err == 0) {
		LOG_INF("Button: Bookmark added at %u seconds", g_recording_time);
		/* Trigger UI mark display */
		ui_trigger_mark();
	} else {
		LOG_ERR("Button: Failed to add bookmark: %d", err);
	}
}

/* Button callback - runs in button driver thread with small stack */
/* Only submit work items here, do not call audio functions directly */
static void button_event_callback(const struct device *dev,
				   enum button_action action)
{
	ARG_UNUSED(dev);

	enum clip_state current_state = state_get_current();

	/* Log both state machine and actual audio state for debugging */
	LOG_INF("Button event: %d (state_machine=%d, audio_recording=%d)",
		action, current_state, audio_is_recording());

	switch (action) {
	case BUTTON_SINGLE_CLICK:
		/* Short press: Add bookmark (only during recording) */
		if (current_state == CLIP_STATE_RECORDING) {
			LOG_INF("Button: Single click - submitting bookmark work");
			k_work_submit_to_queue(&button_work_q, &button_bookmark_work);
		} else if (current_state == CLIP_STATE_IDLE) {
			/* Show status bar in IDLE state */
			LOG_INF("Button: Single click - show status bar");
			ui_trigger_status_show();
		} else {
			LOG_INF("Button: Short press ignored (state=%d)", current_state);
		}
		break;

	case BUTTON_LONG_PRESS:
	case BUTTON_LONG_PRESS_LEVEL_1:
	case BUTTON_LONG_PRESS_LEVEL_2:
	case BUTTON_LONG_PRESS_LEVEL_3:
		/* Long press: Toggle recording based on actual audio state */
		/* Use audio_is_recording() for more reliable state detection */
		if (audio_is_recording()) {
			/* Stop recording - defer to work queue */
			LOG_INF("Button: Long press - submitting stop work");
			k_work_submit_to_queue(&button_work_q, &button_stop_work);
		} else {
			/* Start recording - defer to work queue */
			LOG_INF("Button: Long press - submitting start work");
			k_work_submit_to_queue(&button_work_q, &button_start_work);
		}
		break;

	case BUTTON_DOUBLE_CLICK:
		/* Double click: Disabled - ignore */
		LOG_DBG("Button: Double-click ignored (feature disabled)");
		break;

	default:
		LOG_WRN("Button: Unknown action: %d", action);
		break;
	}
}
