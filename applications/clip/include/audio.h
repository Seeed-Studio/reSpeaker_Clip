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

/* Audio configuration */
#define AUDIO_SAMPLE_RATE     16000
#define AUDIO_SAMPLE_BITS      16
#define AUDIO_CHANNELS         2
#define AUDIO_FRAME_MS         20
#define AUDIO_BLOCK_SIZE      (((AUDIO_SAMPLE_BITS / 8) * (AUDIO_SAMPLE_RATE * AUDIO_FRAME_MS)) / 1000) * AUDIO_CHANNELS
#define AUDIO_OPUS_FRAME_SIZE ((AUDIO_SAMPLE_RATE * AUDIO_FRAME_MS) / 1000)
#define AUDIO_MAX_PACKET_SIZE  4000

/* Audio modes */
enum audio_mode {
	AUDIO_MODE_MONO = 0,    /* Left channel only */
	AUDIO_MODE_STEREO = 1,  /* Stereo output */
	AUDIO_MODE_MERGE = 2,   /* Mix L+R to mono */
};

/* Audio statistics */
struct audio_stats {
	uint32_t frames_encoded;
	uint32_t total_bytes;
	uint32_t dropped_frames;
	uint64_t recording_time_ms;
	int64_t encode_time_min_ms;
	int64_t encode_time_max_ms;
	int64_t encode_time_avg_ms;
};

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
 * @brief Stop audio recording
 *
 * @return 0 on success, negative error code on failure
 */
int audio_stop_recording(void);

/**
 * @brief Check if recording is active
 *
 * @return true if recording, false otherwise
 */
bool audio_is_recording(void);

/**
 * @brief Set Opus bitrate
 *
 * @param bitrate Bitrate in bps
 * @return 0 on success, negative error code on failure
 */
int audio_set_bitrate(uint32_t bitrate);

/**
 * @brief Get current bitrate
 *
 * @return Current bitrate in bps
 */
uint32_t audio_get_bitrate(void);

/**
 * @brief Set Opus complexity (0-10)
 *
 * @param complexity Complexity value
 * @return 0 on success, negative error code on failure
 */
int audio_set_complexity(uint8_t complexity);

/**
 * @brief Get current complexity
 *
 * @return Current complexity value
 */
uint8_t audio_get_complexity(void);

/**
 * @brief Enable/disable noise suppression
 *
 * @param enable true to enable, false to disable
 * @return 0 on success, negative error code on failure
 */
int audio_set_noise_suppress(bool enable);

/**
 * @brief Get noise suppression state
 *
 * @return true if enabled, false otherwise
 */
bool audio_get_noise_suppress(void);

/**
 * @brief Get audio statistics
 *
 * @param stats Output statistics structure
 * @return 0 on success, negative error code on failure
 */
int audio_get_stats(struct audio_stats *stats);

/**
 * @brief Audio recording thread
 *
 * @param p1 Unused
 * @param p2 Unused
 * @param p3 Unused
 */
void audio_recording_thread(void *p1, void *p2, void *p3);

#endif /* AUDIO_H */
