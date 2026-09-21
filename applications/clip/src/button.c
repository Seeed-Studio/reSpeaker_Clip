/*
 * Copyright (c) 2025 Seeed Technology Co., Ltd.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#include <zephyr/kernel.h>
#include <zephyr/device.h>
#include <zephyr/drivers/gpio.h>
#include <zephyr/logging/log.h>
#include <zephyr/drivers/input/button.h>

#include "button.h"
#include "clip_event.h"
#include "haptic.h"

LOG_MODULE_REGISTER(button, CONFIG_CLIP_LOG_LEVEL);

/* Button device from device tree */
static const struct device *button_dev = DEVICE_DT_GET(DT_NODELABEL(usr_btn));

/* Callback function and user data */
static button_callback_t button_cb = NULL;
static void *button_user_data = NULL;

/* Track power-off screen state for two-step shutdown */
static atomic_t poweroff_screen_active = ATOMIC_INIT(0);

/* Track if recording was stopped by long press (skip RELEASE action) */
static atomic_t recording_stopped = ATOMIC_INIT(0);

/* Shutdown in progress (set at POWER_OFF_EXEC entry): ignore ALL input.
 * The shutdown sequence runs hundreds of ms; presses during it used to
 * pop the status bar over the power-off screen or even race a START
 * before ship mode cut power. Cleared only by reboot. */
static atomic_t shutdown_lockout = ATOMIC_INIT(0);

static void button_event_callback(const struct device *dev, enum button_action action)
{
    ARG_UNUSED(dev);
    enum clip_state state = clip_event_get_state();

    /* Firmware upgrade in progress: ignore ALL button input. NOTE: the
     * state machine does NOT enter CLIP_STATE_OTA during upload (the
     * transition table keeps the current state), so this must check the
     * DFU flag — a state check here never fires. Blocks the unguarded
     * 3 s power-off path (would abort the update mid-upload/swap) and
     * UI switches away from the progress screen. An upgrade also
     * CANCELS a pending power-off: clear that latch, or this branch
     * eats the confirming RELEASE and a later release (after the DFU
     * flag clears) would CAS the stale latch and power the device off
     * out of nowhere. */
    if (clip_event_ota_in_progress()) {
        atomic_clear(&poweroff_screen_active);
        return;
    }

    /* Shutdown committed: ignore everything (unless the shutdown
     * failed and the handler unlocked us again). */
    if (atomic_get(&shutdown_lockout)) {
        return;
    }

    /* Power-off screen pending (3 s hold reached, waiting for the
     * confirming release): ignore everything except that RELEASE, so
     * noise during the hold can't switch the UI away from the
     * confirmation screen. A fresh max-level hold is allowed through
     * as a retry: if the confirming RELEASE is ever lost, this latch
     * would otherwise eat all input forever (dead buttons). Re-posting
     * POWER_OFF_SHOW is idempotent. */
    if (atomic_get(&poweroff_screen_active) && action != BUTTON_RELEASE &&
        !(action >= BUTTON_LONG_PRESS_LEVEL_1 && action <= BUTTON_LONG_PRESS_LEVEL_3)) {
        return;
    }

    switch (action) {
    case BUTTON_SINGLE_CLICK:
        if (state == CLIP_STATE_RECORDING || state == CLIP_STATE_PAUSED) {
            clip_post_event(CLIP_EVENT_MARK);  /* MARK event handler vibrates */
        } else if (state == CLIP_STATE_IDLE || state == CLIP_STATE_ERROR
                   || state == CLIP_STATE_WIFI_SYNC) {
            clip_post_event(CLIP_EVENT_STATUS_SHOW);
        }
        break;

    case BUTTON_LONG_PRESS:
	LOG_INF("LONG_PRESS (>1s holding) state=%d", state);
	if (state == CLIP_STATE_RECORDING) {
		/* Stop recording immediately, vibrate to confirm.
		 * User can continue holding for power-off (LEVEL_1/2/3).
		 *
		 * MUST be async: this runs in the button driver's polling
		 * thread. A sync post blocks that thread for the whole SD
		 * flush (hundreds of ms), freezing the 30 ms press-timer
		 * loop while wall-clock time advances — on unblock the
		 * accumulated press duration can jump past the 3 s
		 * LEVEL_1 threshold and trigger an unintended power-off.
		 */
		clip_post_event(CLIP_EVENT_STOP);  /* STOP handler vibrates */
		atomic_set(&recording_stopped, 1);
	} else if (state == CLIP_STATE_IDLE || state == CLIP_STATE_ERROR
		   || state == CLIP_STATE_WIFI_SYNC) {
		/* Vibrate to confirm long-press threshold.
		 * Actual start deferred to RELEASE.
		 */
		haptic_play_pattern(HAPTIC_SHORT);
	}
	break;

    case BUTTON_LONG_PRESS_LEVEL_1:
    case BUTTON_LONG_PRESS_LEVEL_2:
    case BUTTON_LONG_PRESS_LEVEL_3:
	LOG_INF("LONG_PRESS_LVL (pwr off) act=%d st=%d", action, state);
	if (clip_get_context()->status.battery_charging) {
		LOG_INF("USB charging, ignore power off");
		break;
	}
	clip_post_event(CLIP_EVENT_POWER_OFF_SHOW);
	atomic_set(&poweroff_screen_active, 1);
	break;

    case BUTTON_RELEASE:
	if (atomic_cas(&poweroff_screen_active, 1, 0)) {
	    /* Route DIRECTLY to the dedicated shutdown thread via its
	     * semaphore — never through the 8-deep event queue (rapid
	     * button spam fills it; a dropped/delayed POWER_OFF_EXEC is
	     * the "stuck on power-off screen, buttons dead" freeze). The
	     * semaphore has capacity 1 and never blocks this driver
	     * thread. */
	    atomic_set(&shutdown_lockout, 1);
	    clip_request_shutdown();
	} else if (atomic_cas(&recording_stopped, 1, 0)) {
	    /* Recording was stopped by long press, ignore this release */
	} else if (state == CLIP_STATE_RECORDING) {
	    /* Should not reach here — recording is stopped in LONG_PRESS.
	     * But handle as safety fallback.
	     */
	    clip_post_event(CLIP_EVENT_STOP);  /* STOP event handler vibrates */
	} else if (state == CLIP_STATE_IDLE || state == CLIP_STATE_ERROR
		   || state == CLIP_STATE_WIFI_SYNC) {
	    clip_post_event(CLIP_EVENT_START);
	}
	break;

    case BUTTON_DOUBLE_CLICK:
        break;

    default:
        break;
    }

    if (button_cb) {
        button_cb(action, button_user_data);
    }
}

void button_shutdown_lockout(void)
{
    atomic_set(&shutdown_lockout, 1);
}

void button_shutdown_unlock(void)
{
    atomic_clear(&shutdown_lockout);
}

int button_init(void)
{
    int err;

    if (!device_is_ready(button_dev)) {
        LOG_ERR("Button device not ready");
        return -ENODEV;
    }

    err = button_callback_register(button_dev, button_event_callback);
    if (err < 0) {
        LOG_ERR("Failed to register button callback: %d", err);
        return err;
    }

    LOG_INF("Button handler initialized");
    return 0;
}

bool button_is_ready(void)
{
    return device_is_ready(button_dev);
}

int button_register_callback(button_callback_t callback, void *user_data)
{
    if (!callback) {
        return -EINVAL;
    }

    button_cb = callback;
    button_user_data = user_data;

    return 0;
}
