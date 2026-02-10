/*
 * Copyright (c) 2024 Seeed Technology Co., Ltd.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#include <zephyr/kernel.h>
#include <zephyr/device.h>
#include <zephyr/audio/dmic.h>
#include <zephyr/drivers/gpio.h>
#include <zephyr/drivers/uart.h>
#include <zephyr/logging/log.h>
#include <zephyr/sys/byteorder.h>
#include <nrfx_pdm.h>
#include <string.h>

LOG_MODULE_REGISTER(t5838, LOG_LEVEL_INF);

#define SAMPLE_RATE_HZ  16000
#define SAMPLE_BITS     16
#define CHANNEL_COUNT   1
#define TIMEOUT_MS      500
#define CAPTURE_MS      100
#define BLOCK_COUNT     50  /* 5 seconds */
#define BLOCK_SIZE      (((SAMPLE_BITS / 8) * (SAMPLE_RATE_HZ * CAPTURE_MS)) / 1000) * CHANNEL_COUNT

#define TOTAL_BUFFER_SIZE (BLOCK_SIZE * BLOCK_COUNT)

static const struct device *const dmic = DEVICE_DT_GET(DT_ALIAS(dmic0));
static const struct device *const uart_dev = DEVICE_DT_GET(DT_CHOSEN(zephyr_console));
static const struct gpio_dt_spec mic_en = GPIO_DT_SPEC_GET_OR(DT_NODELABEL(mic_reg), gpios, {0});

K_MEM_SLAB_DEFINE_STATIC(mem_slab, BLOCK_SIZE, BLOCK_COUNT, 4);

/* Large buffer to store all recorded data */
static uint8_t record_buffer[TOTAL_BUFFER_SIZE];
static uint32_t record_buffer_offset;

static struct pcm_stream_cfg stream = {
	.pcm_rate = SAMPLE_RATE_HZ,
	.pcm_width = SAMPLE_BITS,
	.block_size = BLOCK_SIZE,
	.mem_slab = &mem_slab,
};

static struct dmic_cfg cfg = {
	.io = {
		.min_pdm_clk_freq = 512000,
		.max_pdm_clk_freq = 3500000,
		.min_pdm_clk_dc = 48,
		.max_pdm_clk_dc = 52,
	},
	.streams = &stream,
	.channel = {
		.req_num_streams = 1,
		.req_num_chan = CHANNEL_COUNT,
	},
};

static int mic_power_on(void)
{
	if (mic_en.port) {
		gpio_pin_configure_dt(&mic_en, GPIO_OUTPUT);
		gpio_pin_set_dt(&mic_en, 1);
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


int main(void)
{
	int ret;
	void *buffer = NULL;
	uint32_t size;

	LOG_INF("ReSpeaker Lav T5838 PDM Test");

	if (!device_is_ready(dmic)) {
		LOG_ERR("DMIC device not ready");
		return -ENODEV;
	}

	if (!device_is_ready(uart_dev)) {
		LOG_ERR("UART device not ready");
		return -ENODEV;
	}

	/* Initialize buffer */
	memset(record_buffer, 0, TOTAL_BUFFER_SIZE);
	record_buffer_offset = 0;

	printf("\n");
	printf("========================================\n");
	printf("Start Speaking or Play some Audio!\n");
	printf("========================================\n");
	printf("\n");

	/* Configure channel map - mono LEFT channel only */
	cfg.channel.req_chan_map_lo = dmic_build_channel_map(0, 0, PDM_CHAN_LEFT);

	/* Power on microphone */
	mic_power_on();
	k_sleep(K_MSEC(100));

	/* Configure DMIC */
	ret = dmic_configure(dmic, &cfg);
	if (ret < 0) {
		LOG_ERR("Failed to configure DMIC: %d", ret);
		return ret;
	}

	/* Set microphone gain - level 6 (+20dB) */
#ifdef NRF_PDM0_S
	nrf_pdm_gain_set(NRF_PDM0_S, 0x3C, 0x3C);
#else
	nrf_pdm_gain_set(NRF_PDM0_NS, 0x3C, 0x3C);
#endif

	/* Phase 1: Record all data to buffer */
	printf(">>> Recording...\n");

	/* Start DMIC once */
	ret = dmic_trigger(dmic, DMIC_TRIGGER_START);
	if (ret < 0) {
		LOG_ERR("START trigger failed: %d", ret);
		goto cleanup;
	}

	/* Read all blocks */
	for (int i = 0; i < BLOCK_COUNT; i++) {
		ret = dmic_read(dmic, 0, &buffer, &size, TIMEOUT_MS);
		if (ret < 0) {
			LOG_ERR("DMIC read failed: %d", ret);
			goto cleanup;
		}

		/* Copy to record buffer */
		if (record_buffer_offset + size <= TOTAL_BUFFER_SIZE) {
			memcpy(&record_buffer[record_buffer_offset], buffer, size);
			record_buffer_offset += size;
		}

		k_mem_slab_free(&mem_slab, buffer);
		buffer = NULL;
	}

	/* Stop DMIC once after all blocks */
	ret = dmic_trigger(dmic, DMIC_TRIGGER_STOP);
	if (ret < 0) {
		LOG_ERR("STOP trigger failed: %d", ret);
	}

	printf(">>> Recording complete. Captured %u bytes\n", record_buffer_offset);

	/* Phase 2: Send all data via UART */
	/* Use printf to ensure this marker arrives before hex data */
	printf(">>> Start sending data\n");

	/* Send as hex for Python script compatibility */
	uint16_t *samples = (uint16_t *)record_buffer;
	uint32_t num_samples = record_buffer_offset / sizeof(uint16_t);

	for (uint32_t i = 0; i < num_samples; i++) {
		printf("%04x\n", samples[i]);
	}

cleanup:
	if (buffer) {
		k_mem_slab_free(&mem_slab, buffer);
	}

	printf("\n");
	printf("========================================\n");
	printf("Stop recording\n");
	printf("PDM example, print done\n");
	printf("========================================\n");
	printf("\n");

	mic_power_off();

	return 0;
}
