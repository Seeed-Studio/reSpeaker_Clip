/*
 * Copyright (c) 2025 Seeed Technology Co., Ltd.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#include <zephyr/kernel.h>
#include <zephyr/device.h>
#include <zephyr/audio/dmic.h>
#include <zephyr/drivers/gpio.h>
#include <zephyr/logging/log.h>
#include <zephyr/sys/byteorder.h>
#include <string.h>
#include <stdio.h>
#include <nrfx_pdm.h>

#include <opus.h>
#include <opus_types.h>

#ifdef CONFIG_SPEEXDSP
#include <speex/speex_preprocess.h>
#endif

#include "audio.h"
#include "clip.h"
#include "config.h"
#include "storage.h"
#include "bookmarks.h"
#include "ble_svc.h"
#include "transfer.h"

LOG_MODULE_REGISTER(audio, LOG_LEVEL_INF);

/* Memory slab for DMIC buffers (increased for stereo mode) */
/* Stereo mode requires more buffers due to higher data rate */
K_MEM_SLAB_DEFINE_STATIC(audio_mem_slab, AUDIO_BLOCK_SIZE, 32, 4);

/* DMIC device */
static const struct device *const dmic_dev = DEVICE_DT_GET(DT_ALIAS(dmic0));
static const struct gpio_dt_spec mic_en = GPIO_DT_SPEC_GET_OR(DT_NODELABEL(mic_reg), gpios, {0});

/* PCM stream configuration for DMIC */
static struct pcm_stream_cfg audio_stream = {
	.pcm_rate = AUDIO_SAMPLE_RATE,
	.pcm_width = AUDIO_SAMPLE_BITS,
	.block_size = AUDIO_BLOCK_SIZE,
	.mem_slab = &audio_mem_slab,
};

/* DMIC configuration */
static struct dmic_cfg audio_cfg = {
	.io = {
		.min_pdm_clk_freq = 1000000,
		.max_pdm_clk_freq = 3500000,
		.min_pdm_clk_dc = 40,
		.max_pdm_clk_dc = 60,
	},
	.streams = &audio_stream,
	.channel = {
		.req_num_streams = 1,
		.req_num_chan = AUDIO_CHANNELS,
	},
};

/* Buffer for processed audio */
static int16_t processed_buffer[AUDIO_OPUS_FRAME_SIZE];

/* Recording state */
static bool recording_active = false;
static enum audio_mode current_mode = AUDIO_MODE_MERGE; /* Default to merge (mono) */
static int opus_channels = 1;

/* Thread-safe start/stop requests */
static K_MUTEX_DEFINE(audio_state_mutex);
static bool start_requested = false;
static enum audio_mode pending_start_mode = AUDIO_MODE_MERGE;
static bool stop_requested = false;

/* Audio recording thread */
K_THREAD_STACK_DEFINE(audio_thread_stack, CLIP_AUDIO_STACK_SIZE);
static struct k_thread audio_thread_data;
static k_tid_t audio_thread_id;

/* Opus encoder state */
static OpusEncoder *opus_encoder = NULL;

#ifdef CONFIG_SPEEXDSP
/* SpeexDSP preprocessor state */
static SpeexPreprocessState *speex_pp = NULL;
static bool speex_enabled = false;
#endif

/* Statistics */
static struct audio_stats stats = {0};
static int64_t encode_time_total = 0;

/* Storage for recording */
static struct storage_file current_storage_file = {0};
static bool storage_enabled = true;

/* Recording segmentation */
static uint32_t recording_frame_count = 0;
static uint32_t current_file_index = 1;
static uint32_t file_start_frame_count = 0;  /* Frame count when current file started */
static bool was_transferring = false;  /* Track previous transfer state */

/* Current session ID for bookmarks */
static char current_session_id[32] = {0};
static uint32_t recording_start_time = 0;  /* For duration calculation */

/* Forward declarations */
static int init_opus_encoder(void);
static void cleanup_opus_encoder(void);
#ifdef CONFIG_SPEEXDSP
static int init_speex_preprocessor(void);
static void cleanup_speex_preprocessor(void);
#endif
static int16_t *process_pcm_frame(int16_t *stereo_input, int frame_size);
static int mic_power_on(void);
static int mic_power_off(void);

int audio_init(void)
{
	int ret;

	if (!device_is_ready(dmic_dev)) {
		LOG_ERR("dmic not ready");
		return -ENODEV;
	}

	/* Initialize audio parameters from loaded config */
	/* MODE_NORMAL = stereo, MODE_ENHANCED = mono with DSP */
	current_mode = (g_config.mode == MODE_NORMAL) ? AUDIO_MODE_STEREO : AUDIO_MODE_MERGE;

	/* Set channels (bitrate calculated in init_opus_encoder) */
	if (current_mode == AUDIO_MODE_STEREO) {
		opus_channels = 2;
	} else {
		opus_channels = 1;
	}

	/* Initialize Opus encoder */
	ret = init_opus_encoder();
	if (ret < 0) {
		LOG_ERR("opus_init: %d", ret);
		return ret;
	}

#ifdef CONFIG_SPEEXDSP
	/* DSP only enabled in enhanced (mono) mode */
	if (g_config.noise_suppress > 0 && current_mode == AUDIO_MODE_MERGE) {
		speex_enabled = true;
		ret = init_speex_preprocessor();
		if (ret < 0) {
			LOG_WRN("speex_init: %d", ret);
			speex_enabled = false;
		}
	}
#endif

	/* Configure channel map */
	audio_cfg.channel.req_chan_map_lo = dmic_build_channel_map(0, 0, PDM_CHAN_LEFT);
	audio_cfg.channel.req_chan_map_lo |= dmic_build_channel_map(1, 0, PDM_CHAN_RIGHT);

	/* Configure DMIC */
	ret = dmic_configure(dmic_dev, &audio_cfg);
	if (ret < 0) {
		LOG_ERR("dmic_cfg: %d", ret);
		cleanup_opus_encoder();
		return ret;
	}

	/* Power on microphone */
	ret = mic_power_on();
	if (ret < 0) {
		LOG_WRN("mic_pwr: %d", ret);
	}

	/* Set microphone gain - level 6 (+20dB) */
#ifdef NRF_PDM0_S
	nrf_pdm_gain_set(NRF_PDM0_S, 0x3C, 0x3C);
#else
	nrf_pdm_gain_set(NRF_PDM0_NS, 0x3C, 0x3C);
#endif

	{
		/* Calculate actual bitrate for logging */
		uint32_t actual_bitrate = (current_mode == AUDIO_MODE_STEREO) ?
			g_config.bitrate * 2 : g_config.bitrate;
		LOG_INF("audio: %dch %ukbps", opus_channels, actual_bitrate/1000);
	}

	/* Start audio recording thread */
	audio_thread_id = k_thread_create(&audio_thread_data,
					  audio_thread_stack,
					  CLIP_AUDIO_STACK_SIZE,
					  audio_recording_thread,
					  NULL, NULL, NULL,
					  CLIP_AUDIO_THREAD_PRIORITY, 0, K_NO_WAIT);
	if (!audio_thread_id) {
		LOG_ERR("Failed to create audio thread");
		cleanup_opus_encoder();
		mic_power_off();
		return -ENOMEM;
	}
	k_thread_name_set(&audio_thread_data, "audio_rec");
	LOG_INF("Audio thread started");

	return 0;
}

void audio_cleanup(void)
{
	audio_stop_recording();

#ifdef CONFIG_SPEEXDSP
	cleanup_speex_preprocessor();
#endif
	cleanup_opus_encoder();

	mic_power_off();
}

/* Internal function to perform recording initialization in audio thread context */
static int audio_start_recording_internal(enum audio_mode mode);
static int audio_stop_recording_internal(void);

int audio_start_recording(enum audio_mode mode)
{
	/* Generate session ID early so it's available for AT command response */
	uint16_t year;
	uint8_t month, day, hour, min, sec;

	/* Lock to protect session_id and state variables */
	k_mutex_lock(&audio_state_mutex, K_FOREVER);

	if (recording_active) {
		k_mutex_unlock(&audio_state_mutex);
		LOG_WRN("Recording already active");
		return -EBUSY;
	}

	/* Generate session ID: always 14 digits */
	if (clip_get_current_time(&year, &month, &day, &hour, &min, &sec)) {
		/* Time synchronized: YYYYMMDDHHMMSS (14 digits) */
		snprintf(current_session_id, sizeof(current_session_id),
			"%04d%02d%02d%02d%02d%02d",
			year, month, day, hour, min, sec);
	} else {
		/* Time not set: use 0 + uptime (14 digits total) */
		uint32_t uptime_sec = (uint32_t)(k_uptime_get() / 1000);
		snprintf(current_session_id, sizeof(current_session_id),
			"0%013u", uptime_sec);  /* 0 + 13-digit uptime = 14 digits */
		LOG_WRN("Time not synchronized, using uptime-based session ID");
	}

	/* Initialize session-dependent variables */
	current_file_index = 1;
	file_start_frame_count = 0;
	was_transferring = false;
	recording_start_time = (uint32_t)(k_uptime_get() / 1000);

	/* Set start request flag with mode */
	start_requested = true;
	pending_start_mode = mode;
	k_mutex_unlock(&audio_state_mutex);

	LOG_INF("Recording start requested (mode=%d, session=%s)", mode, current_session_id);
	return 0;
}

int audio_stop_recording(void)
{
	/* Just set the stop request flag - audio thread will handle cleanup */
	k_mutex_lock(&audio_state_mutex, K_FOREVER);

	if (!recording_active) {
		k_mutex_unlock(&audio_state_mutex);
		return 0;
	}

	stop_requested = true;
	k_mutex_unlock(&audio_state_mutex);

	LOG_INF("Recording stop requested");
	return 0;
}

int audio_set_bitrate(uint32_t bitrate)
{
	/* Validate bitrate (this is the mono bitrate) */
	if (bitrate < 16000 || bitrate > 32000) {
		return -EINVAL;
	}

	/* Store as mono bitrate in config */
	g_config.bitrate = bitrate;

#ifdef CONFIG_SETTINGS
	save_setting_now("config/bitrate", &bitrate, sizeof(bitrate));
#endif

	/* Reinitialize encoder with new bitrate if recording */
	if (recording_active) {
		int ret = init_opus_encoder();
		if (ret < 0) {
			LOG_ERR("Failed to set bitrate: %d", ret);
			return ret;
		}
	}

	LOG_INF("Bitrate set: mono=%u bps", bitrate);
	return 0;
}

uint32_t audio_get_bitrate(void)
{
	/* Return stored mono bitrate (not the actual encoded bitrate) */
	/* The actual encoded bitrate depends on mode: stereo = mono * 2 */
	return g_config.bitrate;
}

int audio_set_complexity(uint8_t complexity)
{
	int ret;

	if (complexity > 10) {
		return -EINVAL;
	}

	if (!opus_encoder) {
		return -ENOTSUP;
	}

	ret = opus_encoder_ctl(opus_encoder, OPUS_SET_COMPLEXITY(complexity));
	if (ret != OPUS_OK) {
		LOG_ERR("Failed to set complexity: %d", ret);
		return ret;
	}

	g_config.complexity = complexity;

	LOG_INF("Complexity set to %u", complexity);
	return 0;
}

uint8_t audio_get_complexity(void)
{
	return g_config.complexity;
}

int audio_set_noise_suppress(bool enable)
{
#ifdef CONFIG_SPEEXDSP
	g_config.noise_suppress = enable ? 1 : 0;
	/* Note: speex_enabled is set based on mode during recording start */
	LOG_INF("Noise suppression config: %s", enable ? "enabled" : "disabled");
	return 0;
#else
	return -ENOTSUP;
#endif
}

bool audio_get_noise_suppress(void)
{
#ifdef CONFIG_SPEEXDSP
	return speex_enabled;
#else
	return false;
#endif
}

int audio_get_stats(struct audio_stats *stats_out)
{
	if (!stats_out) {
		return -EINVAL;
	}

	/* Calculate average if recording stopped */
	if (!recording_active && stats.frames_encoded > 0) {
		stats.encode_time_avg_ms = encode_time_total / stats.frames_encoded;
	}

	memcpy(stats_out, &stats, sizeof(stats));
	return 0;
}

/* Internal recording initialization - executes in audio thread context */
static int audio_start_recording_internal(enum audio_mode mode)
{
	int ret;

	LOG_INF("Starting recording in mode %d (audio thread)", mode);

	/* Update mode if changed */
	if (mode != current_mode) {
		current_mode = mode;

		/* Update Opus channels based on mode */
		if (mode == AUDIO_MODE_STEREO) {
			opus_channels = 2;
		} else {
			opus_channels = 1;
		}

		/* Reinitialize encoder (calculates actual bitrate based on mode) */
		ret = init_opus_encoder();
		if (ret < 0) {
			LOG_ERR("Failed to reinitialize Opus encoder: %d", ret);
			return ret;
		}

#ifdef CONFIG_SPEEXDSP
		/* Handle DSP based on mode: only enabled in enhanced (mono) mode */
		if (mode == AUDIO_MODE_STEREO) {
			/* Disable DSP in stereo mode */
			if (speex_enabled) {
				cleanup_speex_preprocessor();
				speex_enabled = false;
			}
		} else {
			/* Re-enable DSP in enhanced mode if configured */
			if (g_config.noise_suppress > 0 && !speex_enabled) {
				speex_enabled = true;
				ret = init_speex_preprocessor();
				if (ret < 0) {
					LOG_WRN("speex_init: %d", ret);
					speex_enabled = false;
				}
			}
		}
#endif
	}

	/* Reset statistics */
	memset(&stats, 0, sizeof(stats));
	stats.encode_time_min_ms = INT64_MAX;
	encode_time_total = 0;

	/* Reset recording counters */
	recording_frame_count = 0;
	/* Note: current_file_index, file_start_frame_count, was_transferring, and
	 * recording_start_time are already initialized in audio_start_recording() */

	/* Session ID was already generated in audio_start_recording() */
	LOG_INF("Starting recording with session: %s", current_session_id);
	LOG_INF("Audio config: %d Hz, %d ch, frame=%u samples, %u ms, block=%u bytes",
		AUDIO_SAMPLE_RATE, opus_channels, AUDIO_OPUS_FRAME_SIZE, AUDIO_FRAME_MS, AUDIO_BLOCK_SIZE);

	/* Create session directory and first file */
	if (storage_enabled && storage_is_mounted()) {
		/* Create session directory */
		ret = storage_create_session(current_session_id);
		if (ret != 0) {
			LOG_WRN("Failed to create session directory: %d", ret);
		} else {
			/* Initialize bookmarks for this session AFTER directory exists */
			bookmarks_init(current_session_id);

			/* Create first file */
			ret = storage_create_file(&current_storage_file,
				current_session_id, current_file_index);
			if (ret != 0) {
				LOG_WRN("Failed to create storage file: %d", ret);
			} else {
				LOG_INF("Recording to: %s", current_storage_file.filename);
				/* Mark this file as being written */
				storage_set_writing_file(current_session_id,
					current_storage_file.filename);
			}
		}
	} else {
		/* Initialize bookmarks even without storage */
		bookmarks_init(current_session_id);
	}

	/* Start DMIC */
	ret = dmic_trigger(dmic_dev, DMIC_TRIGGER_START);
	if (ret < 0) {
		LOG_ERR("Failed to start DMIC: %d", ret);
		/* Close file if opened */
		if (current_storage_file.is_open) {
			storage_close_file(&current_storage_file);
			storage_set_writing_file(NULL, NULL);
		}
		return ret;
	}

	recording_active = true;

	/* Calculate actual bitrate for logging */
	uint32_t actual_bitrate = (current_mode == AUDIO_MODE_STEREO) ?
		g_config.bitrate * 2 : g_config.bitrate;
	LOG_INF("Recording started: %s mode, %u kbps (mono=%u)",
		(current_mode == AUDIO_MODE_STEREO) ? "stereo" : "mono",
		actual_bitrate/1000, g_config.bitrate/1000);
	return 0;
}

/* Internal stop function - executes in audio thread context */
static int audio_stop_recording_internal(void)
{
	int ret;
	uint32_t duration_sec;

	if (!recording_active) {
		return 0;
	}

	recording_active = false;

	/* Stop DMIC */
	ret = dmic_trigger(dmic_dev, DMIC_TRIGGER_STOP);
	if (ret < 0) {
		LOG_ERR("Failed to stop DMIC: %d", ret);
	}

	/* Close recording file */
	if (current_storage_file.is_open) {
		/* Save filename and size before closing */
		char completed_filename[64];
		uint32_t completed_size;
		strncpy(completed_filename, current_storage_file.filename,
		       sizeof(completed_filename) - 1);
		completed_filename[sizeof(completed_filename) - 1] = '\0';
		completed_size = current_storage_file.bytes_written;

		ret = storage_close_file(&current_storage_file);
		if (ret != 0) {
			LOG_WRN("Failed to close storage file: %d", ret);
		}
		/* Clear writing file mark */
		storage_set_writing_file(NULL, NULL);
		memset(&current_storage_file, 0, sizeof(current_storage_file));
	}

	/* Calculate duration */
	duration_sec = (uint32_t)(k_uptime_get() / 1000) - recording_start_time;

	/* Save bookmarks */
	ret = bookmarks_save(current_session_id);
	if (ret != 0) {
		LOG_WRN("Failed to save bookmarks: %d", ret);
	}

	/* Close session and create metadata files */
	if (storage_is_mounted()) {
		ret = storage_close_session(current_session_id, duration_sec, current_file_index);
		if (ret != 0) {
			LOG_WRN("Failed to close session: %d", ret);
		}
	}

	/* Calculate average encode time */
	if (stats.frames_encoded > 0) {
		stats.encode_time_avg_ms = encode_time_total / stats.frames_encoded;
	}

	LOG_INF("Recording stopped: %u sec, %u KB", duration_sec, stats.total_bytes/1024);

	/* Transition to IDLE state now that recording has actually stopped */
	state_transition(CLIP_STATE_IDLE);

	return 0;
}

/* Audio recording thread */
void audio_recording_thread(void *p1, void *p2, void *p3)
{
	int ret;
	void *buffer = NULL;
	uint32_t size;
	uint8_t opus_packet[AUDIO_MAX_PACKET_SIZE];
	enum audio_mode start_mode;

	LOG_INF("Audio recording thread started");

	while (true) {
		/* Check for start/stop requests (under mutex for thread safety) */
		k_mutex_lock(&audio_state_mutex, K_FOREVER);

		if (start_requested && !recording_active) {
			start_mode = pending_start_mode;
			start_requested = false;
			k_mutex_unlock(&audio_state_mutex);

			/* Perform all initialization in audio thread context */
			ret = audio_start_recording_internal(start_mode);
			if (ret < 0) {
				LOG_ERR("Failed to start recording: %d", ret);
				continue;
			}
			/* Continue to recording loop */
		} else if (stop_requested && recording_active) {
			stop_requested = false;
			k_mutex_unlock(&audio_state_mutex);

			/* Perform cleanup in audio thread context */
			audio_stop_recording_internal();
			continue;
		} else {
			k_mutex_unlock(&audio_state_mutex);
		}

		/* Wait for recording to be active */
		if (!recording_active) {
			k_msleep(100);
			continue;
		}

		/* Read one audio block from DMIC */
		ret = dmic_read(dmic_dev, 0, &buffer, &size, 500);
		if (ret < 0) {
			if (ret == -EAGAIN) {
				/* Timeout, continue */
				continue;
			}
			LOG_ERR("DMIC read error: %d", ret);
			stats.dropped_frames++;
			k_msleep(10);
			continue;
		}

		/* Validate block size */
		if (size != AUDIO_BLOCK_SIZE) {
			LOG_WRN("Invalid block size: %u (expected %u)", size, AUDIO_BLOCK_SIZE);
			k_mem_slab_free(&audio_mem_slab, buffer);
			buffer = NULL;
			stats.dropped_frames++;
			continue;
		}

		/* Measure encode time */
		int64_t encode_start = k_uptime_get();

		/* Process PCM data according to mode */
		int16_t *pcm_data = process_pcm_frame((int16_t *)buffer, AUDIO_OPUS_FRAME_SIZE);

#ifdef CONFIG_SPEEXDSP
		/* Apply SpeexDSP preprocessing */
		if (speex_enabled) {
			if (current_mode == AUDIO_MODE_STEREO) {
				/* Process stereo channels separately */
				int16_t temp_left[AUDIO_OPUS_FRAME_SIZE];
				int16_t temp_right[AUDIO_OPUS_FRAME_SIZE];

				/* Deinterleave */
				for (int i = 0; i < AUDIO_OPUS_FRAME_SIZE; i++) {
					temp_left[i] = pcm_data[i * 2];
					temp_right[i] = pcm_data[i * 2 + 1];
				}

				/* Process each channel */
				speex_preprocess_run(speex_pp, temp_left);
				speex_preprocess_run(speex_pp, temp_right);

				/* Interleave back */
				for (int i = 0; i < AUDIO_OPUS_FRAME_SIZE; i++) {
					pcm_data[i * 2] = temp_left[i];
					pcm_data[i * 2 + 1] = temp_right[i];
				}
			} else {
				/* Mono mode - process single channel */
				speex_preprocess_run(speex_pp, pcm_data);
			}
		}
#endif

		/* Encode audio */
		opus_int32 encoded_bytes = opus_encode(
			opus_encoder,
			pcm_data,
			AUDIO_OPUS_FRAME_SIZE,
			opus_packet,
			AUDIO_MAX_PACKET_SIZE
		);

		/* Free buffer */
		k_mem_slab_free(&audio_mem_slab, buffer);
		buffer = NULL;

		if (encoded_bytes < 0) {
			LOG_ERR("Opus encode error: %d", encoded_bytes);
			stats.dropped_frames++;
			continue;
		}

		/* Update encode time statistics */
		int64_t encode_time = k_uptime_get() - encode_start;
		encode_time_total += encode_time;
		if (encode_time < stats.encode_time_min_ms) {
			stats.encode_time_min_ms = encode_time;
		}
		if (encode_time > stats.encode_time_max_ms) {
			stats.encode_time_max_ms = encode_time;
		}

		/* Warn if encoding takes too long (should be < 15ms for 20ms frame) */
		if (encode_time > 15) {
			LOG_WRN("Encode time too high: %lld ms (frame %u)", encode_time, recording_frame_count);
		}

		/* Update statistics */
		stats.frames_encoded++;
		stats.total_bytes += encoded_bytes;
		recording_frame_count++;

		/* Print encode time stats every second (50 frames) */
		if (recording_frame_count % 50 == 0) {
			int64_t avg_time = encode_time_total / stats.frames_encoded;
			LOG_INF("Encode: avg=%lld ms, min=%lld ms, max=%lld ms, pkt=%u bytes (frame %u)",
				avg_time, stats.encode_time_min_ms, stats.encode_time_max_ms,
				encoded_bytes, recording_frame_count);
		}

		/* Check if we need to create a new file (segmentation)
		 * Use different segment durations based on transfer state:
		 * - When transferring: shorter segments (CLIP_AUDIO_SEGMENT_DURATION_SYNC)
		 * - When not transferring: longer segments (CLIP_AUDIO_SEGMENT_DURATION_NO_SYNC)
		 */
		bool is_transferring = transfer_is_active();
		uint32_t segment_duration_sec;

		if (is_transferring) {
			segment_duration_sec = CLIP_AUDIO_SEGMENT_DURATION_SYNC;
		} else {
			segment_duration_sec = CLIP_AUDIO_SEGMENT_DURATION_NO_SYNC;
		}

		/* Calculate frames per file based on current segment duration */
		uint32_t frames_per_file = segment_duration_sec * (1000 / AUDIO_FRAME_MS);

		/* Check for state transition: not transferring -> transferring
		 * If current file duration exceeds sync segment duration, slice immediately
		 */
		if (was_transferring == false && is_transferring == true && recording_frame_count > 1) {
			uint32_t current_file_frames = recording_frame_count - file_start_frame_count;
			uint32_t sync_frames_per_file = CLIP_AUDIO_SEGMENT_DURATION_SYNC * (1000 / AUDIO_FRAME_MS);

			if (current_file_frames >= sync_frames_per_file) {
				/* File exceeds sync duration, slice immediately */
				LOG_INF("Transfer started, slicing current file (%u frames >= %u sync frames)",
					current_file_frames, sync_frames_per_file);
				goto create_new_segment;
			}
		}

		/* Update transfer state tracking */
		was_transferring = is_transferring;

		/* Regular segment check based on current segment duration */
		if (recording_frame_count > 1 && (recording_frame_count - file_start_frame_count) >= frames_per_file) {
create_new_segment:
			/* Time to create a new segment file */
			LOG_INF("Segment switch: frame %u, creating file #%u (duration: %us, transferring: %d)",
				recording_frame_count, current_file_index + 1, segment_duration_sec, is_transferring);

			if (current_storage_file.is_open) {
				LOG_INF("Closing current segment: %s (%u bytes)",
					current_storage_file.filename,
					current_storage_file.bytes_written);

				/* Save filename and size before closing */
				char completed_filename[64];
				uint32_t completed_size;
				strncpy(completed_filename, current_storage_file.filename,
				       sizeof(completed_filename) - 1);
				completed_filename[sizeof(completed_filename) - 1] = '\0';
				completed_size = current_storage_file.bytes_written;

				storage_close_file(&current_storage_file);
				/* Clear old writing file mark */
				storage_set_writing_file(NULL, NULL);

				/* NOTE: Recording and transfer are now separated - client initiates transfer via AT+DOWNLOAD */
			}

			/* Create new file with incremented index */
			ret = storage_create_file(&current_storage_file,
				current_session_id, ++current_file_index);
			if (ret != 0) {
				LOG_ERR("Failed to create segment file: %d", ret);
				/* Continue recording without storage */
			} else {
				LOG_INF("Created new segment: %s", current_storage_file.filename);
				file_start_frame_count = recording_frame_count;
			}
		}

		/* Save to SD card if storage enabled and file open */
		if (storage_enabled && current_storage_file.is_open) {
			ret = storage_write_frame(&current_storage_file,
					       opus_packet, encoded_bytes);
			if (ret != 0) {
				LOG_ERR("Storage write error: %d", ret);
				/* Close file on error */
				storage_close_file(&current_storage_file);
				memset(&current_storage_file, 0, sizeof(current_storage_file));
			}
		}

		k_yield();
	}
}

/* Internal functions */
static int init_opus_encoder(void)
{
	int err;

	/* Destroy old encoder if exists */
	if (opus_encoder) {
		opus_encoder_destroy(opus_encoder);
		opus_encoder = NULL;
	}

	/* Create Opus encoder */
	opus_encoder = opus_encoder_create(AUDIO_SAMPLE_RATE, opus_channels,
					   OPUS_APPLICATION_VOIP, &err);
	if (!opus_encoder) {
		LOG_ERR("Failed to create Opus encoder: %d", err);
		return err;
	}

	LOG_INF("Opus encoder created: %d Hz, %d ch, application=VOIP",
		AUDIO_SAMPLE_RATE, opus_channels);

	/* Query and print default encoder parameters before configuration */
	opus_int32 lookhead;
	err = opus_encoder_ctl(opus_encoder, OPUS_GET_LOOKAHEAD(&lookhead));
	if (err == OPUS_OK) {
		LOG_INF("Opus lookahead: %d samples", lookhead);
	}

	/* Set bitrate (stereo = mono * 2) */
	uint32_t actual_bitrate;
	if (current_mode == AUDIO_MODE_STEREO) {
		actual_bitrate = g_config.bitrate * 2;
	} else {
		actual_bitrate = g_config.bitrate;
	}
	err = opus_encoder_ctl(opus_encoder, OPUS_SET_BITRATE(actual_bitrate));
	if (err != OPUS_OK) {
		LOG_ERR("Failed to set bitrate: %d", err);
		return err;
	}

	/* Verify bitrate was set correctly */
	opus_int32 configured_bitrate;
	opus_encoder_ctl(opus_encoder, OPUS_GET_BITRATE(&configured_bitrate));

	/* Set complexity */
	err = opus_encoder_ctl(opus_encoder, OPUS_SET_COMPLEXITY(g_config.complexity));
	if (err != OPUS_OK) {
		LOG_ERR("Failed to set complexity: %d", err);
		return err;
	}

	/* Verify complexity */
	opus_int32 configured_complexity;
	opus_encoder_ctl(opus_encoder, OPUS_GET_COMPLEXITY(&configured_complexity));

	/* Get max payload size */
	opus_int32 max_payload;
	opus_encoder_ctl(opus_encoder, OPUS_GET_MAX_PACKET_SIZE(&max_payload));

	/* Disable FEC */
	err = opus_encoder_ctl(opus_encoder, OPUS_SET_INBAND_FEC(0));
	if (err != OPUS_OK) {
		LOG_ERR("Failed to disable FEC: %d", err);
		return err;
	}

	LOG_INF("Opus config: %d ch, bitrate=%u bps (requested=%u), complexity=%u, max_payload=%u",
		opus_channels, configured_bitrate, actual_bitrate, configured_complexity, max_payload);

	return 0;
}

static void cleanup_opus_encoder(void)
{
	if (opus_encoder) {
		opus_encoder_destroy(opus_encoder);
		opus_encoder = NULL;
	}
}

#ifdef CONFIG_SPEEXDSP
static int init_speex_preprocessor(void)
{
	/* Destroy old preprocessor if exists */
	if (speex_pp) {
		speex_preprocess_state_destroy(speex_pp);


		
		speex_pp = NULL;
	}

	/* Create preprocessor state */
	speex_pp = speex_preprocess_state_init(AUDIO_OPUS_FRAME_SIZE, AUDIO_SAMPLE_RATE);
	if (!speex_pp) {
		LOG_ERR("Failed to create SpeexDSP preprocessor");
		return -ENOMEM;
	}

	/* Set noise suppression (30dB) */
	int denoise = 30;
	speex_preprocess_ctl(speex_pp, SPEEX_PREPROCESS_SET_NOISE_SUPPRESS, &denoise);

	/* Enable dereverberation */
	int dereverb = 1;
	speex_preprocess_ctl(speex_pp, SPEEX_PREPROCESS_SET_DEREVERB, &dereverb);

	/* Set dereverb level */
	int dereverb_level = 40;
	speex_preprocess_ctl(speex_pp, SPEEX_PREPROCESS_SET_DEREVERB_LEVEL, &dereverb_level);

	/* Set dereverb decay */
	int dereverb_decay = 20;
	speex_preprocess_ctl(speex_pp, SPEEX_PREPROCESS_SET_DEREVERB_DECAY, &dereverb_decay);

	LOG_INF("SpeexDSP initialized: NS=30dB, dereverb=enabled");

	return 0;
}

static void cleanup_speex_preprocessor(void)
{
	if (speex_pp) {
		speex_preprocess_state_destroy(speex_pp);
		speex_pp = NULL;
	}
}
#endif

static int16_t *process_pcm_frame(int16_t *stereo_input, int frame_size)
{
	/* stereo_input layout: L0, R0, L1, R1, L2, R2, ... */

	if (current_mode == AUDIO_MODE_MONO) {
		/* Extract left channel only */
		for (int i = 0; i < frame_size; i++) {
			processed_buffer[i] = stereo_input[i * 2];  /* Left channel */
		}
		return processed_buffer;

	} else if (current_mode == AUDIO_MODE_MERGE) {
		/* Mix left and right: (L + R) / 2 */
		for (int i = 0; i < frame_size; i++) {
			int32_t left = stereo_input[i * 2];
			int32_t right = stereo_input[i * 2 + 1];
			int32_t mixed = (left + right) / 2;
			/* Clamp to int16 range */
			if (mixed > 32767) mixed = 32767;
			if (mixed < -32768) mixed = -32768;
			processed_buffer[i] = (int16_t)mixed;
		}
		return processed_buffer;

	} else {
		/* AUDIO_MODE_STEREO: return original stereo data */
		return stereo_input;
	}
}

static int mic_power_on(void)
{
	if (mic_en.port) {
		gpio_pin_configure_dt(&mic_en, GPIO_OUTPUT);
		gpio_pin_set_dt(&mic_en, 1);
		k_msleep(10); /* Delay for power stabilization */
	}
	return 0;
}

static int mic_power_off(void)
{
	if (mic_en.port) {
		gpio_pin_configure_dt(&mic_en, GPIO_OUTPUT);
		gpio_pin_set_dt(&mic_en, 0);
	}
	return 0;
}

/* Public API functions */
int audio_add_bookmark(const char *note)
{
	struct bookmark bm;
	uint32_t recording_sec;

	if (!recording_active) {
		return -EINVAL;
	}

	/* Calculate recording time in seconds */
	recording_sec = (stats.frames_encoded * AUDIO_FRAME_MS) / 1000;

	/* Fill bookmark structure */
	memset(&bm, 0, sizeof(bm));
	bm.timestamp = (uint32_t)(k_uptime_get() / 1000);
	bm.offset_sec = recording_sec;
	bm.file_index = current_file_index;
	bm.file_offset = current_storage_file.bytes_written;
	if (note) {
		strncpy(bm.note, note, sizeof(bm.note) - 1);
	} else {
		bm.note[0] = '\0';
	}

	/* Add to bookmarks module */
	return bookmarks_add(current_session_id, &bm);
}

const char *audio_get_session_id(void)
{
	/* Return session ID if recording is active or if start was requested
	 * (session ID is generated early in audio_start_recording) */
	k_mutex_lock(&audio_state_mutex, K_FOREVER);
	bool has_session = (recording_active || start_requested);
	k_mutex_unlock(&audio_state_mutex);

	if (!has_session) {
		return NULL;
	}

	/* Check if session_id is not empty */
	if (current_session_id[0] == '\0') {
		return NULL;
	}

	return current_session_id;
}

bool audio_is_recording(void)
{
	/* Check if audio is actively recording (or starting/stopping)
	 * This is more accurate than the state machine for button handling */
	k_mutex_lock(&audio_state_mutex, K_FOREVER);
	bool is_active = recording_active || start_requested;
	k_mutex_unlock(&audio_state_mutex);

	return is_active;
}
