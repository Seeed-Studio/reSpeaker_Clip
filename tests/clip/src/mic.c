/*
 * Microphone module with WAV recording to SD card
 *
 * Commands:
 *   mic capture [time_sec]     - Capture and print sample stats
 *   mic record [time_sec]      - Record WAV file to SD card
 *   mic power on/off           - Control mic power
 */

#include <zephyr/kernel.h>
#include <zephyr/device.h>
#include <zephyr/drivers/gpio.h>
#include <zephyr/drivers/regulator.h>
#include <zephyr/audio/dmic.h>
#include <zephyr/fs/fs.h>
#include <zephyr/shell/shell.h>
#include <zephyr/sys/util.h>
#include <zephyr/logging/log.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "mic.h"
#include "sdcard.h"

LOG_MODULE_REGISTER(mic, LOG_LEVEL_INF);

#define SAMPLE_RATE_HZ 16000
#define SAMPLE_BITS 16
#define CHANNEL_COUNT 2
#define TIMEOUT_MS 500
#define CAPTURE_MS 100
#define BLOCK_SIZE (((SAMPLE_BITS / 8) * (SAMPLE_RATE_HZ * CAPTURE_MS)) / 1000) * CHANNEL_COUNT
#define BLOCK_COUNT 4

static const struct device *const dmic = DEVICE_DT_GET(DT_ALIAS(dmic0));

/* Mic 1.8V supply = NPM1300 LDO1. Off by default (no regulator-boot-on in DTS),
 * so it must be enabled here — mirroring applications/clip audio.c. */
static const struct device *const mic_ldo = DEVICE_DT_GET(DT_NODELABEL(npm1300_ldo1));

/* PDM_EN: P1.14 drives the TXS0104E level-shifter VCCB (PDM signal path). */
static const struct gpio_dt_spec pdm_en_gpio = {
	.port = DEVICE_DT_GET(DT_NODELABEL(gpio1)),
	.pin = 14,
	.dt_flags = GPIO_OUTPUT | GPIO_ACTIVE_HIGH,
};

K_MEM_SLAB_DEFINE_STATIC(mem_slab, BLOCK_SIZE, BLOCK_COUNT, 4);

static struct pcm_stream_cfg stream = {
	.pcm_rate = SAMPLE_RATE_HZ,
	.pcm_width = SAMPLE_BITS,
	.block_size = BLOCK_SIZE,
	.mem_slab = &mem_slab,
};

static struct dmic_cfg cfg = {
	.io =
		{
			.min_pdm_clk_freq = 1000000,
			.max_pdm_clk_freq = 3500000,
			.min_pdm_clk_dc = 40,
			.max_pdm_clk_dc = 60,
		},
	.streams = &stream,
	.channel =
		{
			.req_num_streams = 1,
			.req_num_chan = CHANNEL_COUNT,
		},
};

static bool initialized;
static uint16_t recording_counter;

/* WAV file header (44 bytes) */
struct wav_header {
	uint8_t  riff[4];         /* "RIFF" */
	uint32_t file_size;       /* File size - 8 */
	uint8_t  wave[4];         /* "WAVE" */
	uint8_t  fmt[4];         /* "fmt " */
	uint32_t fmt_size;       /* 16 for PCM */
	uint16_t audio_format;   /* 1 = PCM */
	uint16_t num_channels;
	uint32_t sample_rate;
	uint32_t byte_rate;      /* sample_rate * num_channels * bits_per_sample/8 */
	uint16_t block_align;    /* num_channels * bits_per_sample/8 */
	uint16_t bits_per_sample;
	uint8_t  data[4];        /* "data" */
	uint32_t data_size;      /* num_samples * num_channels * bits_per_sample/8 */
};

static void wav_header_init(struct wav_header *hdr, uint16_t channels,
			    uint32_t sample_rate, uint16_t bits_per_sample,
			    uint32_t data_size)
{
	memcpy(hdr->riff, "RIFF", 4);
	memcpy(hdr->wave, "WAVE", 4);
	memcpy(hdr->fmt, "fmt ", 4);
	memcpy(hdr->data, "data", 4);

	hdr->fmt_size = 16;
	hdr->audio_format = 1;
	hdr->num_channels = channels;
	hdr->sample_rate = sample_rate;
	hdr->bits_per_sample = bits_per_sample;
	hdr->block_align = channels * bits_per_sample / 8;
	hdr->byte_rate = sample_rate * hdr->block_align;
	hdr->data_size = data_size;
	hdr->file_size = data_size + 36;
}

static void wav_header_write(struct fs_file_t *file, uint16_t channels,
			     uint32_t sample_rate, uint16_t bits_per_sample,
			     uint32_t data_size)
{
	struct wav_header hdr;

	wav_header_init(&hdr, channels, sample_rate, bits_per_sample, data_size);
	fs_seek(file, 0, SEEK_SET);
	fs_write(file, &hdr, sizeof(hdr));
}

/* Record WAV file to SD card */
static int cmd_mic_record(const struct shell *sh, size_t argc, char **argv)
{
	int ret, time = 3;
	char filepath[64];
	struct fs_file_t file;
	uint32_t total_data_size = 0;
	uint32_t start_time, end_time;

	if (argc > 1) {
		time = strtol(argv[1], NULL, 10);
		if (time <= 0 || time > 300) {
			shell_error(sh, "Invalid time (1-300 seconds)");
			return -EINVAL;
		}
	}

	if (!initialized) {
		shell_error(sh, "Microphone not initialized");
		return -EPERM;
	}

	if (!sdcard_is_mounted()) {
		shell_error(sh, "SD card not mounted. Use 'sd mount' first");
		return -ENODEV;
	}

	/* Generate filename */
	recording_counter++;
	snprintf(filepath, sizeof(filepath), "/SD:/REC%04u.WAV", recording_counter);

	shell_print(sh, "Recording %d sec to %s ...", time, filepath);

	/* Create file and write placeholder header */
	fs_file_t_init(&file);
	ret = fs_open(&file, filepath, FS_O_CREATE | FS_O_WRITE);
	if (ret != 0) {
		shell_error(sh, "Failed to create file: %d", ret);
		return ret;
	}

	/* Write placeholder header (will be updated at end) */
	struct wav_header hdr;
	wav_header_init(&hdr, CHANNEL_COUNT, SAMPLE_RATE_HZ, SAMPLE_BITS, 0);
	fs_write(&file, &hdr, sizeof(hdr));

	/* Power on mic */
	mic_power_on();

	ret = dmic_configure(dmic, &cfg);
	if (ret < 0) {
		shell_error(sh, "DMIC configure failed: %d", ret);
		fs_close(&file);
		mic_power_off();
		return ret;
	}

	start_time = (uint32_t)k_uptime_get_32();
	int blocks_target = time * (1000 / CAPTURE_MS);

	for (int i = 0; i < blocks_target; i++) {
		void *buffer = NULL;
		uint32_t size;

		ret = dmic_trigger(dmic, DMIC_TRIGGER_START);
		if (ret < 0) {
			shell_error(sh, "START failed: %d", ret);
			break;
		}

		ret = dmic_read(dmic, 0, &buffer, &size, TIMEOUT_MS);
		if (ret < 0) {
			dmic_trigger(dmic, DMIC_TRIGGER_STOP);
			break;
		}

		/* Write PCM data to file */
		fs_write(&file, buffer, size);
		total_data_size += size;

		k_mem_slab_free(&mem_slab, buffer);
		dmic_trigger(dmic, DMIC_TRIGGER_STOP);

		/* Progress every second */
		if ((i + 1) % (1000 / CAPTURE_MS) == 0) {
			uint32_t elapsed = ((uint32_t)k_uptime_get_32() - start_time) / 1000;
			shell_print(sh, "  %u/%u sec (%u KB)",
				    elapsed, (uint32_t)time,
				    total_data_size / 1024);
		}
	}

	end_time = (uint32_t)k_uptime_get_32();

	/* Update WAV header with actual data size */
	wav_header_write(&file, CHANNEL_COUNT, SAMPLE_RATE_HZ, SAMPLE_BITS, total_data_size);
	fs_close(&file);

	mic_power_off();

	uint32_t elapsed_ms = end_time - start_time;
	uint32_t file_kb = (total_data_size + sizeof(hdr)) / 1024;

	shell_print(sh, "Recording complete:");
	shell_print(sh, "  File: %s (%u KB)", filepath, file_kb);
	shell_print(sh, "  Duration: %u ms", elapsed_ms);
	shell_print(sh, "  Channels: %d, Rate: %d Hz, Bits: %d",
		    CHANNEL_COUNT, SAMPLE_RATE_HZ, SAMPLE_BITS);
	shell_print(sh, "  Use 'usb msc on' to access via USB");

	return 0;
}

/* Capture and print sample stats (original behavior) */
static int cmd_mic_capture(const struct shell *sh, size_t argc, char **argv)
{
	int ret, time = 1;
	void *buffer = NULL;
	uint32_t size;

	if (argc > 1) {
		char *endptr;
		time = strtol(argv[1], &endptr, 10);
		if (*endptr != '\0' || time <= 0) {
			shell_error(sh, "Invalid time argument");
			return -EINVAL;
		}
		time *= (1000 / CAPTURE_MS);
	}

	if (!initialized) {
		shell_error(sh, "Microphone not initialized");
		return -EPERM;
	}

	mic_power_on();

	shell_print(sh, "S");
	ret = dmic_configure(dmic, &cfg);
	if (ret < 0) {
		shell_error(sh, "Failed to configure DMIC(%d)", ret);
		goto cleanup;
	}

	for (int i = 0; i < time; i++) {
		ret = dmic_trigger(dmic, DMIC_TRIGGER_START);
		if (ret < 0) {
			shell_error(sh, "START trigger failed (%d)", ret);
			goto cleanup;
		}

		ret = dmic_read(dmic, 0, &buffer, &size, TIMEOUT_MS);
		if (ret < 0) {
			shell_error(sh, "DMIC read failed (%d)", ret);
			dmic_trigger(dmic, DMIC_TRIGGER_STOP);
			goto cleanup;
		}

		int16_t *samples = (int16_t *)buffer;
		uint32_t num_samples = size / sizeof(int16_t);
		int32_t sum = 0;
		int16_t min = 0, max = 0;

		for (uint32_t j = 0; j < num_samples; j++) {
			sum += samples[j];
			if (j == 0 || samples[j] < min) min = samples[j];
			if (j == 0 || samples[j] > max) max = samples[j];
		}

		int32_t avg = sum / num_samples;
		shell_print(sh, "Block %u: samples=%u, avg=%d, min=%d, max=%d",
			    i + 1, num_samples, avg, min, max);

		k_mem_slab_free(&mem_slab, buffer);
		buffer = NULL;
		ret = dmic_trigger(dmic, DMIC_TRIGGER_STOP);
		if (ret < 0) {
			shell_error(sh, "STOP trigger failed (%d)", ret);
		}
	}

cleanup:
	if (buffer) {
		k_mem_slab_free(&mem_slab, buffer);
	}
	shell_print(sh, "E");
	mic_power_off();

	return ret;
}

SHELL_STATIC_SUBCMD_SET_CREATE(sub_mic_cmds,
	SHELL_CMD_ARG(capture, NULL, "Capture mic data [time_sec]", cmd_mic_capture, 0, 1),
	SHELL_CMD_ARG(record, NULL, "Record WAV to SD card [time_sec]", cmd_mic_record, 0, 1),
	SHELL_SUBCMD_SET_END
);

SHELL_CMD_REGISTER(mic, &sub_mic_cmds, "Microphone commands", NULL);

int mic_power_off(void)
{
	/* Disable mic 1.8V via NPM1300 LDO1 */
	if (device_is_ready(mic_ldo)) {
		regulator_disable(mic_ldo);
	}
	/* Disable PDM level shifter */
	if (device_is_ready(pdm_en_gpio.port)) {
		gpio_pin_set_dt(&pdm_en_gpio, 0);
	}
	return 0;
}

int mic_power_on(void)
{
	/* Enable PDM level shifter (TXS0104E VCCB) */
	if (device_is_ready(pdm_en_gpio.port)) {
		gpio_pin_configure_dt(&pdm_en_gpio, GPIO_OUTPUT_HIGH);
	}
	/* Enable mic 1.8V via NPM1300 LDO1 */
	if (device_is_ready(mic_ldo)) {
		int ret = regulator_enable(mic_ldo);
		if (ret) {
			LOG_ERR("Mic LDO1 enable failed: %d", ret);
			return ret;
		}
		k_msleep(10);	/* let the mic settle; avoids power-up pop */
	}
	return 0;
}

int mic_init(void)
{
	if (!device_is_ready(dmic)) {
		return -ENODEV;
	}

	mic_power_off();

	cfg.channel.req_chan_map_lo =
		dmic_build_channel_map(0, 0, PDM_CHAN_LEFT) |
		dmic_build_channel_map(1, 0, PDM_CHAN_RIGHT);

	initialized = true;

	return 0;
}
