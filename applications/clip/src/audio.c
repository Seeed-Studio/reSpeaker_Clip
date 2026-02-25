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

/* Memory slab for DMIC buffers (increased for double-buffering) */
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
static uint32_t current_bitrate = 24000;

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

	LOG_INF("Initializing audio subsystem...");

	if (!device_is_ready(dmic_dev)) {
		LOG_ERR("DMIC device not ready");
		return -ENODEV;
	}

	/* Initialize Opus encoder */
	ret = init_opus_encoder();
	if (ret < 0) {
		LOG_ERR("Failed to initialize Opus encoder: %d", ret);
		return ret;
	}

#ifdef CONFIG_SPEEXDSP
	/* Initialize SpeexDSP if enabled in config */
	if (g_config.noise_suppress > 0) {
		speex_enabled = true;
		ret = init_speex_preprocessor();
		if (ret < 0) {
			LOG_WRN("Failed to initialize SpeexDSP: %d", ret);
			speex_enabled = false;
		}
	}
#endif

	/* Configure channel map - stereo LEFT and RIGHT channels */
	audio_cfg.channel.req_chan_map_lo = dmic_build_channel_map(0, 0, PDM_CHAN_LEFT);
	audio_cfg.channel.req_chan_map_lo |= dmic_build_channel_map(1, 0, PDM_CHAN_RIGHT);

	/* Configure DMIC */
	ret = dmic_configure(dmic_dev, &audio_cfg);
	if (ret < 0) {
		LOG_ERR("Failed to configure DMIC: %d", ret);
		cleanup_opus_encoder();
		return ret;
	}

	/* Power on microphone */
	ret = mic_power_on();
	if (ret < 0) {
		LOG_WRN("Failed to power on mic: %d", ret);
	}

	/* Set microphone gain - level 6 (+20dB) */
#ifdef NRF_PDM0_S
	nrf_pdm_gain_set(NRF_PDM0_S, 0x3C, 0x3C);
#else
	nrf_pdm_gain_set(NRF_PDM0_NS, 0x3C, 0x3C);
#endif

	/* Initialize mode from config */
	current_mode = (g_config.mode == MODE_ENHANCED) ? AUDIO_MODE_STEREO : AUDIO_MODE_MERGE;
	current_bitrate = g_config.bitrate;

	if (current_mode == AUDIO_MODE_STEREO) {
		opus_channels = 2;
	} else {
		opus_channels = 1;
	}

	/* Reinitialize encoder with correct settings */
	init_opus_encoder();

	LOG_INF("Audio subsystem initialized: %d Hz, %d ch, %d bps",
		AUDIO_SAMPLE_RATE, opus_channels, current_bitrate);

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

	LOG_INF("Audio subsystem cleaned up");
}

int audio_start_recording(enum audio_mode mode)
{
	int ret;

	if (recording_active) {
		LOG_WRN("Recording already active");
		return -EBUSY;
	}

	LOG_INF("Starting recording in mode %d", mode);

	/* Update mode if changed */
	if (mode != current_mode) {
		current_mode = mode;

		/* Update Opus channels based on mode */
		if (mode == AUDIO_MODE_STEREO) {
			opus_channels = 2;
			current_bitrate = 48000;
		} else {
			opus_channels = 1;
			current_bitrate = 24000;
		}

		/* Reinitialize encoder */
		ret = init_opus_encoder();
		if (ret < 0) {
			LOG_ERR("Failed to reinitialize Opus encoder: %d", ret);
			return ret;
		}
	}

	/* Reset statistics */
	memset(&stats, 0, sizeof(stats));
	stats.encode_time_min_ms = INT64_MAX;
	encode_time_total = 0;

	/* Reset recording counters */
	recording_frame_count = 0;
	current_file_index = 1;
	file_start_frame_count = 0;
	was_transferring = false;
	recording_start_time = (uint32_t)(k_uptime_get() / 1000);

	/* Generate session ID: always 14 digits */
	uint16_t year, month, day, hour, min, sec;
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

	LOG_INF("Session ID: %s", current_session_id);

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

	LOG_INF("Recording started");
	return 0;
}

int audio_stop_recording(void)
{
	int ret;
	uint32_t duration_sec;

	if (!recording_active) {
		return 0;
	}

	LOG_INF("Stopping recording");

	recording_active = false;

	/* Stop DMIC */
	ret = dmic_trigger(dmic_dev, DMIC_TRIGGER_STOP);
	if (ret < 0) {
		LOG_ERR("Failed to stop DMIC: %d", ret);
	}

	/* Close SD card file if open */
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

		/* NOTE: Recording and transfer are now separated - client initiates transfer via AT+DOWNLOAD */
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

	LOG_INF("Recording stopped: %u frames, %u bytes, %u sec",
		stats.frames_encoded, stats.total_bytes, duration_sec);

	return 0;
}

bool audio_is_recording(void)
{
	return recording_active;
}

int audio_set_bitrate(uint32_t bitrate)
{
	int ret;

	if (bitrate < 16000 || bitrate > 64000) {
		return -EINVAL;
	}

	current_bitrate = bitrate;

	/* Reinitialize encoder with new bitrate */
	ret = init_opus_encoder();
	if (ret < 0) {
		LOG_ERR("Failed to set bitrate: %d", ret);
		return ret;
	}

	LOG_INF("Bitrate set to %u bps", bitrate);
	return 0;
}

uint32_t audio_get_bitrate(void)
{
	return current_bitrate;
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
	speex_enabled = enable;
	g_config.noise_suppress = enable ? 1 : 0;
	LOG_INF("Noise suppression %s", enable ? "enabled" : "disabled");
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

/* Audio recording thread */
void audio_recording_thread(void *p1, void *p2, void *p3)
{
	int ret;
	void *buffer = NULL;
	uint32_t size;
	uint8_t opus_packet[AUDIO_MAX_PACKET_SIZE];

	LOG_INF("Audio recording thread started");

	while (true) {
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

		/* Update statistics */
		stats.frames_encoded++;
		stats.total_bytes += encoded_bytes;
		recording_frame_count++;

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

	/* Set bitrate */
	err = opus_encoder_ctl(opus_encoder, OPUS_SET_BITRATE(current_bitrate));
	if (err != OPUS_OK) {
		LOG_ERR("Failed to set bitrate: %d", err);
		return err;
	}

	/* Set complexity */
	err = opus_encoder_ctl(opus_encoder, OPUS_SET_COMPLEXITY(g_config.complexity));
	if (err != OPUS_OK) {
		LOG_ERR("Failed to set complexity: %d", err);
		return err;
	}

	/* Disable FEC */
	err = opus_encoder_ctl(opus_encoder, OPUS_SET_INBAND_FEC(0));
	if (err != OPUS_OK) {
		LOG_ERR("Failed to disable FEC: %d", err);
		return err;
	}

	LOG_INF("Opus encoder: %d Hz, %d ch, %d bps, complexity=%d",
		AUDIO_SAMPLE_RATE, opus_channels, current_bitrate, g_config.complexity);

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
	if (!recording_active) {
		return NULL;
	}

	return current_session_id;
}
