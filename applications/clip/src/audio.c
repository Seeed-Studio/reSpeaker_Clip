/*
 * Copyright (c) 2025 Seeed Technology Co., Ltd.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#include <zephyr/kernel.h>
#include <zephyr/device.h>
#include <zephyr/audio/dmic.h>
#include <zephyr/drivers/gpio.h>
#include <zephyr/drivers/regulator.h>
#include <zephyr/logging/log.h>
#include <zephyr/sys/byteorder.h>
#include <string.h>
#include <stdio.h>
#include <math.h>
#include <nrfx_pdm.h>
#include <cmsis_core.h>

#include <opus.h>
#include <opus_types.h>

#ifdef CONFIG_SPEEXDSP
#include <speex/speex_preprocess.h>
#endif

#include "audio.h"
#include "clip.h"
#include "config.h"
#include "storage.h"
#include "transfer.h"
#include "ble.h"
#include "display.h"

LOG_MODULE_REGISTER(audio, CONFIG_CLIP_LOG_LEVEL);

/* Memory slab for DMIC buffers */
K_MEM_SLAB_DEFINE_STATIC(audio_mem_slab, AUDIO_BLOCK_SIZE, 32, 4);

/* DMIC device */
static const struct device *const dmic_dev = DEVICE_DT_GET(DT_ALIAS(dmic0));
static const struct device *mic_regulator =
	DEVICE_DT_GET(DT_NODELABEL(npm1300_ldo1));

/* PDM_EN: P1.14 controls TXS0104E level shifter VCCB (mic signal path) */
static const struct gpio_dt_spec pdm_en_gpio = {
	.port = DEVICE_DT_GET(DT_NODELABEL(gpio1)),
	.pin = 14,
	.dt_flags = GPIO_OUTPUT | GPIO_ACTIVE_HIGH,
};

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
        .min_pdm_clk_freq = 1280000,
        .max_pdm_clk_freq = 1280000,
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
static enum audio_mode current_mode = AUDIO_MODE_MERGE;
static int opus_channels = 1;

/* Semaphore for blocking audio thread when not recording */
static K_SEM_DEFINE(audio_start_sem, 0, 1);

/* Mutex for protecting recording state */
static K_MUTEX_DEFINE(audio_state_mutex);

/* Stop request flag */
static volatile bool stop_requested = false;

/* Semaphore: audio thread signals when stop cleanup is done */
static struct k_sem stop_done_sem;

/* Pause state */
static volatile bool pause_requested = false;
static volatile bool is_paused = false;

/* Current session ID */
static char current_session_id[32] = {0};
static uint32_t recording_frame_count = 0;

/* Storage integration */
static struct storage_file current_storage_file = {0};
static uint32_t current_file_index = 1;
static uint32_t file_start_frame_count = 0;

/* False for RTC sessions: the pipeline runs but nothing is written to the
 * SD card (no session dir, no segment files, no session.json on stop). */
static bool session_persists = true;

/* Transfer state tracking for dynamic segment duration */
static bool was_transferring = false;

/* Audio energy level (0-10) for visualization */
static uint8_t audio_energy_level = 0;
static uint8_t audio_energy_history[13];  /* History for trend display */
static int audio_energy_history_index = 0;
static bool audio_energy_history_filled = false;
static K_MUTEX_DEFINE(audio_energy_mutex);

/* Statistics */
static struct audio_stats stats = {0};
static uint64_t encode_time_total_us = 0;
static uint64_t dsp_time_total_us = 0;

/* Hand-rolled AGC / high-pass filter state (MERGE mode). Reset on each
 * new recording to avoid stale gain from a loud prior session. */
static int32_t agc_hp_x1 = 0;
static int32_t agc_envelope = 0;
static int32_t agc_gain_q8 = 256;

/* CPU cycle counter helpers (DWT->CYCCNT at 128 MHz) */
#define CPU_FREQ_HZ 128000000
static inline uint32_t cyc_to_us(uint32_t cycles)
{
	return (uint32_t)((uint64_t)cycles * 1000000ULL / CPU_FREQ_HZ);
}
static inline uint32_t cyc_start(void) { return DWT->CYCCNT; }
static inline uint32_t cyc_end(uint32_t start) { return DWT->CYCCNT - start; }

/* Data callback */
static audio_data_callback_t data_callback = NULL;
static void *data_callback_user_data = NULL;

/* Audio recording thread */
K_THREAD_STACK_DEFINE(audio_thread_stack, CONFIG_CLIP_AUDIO_STACK_SIZE);
static struct k_thread audio_thread_data;
static k_tid_t audio_thread_id;

/* Opus encoder state */
static OpusEncoder *opus_encoder = NULL;

#ifdef CONFIG_SPEEXDSP
/* SpeexDSP preprocessor state */
static SpeexPreprocessState *speex_pp = NULL;
static bool speex_enabled = false;

/* Cached SpeexDSP parameters for reinit detection */
static struct {
    uint8_t noise_suppress;
    bool dereverb_enabled;
    bool initialized;
} dsp_params = {0};
#endif

/* Cached encoder parameters for reinit detection */
static struct {
    uint32_t bitrate;
    uint8_t complexity;
    int channels;
    bool initialized;
} encoder_params = {0};

/* Forward declarations */
static int init_opus_encoder(void);
static void cleanup_opus_encoder(void);
static bool encoder_params_changed(void);
#ifdef CONFIG_SPEEXDSP
static int init_speex_preprocessor(void);
static void cleanup_speex_preprocessor(void);
static bool dsp_params_changed(void);
#endif
static int16_t *process_pcm_frame(int16_t *stereo_input, int frame_size);
static int mic_power_on(void);
static int mic_power_off(void);
static int audio_start_recording_internal(enum audio_mode mode);
static int audio_stop_recording_internal(void);
static void calculate_energy_level(int16_t *pcm_data, int frame_size);
static void dmic_flush_initial(void);

/* Static Opus packet buffer (shared across encoding operations) */
static uint8_t opus_packet[AUDIO_MAX_PACKET_SIZE];

int audio_init(void)
{
    int ret;

    if (!device_is_ready(dmic_dev)) {
        LOG_ERR("dmic not ready");
        return -ENODEV;
    }

    /* Initialize audio parameters from loaded config */
    struct clip_context *c = clip_get_context();
    current_mode = AUDIO_MODE_MERGE;  /* Both modes use merge (L+R → mono) */

    /* Set channels */
    if (current_mode == AUDIO_MODE_STEREO) {
        opus_channels = 2;
    } else {
        opus_channels = 1;
    }

    /* Configure channel map */
    audio_cfg.channel.req_chan_map_lo = dmic_build_channel_map(0, 0, PDM_CHAN_LEFT);
    audio_cfg.channel.req_chan_map_lo |= dmic_build_channel_map(1, 0, PDM_CHAN_RIGHT);

    /* Configure DMIC */
    ret = dmic_configure(dmic_dev, &audio_cfg);
    if (ret < 0) {
        LOG_ERR("dmic_cfg: %d", ret);
        return ret;
    }

    /* Set microphone gain - +10dB for balanced near/far-field */
#ifdef NRF_PDM0_S
    nrf_pdm_gain_set(NRF_PDM0_S, 0x48, 0x48);
#else
    nrf_pdm_gain_set(NRF_PDM0_NS, 0x48, 0x48);
#endif

    /* Initialize stop-done semaphore */
    k_sem_init(&stop_done_sem, 0, 1);

    /* Start audio recording thread */
    audio_thread_id = k_thread_create(&audio_thread_data,
                      audio_thread_stack,
                      CONFIG_CLIP_AUDIO_STACK_SIZE,
                      audio_recording_thread,
                      NULL, NULL, NULL,
                      CONFIG_CLIP_AUDIO_THREAD_PRIORITY, 0, K_NO_WAIT);
    if (!audio_thread_id) {
        LOG_ERR("Failed to create audio thread");
        return -ENOMEM;
    }
    k_thread_name_set(&audio_thread_data, "audio_rec");

    LOG_INF("audio: pri=%d stk=%u",
        CONFIG_CLIP_AUDIO_THREAD_PRIORITY,
        CONFIG_CLIP_AUDIO_STACK_SIZE);

    return 0;
}

void audio_cleanup(void)
{
    audio_stop_recording();
}

/* Common start path for recording and RTC sessions. Recording persists
 * segments to the SD card; RTC delivers encoded frames through the data
 * callback only and never touches storage. */
static int audio_start_common(enum audio_mode mode, bool persists)
{
    struct clip_context *c = clip_get_context();
    uint16_t year;
    uint8_t month, day, hour, min, sec;
    int ret;

    /* Lock to protect session_id and state variables */
    k_mutex_lock(&audio_state_mutex, K_FOREVER);

    if (recording_active) {
        k_mutex_unlock(&audio_state_mutex);
        LOG_WRN("Recording already active");
        return -EBUSY;
    }

    session_persists = persists;

    /* Store mode for audio thread */
    current_mode = mode;
    if (current_mode == AUDIO_MODE_STEREO) {
        opus_channels = 2;
    } else {
        opus_channels = 1;
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
            "0%013u", uptime_sec);
        LOG_WRN("time unset, using uptime session id");
    }

    /* Reset counters */
    recording_frame_count = 0;
    stop_requested = false;
    k_sem_reset(&stop_done_sem);

    /* Wake up audio thread by giving semaphore */
    k_sem_give(&audio_start_sem);
    k_mutex_unlock(&audio_state_mutex);

    LOG_INF("rec start (mode=%d, %s)", mode, current_session_id);
    return 0;
}

int audio_start_recording(enum audio_mode mode)
{
    return audio_start_common(mode, true);
}

int audio_start_rtc(void)
{
    /* RTC: encoded frames go to the stream queue, never to the SD card */
    return audio_start_common(AUDIO_MODE_MERGE, false);
}

int audio_stop_recording(void)
{
    k_mutex_lock(&audio_state_mutex, K_FOREVER);

    if (!recording_active) {
        /* Recording not yet active, but start may be pending (semaphore given
         * but audio thread hasn't processed it yet). Set stop_requested so
         * the audio thread skips the pending start.
         */
        stop_requested = true;
        k_mutex_unlock(&audio_state_mutex);
        return 0;
    }

    /* Set stop request flag - audio thread will handle cleanup.
     * Pause polling loop checks stop_requested, so no semaphore needed.
     */
    stop_requested = true;

    k_mutex_unlock(&audio_state_mutex);
    LOG_INF("Recording stop requested");

    /* Wait for audio thread to finish cleanup (file close + sync on slow SD) */
    if (k_sem_take(&stop_done_sem, K_MSEC(5000)) != 0) {
        LOG_WRN("audio stop timed out (slow SD close?)");
        return -ETIMEDOUT;
    }

    return 0;
}

int audio_pause_recording(void)
{
    k_mutex_lock(&audio_state_mutex, K_FOREVER);

    if (!recording_active || is_paused) {
        k_mutex_unlock(&audio_state_mutex);
        return 0;
    }

    /* Set pause request flag */
    pause_requested = true;
    k_mutex_unlock(&audio_state_mutex);

    LOG_INF("Recording pause requested");
    return 0;
}

int audio_resume_recording(void)
{
    k_mutex_lock(&audio_state_mutex, K_FOREVER);

    if (!recording_active || !is_paused) {
        k_mutex_unlock(&audio_state_mutex);
        return 0;
    }

    /* Clear paused state - audio thread's polling loop will detect this */
    is_paused = false;
    k_mutex_unlock(&audio_state_mutex);

    LOG_INF("Recording resume requested");
    return 0;
}

bool audio_is_recording(void)
{
    k_mutex_lock(&audio_state_mutex, K_FOREVER);
    bool is_active = recording_active;
    k_mutex_unlock(&audio_state_mutex);

    return is_active;
}

bool audio_session_is_rtc(void)
{
    k_mutex_lock(&audio_state_mutex, K_FOREVER);
    bool is_rtc = recording_active && !session_persists;
    k_mutex_unlock(&audio_state_mutex);

    return is_rtc;
}

int audio_add_bookmark(void)
{
    uint32_t recording_sec;
    struct audio_stats stats;

    /* Check if recording is active */
    if (!audio_is_recording()) {
        return -EINVAL;
    }

    /* Get current statistics */
    if (audio_get_stats(&stats) != 0) {
        return -EIO;
    }

    /* Calculate recording time in seconds */
    recording_sec = stats.recording_time_ms / 1000;

    /* Add bookmark via storage module */
    return storage_add_bookmark(current_session_id, recording_sec);
}

int audio_get_stats(struct audio_stats *stats_out)
{
    if (!stats_out) {
        return -EINVAL;
    }

    /* Calculate average if recording stopped */
    if (!recording_active && stats.frames_encoded > 0) {
        stats.encode_time_avg_us = (uint32_t)(encode_time_total_us / stats.frames_encoded);
    }

    memcpy(stats_out, &stats, sizeof(stats));
    return 0;
}

void audio_register_data_callback(audio_data_callback_t callback, void *user_data)
{
    data_callback = callback;
    data_callback_user_data = user_data;
}

uint32_t audio_thread_stack_free(void)
{
    size_t unused = 0;

    if (audio_thread_id == NULL ||
        k_thread_stack_space_get(audio_thread_id, &unused) != 0) {
        return 0;
    }
    return (uint32_t)unused;
}

const char *audio_get_session_id(void)
{
    k_mutex_lock(&audio_state_mutex, K_FOREVER);

    /* Return session_id if it's set, even if recording not fully started yet
     * This allows AT+START to return session_id immediately */
    if (current_session_id[0] == '\0') {
        k_mutex_unlock(&audio_state_mutex);
        return NULL;
    }

    /* Copy to static buffer for thread safety */
    static char session_id_copy[STORAGE_SESSION_ID_LEN];
    strncpy(session_id_copy, current_session_id, sizeof(session_id_copy) - 1);
    session_id_copy[sizeof(session_id_copy) - 1] = '\0';

    k_mutex_unlock(&audio_state_mutex);
    return session_id_copy;
}

bool audio_is_paused(void)
{
    k_mutex_lock(&audio_state_mutex, K_FOREVER);
    bool paused = is_paused;
    k_mutex_unlock(&audio_state_mutex);

    return paused;
}

/* Internal recording initialization */
static int audio_start_recording_internal(enum audio_mode mode)
{
    int ret;
    struct clip_context *c = clip_get_context();

    /* Ensure DWT cycle counter is enabled for timing measurement */
    CoreDebug->DEMCR |= CoreDebug_DEMCR_TRCENA_Msk;
    DWT->CYCCNT = 0;
    DWT->CTRL |= DWT_CTRL_CYCCNTENA_Msk;

    /* Reset statistics */
    memset(&stats, 0, sizeof(stats));
    stats.encode_time_min_us = UINT32_MAX;
    encode_time_total_us = 0;
    dsp_time_total_us = 0;

    /* Reset hand-rolled AGC / high-pass filter state */
    agc_hp_x1 = 0;
    agc_envelope = 0;
    agc_gain_q8 = 256;

    /* Reset file index */
    current_file_index = 1;
    file_start_frame_count = 0;

    /* Boost CPU to 128MHz for encoding, before mic power-on.
     * The 10ms mic stabilization delay also serves as CPU frequency
     * settling time.
     */
    LOG_INF("Boosting CPU for recording");
    clip_cpu_boost_acquire();

    /* Power on microphone with delay for stabilization */
    ret = mic_power_on();
    if (ret < 0) {
        LOG_ERR("Failed to power on microphone: %d", ret);
        clip_cpu_boost_release();
        return ret;
    }

    /* Initialize Opus encoder (only if not initialized or params changed) */
    ret = init_opus_encoder();
    if (ret < 0) {
        LOG_ERR("Failed to init Opus encoder: %d", ret);
        mic_power_off();
        clip_cpu_boost_release();
        return ret;
    }

#ifdef CONFIG_SPEEXDSP
    /* Initialize/Reinitialize SpeexDSP - enhanced mode only */
    if (c->config.mode == MODE_ENHANCED && c->config.noise_suppress > 0) {
        speex_enabled = true;
        ret = init_speex_preprocessor();
        if (ret < 0) {
            LOG_WRN("SpeexDSP init failed: %d", ret);
            speex_enabled = false;
        }
    } else {
        /* STEREO mode or no noise suppression - cleanup DSP if exists */
        if (speex_enabled || speex_pp) {
            cleanup_speex_preprocessor();
            speex_enabled = false;
        }
    }
#endif

    /* Start DMIC */
    ret = dmic_trigger(dmic_dev, DMIC_TRIGGER_START);
    if (ret < 0) {
        LOG_ERR("Failed to start DMIC: %d", ret);
        mic_power_off();
        clip_cpu_boost_release();
        return ret;
    }

    /* Discard initial frames to eliminate mic power-up pop */
    dmic_flush_initial();

    /* Create storage session + first file — done AFTER mic/opus/dmic init
     * so a failure in those steps doesn't leak an orphan session. */
    if (session_persists) {
        uint8_t channels = (mode == AUDIO_MODE_STEREO) ? 2 : 1;
        const char *mode_str = (mode == AUDIO_MODE_STEREO) ? "stereo" : "mono";
        ret = storage_create_session(current_session_id, channels,
                                     AUDIO_SAMPLE_RATE, mode_str);
        if (ret != 0 && ret != -EEXIST) {
            LOG_WRN("Failed to create storage session: %d", ret);
        }

        ret = storage_create_file(&current_storage_file, current_session_id,
                                  current_file_index);
        if (ret != 0) {
            LOG_WRN("Failed to create storage file: %d", ret);
        } else {
            LOG_DBG("Recording to: %s", current_storage_file.filename);
        }
    } else {
        /* RTC: no on-card session/file */
        memset(&current_storage_file, 0, sizeof(current_storage_file));
    }

    recording_active = true;
    is_paused = false;

    /* Calculate actual bitrate for logging */
    uint32_t actual_bitrate = (current_mode == AUDIO_MODE_STEREO) ?
        CONFIG_CLIP_NORMAL_BITRATE * 2 : CONFIG_CLIP_ENHANCED_BITRATE;
    LOG_INF("rec: %s %ukbps %s",
        (current_mode == AUDIO_MODE_STEREO) ? "stereo" : "mono",
        actual_bitrate/1000, current_session_id);
    return 0;
}

/* Internal stop function */
static int audio_stop_recording_internal(void)
{
    int ret;
    uint32_t duration_sec;

    if (!recording_active) {
        return 0;
    }

    recording_active = false;
    is_paused = false;

    /* Stop DMIC */
    ret = dmic_trigger(dmic_dev, DMIC_TRIGGER_STOP);
    if (ret < 0) {
        LOG_ERR("Failed to stop DMIC: %d", ret);
    }

    /* Close storage file if open */
    if (current_storage_file.is_open) {
        ret = storage_close_file(&current_storage_file);
        if (ret != 0) {
            LOG_WRN("Failed to close storage file: %d", ret);
        }
    }

    /* Calculate average encode time */
    if (stats.frames_encoded > 0) {
        stats.encode_time_avg_us = (uint32_t)(encode_time_total_us / stats.frames_encoded);
    }

    /* Close storage session */
    if (session_persists) {
        duration_sec = stats.recording_time_ms / 1000;
        ret = storage_close_session(current_session_id, duration_sec, current_file_index);
        if (ret != 0) {
            LOG_WRN("Failed to close storage session: %d", ret);
        }
    }

    /* Restore default for the next session */
    session_persists = true;

    /* Sync time baseline so reboot doesn't lose accumulated uptime */
    config_sync_time();

    /* Power off microphone to save power */
    mic_power_off();

    LOG_INF("Recording stopped, releasing CPU boost");
    clip_cpu_boost_release();

    /* Note: Keep encoder and DSP initialized for next recording
     * They will be reinitialized only if parameters change */

    return 0;
}

/* Audio recording thread */
void audio_recording_thread(void *p1, void *p2, void *p3)
{
    int ret;
    void *buffer = NULL;
    uint32_t size;
    uint16_t year;
    uint8_t month, day, hour, min, sec;
    int dmic_timeout_count = 0;  /* For DMIC recovery */

    ARG_UNUSED(p1);
    ARG_UNUSED(p2);
    ARG_UNUSED(p3);

    while (true) {
        /* Wait for start signal (blocks here) */
        k_sem_take(&audio_start_sem, K_FOREVER);

        /* Check if stop was requested before we started */
        if (stop_requested) {
            stop_requested = false;
            continue;
        }

        /* Perform initialization in audio thread context */
        ret = audio_start_recording_internal(current_mode);
        if (ret < 0) {
            LOG_ERR("Failed to start recording: %d", ret);
            continue;
        }

        /* Recording loop - process audio until stop requested */
        while (!stop_requested) {
            /* Check for pause request */
            if (pause_requested) {
                pause_requested = false;

                /* Close current file */
                if (current_storage_file.is_open) {
                    ret = storage_close_file(&current_storage_file);
                    if (ret != 0) {
                        LOG_WRN("Failed to close file on pause: %d", ret);
                    }
                }

                /* Stop DMIC and mic power to save power */
                dmic_trigger(dmic_dev, DMIC_TRIGGER_STOP);
                mic_power_off();

                is_paused = true;
                LOG_INF("Recording paused at %u sec", (unsigned int)(stats.recording_time_ms / 1000));

                /* Wait for resume signal */
                while (is_paused && !stop_requested) {
                    k_sleep(K_MSEC(100));
                }

                /* Check if stop was requested while paused */
                if (stop_requested) {
                    break;
                }

                /* Resume: Create new file with incremented index */
                current_file_index++;
                ret = storage_create_file(&current_storage_file, current_session_id, current_file_index);
                if (ret != 0) {
                    LOG_ERR("resume file create %d", ret);
                    current_file_index--;
                    break;
                }

                file_start_frame_count = recording_frame_count;

                /* Power on mic and restart DMIC */
                mic_power_on();
                ret = dmic_trigger(dmic_dev, DMIC_TRIGGER_START);
                if (ret < 0) {
                    LOG_ERR("Failed to restart DMIC: %d", ret);
                    break;
                }

                /* Discard initial frames for DMIC settling */
                dmic_flush_initial();

                LOG_INF("Recording resumed: new file #%u", current_file_index);
                continue;
            }

            /* Read one audio block from DMIC.
             * Use a generous timeout to tolerate transient scheduling delays
             * caused by BLE activity (BT RX thread runs at higher priority).
             * With 32 buffers (640ms queue), the DMIC can absorb short gaps.
             */
            ret = dmic_read(dmic_dev, 0, &buffer, &size, 200);
            if (ret < 0) {
                LOG_WRN("dmic_read: err=%d consec=%d frames=%u",
                        ret, dmic_timeout_count + 1, stats.frames_encoded);
                if (ret == -EAGAIN) {
                    /* Timeout - track consecutive timeouts for recovery */
                    dmic_timeout_count++;

                    if (dmic_timeout_count >= 2) {
                        LOG_WRN("DMIC timeout, retrigger");
                        LOG_WRN("DSP=%uus enc=%uus (frm=%u)",
                                stats.frames_encoded > 0 ?
                                    (uint32_t)(dsp_time_total_us / stats.frames_encoded) : 0,
                                stats.frames_encoded > 0 ?
                                    (uint32_t)(encode_time_total_us / stats.frames_encoded) : 0,
                                stats.frames_encoded);
                        dmic_timeout_count = 0;

                        /* Try to recover DMIC */
                        dmic_trigger(dmic_dev, DMIC_TRIGGER_STOP);
                        k_sleep(K_MSEC(10));
                        ret = dmic_trigger(dmic_dev, DMIC_TRIGGER_START);
                        if (ret < 0) {
                            LOG_ERR("DMIC recovery failed: %d", ret);
                        } else {
                            dmic_flush_initial();
                            LOG_INF("DMIC recovered");
                        }
                    }
                    continue;
                }
                LOG_ERR("DMIC read error: %d", ret);
                stats.dropped_frames++;
                break;
            }

            /* Reset timeout counter on successful read */
            dmic_timeout_count = 0;

            /* Validate block size */
            if (size != AUDIO_BLOCK_SIZE) {
                LOG_WRN("Invalid block size: %u (expected %u)", size, AUDIO_BLOCK_SIZE);
                k_mem_slab_free(&audio_mem_slab, buffer);
                buffer = NULL;
                stats.dropped_frames++;
                continue;
            }

            /* Process PCM data according to mode (DSP: merge, denoise, dereverb) */
            uint32_t dsp_cyc = cyc_start();
            int16_t *pcm_data = process_pcm_frame((int16_t *)buffer, AUDIO_OPUS_FRAME_SIZE);
            uint32_t dsp_us = cyc_to_us(cyc_end(dsp_cyc));
            dsp_time_total_us += dsp_us;

            /* Check encoder state */
            if (!opus_encoder) {
                LOG_ERR("Opus encoder is NULL!");
                k_mem_slab_free(&audio_mem_slab, buffer);
                stats.dropped_frames++;
                continue;
            }

            /* Measure encode time with DWT cycle counter */
            uint32_t enc_cyc = cyc_start();

            /* Encode audio */
            opus_int32 encoded_bytes = opus_encode(
                opus_encoder,
                pcm_data,
                AUDIO_OPUS_FRAME_SIZE,
                opus_packet,
                AUDIO_MAX_PACKET_SIZE
            );

            /* Calculate encode time in microseconds */
            uint32_t encode_us = cyc_to_us(cyc_end(enc_cyc));

            /* Free buffer */
            k_mem_slab_free(&audio_mem_slab, buffer);
            buffer = NULL;

            if (encoded_bytes < 0) {
                LOG_ERR("Opus encode error: %d", encoded_bytes);
                stats.dropped_frames++;
                continue;
            }

            /* Update statistics */
            stats.frames_encoded++;
            stats.recording_time_ms = (uint64_t)stats.frames_encoded * AUDIO_FRAME_MS;
            stats.total_bytes += encoded_bytes;
            recording_frame_count++;

            /* Update encode time statistics */
            encode_time_total_us += encode_us;
            if (encode_us < stats.encode_time_min_us) {
                stats.encode_time_min_us = encode_us;
            }
            if (encode_us > stats.encode_time_max_us) {
                stats.encode_time_max_us = encode_us;
            }

            /* Print encode stats every 10 seconds (500 frames at 20ms/frame) */
            if (stats.frames_encoded % 500 == 0) {
                uint32_t avg_enc = (uint32_t)(encode_time_total_us / stats.frames_encoded);
                uint32_t avg_dsp = (uint32_t)(dsp_time_total_us / stats.frames_encoded);
                LOG_INF("enc: avg=%u min=%u max=%u dsp=%u (%u)",
                        avg_enc, stats.encode_time_min_us, stats.encode_time_max_us,
                        avg_dsp, stats.frames_encoded);
            }

            /* Deliver the encoded frame to the realtime consumer (RTC).
             * Runs in this top-priority thread: the callback must be O(1)
             * (queue push only, never block). */
            if (data_callback) {
                data_callback(opus_packet, (size_t)encoded_bytes,
                              data_callback_user_data);
            }

            /* Calculate energy level for visualization.
             * Skip when BLE vis not subscribed AND display is in REC_DOT
             * (no display animation needs the data). Always calculate when
             * BLE client is subscribed or display shows REC_WAVE.
             */
            if (ble_is_audio_vis_subscribed() ||
                display_get_state() == UI_STATE_REC_WAVE) {
                calculate_energy_level(pcm_data, AUDIO_OPUS_FRAME_SIZE);
            }

            /* Write encoded data to storage (with 2-byte length header) */
            if (current_storage_file.is_open) {
                ret = storage_write_frame(&current_storage_file, opus_packet, encoded_bytes);
                if (ret != 0) {
                    LOG_ERR("Storage write error (card full?): %d", ret);
                    storage_close_file(&current_storage_file);
                    memset(&current_storage_file, 0, sizeof(current_storage_file));
                    /* Card full: stop recording cleanly + show on screen */
                    stop_requested = true;
                    display_post_error("Storage Full");
                    ble_notify_event("storage", "full");
                }
            }

            /* Check if we need to create a new segment file
             * Use different segment durations based on transfer state:
             * - When transferring: shorter segments (CLIP_AUDIO_SEGMENT_DURATION_SYNC)
             * - When not transferring: longer segments (CLIP_AUDIO_SEGMENT_DURATION_NO_SYNC)
             * Segment management applies only to SD-persisted sessions; RTC
             * sessions have no files to slice.
             */
            if (session_persists) {
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
                        goto create_new_segment;
                    }
                }

                /* Update transfer state tracking */
                was_transferring = is_transferring;

                /* Regular segment check based on current segment duration */
                if (recording_frame_count > 1 && (recording_frame_count - file_start_frame_count) >= frames_per_file) {
create_new_segment:
                    /* Close current file */
                    if (current_storage_file.is_open) {
                        uint32_t segment_frames = recording_frame_count - file_start_frame_count;
                        uint32_t segment_bytes = current_storage_file.bytes_written;

                        ret = storage_close_file(&current_storage_file);
                        if (ret != 0) {
                            LOG_WRN("Failed to close segment file: %d", ret);
                        }

                        LOG_INF("seg #%u: %u frm %uB %us",
                                current_file_index, segment_frames, segment_bytes,
                                segment_duration_sec);
                    }

                    /* Create new file */
                    current_file_index++;
                    ret = storage_create_file(&current_storage_file, current_session_id, current_file_index);
                    if (ret != 0) {
                        LOG_ERR("Failed to create new segment file: %d", ret);
                        current_file_index--;
                        /* Continue recording without storage */
                    } else {
                        file_start_frame_count = recording_frame_count;
                    }
                }
            }

            k_yield();
        }

        /* Perform cleanup in audio thread context */
        audio_stop_recording_internal();
        stop_requested = false;
        pause_requested = false;

        /* Signal that stop is complete */
        k_sem_give(&stop_done_sem);

        LOG_INF("rec done: %u frm %us %uKB",
            stats.frames_encoded,
            (unsigned int)(stats.recording_time_ms / 1000),
            (unsigned int)(stats.total_bytes / 1024));
    }
}

/* Internal functions */
static bool encoder_params_changed(void)
{
    /* Calculate current parameters based on mode */
    uint32_t actual_bitrate = (current_mode == AUDIO_MODE_STEREO) ?
        CONFIG_CLIP_NORMAL_BITRATE * 2 : CONFIG_CLIP_ENHANCED_BITRATE;
    uint8_t effective_complexity = (current_mode == AUDIO_MODE_STEREO) ?
        CONFIG_CLIP_NORMAL_COMPLEXITY : CONFIG_CLIP_ENHANCED_COMPLEXITY;

    /* Check if parameters changed */
    if (!encoder_params.initialized) {
        return true;
    }

    if (encoder_params.bitrate != actual_bitrate ||
        encoder_params.complexity != effective_complexity ||
        encoder_params.channels != opus_channels) {
        return true;
    }

    return false;
}

static int init_opus_encoder(void)
{
    int err;
    struct clip_context *c = clip_get_context();

    /* Calculate current parameters based on mode */
    uint32_t actual_bitrate = (current_mode == AUDIO_MODE_STEREO) ?
        CONFIG_CLIP_NORMAL_BITRATE * 2 : CONFIG_CLIP_ENHANCED_BITRATE;
    uint8_t effective_complexity = (current_mode == AUDIO_MODE_STEREO) ?
        CONFIG_CLIP_NORMAL_COMPLEXITY : CONFIG_CLIP_ENHANCED_COMPLEXITY;

    /* Check if reinitialization is needed */
    if (opus_encoder && !encoder_params_changed()) {
        /* Parameters unchanged, no need to reinit */
        return 0;
    }

    /* Destroy old encoder if exists */
    if (opus_encoder) {
        cleanup_opus_encoder();
    }

    /* Create Opus encoder.
     * AUDIO mode preserves high-frequency detail (fricatives: zhi/chi/shi)
     * better than VOIP mode for STT transcription accuracy.
     */
    opus_encoder = opus_encoder_create(AUDIO_SAMPLE_RATE, opus_channels,
                       OPUS_APPLICATION_AUDIO, &err);
    if (!opus_encoder) {
        LOG_ERR("Failed to create Opus encoder: %d", err);
        return err;
    }

    /* Set bitrate */
    opus_encoder_ctl(opus_encoder, OPUS_SET_BITRATE((opus_int32)actual_bitrate));

    /* Enable VBR with unconstrained quality */
    opus_encoder_ctl(opus_encoder, OPUS_SET_VBR(1));
    opus_encoder_ctl(opus_encoder, OPUS_SET_VBR_CONSTRAINT(0));

    /* Set complexity from Kconfig (mode-specific) */
    err = opus_encoder_ctl(opus_encoder, OPUS_SET_COMPLEXITY(effective_complexity));
    if (err != OPUS_OK) {
        LOG_ERR("Failed to set complexity: %d", err);
        return err;
    }

    /* Voice-optimized signal */
    opus_encoder_ctl(opus_encoder, OPUS_SET_SIGNAL(OPUS_SIGNAL_VOICE));

    /* Input sample depth */
    opus_encoder_ctl(opus_encoder, OPUS_SET_LSB_DEPTH(16));

    /* Disable DTX, FEC, packet loss */
    opus_encoder_ctl(opus_encoder, OPUS_SET_DTX(0));
    opus_encoder_ctl(opus_encoder, OPUS_SET_INBAND_FEC(0));
    opus_encoder_ctl(opus_encoder, OPUS_SET_PACKET_LOSS_PERC(0));
    

    /* Update cached parameters */
    encoder_params.bitrate = actual_bitrate;
    encoder_params.complexity = effective_complexity;
    encoder_params.channels = opus_channels;
    encoder_params.initialized = true;

    LOG_INF("opus: %dch %ukbps c=%u %s",
        opus_channels, actual_bitrate / 1000, effective_complexity,
        (current_mode == AUDIO_MODE_STEREO) ? "stereo" : "mono");

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
static bool dsp_params_changed(void)
{
    struct clip_context *c = clip_get_context();

    if (!dsp_params.initialized) {
        return true;
    }

    if (dsp_params.noise_suppress != c->config.noise_suppress ||
        dsp_params.dereverb_enabled != c->config.dereverb_enabled) {
        return true;
    }

    return false;
}

static int init_speex_preprocessor(void)
{
    struct clip_context *c = clip_get_context();

    /* Check if reinitialization is needed */
    if (speex_pp && !dsp_params_changed()) {
        /* Parameters unchanged, no need to reinit */
        return 0;
    }

    /* Destroy old preprocessor if exists */
    if (speex_pp) {
        cleanup_speex_preprocessor();
    }

    /* Create preprocessor state */
    speex_pp = speex_preprocess_state_init(AUDIO_OPUS_FRAME_SIZE, AUDIO_SAMPLE_RATE);
    if (!speex_pp) {
        LOG_ERR("Failed to create SpeexDSP preprocessor");
        return -ENOMEM;
    }

    /* Noise suppression (Kconfig) */
    int denoise = CONFIG_CLIP_DEFAULT_NOISE;
    speex_preprocess_ctl(speex_pp, SPEEX_PREPROCESS_SET_NOISE_SUPPRESS, &denoise);

    /* Dereverberation (Kconfig) */
    int dereverb = IS_ENABLED(CONFIG_CLIP_DEFAULT_DEREVERB) ? 1 : 0;
    speex_preprocess_ctl(speex_pp, SPEEX_PREPROCESS_SET_DEREVERB, &dereverb);

    /* Dereverberation - moderate settings for far-field pickup.
     * Level 40 / Decay 30: reduces room reflections without over-processing.
     */
    int dereverb_level = 40;
    speex_preprocess_ctl(speex_pp, SPEEX_PREPROCESS_SET_DEREVERB_LEVEL, &dereverb_level);

    int dereverb_decay = 30;
    speex_preprocess_ctl(speex_pp, SPEEX_PREPROCESS_SET_DEREVERB_DECAY, &dereverb_decay);

    /* AGC is implemented as a lightweight integer AGC in process_pcm_frame().
     * SpeexDSP AGC is not available (FIXED_POINT mode) and would be too slow
     * even with FPU enabled (~15ms/frame for float FFT).
     */

    dsp_params.initialized = true;

    LOG_INF("dsp: noise=%ddB drv=%d agc=integer",
            CONFIG_CLIP_DEFAULT_NOISE,
            IS_ENABLED(CONFIG_CLIP_DEFAULT_DEREVERB) ? 1 : 0);

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

    if (current_mode == AUDIO_MODE_STEREO) {
        /* STEREO mode: return original stereo data (no DSP) */
        return stereo_input;

    } else {  /* AUDIO_MODE_MERGE */
        /* Enhanced mode: dual-mic delay-aligned merge + SpeexDSP + integer AGC.
         *
         * Pipeline:
         * 1. Delay-aligned merge: cross-correlation to find ITD, align L/R
         * 2. SpeexDSP: noise suppression + dereverb (fixed-point, fast)
         * 3. Integer AGC: lightweight gain control (pure integer, ~50us)
         * 4. Soft limiter: safety net for peaks
         *
         * Mic spacing = 2.85cm → max ITD ≈ 84μs ≈ 1.3 samples at 16kHz.
         * Delay alignment prevents comb filtering from phase offset.
         */

        /* Cross-correlation for delay estimation (lags -1, 0, +1).
         * Only need 3 taps since max ITD is ~1 sample.
         * Use a subset of the frame for speed (first 80 samples = 5ms).
         */
        int32_t corr_m1 = 0;  /* lag -1: right leads by 1 sample */
        int32_t corr_0  = 0;  /* lag  0: no delay */
        int32_t corr_p1 = 0;  /* lag +1: left leads by 1 sample */

        int corr_len = frame_size > 80 ? 80 : frame_size;
        for (int i = 1; i < corr_len - 1; i++) {
            int32_t l = stereo_input[i * 2];
            int32_t r = stereo_input[i * 2 + 1];
            int32_t r_prev = stereo_input[(i - 1) * 2 + 1];
            int32_t r_next = stereo_input[(i + 1) * 2 + 1];

            corr_m1 += l * r_next;
            corr_0  += l * r;
            corr_p1 += l * r_prev;
        }

        int best_lag = 0;
        int32_t best_corr = corr_0;
        if (corr_m1 > best_corr) { best_corr = corr_m1; best_lag = -1; }
        if (corr_p1 > best_corr) { best_corr = corr_p1; best_lag = 1; }

        /* Merge with delay alignment */
        for (int i = 0; i < frame_size; i++) {
            int32_t left = stereo_input[i * 2];
            int32_t ri = i - best_lag;
            int32_t right;
            if (ri < 0) {
                right = stereo_input[1];
            } else if (ri >= frame_size) {
                right = stereo_input[(frame_size - 1) * 2 + 1];
            } else {
                right = stereo_input[ri * 2 + 1];
            }
            int32_t avg = (left + right + 1) >> 1;
            if (avg > 32767) avg = 32767;
            if (avg < -32768) avg = -32768;
            processed_buffer[i] = (int16_t)avg;
        }

#ifdef CONFIG_SPEEXDSP
        /* First-order high-pass filter (fc≈100Hz at 16kHz) */
        {
            for (int i = 0; i < frame_size; i++) {
                int32_t x = processed_buffer[i];
                processed_buffer[i] = (int16_t)(x - agc_hp_x1);
                agc_hp_x1 += (x - agc_hp_x1) * 39 >> 10;
            }
        }

        if (speex_enabled && speex_pp) {
            speex_preprocess_run(speex_pp, processed_buffer);
        }

        /* Integer AGC: standard compressor model + makeup gain.
         *
         * Classic audio AGC with three stages:
         * 1. Envelope detector: peak tracking with fast attack / slow release
         * 2. Gain computer: desired_gain = target / envelope
         * 3. Gain smoother: attack (loud→quiet) faster than release (quiet→loud)
         * 4. Makeup gain: overall volume boost after AGC
         *
         * Uses arm_absmax_q15() for fast peak detection (CMSIS-DSP).
         */
        {
            /* AGC state is file-scope (reset on each new recording) */

            /* Step 1: Envelope detector - find peak in frame */
            int32_t peak = 0;
            for (int i = 0; i < frame_size; i++) {
                int32_t s = processed_buffer[i];
                s = s > 0 ? s : -s;
                if (s > peak) peak = s;
            }

            /* Ballistics: slower attack to reduce pop (tau≈30ms), slow release (tau≈300ms) */
            if (peak > agc_envelope) {
                agc_envelope += (peak - agc_envelope) * 3 >> 2;
            } else {
                agc_envelope = agc_envelope - (agc_envelope >> 4);
                if (agc_envelope < peak) agc_envelope = peak;
            }

            /* Step 2: Gain computer.
             * Target 6000 ≈ -14.7dBFS: lower target reduces pop from sudden gain jumps.
             */
            int32_t target_level = 6000;
            int32_t noise_gate = 200;

            int32_t desired_q8;
            if (agc_envelope > noise_gate) {
                desired_q8 = (target_level << 8) / agc_envelope;
                if (desired_q8 > 4096) desired_q8 = 4096;  /* +24dB max for far-field */
                if (desired_q8 < 64) desired_q8 = 64;      /* -12dB min */
            } else {
                desired_q8 = 256;
            }

            /* Step 3: Gain smoother — slower transitions to reduce pop */
            int32_t diff = desired_q8 - agc_gain_q8;
            if (diff < 0) {
                agc_gain_q8 += diff >> 2;   /* Attack: ~4 frames */
            } else {
                agc_gain_q8 += diff >> 8;   /* Release: ~256 frames */
            }

            /* Step 4: Apply gain (no separate makeup gain).
             * AGC already targets 18000, so output is near that level.
             * Speech peaks can exceed target (crest factor ~6-12dB),
             * handled by the soft limiter in the next stage.
             */
            for (int i = 0; i < frame_size; i++) {
                int32_t s = ((int32_t)processed_buffer[i] * agc_gain_q8) >> 8;
                if (s > 32767) s = 32767;
                if (s < -32768) s = -32768;
                processed_buffer[i] = (int16_t)s;
            }
        }

        /* Soft limiter: safety net for AGC + makeup gain overshoot.
         * Knee at 26000 (~-2.0dBFS), hard limit at 31000 (~-0.5dBFS).
         */
        for (int i = 0; i < frame_size; i++) {
            int32_t s = processed_buffer[i];
            int32_t abs_s = s > 0 ? s : -s;

            if (abs_s > 26000) {
                int32_t over = abs_s - 26000;
                int32_t range = 32768 - 26000;
                int32_t headroom = 31000 - 26000;
                int32_t compressed = 26000 + headroom - (headroom * (range - over) * (range - over)) / (range * range);

                if (s > 0) {
                    processed_buffer[i] = (int16_t)(compressed > 31000 ? 31000 : compressed);
                } else {
                    processed_buffer[i] = (int16_t)(-(compressed > 31000 ? 31000 : compressed));
                }
            }
        }
#endif

        return processed_buffer;
    }
}

static int mic_power_on(void)
{
    /* Enable PDM level shifter (TXS0104E VCCB) */
    if (device_is_ready(pdm_en_gpio.port)) {
        gpio_pin_configure_dt(&pdm_en_gpio, GPIO_OUTPUT_HIGH);
    }
    /* Enable mic 1.8V via NPM1300 LDO1 */
    if (mic_regulator) {
        int ret = regulator_enable(mic_regulator);
        if (ret) {
            LOG_WRN("Mic regulator enable failed: %d", ret);
            return ret;
        }
    }
    return 0;
}

static int mic_power_off(void)
{
    /* Disable mic 1.8V via NPM1300 LDO1 */
    if (mic_regulator) {
        int ret = regulator_disable(mic_regulator);
        if (ret) {
            LOG_WRN("Mic regulator disable failed: %d", ret);
            return ret;
        }
    }
    /* Disable PDM level shifter */
    if (device_is_ready(pdm_en_gpio.port)) {
        gpio_pin_set_dt(&pdm_en_gpio, 0);
    }
    return 0;
}

/* Flush initial DMIC frames to discard mic power-up transients */
#define DMIC_FLUSH_FRAMES CONFIG_CLIP_AUDIO_DMIC_FLUSH_FRAMES

static void dmic_flush_initial(void)
{
    void *buf;
    uint32_t sz;

    for (int i = 0; i < DMIC_FLUSH_FRAMES; i++) {
        if (dmic_read(dmic_dev, 0, &buf, &sz, AUDIO_FRAME_MS * 2) == 0) {
            k_mem_slab_free(&audio_mem_slab, buf);
        }
    }
}

/* ========================================
 * Audio Visualization
 * ======================================== */

/**
 * @brief Calculate energy level from PCM data
 *
 * Calculates the RMS energy of the entire audio frame and maps it to 0-10 range.
 * Sends audio visualization data via BLE every ~200ms.
 *
 * @param pcm_data PCM audio data (mono or stereo interleaved)
 * @param frame_size Number of samples in pcm_data
 */
static void calculate_energy_level(int16_t *pcm_data, int frame_size)
{
    int64_t sum_squares = 0;

    /* Calculate RMS energy for the entire frame */
    for (int i = 0; i < frame_size; i++) {
        int16_t sample;

        /* Handle stereo vs mono */
        if (current_mode == AUDIO_MODE_STEREO) {
            /* Average of L+R channels */
            int16_t left = pcm_data[i * 2];
            int16_t right = pcm_data[i * 2 + 1];
            sample = (left + right) / 2;
        } else {
            /* Mono or merged - already processed */
            sample = pcm_data[i];
        }

        sum_squares += (int64_t)sample * sample;
    }

    /* Calculate RMS */
    int32_t rms = (int32_t)sqrt((float)sum_squares / frame_size);

    /* Map RMS to 0-10 range using logarithmic scale
     * Adjusted for microphone noise floor (~300-400 RMS)
     * - rms < 256: level 0 (below noise floor)
     * - rms 256-511: level 1 (noise floor)
     * - rms 512-1023: level 2 (quiet speech)
     * - rms 1024-2047: level 3 (normal speech)
     * - rms 2048-4095: level 4 (loud speech)
     * - rms 4096-8191: level 5 (very loud)
     * - rms 8192-16383: level 6
     * - rms 16384-20479: level 7
     * - rms 20480-24575: level 8
     * - rms 24576-28671: level 9
     * - rms >= 28672: level 10  (RMS of int16 samples maxes at ~32767)
     */
    uint8_t new_level;
    if (rms < 256) {
        new_level = 0;
    } else if (rms < 512) {
        new_level = 1;
    } else if (rms < 1024) {
        new_level = 2;
    } else if (rms < 2048) {
        new_level = 3;
    } else if (rms < 4096) {
        new_level = 4;
    } else if (rms < 8192) {
        new_level = 5;
    } else if (rms < 16384) {
        new_level = 6;
    } else if (rms < 20480) {
        new_level = 7;
    } else if (rms < 24576) {
        new_level = 8;
    } else if (rms < 28672) {
        new_level = 9;
    } else {
        new_level = 10;
    }

    /* Update shared data with mutex protection */
    k_mutex_lock(&audio_energy_mutex, K_FOREVER);
    audio_energy_level = new_level;

    /* Update energy history for trend display */
    audio_energy_history[audio_energy_history_index] = new_level;
    audio_energy_history_index = (audio_energy_history_index + 1) % 13;
    if (audio_energy_history_index == 0) {
        audio_energy_history_filled = true;
    }

    k_mutex_unlock(&audio_energy_mutex);

    /* Send audio visualization data via BLE (every ~200ms)
     * Pack 13 values (4 bits each) into 7 bytes (oldest to newest)
     * Byte format: [val0:val1] [val2:val3] [val4:val5] [val6:val7]
     *              [val8:val9] [val10:val11] [val12:0x0] */
    static int64_t last_vis_send = 0;
    int64_t now = k_uptime_get();
    if (now - last_vis_send >= 200) {
        uint8_t history_copy[13];
        uint8_t packed[7];

        /* Copy history in order: oldest to newest */
        k_mutex_lock(&audio_energy_mutex, K_FOREVER);
        if (audio_energy_history_filled) {
            /* History array has wrapped, copy from current index */
            int idx = 0;
            for (int i = 0; i < 13; i++) {
                history_copy[idx++] = audio_energy_history[(audio_energy_history_index + i) % 13];
            }
        } else {
            /* Not filled yet, copy from start */
            memcpy(history_copy, audio_energy_history, audio_energy_history_index);
            /* Fill remaining with current value */
            for (int i = audio_energy_history_index; i < 13; i++) {
                history_copy[i] = new_level;
            }
        }
        k_mutex_unlock(&audio_energy_mutex);

        /* Pack 13 values (4 bits each) into 7 bytes */
        for (int i = 0; i < 6; i++) {
            packed[i] = (history_copy[i * 2] & 0x0F) | ((history_copy[i * 2 + 1] & 0x0F) << 4);
        }
        packed[6] = history_copy[12] & 0x0F;  /* Last value in low nibble */

        extern int ble_send_audio_vis(const uint8_t *data, uint16_t len);
        ble_send_audio_vis(packed, 7);
        last_vis_send = now;
    }
}

int audio_get_energy_level(void)
{
    int level;
    k_mutex_lock(&audio_energy_mutex, K_FOREVER);
    level = audio_energy_level;
    k_mutex_unlock(&audio_energy_mutex);
    return level;
}
