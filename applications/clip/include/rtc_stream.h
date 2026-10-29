/*
 * Copyright (c) 2025 Seeed Technology Co., Ltd.
 *
 * SPDX-License-Identifier: Apache-2.0
 *
 * RTC streaming — realtime Opus delivery over BLE.
 *
 * An RTC session (AT+START=RTC) runs the normal audio pipeline
 * (PDM -> DSP -> Opus) without touching the SD card. Encoded frames are
 * pushed into a bounded queue (drop-oldest on overflow). Once the phone
 * starts the stream with AT+DOWNLOAD=<session>, a consumer thread drains
 * the queue and emits STREAM_* frames over the BLE File Data
 * characteristic. RTC favors low latency over completeness: on backpressure
 * or pause the oldest data is dropped, never blocked on.
 */

#ifndef CLIP_RTC_STREAM_H
#define CLIP_RTC_STREAM_H

#include <zephyr/kernel.h>
#include <stdint.h>
#include <stdbool.h>

/* STREAM_END reasons (frame type 0x15) */
#define RTC_END_REASON_STOPPED     0
#define RTC_END_REASON_TIMEOUT     1
#define RTC_END_REASON_DISCONNECT  2

/**
 * @brief Initialize the RTC stream module (queue, thread, work items)
 *
 * Registers itself as the audio data callback; pushes are no-ops until a
 * session begins.
 *
 * @return 0 on success, negative error code on failure
 */
int rtc_stream_init(void);

/**
 * @brief Begin an RTC session (audio pipeline is starting)
 *
 * Arms the start timeout: if the stream is not started with
 * rtc_stream_start() within CONFIG_CLIP_RTC_START_TIMEOUT_SEC, the session
 * is aborted (STREAM never started, audio stop requested).
 *
 * @param session_id Session ID (14-digit string)
 * @return 0 on success, -EBUSY if a session is already active
 */
int rtc_stream_session_begin(const char *session_id);

/**
 * @brief End the RTC session and release all state
 *
 * Safe to call when no session is active. Does not send STREAM_END; call
 * rtc_stream_stop() first if the stream is active and the link is up.
 */
void rtc_stream_session_end(void);

/**
 * @brief Check if an RTC session is active
 */
bool rtc_stream_session_active(void);

/**
 * @brief Get the active RTC session ID ("" if none)
 */
const char *rtc_stream_session_id(void);

/**
 * @brief Start the stream consumer (AT+DOWNLOAD)
 *
 * Flushes any frames queued before the consumer started (RTC delivers
 * "now", not buffered past), resets the sequence, sends STREAM_START and
 * begins emitting STREAM_DATA.
 *
 * @return 0 on success, -ENOENT if no session, negative error if
 *         STREAM_START could not be sent
 */
int rtc_stream_start(void);

/**
 * @brief Stop the stream consumer (sends STREAM_END if the link is up)
 *
 * @param reason RTC_END_REASON_*
 */
void rtc_stream_stop(uint8_t reason);

/**
 * @brief Pause the stream: queued data is discarded, new frames dropped
 *
 * The audio pipeline keeps running; only the BLE emission stops.
 */
void rtc_stream_pause(void);

/**
 * @brief Resume the stream from the current frame
 */
void rtc_stream_resume(void);

/**
 * @brief Check if the stream consumer is running (between DOWNLOAD & STOP)
 */
bool rtc_stream_is_streaming(void);

/**
 * @brief Check if the stream is paused
 */
bool rtc_stream_is_paused(void);

/**
 * @brief BLE disconnect hook — submits deferred teardown work
 *
 * Safe to call from the BLE RX context. If a session is active it is ended
 * and CLIP_EVENT_STOP is posted to shut down the audio pipeline.
 */
void rtc_stream_ble_disconnected(void);

#endif /* CLIP_RTC_STREAM_H */
