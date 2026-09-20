/*
 * Copyright (c) 2026 Seeed Technology Co., Ltd.
 *
 * SPDX-License-Identifier: LicenseRef-Nordic-5-Clause
 */

#include <zephyr/kernel.h>
#include <zephyr/device.h>
#include <zephyr/drivers/flash.h>
#include <zephyr/logging/log.h>
#include <zephyr/shell/shell.h>
#include <stdlib.h>
#include <string.h>

LOG_MODULE_REGISTER(flash_test, LOG_LEVEL_INF);

/* Keep the battery fuel-gauge settings in the LittleFS partition starting at
 * 0x130000 intact. The no-MCUboot hardware-test image does not use the two
 * external OTA slots, so reserve the 960 KB app slot for destructive raw
 * Flash testing instead. */
#define FLASH_TEST_OFFSET 0x000000
#define FLASH_TEST_MAX_SIZE (960 * 1024)
#define CHUNK_SIZE 4096

static int cmd_flash_speed(const struct shell *sh, size_t argc, char **argv)
{
	const struct device *flash_dev;
	uint32_t test_size = FLASH_TEST_MAX_SIZE;
	uint8_t *write_buf;
	uint8_t *read_buf;
	uint64_t start_time, end_time;
	int rc;

	flash_dev = DEVICE_DT_GET(DT_NODELABEL(spi_flash));
	if (!device_is_ready(flash_dev)) {
		shell_error(sh, "SPI flash not ready");
		return -ENODEV;
	}

	if (argc >= 2) {
		test_size = atoi(argv[1]) * 1024;
		if (test_size < CHUNK_SIZE) {
			test_size = CHUNK_SIZE;
		}
		if (test_size > FLASH_TEST_MAX_SIZE) {
			test_size = FLASH_TEST_MAX_SIZE;
		}
	}

	shell_print(sh, "Flash speed test (size: %u KB, offset: 0x%x)...",
		    test_size / 1024, FLASH_TEST_OFFSET);

	write_buf = k_malloc(CHUNK_SIZE);
	read_buf = k_malloc(CHUNK_SIZE);
	if (!write_buf || !read_buf) {
		shell_error(sh, "Failed to allocate buffers");
		k_free(write_buf);
		k_free(read_buf);
		return -ENOMEM;
	}

	/* Fill write buffer with pattern */
	for (uint32_t i = 0; i < CHUNK_SIZE; i++) {
		write_buf[i] = (uint8_t)(i & 0xFF);
	}

	/* Erase test */
	shell_print(sh, "Erasing %u KB...", test_size / 1024);
	start_time = k_uptime_get();
	for (uint32_t offset = 0; offset < test_size; offset += CHUNK_SIZE) {
		rc = flash_erase(flash_dev, FLASH_TEST_OFFSET + offset, CHUNK_SIZE);
		if (rc != 0) {
			shell_error(sh, "Erase failed at 0x%x: %d",
				    FLASH_TEST_OFFSET + offset, rc);
			goto cleanup;
		}
	}
	end_time = k_uptime_get();
	{
		uint64_t erase_time = end_time - start_time;
		uint32_t erase_speed = erase_time > 0 ?
			(test_size / 1024 * 1000) / erase_time : 0;
		shell_print(sh, "Erase: %llu ms, %u KB/s", erase_time, erase_speed);
	}

	/* Write test */
	shell_print(sh, "Writing %u KB...", test_size / 1024);
	start_time = k_uptime_get();
	for (uint32_t offset = 0; offset < test_size; offset += CHUNK_SIZE) {
		rc = flash_write(flash_dev, FLASH_TEST_OFFSET + offset,
				 write_buf, CHUNK_SIZE);
		if (rc != 0) {
			shell_error(sh, "Write failed at 0x%x: %d",
				    FLASH_TEST_OFFSET + offset, rc);
			goto cleanup;
		}
	}
	end_time = k_uptime_get();
	{
		uint64_t write_time = end_time - start_time;
		uint32_t write_speed = write_time > 0 ?
			(test_size / 1024 * 1000) / write_time : 0;
		shell_print(sh, "Write: %llu ms, %u KB/s", write_time, write_speed);
	}

	/* Read test + verify */
	shell_print(sh, "Reading %u KB...", test_size / 1024);
	start_time = k_uptime_get();
	for (uint32_t offset = 0; offset < test_size; offset += CHUNK_SIZE) {
		rc = flash_read(flash_dev, FLASH_TEST_OFFSET + offset,
				read_buf, CHUNK_SIZE);
		if (rc != 0) {
			shell_error(sh, "Read failed at 0x%x: %d",
				    FLASH_TEST_OFFSET + offset, rc);
			goto cleanup;
		}
		if (memcmp(write_buf, read_buf, CHUNK_SIZE) != 0) {
			shell_error(sh, "Verify failed at 0x%x",
				    FLASH_TEST_OFFSET + offset);
		}
	}
	end_time = k_uptime_get();
	{
		uint64_t read_time = end_time - start_time;
		uint32_t read_speed = read_time > 0 ?
			(test_size / 1024 * 1000) / read_time : 0;
		shell_print(sh, "Read:  %llu ms, %u KB/s (verified)", read_time, read_speed);
	}

cleanup:
	k_free(write_buf);
	k_free(read_buf);
	return 0;
}

/* Quick PASS/FAIL test: erase a 4 KiB block, write a 256 B pattern, read back,
 * verify. Result goes to the shell (not the OLED). Uses FLASH_TEST_OFFSET
 * (the unused OTA app slot in this no-MCUboot image) — the fuel-gauge
 * LittleFS at 0x130000 is left intact. */
static int cmd_flash_test(const struct shell *sh, size_t argc, char **argv)
{
	const struct device *flash_dev;
	uint8_t write_buf[256];
	uint8_t read_buf[256];
	int rc;

	ARG_UNUSED(argc);
	ARG_UNUSED(argv);

	flash_dev = DEVICE_DT_GET(DT_NODELABEL(spi_flash));
	if (!device_is_ready(flash_dev)) {
		shell_print(sh, "FAIL: SPI flash not ready");
		return -ENODEV;
	}

	for (int i = 0; i < sizeof(write_buf); i++) {
		write_buf[i] = (uint8_t)(i ^ 0xAA);
	}

	rc = flash_erase(flash_dev, FLASH_TEST_OFFSET, 4096);
	if (rc != 0) {
		shell_print(sh, "FAIL: erase %d", rc);
		return rc;
	}

	rc = flash_write(flash_dev, FLASH_TEST_OFFSET, write_buf, sizeof(write_buf));
	if (rc != 0) {
		shell_print(sh, "FAIL: write %d", rc);
		return rc;
	}

	rc = flash_read(flash_dev, FLASH_TEST_OFFSET, read_buf, sizeof(read_buf));
	if (rc != 0) {
		shell_print(sh, "FAIL: read %d", rc);
		return rc;
	}

	if (memcmp(write_buf, read_buf, sizeof(write_buf)) != 0) {
		shell_print(sh, "FAIL: verify mismatch");
		return -EIO;
	}

	shell_print(sh, "PASS: flash erase/write/read/verify OK");
	return 0;
}

SHELL_STATIC_SUBCMD_SET_CREATE(sub_flash,
	SHELL_CMD_ARG(speed, NULL, "Flash speed test [size_kb]", cmd_flash_speed, 1, 1),
	SHELL_CMD_ARG(test, NULL, "Flash PASS/FAIL test", cmd_flash_test, 1, 0),
	SHELL_SUBCMD_SET_END
);

SHELL_CMD_REGISTER(flash, &sub_flash, "SPI flash test commands", NULL);
