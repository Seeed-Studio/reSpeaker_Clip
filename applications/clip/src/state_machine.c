/*
 * Copyright (c) 2024 Seeed Technology Co., Ltd.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#include <zephyr/kernel.h>
#include <zephyr/sys/util.h>
#include <zephyr/logging/log.h>
#include "state_machine.h"

LOG_MODULE_REGISTER(state_machine, LOG_LEVEL_DBG);

#define MAX_CALLBACKS 4

/* State transition table */
static const bool state_transitions[CLIP_STATE_ERROR + 1][CLIP_STATE_ERROR + 1] = {
    /*                     UNINITIALIZED IDLE RECORDING TRANSMITTING PAUSED ERROR */
    /* UNINITIALIZED */  { false,      true, false,    false,          false, false },
    /* IDLE */            { false,      false, true,     true,           false, true },
    /* RECORDING */       { false,      true,  false,    false,          true,  true },  /* RECORDING→PAUSED for pause recording */
    /* TRANSMITTING */     { false,      true,  false,    false,          false, true },  /* Removed PAUSED - transfer only supports cancel */
    /* PAUSED */           { false,      true,  true,     false,          false, true },  /* PAUSED→RECORDING for resume, removed PAUSED→TRANSMITTING */
    /* ERROR */            { false,      true,  false,    false,          false, false },
};

/* Current state */
static enum clip_state current_state = CLIP_STATE_UNINITIALIZED;

/* Mutex for state access */
K_MUTEX_DEFINE(state_lock);

/* Callbacks */
static state_change_callback_t callbacks[MAX_CALLBACKS];
static int callback_count = 0;

/* Work for notifying callbacks */
static struct k_work notify_work;

/* State change notification data */
struct state_change_data {
    enum clip_state old_state;
    enum clip_state new_state;
};

static struct state_change_data last_change;

const char *state_to_string(enum clip_state state)
{
    switch (state) {
    case CLIP_STATE_UNINITIALIZED:
        return "UNINITIALIZED";
    case CLIP_STATE_IDLE:
        return "IDLE";
    case CLIP_STATE_RECORDING:
        return "RECORDING";
    case CLIP_STATE_TRANSMITTING:
        return "TRANSMITTING";
    case CLIP_STATE_PAUSED:
        return "PAUSED";
    case CLIP_STATE_ERROR:
        return "ERROR";
    default:
        return "UNKNOWN";
    }
}

static void notify_work_handler(struct k_work *work)
{
    for (int i = 0; i < callback_count; i++) {
        if (callbacks[i]) {
            callbacks[i](last_change.old_state, last_change.new_state);
        }
    }
}

int state_init(void)
{
    k_mutex_init(&state_lock);
    k_work_init(&notify_work, notify_work_handler);

    memset(callbacks, 0, sizeof(callbacks));
    callback_count = 0;

    current_state = CLIP_STATE_UNINITIALIZED;

    LOG_DBG("State machine initialized");
    return 0;
}

enum clip_state state_get_current(void)
{
    enum clip_state state;

    k_mutex_lock(&state_lock, K_FOREVER);
    state = current_state;
    k_mutex_unlock(&state_lock);

    return state;
}

int state_transition(enum clip_state new_state)
{
    enum clip_state old_state;

    k_mutex_lock(&state_lock, K_FOREVER);

    old_state = current_state;

    /* Check if transition is valid */
    if (new_state >= ARRAY_SIZE(state_transitions) ||
        old_state >= ARRAY_SIZE(state_transitions)) {
        k_mutex_unlock(&state_lock);
        LOG_ERR("Invalid transition: state out of range");
        return -EINVAL;
    }

    if (!state_transitions[old_state][new_state]) {
        k_mutex_unlock(&state_lock);
        LOG_ERR("Invalid transition: %s -> %s",
                state_to_string(old_state), state_to_string(new_state));
        return -EINVAL;
    }

    /* Update state */
    current_state = new_state;

    k_mutex_unlock(&state_lock);

    /* Log state transition - core state change */
    LOG_INF("State: %s -> %s", state_to_string(old_state), state_to_string(new_state));

    /* Notify callbacks */
    last_change.old_state = old_state;
    last_change.new_state = new_state;
    k_work_submit(&notify_work);

    return 0;
}

int state_register_callback(state_change_callback_t callback)
{
    if (callback_count >= MAX_CALLBACKS) {
        return -ENOMEM;
    }

    callbacks[callback_count++] = callback;

    return 0;
}
