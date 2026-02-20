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

LOG_MODULE_REGISTER(button_handler, LOG_LEVEL_INF);

/* Button device from device tree */
static const struct device *button_dev = DEVICE_DT_GET(DT_NODELABEL(usr_btn));

/* Forward declarations */
static void button_event_callback(const struct device *dev,
				   enum button_action action);

int button_handler_init(void)
{
	int ret;

	if (!device_is_ready(button_dev)) {
		LOG_ERR("Button device not ready");
		return -ENODEV;
	}

	LOG_INF("Initializing button handler...");

	/* Register callback for all button events */
	ret = button_callback_register(button_dev, button_event_callback);
	if (ret < 0) {
		LOG_ERR("Failed to register button callback: %d", ret);
		return ret;
	}

	LOG_INF("Button handler initialized");
	LOG_INF("Short press: Toggle recording");
	LOG_INF("Long press (1s): Toggle mode (normal/enhanced)");
	LOG_INF("Long press (3s): Factory reset");
	LOG_INF("Double click: Stop recording");

	return 0;
}

bool button_handler_is_ready(void)
{
	return device_is_ready(button_dev);
}

static void button_event_callback(const struct device *dev,
				   enum button_action action)
{
	ARG_UNUSED(dev);

	enum clip_state current_state = state_get_current();

	LOG_INF("Button event: %d (current state: %d)",
		action, current_state);

	switch (action) {
	case BUTTON_SINGLE_CLICK:
		/* Short press: Toggle recording */
		if (current_state == CLIP_STATE_IDLE || current_state == CLIP_STATE_PAUSED) {
			/* Start recording */
			enum audio_mode mode = (g_config.mode == MODE_ENHANCED) ?
					       AUDIO_MODE_STEREO : AUDIO_MODE_MERGE;
			int err = audio_start_recording(mode);
			if (err == 0) {
				state_transition(CLIP_STATE_RECORDING);
				LOG_INF("Button: Started recording");
			} else {
				LOG_ERR("Button: Failed to start recording: %d", err);
			}
		} else if (current_state == CLIP_STATE_RECORDING) {
			/* Pause/stop recording */
			int err = audio_stop_recording();
			if (err == 0) {
				state_transition(CLIP_STATE_IDLE);
				LOG_INF("Button: Stopped recording");
			}
		}
		break;

	case BUTTON_DOUBLE_CLICK:
		/* Double click: Stop recording immediately */
		if (current_state == CLIP_STATE_RECORDING) {
			int err = audio_stop_recording();
			if (err == 0) {
				state_transition(CLIP_STATE_IDLE);
				LOG_INF("Button: Stopped recording (double-click)");
			}
		}
		break;

	case BUTTON_LONG_PRESS:
		/* First level long press (1s): Toggle mode */
		if (current_state == CLIP_STATE_IDLE || current_state == CLIP_STATE_PAUSED) {
			/* Toggle between normal and enhanced mode */
			enum recording_mode new_mode = (g_config.mode == MODE_NORMAL) ?
						    MODE_ENHANCED : MODE_NORMAL;

			g_config.mode = new_mode;
			config_save();  /* Save to NVS */

			LOG_INF("Button: Mode changed to %s",
			       new_mode == MODE_NORMAL ? "normal" : "enhanced");

			/* TODO: Add haptic feedback */
		}
		break;

	case BUTTON_LONG_PRESS + 1:
		/* Second level long press (3s): Factory reset */
		LOG_WRN("Button: Factory reset requested!");
		/* TODO: Implement factory reset */
		/* config_factory_reset(); */
		break;

	default:
		LOG_WRN("Button: Unknown action: %d", action);
		break;
	}
}
