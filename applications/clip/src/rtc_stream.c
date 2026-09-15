/*
 * Copyright (c) 2025 Seeed Technology Co., Ltd.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>
#include <string.h>
#include "rtc_stream.h"
#include "audio.h"
#include "ble.h"
#include "transport_ble.h"
#include "clip_event.h"

LOG_MODULE_REGISTER(rtc_stream, CONFIG_CLIP_LOG_LEVEL);

/* One queue slot: a single encoded Opus frame (20 ms). */
struct rtc_frame {
    uint16_t len;
    uint8_t data[CONFIG_CLIP_RTC_FRAME_MAX_BYTES];
};

K_MSGQ_DEFINE(rtc_frame_msgq, sizeof(struct rtc_frame),
              CONFIG_CLIP_RTC_QUEUE_FRAMES, 4);

/* Producer staging slot. The audio thread is the only producer, so a single
 * static frame keeps the ~400 byte struct off its stack. */
static struct rtc_frame push_frame;

/* Wakes the consumer thread; count tracks queued frames. */
static K_SEM_DEFINE(frame_sem, 0, CONFIG_CLIP_RTC_QUEUE_FRAMES);

static atomic_t session_active;
static atomic_t stream_active;
static atomic_t stream_paused;

static char rtc_session_id[32];

static struct k_work_delayable start_timeout_work;
static struct k_work disconnect_work;

/* Session statistics (logged on session end) */
static uint32_t frames_pushed;
static uint32_t frames_dropped_queue;  /* queue full: oldest evicted / oversize */
static uint32_t frames_dropped_tx;     /* consumer side: no link or backpressure */
static uint32_t frames_consumed;       /* successfully notified STREAM_DATA frames */

/* Thread */
K_THREAD_STACK_DEFINE(rtc_stream_stack, CONFIG_CLIP_RTC_STACK_SIZE);
static struct k_thread rtc_stream_thread_data;

/* ----------------------------------------------------------------------- */
/* Internal helpers                                                        */
/* ----------------------------------------------------------------------- */

static void rtc_stream_flush(void)
{
    k_msgq_purge(&rtc_frame_msgq);
    k_sem_reset(&frame_sem);
}

/* Producer: runs in the audio recording thread (highest app priority).
 * Must be O(1) and never block. */
static void rtc_stream_push(const uint8_t *data, size_t len, void *user_data)
{
    ARG_UNUSED(user_data);

    if (!atomic_get(&session_active)) {
        return;
    }

    frames_pushed++;

    if (len > sizeof(push_frame.data)) {
        frames_dropped_queue++;
        return;
    }

    push_frame.len = (uint16_t)len;
    memcpy(push_frame.data, data, len);

    if (k_msgq_put(&rtc_frame_msgq, &push_frame, K_NO_WAIT) != 0) {
        /* Queue full — RTC semantics: drop the oldest frame. */
        struct rtc_frame discard;

        (void)k_msgq_get(&rtc_frame_msgq, &discard, K_NO_WAIT);
        if (k_msgq_put(&rtc_frame_msgq, &push_frame, K_NO_WAIT) != 0) {
            frames_dropped_queue++;
            return;
        }
        frames_dropped_queue++;
    }

    k_sem_give(&frame_sem);
}

/* Consumer: drains the queue and emits STREAM_DATA over BLE. */
static void rtc_stream_thread_fn(void *p1, void *p2, void *p3)
{
    ARG_UNUSED(p1);
    ARG_UNUSED(p2);
    ARG_UNUSED(p3);
    struct rtc_frame frame;

    while (true) {
        k_sem_take(&frame_sem, K_FOREVER);

        if (k_msgq_get(&rtc_frame_msgq, &frame, K_NO_WAIT) != 0) {
            continue; /* stale wake after flush */
        }

        if (!atomic_get(&stream_active) || atomic_get(&stream_paused)) {
            continue; /* consume & drop: stream not started or paused */
        }

        if (!ble_is_connected() || !ble_is_file_data_notify_enabled()) {
            frames_dropped_tx++;
            continue;
        }

        int ret = transport_ble_send_stream_data(frame.data, frame.len);

        if (ret < 0) {
            /* -ENOMEM/-EAGAIN/-EBUSY: BLE TX backpressure.
             * -ENOTCONN/-EMSGSIZE: link gone / frame too large.
             * RTC never retries or blocks — drop and move on. */
            frames_dropped_tx++;
        } else {
            frames_consumed++;
        }
    }
}

/* ----------------------------------------------------------------------- */
/* Timeout & disconnect work                                               */
/* ----------------------------------------------------------------------- */

static void start_timeout_fn(struct k_work *work)
{
    ARG_UNUSED(work);

    if (!atomic_get(&session_active) || atomic_get(&stream_active)) {
        return;
    }

    LOG_INF("no DOWNLOAD within %us, ending RTC session",
            CONFIG_CLIP_RTC_START_TIMEOUT_SEC);
    ble_notify_event("rtc", "timeout");
    rtc_stream_session_end();
    clip_post_event(CLIP_EVENT_STOP);
}

static void disconnect_work_fn(struct k_work *work)
{
    ARG_UNUSED(work);

    if (!atomic_get(&session_active)) {
        return;
    }

    LOG_INF("BLE disconnected, ending RTC session");
    rtc_stream_session_end();
    clip_post_event(CLIP_EVENT_STOP);
}

/* Wait for tight connection parameters to be applied before sending the
 * first frame, so the stream never starts on a slow default link. Polls
 * the negotiated interval and falls back to starting anyway after the max
 * wait (the central may refuse the tight params). */
#define RTC_PARAM_WAIT_POLL_MS 100
#define RTC_PARAM_WAIT_MAX_MS  5000

static struct k_work_delayable param_wait_work;
static atomic_t start_pending;
static uint32_t param_wait_ms;

static bool rtc_conn_params_tight(void)
{
    uint16_t interval = ble_get_conn_interval();

    return interval != 0 && interval <= 12;
}

static void rtc_stream_go(void)
{
    /* RTC delivers "now": drop whatever queued while waiting. */
    rtc_stream_flush();

    int ret = transport_ble_send_stream_start(rtc_session_id);
    if (ret < 0) {
        LOG_ERR("STREAM_START send failed: %d", ret);
        return; /* start_pending stays set -> poll loop retries */
    }

    atomic_set(&start_pending, 0);
    atomic_set(&stream_active, 1);
    LOG_INF("stream started: %s (wait=%ums interval=%u)", rtc_session_id,
            param_wait_ms, ble_get_conn_interval());
}

static void param_wait_fn(struct k_work *work)
{
    ARG_UNUSED(work);

    if (!atomic_get(&start_pending) || !atomic_get(&session_active)) {
        atomic_set(&start_pending, 0);
        return;
    }

    param_wait_ms += RTC_PARAM_WAIT_POLL_MS;

    if (!rtc_conn_params_tight()) {
        if (param_wait_ms < RTC_PARAM_WAIT_MAX_MS) {
            k_work_reschedule(&param_wait_work,
                              K_MSEC(RTC_PARAM_WAIT_POLL_MS));
            return;
        }
        if (param_wait_ms == RTC_PARAM_WAIT_MAX_MS) {
            LOG_INF("connection parameter wait expired (interval=%u)",
                    ble_get_conn_interval());
        }
        if (param_wait_ms >= 2 * RTC_PARAM_WAIT_MAX_MS) {
            LOG_ERR("stream start retries exhausted, aborting");
            atomic_set(&start_pending, 0);
            return;
        }
    }

    rtc_stream_go();
    if (atomic_get(&start_pending)) {
        /* STREAM_START send failed; retry on next poll */
        k_work_reschedule(&param_wait_work, K_MSEC(RTC_PARAM_WAIT_POLL_MS));
    }
}

/* ----------------------------------------------------------------------- */
/* Public API                                                              */
/* ----------------------------------------------------------------------- */

int rtc_stream_init(void)
{
    k_work_init_delayable(&start_timeout_work, start_timeout_fn);
    k_work_init(&disconnect_work, disconnect_work_fn);
    k_work_init_delayable(&param_wait_work, param_wait_fn);

    audio_register_data_callback(rtc_stream_push, NULL);

    k_tid_t tid = k_thread_create(&rtc_stream_thread_data, rtc_stream_stack,
                                  K_THREAD_STACK_SIZEOF(rtc_stream_stack),
                                  rtc_stream_thread_fn, NULL, NULL, NULL,
                                  CONFIG_CLIP_RTC_THREAD_PRIORITY, 0, K_NO_WAIT);
    if (!tid) {
        LOG_ERR("failed to create rtc stream thread");
        return -ENOMEM;
    }
    k_thread_name_set(tid, "rtc_stream");

    return 0;
}

int rtc_stream_session_begin(const char *session_id)
{
    if (atomic_get(&session_active)) {
        return -EBUSY;
    }

    strncpy(rtc_session_id, session_id, sizeof(rtc_session_id) - 1);
    rtc_session_id[sizeof(rtc_session_id) - 1] = '\0';

    rtc_stream_flush();
    frames_pushed = 0;
    frames_dropped_queue = 0;
    frames_dropped_tx = 0;
    frames_consumed = 0;
    atomic_set(&stream_paused, 0);
    atomic_set(&stream_active, 0);
    atomic_set(&session_active, 1);

    /* Abort the session if the phone never starts the stream. */
    k_work_schedule(&start_timeout_work,
                    K_SECONDS(CONFIG_CLIP_RTC_START_TIMEOUT_SEC));

    LOG_INF("session %s (start timeout %us)", rtc_session_id,
            CONFIG_CLIP_RTC_START_TIMEOUT_SEC);
    return 0;
}

void rtc_stream_session_end(void)
{
    if (!atomic_get(&session_active)) {
        return;
    }

    atomic_set(&session_active, 0);
    atomic_set(&stream_active, 0);
    atomic_set(&stream_paused, 0);
    atomic_set(&start_pending, 0);
    k_work_cancel_delayable(&start_timeout_work);
    k_work_cancel_delayable(&param_wait_work);
    rtc_stream_flush();
    rtc_session_id[0] = '\0';

    LOG_INF("session ended: pushed=%u sent=%u drop_q=%u drop_tx=%u",
            frames_pushed, frames_consumed, frames_dropped_queue,
            frames_dropped_tx);
}

bool rtc_stream_session_active(void)
{
    return atomic_get(&session_active) != 0;
}

const char *rtc_stream_session_id(void)
{
    return rtc_session_id;
}


int rtc_stream_start(void)
{
    if (!atomic_get(&session_active)) {
        return -ENOENT;
    }
    if (atomic_get(&stream_active) || atomic_get(&start_pending)) {
        return 0; /* idempotent */
    }

    k_work_cancel_delayable(&start_timeout_work);
    atomic_set(&stream_paused, 0);

    /* Tight params were already requested when the RTC session began
     * (AT+START=RTC); ask again defensively. */
    ble_request_rtc_conn_params(true);

    param_wait_ms = 0;
    atomic_set(&start_pending, 1);

    if (rtc_conn_params_tight()) {
        rtc_stream_go();
        if (!atomic_get(&start_pending)) {
            return 0; /* started immediately */
        }
    }

    k_work_schedule(&param_wait_work, K_MSEC(RTC_PARAM_WAIT_POLL_MS));
    return 0;
}

void rtc_stream_stop(uint8_t reason)
{
    bool was_pending = atomic_get(&start_pending) != 0;

    atomic_set(&start_pending, 0);
    k_work_cancel_delayable(&param_wait_work);

    if (!atomic_get(&stream_active)) {
        if (was_pending) {
            ble_request_rtc_conn_params(false);
        }
        return;
    }

    atomic_set(&stream_active, 0);
    ble_request_rtc_conn_params(false);
    rtc_stream_flush();

    if (ble_is_connected() && ble_is_file_data_notify_enabled()) {
        (void)transport_ble_send_stream_end(reason);
    }

    LOG_INF("stream stopped (reason=%u)", reason);
}

void rtc_stream_pause(void)
{
    atomic_set(&stream_paused, 1);
    rtc_stream_flush(); /* paused = discard everything queued */
    LOG_INF("stream paused");
}

void rtc_stream_resume(void)
{
    atomic_set(&stream_paused, 0);
    LOG_INF("stream resumed");
}

bool rtc_stream_is_streaming(void)
{
    return atomic_get(&stream_active) != 0;
}

bool rtc_stream_is_paused(void)
{
    return atomic_get(&stream_paused) != 0;
}

void rtc_stream_ble_disconnected(void)
{
    if (atomic_get(&session_active)) {
        k_work_submit(&disconnect_work);
    }
}
