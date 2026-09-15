/*
 * Copyright (c) 2025 Seeed Technology Co., Ltd.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#ifndef AUDIO_H
#define AUDIO_H

#include <stdint.h>
#include <stddef.h>
#include <zephyr/kernel.h>

/**
 * @brief Audio configuration
 */
#define AUDIO_SAMPLE_RATE     16000
#define AUDIO_SAMPLE_BITS      16
#define AUDIO_CHANNELS         2
#define AUDIO_FRAME_MS         20
#define AUDIO_BLOCK_SIZE      (((AUDIO_SAMPLE_BITS / 8) * (AUDIO_SAMPLE_RATE * AUDIO_FRAME_MS)) / 1000) * AUDIO_CHANNELS
#define AUDIO_OPUS_FRAME_SIZE ((AUDIO_SAMPLE_RATE * AUDIO_FRAME_MS) / 1000)
#define AUDIO_MAX_PACKET_SIZE  4000

/* Audio segment duration (from Kconfig) */
#define CLIP_AUDIO_SEGMENT_DURATION_SYNC      CONFIG_CLIP_AUDIO_SEGMENT_DURATION_SYNC
#define CLIP_AUDIO_SEGMENT_DURATION_NO_SYNC   CONFIG_CLIP_AUDIO_SEGMENT_DURATION_NO_SYNC

/**
 * @brief Audio recording modes
 */
enum audio_mode {
	AUDIO_MODE_STEREO = 0,  /* Stereo: record both channels, encode as stereo */
	AUDIO_MODE_MERGE = 1,   /* Enhanced: mix L+R to mono, apply DSP, encode as mono */
};

/**
 * @brief Audio statistics
 */
struct audio_stats {
    uint32_t frames_encoded;
    uint32_t total_bytes;
    uint32_t dropped_frames;
    uint64_t recording_time_ms;
    uint32_t encode_time_min_us;
    uint32_t encode_time_max_us;
    uint32_t encode_time_avg_us;
};

/**
 * @brief Audio data callback
 *
 * Called when encoded audio data is available.
 *
 * @param data Encoded audio data (Opus packet)
 * @param len Length of data in bytes
 * @param user_data User data pointer
 */
typedef void (*audio_data_callback_t)(const uint8_t *data, size_t len, void *user_data);

/**
 * @brief Initialize audio subsystem
 *
 * @return 0 on success, negative error code on failure
 */
int audio_init(void);

/**
 * @brief Cleanup audio subsystem
 */
void audio_cleanup(void);

/**
 * @brief Start audio recording
 *
 * @param mode Audio mode (mono/stereo/merge)
 * @return 0 on success, negative error code on failure
 */
int audio_start_recording(enum audio_mode mode);

/**
 * @brief Start an RTC (real-time streaming) audio session
 *
 * Runs the same pipeline as recording (PDM -> DSP -> Opus) but encoded
 * frames are only delivered through the registered data callback. Nothing
 * is written to storage and no session is created on the SD card, so RTC
 * works even on a full card.
 *
 * @return 0 on success, negative error code on failure
 */
int audio_start_rtc(void);

/**
 * @brief Stop audio recording
 *
 * @return 0 on success, negative error code on failure
 */
int audio_stop_recording(void);

/**
 * @brief Pause audio recording
 *
 * Pauses recording and writes remaining data to storage.
 *
 * @return 0 on success, negative error code on failure
 */
int audio_pause_recording(void);

/**
 * @brief Resume audio recording
 *
 * Resumes recording with a new session file.
 *
 * @return 0 on success, negative error code on failure
 */
int audio_resume_recording(void);

/**
 * @brief Check if recording is paused
 *
 * @return true if paused, false otherwise
 */
bool audio_is_paused(void);

/**
 * @brief Check if recording is active
 *
 * @return true if recording, false otherwise
 */
bool audio_is_recording(void);

/**
 * @brief Check if the active session is an RTC (non-persisted) session
 *
 * @return true if recording and the session does not persist to SD
 */
bool audio_session_is_rtc(void);

/**
 * @brief Get audio statistics
 *
 * @param stats Output statistics structure
 * @return 0 on success, negative error code on failure
 */
int audio_get_stats(struct audio_stats *stats);

/**
 * @brief Register audio data callback
 *
 * @param callback Callback function
 * @param user_data User data pointer
 */
void audio_register_data_callback(audio_data_callback_t callback, void *user_data);

/**
 * @brief Get current session ID
 *
 * @return Session ID string, or NULL if not recording
 */
const char *audio_get_session_id(void);

/**
 * @brief Audio recording thread
 *
 * @param p1 Unused
 * @param p2 Unused
 * @param p3 Unused
 */
void audio_recording_thread(void *p1, void *p2, void *p3);

/**
 * @brief Get current audio energy level (0-10)
 *
 * Returns the current audio energy level for visualization.
 * Used for display waveform animation.
 *
 * @return Energy level (0 = quiet, 10 = loud)
 */
int audio_get_energy_level(void);

/**
 * @brief Add a bookmark at current recording position
 *
 * Adds a bookmark at the current recording time.
 * Can only be called while recording is active.
 *
 * @return 0 on success, negative error code on failure
 */
int audio_add_bookmark(void);

/**
 * @brief Free stack bytes of the audio recording thread
 *
 * Diagnostic helper: returns the unused stack space of the audio thread,
 * or 0 if the thread is not running.
 */
uint32_t audio_thread_stack_free(void);

#endif /* AUDIO_H */
