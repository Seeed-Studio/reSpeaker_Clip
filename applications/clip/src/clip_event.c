/*
 * Copyright (c) 2025 Seeed Technology Co., Ltd.
 *
 * SPDX-License-Identifier: Apache-2.0
 *
 * Central event dispatcher — table-driven state machine.
 *
 * All state transitions and side effects (audio, haptic, display)
 * are handled here. Button and AT command modules only post events.
 *
 * Events are processed in the main thread (via clip_event_process()),
 * which provides a large enough stack for WiFi ON/OFF operations.
 */

#include <zephyr/kernel.h>
#include <zephyr/sys/reboot.h>
#include <zephyr/logging/log.h>
#include <zephyr/drivers/regulator.h>
#include <zephyr/mgmt/mcumgr/mgmt/callbacks.h>
#include <zephyr/mgmt/mcumgr/grp/img_mgmt/img_mgmt.h>
#include <nrfx_clock.h>
#include "clip_event.h"
#include "clip.h"
#include "audio.h"
#include "haptic.h"
#include "display.h"
#include "battery.h"
#include "ble.h"
#include "wifi.h"
#include "storage.h"
#include "transfer.h"
#include "usb_cdc.h"
#include "button.h"
#include "config.h"

LOG_MODULE_REGISTER(clip_event, LOG_LEVEL_WRN); /* chatty event-flow logs */

/* ========================================================================== */
/* State Transition Table                                                       */
/* ========================================================================== */

#define TRANS_INVALID  0   /* No valid transition */
#define TRANS_SAME     255 /* Stay in current state (MARK, STATUS, POWER_OFF_SHOW) */

/*
 * transition_table[current_state][event] = next_state
 *
 *                  START  STOP   PAUSE  RESUME MARK   WIFI_ON WIFI_OFF POFF_S POFF_E STATUS USB   OTA_S OTA_D
 */
static const uint8_t transition_table[CLIP_STATE_OTA + 1][CLIP_EVENT_COUNT] = {
    /* UNINITIALIZED */ { 0, 0, 0, 0, 0, 0, 0, TRANS_SAME, TRANS_SAME, 0,    0,    0,    0 },
    /* IDLE          */ { CLIP_STATE_RECORDING, 0, 0, 0, 0,
                         CLIP_STATE_WIFI_SYNC, 0,
                         TRANS_SAME, TRANS_SAME, TRANS_SAME,
                         TRANS_SAME, TRANS_SAME, TRANS_SAME },
    /* RECORDING     */ { 0, CLIP_STATE_IDLE, CLIP_STATE_PAUSED, 0,
                         TRANS_SAME, 0, 0,
                         TRANS_SAME, TRANS_SAME, 0,
                         TRANS_SAME, TRANS_SAME, TRANS_SAME },
    /* TRANSMITTING  */ { 0, 0, 0, 0, 0,
                         CLIP_STATE_WIFI_SYNC, 0,
                         TRANS_SAME, TRANS_SAME, 0,
                         TRANS_SAME, TRANS_SAME, TRANS_SAME },
    /* WIFI_SYNC     */ { 0, 0, 0, 0, 0,
                         TRANS_SAME,
                         CLIP_STATE_IDLE, TRANS_SAME, TRANS_SAME, TRANS_SAME,
                         TRANS_SAME, TRANS_SAME, TRANS_SAME },
    /* PAUSED        */ { 0, CLIP_STATE_IDLE, 0, CLIP_STATE_RECORDING,
                         TRANS_SAME,
                         CLIP_STATE_WIFI_SYNC, 0,
                         TRANS_SAME, TRANS_SAME, 0,
                         TRANS_SAME, TRANS_SAME, TRANS_SAME },
    /* ERROR         */ { CLIP_STATE_IDLE, 0, 0, 0, 0,
                         CLIP_STATE_WIFI_SYNC, 0,
                         TRANS_SAME, TRANS_SAME, TRANS_SAME,
                         TRANS_SAME, TRANS_SAME, TRANS_SAME },
    /* OTA           */ { 0, 0, 0, 0, 0,
                         CLIP_STATE_WIFI_SYNC, 0,
                         TRANS_SAME, TRANS_SAME, TRANS_SAME,
                         0, TRANS_SAME, CLIP_STATE_IDLE },
};

/* ========================================================================== */
/* Event Queue                                                                 */
/* ========================================================================== */

struct clip_event_item {
    enum clip_event event;
    struct k_sem *done_sem;
    struct clip_event_result_info *result;
};

#define EVENT_QUEUE_SIZE 8

/* Dedicated shutdown path — bypasses the event queue entirely.
 * Rapid button spam fills the 8-deep event queue with STATUS_SHOW
 * events; a POWER_OFF_EXEC posted through it can be dropped (K_NO_WAIT)
 * or delayed behind the backlog, freezing the device on the power-off
 * screen with locked input. The confirming release instead gives this
 * semaphore directly; a dedicated thread with its own stack runs the
 * shutdown sequence without depending on the event thread. */
static K_SEM_DEFINE(shutdown_sem, 0, 1);
#define SHUTDOWN_THREAD_STACK 2048
static K_THREAD_STACK_DEFINE(shutdown_thread_stack, SHUTDOWN_THREAD_STACK);
static struct k_thread shutdown_thread_data;
static void shutdown_thread_fn(void);
K_MSGQ_DEFINE(clip_ev_msgq, sizeof(struct clip_event_item),
              EVENT_QUEUE_SIZE, 4);

/* ========================================================================== */
/* Event Notification Semaphore                                               */
/* ========================================================================== */

/* Signaled when a new event is queued; main loop waits on this */
struct k_sem event_notify_sem;

/* ========================================================================== */
/* OTA Progress Polling (Work Queue)                                             */
/* ========================================================================== */

#define OTA_PROGRESS_POLL_INTERVAL_MS  200

static struct k_work_delayable ota_progress_work;
/* Atomic: read cross-thread from the button callback's input gate. */
static atomic_t ota_in_progress = ATOMIC_INIT(0);

bool clip_event_ota_in_progress(void)
{
	return atomic_get(&ota_in_progress) != 0;
}

void clip_request_shutdown(void)
{
	k_sem_give(&shutdown_sem);
}

static void ota_progress_work_handler(struct k_work *work)
{
    if (atomic_get(&ota_in_progress) && g_img_mgmt_state.size > 0) {
        size_t offset = g_img_mgmt_state.off;
        size_t total = g_img_mgmt_state.size;
        uint8_t pct = 0;

        if (offset <= total) {
            pct = (uint8_t)((offset * 100) / total);
            display_set_ota_progress(pct);
        }

        /* Reschedule work if OTA still in progress and not complete */
        if (atomic_get(&ota_in_progress) && pct < 100) {
            k_work_schedule(&ota_progress_work, K_MSEC(OTA_PROGRESS_POLL_INTERVAL_MS));
        }
    }
}

/* ========================================================================== */
/* State                                                                       */
/* ========================================================================== */

static atomic_t g_state;
static atomic_t g_boost_refcnt;

/* OTA progress tracking - protected by ota_mutex (accessed from MCUmgr cb + work queue) */
static K_MUTEX_DEFINE(ota_mutex);
static size_t g_ota_total_size = 0;
static uint32_t g_ota_chunk_count = 0;

/* ========================================================================== */
/* Forward Declarations                                                         */
/* ========================================================================== */

static enum clip_event_result execute_transition(enum clip_event event,
                                                 enum clip_state from,
                                                 enum clip_state to);

/* Still alive 8 s after POWER_OFF_EXEC started: the shutdown hung —
 * force a clean reboot instead of a frozen power-off screen. A k_timer,
 * NOT a work item: the system workqueue may itself be part of the hang
 * (e.g. the fg-save work blocked on a mutex), and a timer expiry does
 * not depend on any thread being scheduled. */
static void shutdown_failsafe_fn(struct k_timer *tmr)
{
	ARG_UNUSED(tmr);
	printk("shutdown hung >8 s, forcing reboot\n");
	sys_reboot(SYS_REBOOT_COLD);
}
static K_TIMER_DEFINE(shutdown_failsafe, shutdown_failsafe_fn, NULL);

/* ========================================================================== */
/* Init                                                                        */
/* ========================================================================== */

/* MCUmgr DFU callback — notifies display on OTA start/progress/pending */
static enum mgmt_cb_return mcumgr_dfu_cb(uint32_t event, enum mgmt_cb_return prev_status,
                                          int32_t *rc, uint16_t *group, bool *abort_more,
                                          void *data, size_t data_size)
{
    if (event == MGMT_EVT_OP_IMG_MGMT_DFU_STARTED) {
        LOG_INF("OTA started");
        k_mutex_lock(&ota_mutex, K_FOREVER);
        g_ota_total_size = 0;
        g_ota_chunk_count = 0;
        k_mutex_unlock(&ota_mutex);
        atomic_set(&ota_in_progress, 1);
        /* Start periodic work to poll g_img_mgmt_state */
        k_work_schedule(&ota_progress_work, K_MSEC(OTA_PROGRESS_POLL_INTERVAL_MS));
        clip_post_event(CLIP_EVENT_OTA_START);
    } else if (event == MGMT_EVT_OP_IMG_MGMT_DFU_CHUNK) {
        if (data && data_size >= sizeof(struct img_mgmt_upload_check)) {
            struct img_mgmt_upload_check *check = (struct img_mgmt_upload_check *)data;

            /* Get total size from action (only once, on first chunk) */
            k_mutex_lock(&ota_mutex, K_FOREVER);

            /* Detect OTA resume: first chunk with offset > 0 means resuming */
            if (!atomic_get(&ota_in_progress) && check->req && check->req->off > 0) {
                LOG_INF("OTA resumed at offset %zu", (size_t)check->req->off);
                atomic_set(&ota_in_progress, 1);
                k_work_schedule(&ota_progress_work, K_MSEC(OTA_PROGRESS_POLL_INTERVAL_MS));
                clip_post_event(CLIP_EVENT_OTA_START);
            }

            if (check->action && g_ota_total_size == 0) {
                unsigned long long action_size = check->action->size;
                if (action_size > 0) {
                    g_ota_total_size = (size_t)action_size;
                    LOG_INF("OTA size: %zu", g_ota_total_size);
                }
            }

            /* Calculate and update progress using offset if available */
            if (check->req) {
                size_t offset = check->req->off;
                size_t req_size = check->req->size;

                LOG_DBG("req: off=%zu, size=%zu", offset, req_size);

                /* Use req->size if total size not yet set */
                if (g_ota_total_size == 0 && req_size > 0 && req_size != SIZE_MAX) {
                    g_ota_total_size = req_size;
                    LOG_INF("OTA size(req): %zu", g_ota_total_size);
                }

                if (g_ota_total_size > 0 && offset <= g_ota_total_size) {
                    uint8_t pct = (uint8_t)((offset * 100) / g_ota_total_size);
                    LOG_DBG("OTA progress: %u%% (offset=%zu/%zu)",
                            pct, offset, g_ota_total_size);
                    k_mutex_unlock(&ota_mutex);
                    display_set_ota_progress(pct);
                    k_mutex_lock(&ota_mutex, K_FOREVER);
                }
            }

            /* Fallback: use chunk count for visual feedback */
            g_ota_chunk_count++;
            if (g_ota_total_size == 0 && g_ota_chunk_count > 1) {
                /* Show animated progress based on chunk count (0-90%) */
                uint8_t pct = (g_ota_chunk_count % 90);
                k_mutex_unlock(&ota_mutex);
                display_set_ota_progress(pct);
                LOG_DBG("OTA fallback progress: %u%% (chunk %u)",
                        pct, g_ota_chunk_count);
                k_mutex_lock(&ota_mutex, K_FOREVER);
            }
            k_mutex_unlock(&ota_mutex);
        } else {
            LOG_WRN("DFU: invalid data ptr");
        }
    } else if (event == MGMT_EVT_OP_IMG_MGMT_DFU_PENDING) {
        k_mutex_lock(&ota_mutex, K_FOREVER);
        LOG_INF("OTA done, pending reboot (%u chunks)",
                g_ota_chunk_count);
        g_ota_total_size = 0;
        g_ota_chunk_count = 0;
        k_mutex_unlock(&ota_mutex);
        atomic_clear(&ota_in_progress);
        /* Cancel the progress work */
        k_work_cancel_delayable(&ota_progress_work);
        display_set_ota_progress(100);
    } else if (event == MGMT_EVT_OP_IMG_MGMT_DFU_STOPPED) {
        k_mutex_lock(&ota_mutex, K_FOREVER);
        LOG_INF("OTA stopped/cancelled (%u chunks)", g_ota_chunk_count);
        g_ota_total_size = 0;
        g_ota_chunk_count = 0;
        k_mutex_unlock(&ota_mutex);
        atomic_clear(&ota_in_progress);
        k_work_cancel_delayable(&ota_progress_work);
        clip_post_event(CLIP_EVENT_OTA_DONE);
    }

    return MGMT_CB_OK;
}

void clip_event_ota_cancel(void)
{
    if (ota_in_progress) {
        LOG_INF("OTA cancelled (BLE disconnect)");
        atomic_clear(&ota_in_progress);
        k_work_cancel_delayable(&ota_progress_work);
        clip_post_event(CLIP_EVENT_OTA_DONE);
    }
}

static struct mgmt_callback mcumgr_dfu_cb_started;
static struct mgmt_callback mcumgr_dfu_cb_chunk;
static struct mgmt_callback mcumgr_dfu_cb_pending;
static struct mgmt_callback mcumgr_dfu_cb_stopped;

/* ========================================================================== */
/* SD Idle Power-Off (Work Queue)                                             */
/* ========================================================================== */

#define SD_IDLE_POWEROFF_DELAY_MS  K_MSEC(CONFIG_CLIP_SD_IDLE_DELAY_MS)
static struct k_work_delayable sd_idle_poweroff_work;

/* Deferred fuel-gauge state save at the power-off level (so a 7 s PMIC hard
 * reset that bypasses POWER_OFF_EXEC doesn't lose the SoC). Runs on the system
 * workqueue so it can't block the main event thread / the 3 s power-off flow. */
static struct k_work fg_save_work;
static void fg_save_work_handler(struct k_work *work)
{
	ARG_UNUSED(work);
	battery_save_fg_state();
}

/*
 * True only when genuinely idle: IDLE state, no recording/transfer/OTA,
 * USB not exposing the SD (MSC), FS log backend off, no file mid-write,
 * and the SD rail is currently up (something to power off).
 */
/* Registered with storage as the busy callback: returns true (busy) if the SD
 * must NOT be idle-powered-off. Evaluated under sd_lifecycle_mutex by
 * storage_idle_poweroff(), closing the TOCTOU with the unlocked tick. */
static bool clip_sd_busy(void)
{
    if ((enum clip_state)atomic_get(&g_state) != CLIP_STATE_IDLE) {
        return true;
    }
    if (transfer_is_active() || audio_is_recording() || ota_in_progress) {
        return true;
    }
    if (usb_cdc_is_enabled()) {
        return true;   /* USB MSC exposes the SD — don't pull the rail */
    }
    if (clip_log_fs_active()) {
        return true;   /* logs write to SD */
    }
    return false;
}

static void sd_idle_poweroff_work_handler(struct k_work *work)
{
    /* storage_idle_poweroff() checks writing_file + the busy callback UNDER
     * the lock, so no TOCTOU with a recording/transfer starting mid-check. */
    (void)storage_idle_poweroff();
    /* Keep re-arming so we re-evaluate each interval (no-op once powered off) */
    k_work_schedule(&sd_idle_poweroff_work, SD_IDLE_POWEROFF_DELAY_MS);
}

void clip_storage_activity_notify(void)
{
    /* Any SD access re-arms the idle timer */
    k_work_reschedule(&sd_idle_poweroff_work, SD_IDLE_POWEROFF_DELAY_MS);
}

int clip_event_init(void)
{
    atomic_set(&g_state, CLIP_STATE_IDLE);
    k_sem_init(&event_notify_sem, 0, 1);

    k_work_init_delayable(&ota_progress_work, ota_progress_work_handler);
    k_work_init_delayable(&sd_idle_poweroff_work, sd_idle_poweroff_work_handler);
    k_thread_create(&shutdown_thread_data, shutdown_thread_stack,
                    K_THREAD_STACK_SIZEOF(shutdown_thread_stack),
                    (k_thread_entry_t)shutdown_thread_fn,
                    NULL, NULL, NULL,
                    K_PRIO_PREEMPT(1), 0, K_NO_WAIT);
    k_thread_name_set(&shutdown_thread_data, "shutdown");

    k_work_init(&fg_save_work, fg_save_work_handler);
    storage_set_activity_cb(clip_storage_activity_notify);
    storage_set_busy_cb(clip_sd_busy);
    k_work_schedule(&sd_idle_poweroff_work, SD_IDLE_POWEROFF_DELAY_MS);

    mcumgr_dfu_cb_started.callback = mcumgr_dfu_cb;
    mcumgr_dfu_cb_started.event_id = MGMT_EVT_OP_IMG_MGMT_DFU_STARTED;
    mgmt_callback_register(&mcumgr_dfu_cb_started);

    mcumgr_dfu_cb_chunk.callback = mcumgr_dfu_cb;
    mcumgr_dfu_cb_chunk.event_id = MGMT_EVT_OP_IMG_MGMT_DFU_CHUNK;
    mgmt_callback_register(&mcumgr_dfu_cb_chunk);

    mcumgr_dfu_cb_pending.callback = mcumgr_dfu_cb;
    mcumgr_dfu_cb_pending.event_id = MGMT_EVT_OP_IMG_MGMT_DFU_PENDING;
    mgmt_callback_register(&mcumgr_dfu_cb_pending);

    mcumgr_dfu_cb_stopped.callback = mcumgr_dfu_cb;
    mcumgr_dfu_cb_stopped.event_id = MGMT_EVT_OP_IMG_MGMT_DFU_STOPPED;
    mgmt_callback_register(&mcumgr_dfu_cb_stopped);

    return 0;
}

/* ========================================================================== */
/* CPU Boost (reference counted)                                                */
/* ========================================================================== */

void clip_cpu_boost_acquire(void)
{
    int ref = atomic_inc(&g_boost_refcnt);
    if (ref == 0) {
#ifdef CLOCK_FEATURE_HFCLK_DIVIDE_PRESENT
        nrfx_clock_divider_set(NRF_CLOCK_DOMAIN_HFCLK, NRF_CLOCK_HFCLK_DIV_1);
        /* Wait for HFCLK divider to stabilize */
        k_busy_wait(20);
        LOG_INF("CPU boost ON (128MHz)");
#endif
    }
}

void clip_cpu_boost_release(void)
{
    int ref = atomic_dec(&g_boost_refcnt);
    if (ref == 1) {
#ifdef CLOCK_FEATURE_HFCLK_DIVIDE_PRESENT
        nrfx_clock_divider_set(NRF_CLOCK_DOMAIN_HFCLK, NRF_CLOCK_HFCLK_DIV_2);
        /* Wait for HFCLK divider to stabilize */
        k_busy_wait(20);
        LOG_INF("CPU boost OFF (64MHz)");
#endif
    }
}

enum clip_state clip_event_get_state(void)
{
    return (enum clip_state)atomic_get(&g_state);
}

/* ========================================================================== */
/* Event Submission                                                            */
/* ========================================================================== */

int clip_post_event(enum clip_event event)
{
    struct clip_event_item item = { .event = event };

    int ret = k_msgq_put(&clip_ev_msgq, &item, K_NO_WAIT);
    if (ret != 0) {
        LOG_WRN("Event queue full, dropping event %d", event);
        return ret;
    }

    k_sem_give(&event_notify_sem);
    return 0;
}

int clip_post_event_sync(enum clip_event event,
                         struct clip_event_result_info *info)
{
    struct k_sem sem;
    k_sem_init(&sem, 0, 1);

    struct clip_event_item item = {
        .event = event,
        .done_sem = &sem,
        .result = info,
    };

    int ret = k_msgq_put(&clip_ev_msgq, &item, K_NO_WAIT);
    if (ret != 0) {
        if (info) {
            info->result = CLIP_EVENT_BUSY;
            info->error_code = ret;
        }
        return ret;
    }

    k_sem_give(&event_notify_sem);
    k_sem_take(&sem, K_FOREVER);
    return 0;
}

/* ========================================================================== */
/* Event Processing — called from main thread                                   */
/* ========================================================================== */

void clip_event_wait(k_timeout_t timeout)
{
    k_sem_take(&event_notify_sem, timeout);
}

void clip_event_process(void)
{
    struct clip_event_item item;

    while (k_msgq_get(&clip_ev_msgq, &item, K_NO_WAIT) == 0) {
        enum clip_state current = (enum clip_state)atomic_get(&g_state);

        if (item.event >= CLIP_EVENT_COUNT) {
            LOG_WRN("Invalid event: %d", item.event);
            goto notify;
        }

        /* Special case: recording blocked while WiFi active */
        if (current == CLIP_STATE_WIFI_SYNC && item.event == CLIP_EVENT_START) {
            LOG_INF("Recording blocked: WiFi active");
            display_post_event(UI_EVENT_WIFI_BLOCKED);
            if (item.result) {
                item.result->result = CLIP_EVENT_INVALID;
            }
            goto notify;
        }

        /* Special case: recording blocked while USB MSC active */
        if (usb_cdc_is_enabled() && item.event == CLIP_EVENT_START) {
            LOG_INF("Recording blocked: USB MSC active");
            display_post_event(UI_EVENT_USB_BLOCKED);
            if (item.result) {
                item.result->result = CLIP_EVENT_INVALID;
            }
            goto notify;
        }

        uint8_t next = transition_table[current][item.event];
        if (next == TRANS_INVALID) {
            LOG_WRN("Invalid transition: state=%d event=%d", current, item.event);
            if (item.result) {
                item.result->result = CLIP_EVENT_INVALID;
            }
            goto notify;
        }

        enum clip_state new_state = (next == TRANS_SAME) ? current
                                                         : (enum clip_state)next;

        enum clip_event_result result = execute_transition(item.event, current, new_state);

        if (result == CLIP_EVENT_OK && next != TRANS_SAME) {
            /* Sanity check: warn if state leaves RECORDING while audio active */
            if (current == CLIP_STATE_RECORDING && audio_is_recording()) {
                LOG_WRN("leave REC (%d->%d) audio active",
                         current, new_state);
            }
            atomic_set(&g_state, (atomic_val_t)new_state);
        }

        if (item.result) {
            item.result->result = result;
        }

notify:
        if (item.done_sem) {
            k_sem_give(item.done_sem);
        }
    }
}


/* ========================================================================== */
/* Dedicated shutdown thread                                                    */
/* ========================================================================== */

static void shutdown_thread_fn(void)
{
    int err;

    while (true) {
        k_sem_take(&shutdown_sem, K_FOREVER);

        /* Failsafe armed FIRST: everything below is best-effort. If ship
         * mode has not killed us within 8 s, force a clean reboot. */
        k_timer_start(&shutdown_failsafe, K_SECONDS(8), K_NO_WAIT);

        /* Ignore all button input from here on. */
        button_shutdown_lockout();

        /* Confirmation buzz plays on the haptic thread WHILE we clean up. */
        haptic_play_pattern(HAPTIC_DOUBLE);
        int64_t power_cut_earliest = k_uptime_get() + 800;

        /* Stop recording first — file integrity is the one thing worth
         * waiting for. */
        if (audio_is_recording()) {
            LOG_INF("Stopping recording before power off");
            int stop_rc = audio_stop_recording();
            if (stop_rc != 0) {
                LOG_WRN("audio_stop %d (slow SD) grace", stop_rc);
                k_sleep(K_MSEC(500));
            }
        }

        /* Signal the transfer to stop (flag only). */
        if (transfer_is_active()) {
            LOG_INF("Cancelling transfer before power off");
            transfer_cancel();
        }

        const struct device *regulators =
            DEVICE_DT_GET(DT_NODELABEL(npm1300_regulators));

        if (device_is_ready(regulators) &&
            battery_fg_state_age_ms() > 60000) {
            battery_save_fg_state();
        }

        int64_t left = power_cut_earliest - k_uptime_get();
        if (left > 0) {
            k_sleep(K_MSEC(left));
        }

        if (device_is_ready(regulators)) {
            for (int i = 0; i < 3; i++) {
                err = regulator_parent_ship_mode(regulators);
                if (err == 0) {
                    k_sleep(K_SECONDS(9));
                    err = -ETIMEDOUT;
                    break;
                }
                LOG_WRN("ship mode try %d failed: %d", i + 1, err);
                k_sleep(K_MSEC(100));
            }
        } else {
            LOG_ERR("Regulators not ready for ship mode");
            err = -ENODEV;
        }

        /* Still alive: ship mode could not be entered. Recover. */
        LOG_ERR("power-off failed (%d), recovering", err);
        k_timer_stop(&shutdown_failsafe);
        button_shutdown_unlock();
        display_post_event(UI_EVENT_STATUS_SHOW);
        ble_notify_event("poweroff", "failed");
    }
}

/* ========================================================================== */
/* Transition Actions — single place for all side effects                     */
/* ========================================================================== */

static enum clip_event_result execute_transition(enum clip_event event,
                                                 enum clip_state from,
                                                 enum clip_state to)
{
    struct clip_context *c = clip_get_context();
    int err;

    switch (event) {
    case CLIP_EVENT_START:
    {
        struct clip_context *ctx = clip_get_context();

        /* SD may be idle-powered-off — bring it up before recording writes */
        err = storage_ensure_mounted();
        if (err) {
            LOG_ERR("storage_ensure_mounted failed: %d", err);
            display_post_error("SD Error");
            return CLIP_EVENT_ERROR;
        }

        /* Refuse recording if storage is (near) full */
        struct storage_stats st;
        storage_get_stats(&st);   /* refresh free/total */
        if (storage_is_full()) {
            LOG_WRN("Storage full, refusing recording");
            display_post_error("Storage Full");
            ble_notify_event("storage", "full");
            return CLIP_EVENT_ERROR;
        }

        err = audio_start_recording(AUDIO_MODE_MERGE);
        if (err) {
            if (err == -EBUSY) {
                return CLIP_EVENT_BUSY;
            }
            LOG_ERR("audio_start_recording failed: %d", err);
            display_post_error("Rec Fail");
            return CLIP_EVENT_ERROR;
        }
        display_post_event(UI_EVENT_REC_START);
        display_set_recording(true, c->config.mode == MODE_ENHANCED);
        ble_notify_state_change("RECORDING", audio_get_session_id(), -1);
        return CLIP_EVENT_OK;
    }

    case CLIP_EVENT_STOP:
    {
        if (!audio_is_recording()) {
            return CLIP_EVENT_INVALID;
        }

        /* Feedback FIRST: haptic (non-blocking, own thread) + UI flags post
         * instantly at the button threshold, BEFORE the SD-bound file flush
         * below — which can take hundreds of ms when a transfer is reading
         * the card. The stop itself completes right after. */
        haptic_play_pattern(HAPTIC_DOUBLE);  /* stop = 2 buzzes (button or AT) */
        display_post_event(UI_EVENT_REC_STOP);
        display_set_recording(false, false);

        err = audio_stop_recording();
        if (err == -ETIMEDOUT) {
            /* Stop was requested but the audio thread is slow to flush/close
             * the file (SD busy, e.g. a concurrent transfer reading the card).
             * The stop IS committed and completes asynchronously — commit IDLE
             * now so the state machine never deadlocks in RECORDING (which
             * would drop the IDLE notification and make the host flood STOP).
             * The recording tail may be cut, which is acceptable. */
            LOG_WRN("stop slow (SD busy), IDLE async");
        } else if (err) {
            LOG_ERR("audio_stop_recording failed: %d", err);
            return CLIP_EVENT_ERROR;
        }
        {
            struct audio_stats stats;
            int dur = -1;

            if (audio_get_stats(&stats) == 0) {
                dur = (int)(stats.recording_time_ms / 1000U);
            }
            ble_notify_state_change("IDLE", audio_get_session_id(), dur);
        }
        return CLIP_EVENT_OK;
    }

    case CLIP_EVENT_PAUSE:
    {
        if (!audio_is_recording()) {
            return CLIP_EVENT_INVALID;
        }

        err = audio_pause_recording();
        if (err) {
            LOG_ERR("audio_pause_recording failed: %d", err);
            return CLIP_EVENT_ERROR;
        }
        haptic_play_pattern(HAPTIC_SHORT);
        display_post_event(UI_EVENT_REC_PAUSE);
        ble_notify_state_change("PAUSED", audio_get_session_id(), -1);
        return CLIP_EVENT_OK;
    }

    case CLIP_EVENT_RESUME:
    {
        /* Buzz first: the audio thread waits for haptic quiet before
         * re-powering the mics, so the motor noise is not recorded. */
        haptic_play_pattern(HAPTIC_SHORT);
        err = audio_resume_recording();
        if (err) {
            LOG_ERR("audio_resume_recording failed: %d", err);
            return CLIP_EVENT_ERROR;
        }
        display_post_event(UI_EVENT_REC_RESUME);
        display_set_recording(true, c->config.mode == MODE_ENHANCED);
        ble_notify_state_change("RECORDING", audio_get_session_id(), -1);
        return CLIP_EVENT_OK;
    }

    case CLIP_EVENT_MARK:
    {
        if (!audio_is_recording()) {
            return CLIP_EVENT_INVALID;
        }

        err = audio_add_bookmark();
        if (err) {
            LOG_ERR("audio_add_bookmark failed: %d", err);
            return CLIP_EVENT_ERROR;
        }
        haptic_play_pattern(HAPTIC_SHORT);  /* mark = 1 buzz (button or AT) */
        display_post_event(UI_EVENT_MARK);
        {
            int count = storage_count_bookmarks(audio_get_session_id());

            if (count > 0) {
                ble_notify_mark(audio_get_session_id(), count);
            }
        }
        return CLIP_EVENT_OK;
    }

    case CLIP_EVENT_WIFI_ON:
    {
        if (wifi_ap_is_running()) {
            return CLIP_EVENT_OK;
        }

        err = wifi_on();
        if (err) {
            LOG_ERR("wifi_on failed: %d", err);
            display_post_error("WiFi Fail");
            return CLIP_EVENT_ERROR;
        }
        return CLIP_EVENT_OK;
    }

    case CLIP_EVENT_WIFI_OFF:
    {
        err = wifi_off();
        if (err) {
            LOG_ERR("wifi_off failed: %d", err);
            return CLIP_EVENT_ERROR;
        }
        return CLIP_EVENT_OK;
    }

    case CLIP_EVENT_POWER_OFF_SHOW:
    {
        /* A held-long-enough press triggers a PMIC hardware reset that
         * bypasses the software POWER_OFF_EXEC shutdown (where the fuel-gauge
         * state is normally persisted). Queue a save now, at the 3 s poweroff
         * level, so a hard reset doesn't lose it. Deferred to the system
         * workqueue so it cannot block this thread or the 3 s power-off flow;
         * POWER_OFF_EXEC saves a fresh copy again on a graceful release. */
        k_work_submit(&fg_save_work);
        display_post_event(UI_EVENT_POWER_OFF_SHOW);
        return CLIP_EVENT_OK;
    }

    case CLIP_EVENT_POWER_OFF_EXEC:
    {
        /* Route to the dedicated shutdown thread (see shutdown_thread_fn):
         * rapid button spam can fill the event queue and delay or drop
         * this event; the direct semaphore path has no such dependency. */
        k_sem_give(&shutdown_sem);
        return CLIP_EVENT_OK;
    }

    case CLIP_EVENT_STATUS_SHOW:
    {
        ble_adv_restart_fast();
        display_post_event(UI_EVENT_STATUS_SHOW);
        return CLIP_EVENT_OK;
    }

    case CLIP_EVENT_USB_CONNECTED:
    {
        display_post_event(UI_EVENT_USB_CONNECTED);
        return CLIP_EVENT_OK;
    }

    case CLIP_EVENT_OTA_START:
    {
        display_post_event(UI_EVENT_OTA_START);
        return CLIP_EVENT_OK;
    }

    case CLIP_EVENT_OTA_DONE:
    {
        display_post_event(UI_EVENT_OTA_DONE);
        return CLIP_EVENT_OK;
    }

    default:
        return CLIP_EVENT_INVALID;
    }
}
