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
#include "display.h"
#include "battery.h"
#include <zephyr/drivers/mfd/npm13xx.h>
#include <zephyr/drivers/regulator.h>

LOG_MODULE_REGISTER(button_handler, LOG_LEVEL_DBG);

/* Button device from device tree */
static const struct device *button_dev = DEVICE_DT_GET(DT_NODELABEL(usr_btn));

/* Work queue for deferred button actions (needs larger stack for audio operations) */
static K_THREAD_STACK_DEFINE(button_work_stack, CLIP_BUTTON_WORK_STACK_SIZE);
static struct k_work_q button_work_q;
static struct k_work button_start_work;
static struct k_work button_stop_work;
static struct k_work button_bookmark_work;
static struct k_work button_status_work;
static struct k_work button_poweroff_show_work;
static struct k_work button_poweroff_exec_work;

/* Forward declarations */
static void button_event_callback(const struct device *dev,
				   enum button_action action);
static void button_start_work_handler(struct k_work *work);
static void button_stop_work_handler(struct k_work *work);
static void button_bookmark_work_handler(struct k_work *work);
static void button_status_work_handler(struct k_work *work);
static void button_poweroff_show_handler(struct k_work *work);
static void button_poweroff_exec_handler(struct k_work *work);

int button_handler_init(void)
{
	int ret;

	if (!device_is_ready(button_dev)) {
		LOG_ERR("Button device not ready");
		return -ENODEV;
	}

	LOG_DBG("Initializing button handler...");

	/* Initialize work queue for button actions */
	k_work_queue_start(&button_work_q, button_work_stack,
			   CLIP_BUTTON_WORK_STACK_SIZE, CLIP_BUTTON_WORK_PRIORITY, NULL);

	/* Initialize work items */
	k_work_init(&button_start_work, button_start_work_handler);
	k_work_init(&button_stop_work, button_stop_work_handler);
	k_work_init(&button_bookmark_work, button_bookmark_work_handler);
	k_work_init(&button_status_work, button_status_work_handler);
	k_work_init(&button_poweroff_show_work, button_poweroff_show_handler);
	k_work_init(&button_poweroff_exec_work, button_poweroff_exec_handler);

	/* Register callback for all button events */
	ret = button_callback_register(button_dev, button_event_callback);
	if (ret < 0) {
		LOG_ERR("Failed to register button callback: %d", ret);
		return ret;
	}

	LOG_DBG("Button handler initialized");

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
		/* Stop requested - audio thread will handle transition */
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

	err = audio_add_bookmark();
	if (err == 0) {
		/* Trigger UI mark display */
		ui_post_event(UI_EVT_MARK);
	} else {
		LOG_ERR("Button: Failed to add bookmark: %d", err);
	}
}

static void button_status_work_handler(struct k_work *work)
{
	ARG_UNUSED(work);

	/* Read fresh battery data via I2C *before* posting the UI event.
	 * This ensures do_show_status_bar() always sees up-to-date values. */
	battery_request_update();
	ui_post_event(UI_EVT_STATUS_SHOW);
}

/* Set when 3s long press fires; cleared on BUTTON_RELEASE */
static atomic_t poweroff_pending = ATOMIC_INIT(0);

static void button_poweroff_show_handler(struct k_work *work)
{
	ARG_UNUSED(work);

	LOG_DBG("Button: 3s long press - showing power-off screen");
	display_show_poweroff();
	/* Mark that the next BUTTON_RELEASE should execute the power-off */
	atomic_set(&poweroff_pending, 1);
}

static void button_poweroff_exec_handler(struct k_work *work)
{
	ARG_UNUSED(work);

	LOG_DBG("Button released - entering ship mode (power off)");

	/* Clear OLED before shutting down */
	oled_clear();

	/* Enter npm1300 ship mode via regulator_parent_ship_mode().
	 * This writes TASKENTERSHIPHOLD (0x0B, offset 0x02) — the only way
	 * to wake up is by holding the button for ship-to-active-time-ms (3s).
	 * Do NOT use mfd_npm13xx_hibernate() — that uses TASKENTERHIB (0x0B/0x00)
	 * which has a timer and auto-wakes after a few seconds.
	 */
	const struct device *regulators = DEVICE_DT_GET(DT_NODELABEL(npm1300_regulators));
	if (!device_is_ready(regulators)) {
		LOG_ERR("npm1300 regulators not ready, cannot power off");
		return;
	}

	int ret = regulator_parent_ship_mode(regulators);
	if (ret != 0) {
		LOG_ERR("Failed to enter ship mode: %d", ret);
	}
	/* If the write succeeded the system powers off immediately */
}

/* Button callback - runs in button driver thread with small stack */
/* Only submit work items here, do not call audio functions directly */
static void button_event_callback(const struct device *dev,
				   enum button_action action)
{
	ARG_UNUSED(dev);

	enum clip_state current_state = state_get_current();

	/* Log both state machine and actual audio state for debugging */
	LOG_DBG("Button event: %d (state=%d, recording=%d)",
		action, current_state, audio_is_recording());

	switch (action) {
	case BUTTON_SINGLE_CLICK:
		/* Short press: Add bookmark (only during recording) */
		if (current_state == CLIP_STATE_RECORDING) {
			k_work_submit_to_queue(&button_work_q, &button_bookmark_work);
		} else if (current_state == CLIP_STATE_IDLE) {
			/* Show status bar in IDLE state.
			 * Use work queue so battery I2C read completes before UI renders. */
			k_work_submit_to_queue(&button_work_q, &button_status_work);
		} else {
			LOG_DBG("Button: Short press ignored (state=%d)", current_state);
		}
		break;

	case BUTTON_LONG_PRESS:       /* released after holding 1s–3s → toggle recording */
		/* 1-second long press: toggle recording */
		if (audio_is_recording()) {
			k_work_submit_to_queue(&button_work_q, &button_stop_work);
		} else {
			k_work_submit_to_queue(&button_work_q, &button_start_work);
		}
		break;

	case BUTTON_LONG_PRESS_LEVEL_1: /* held 3s, auto-fires while button still down */
	case BUTTON_LONG_PRESS_LEVEL_2:
	case BUTTON_LONG_PRESS_LEVEL_3:
		/* 3-second long press: show power-off prompt */
		k_work_submit_to_queue(&button_work_q, &button_poweroff_show_work);
		break;

	case BUTTON_RELEASE:
		/* Button released after auto-triggered long press */
		if (atomic_cas(&poweroff_pending, 1, 0)) {
			k_work_submit_to_queue(&button_work_q, &button_poweroff_exec_work);
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
