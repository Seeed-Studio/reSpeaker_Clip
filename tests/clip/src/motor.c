/*
 * Copyright (c) 2023 Nordic Semiconductor ASA
 *
 * SPDX-License-Identifier: LicenseRef-Nordic-5-Clause
 */

#include <stdio.h>
#include <stdlib.h>
#include <zephyr/kernel.h>
#include <zephyr/device.h>
#include <zephyr/drivers/gpio.h>
#include <zephyr/shell/shell.h>
#include <zephyr/logging/log.h>
#include "motor.h"

LOG_MODULE_REGISTER(motor, LOG_LEVEL_INF);

/* Motor control GPIO (external feedback to PMIC GPIO2) */
#define MOTOR_CTRL_GPIO     6  /* GPIO1.6 */
static const struct device *gpio1_dev = DEVICE_DT_GET(DT_NODELABEL(gpio1));

/* Current motor state */
static bool motor_is_on = false;

/* Initialize motor control */
int motor_init(void)
{
	LOG_INF("Initializing vibration motor control...");

	if (!device_is_ready(gpio1_dev)) {
		LOG_ERR("GPIO1 not ready for motor control");
		return -ENODEV;
	}

	/* Configure motor control GPIO as output */
	int ret = gpio_pin_configure(gpio1_dev, MOTOR_CTRL_GPIO, GPIO_OUTPUT);
	if (ret != 0 && ret != -EEXIST) {
		LOG_ERR("Failed to configure motor GPIO: %d", ret);
		return ret;
	}

	/* Ensure motor is off at startup */
	gpio_port_set_masked_raw(gpio1_dev, BIT(MOTOR_CTRL_GPIO), 0);

	LOG_INF("Motor control ready (GPIO1.%d)", MOTOR_CTRL_GPIO);
	return 0;
}

/* Set motor state */
int motor_set(bool enable)
{
	int ret = gpio_port_set_masked_raw(gpio1_dev, BIT(MOTOR_CTRL_GPIO),
					       enable ? BIT(MOTOR_CTRL_GPIO) : 0);
	if (ret == 0) {
		motor_is_on = enable;
		LOG_INF("Motor %s via GPIO1.%d", enable ? "ON" : "OFF", MOTOR_CTRL_GPIO);
	} else {
		LOG_ERR("Failed to set motor state: %d", ret);
	}

	return ret;
}

/* Get motor state */
bool motor_is_running(void)
{
	return motor_is_on;
}

/* ============================================================================
 * Shell Commands
 * ============================================================================ */

/* Shell command: motor on/off */
static int cmd_motor_on(const struct shell *sh, size_t argc, char **argv)
{
	ARG_UNUSED(argc);
	ARG_UNUSED(argv);

	if (motor_set(true) == 0) {
		shell_print(sh, "Motor ON - Press Ctrl+C to stop");
		return 0;
	}

	shell_print(sh, "Error: Failed to turn on motor");
	return -EIO;
}

static int cmd_motor_off(const struct shell *sh, size_t argc, char **argv)
{
	ARG_UNUSED(argc);
	ARG_UNUSED(argv);

	if (motor_set(false) == 0) {
		shell_print(sh, "Motor OFF");
		return 0;
	}

	shell_print(sh, "Error: Failed to turn off motor");
	return -EIO;
}

/* Shell command: motor pulse (vibrate for specified duration) */
static int cmd_motor_pulse(const struct shell *sh, size_t argc, char **argv)
{
	int duration_ms = 500;  /* Default 500ms */

	if (argc >= 2) {
		duration_ms = strtol(argv[1], NULL, 10);
		if (duration_ms <= 0 || duration_ms > 10000) {
			shell_print(sh, "Error: Duration must be 1-10000 ms");
			return -EINVAL;
		}
	}

	shell_print(sh, "Motor pulse: %d ms...", duration_ms);

	motor_set(true);
	k_sleep(K_MSEC(duration_ms));
	motor_set(false);

	shell_print(sh, "Motor pulse completed");
	return 0;
}

/* Shell command: motor pattern (vibration patterns) */
static int cmd_motor_pattern(const struct shell *sh, size_t argc, char **argv)
{
	const char *pattern = "default";

	if (argc >= 2) {
		pattern = argv[1];
	}

	shell_print(sh, "Vibration pattern: %s", pattern);

	if (strcmp(pattern, "short") == 0) {
		/* Short tap: 100ms */
		motor_set(true);
		k_sleep(K_MSEC(100));
		motor_set(false);

	} else if (strcmp(pattern, "double") == 0) {
		/* Double tap: 100ms on, 100ms off, 100ms on */
		motor_set(true);
		k_sleep(K_MSEC(100));
		motor_set(false);
		k_sleep(K_MSEC(100));
		motor_set(true);
		k_sleep(K_MSEC(100));
		motor_set(false);

	} else if (strcmp(pattern, "long") == 0) {
		/* Long: 500ms on */
		motor_set(true);
		k_sleep(K_MSEC(500));
		motor_set(false);

	} else if (strcmp(pattern, "sos") == 0) {
		/* SOS pattern: 3 short, 3 long, 3 short */
		for (int i = 0; i < 3; i++) {
			motor_set(true);
			k_sleep(K_MSEC(100));
			motor_set(false);
			k_sleep(K_MSEC(100));
		}
		k_sleep(K_MSEC(300));
		for (int i = 0; i < 3; i++) {
			motor_set(true);
			k_sleep(K_MSEC(400));
			motor_set(false);
			k_sleep(K_MSEC(100));
		}
		k_sleep(K_MSEC(300));
		for (int i = 0; i < 3; i++) {
			motor_set(true);
			k_sleep(K_MSEC(100));
			motor_set(false);
			k_sleep(K_MSEC(100));
		}

	} else if (strcmp(pattern, "alert") == 0) {
		/* Alert pattern: 2 short, 1 long */
		motor_set(true);
		k_sleep(K_MSEC(150));
		motor_set(false);
		k_sleep(K_MSEC(150));
		motor_set(true);
		k_sleep(K_MSEC(150));
		motor_set(false);
		k_sleep(K_MSEC(150));
		motor_set(true);
		k_sleep(K_MSEC(400));
		motor_set(false);

	} else {
		/* Default: show available patterns */
		shell_print(sh, "Available patterns:");
		shell_print(sh, "  short   - 100ms tap");
		shell_print(sh, "  double  - 100ms, 100ms, 100ms");
		shell_print(sh, "  long    - 500ms hold");
		shell_print(sh, "  sos     - ... --- ...");
		shell_print(sh, "  alert   - ..- pattern");
		return 0;
	}

	shell_print(sh, "Pattern completed");
	return 0;
}

/* Shell command: motor test (run all test patterns) */
static int cmd_motor_test(const struct shell *sh, size_t argc, char **argv)
{
	ARG_UNUSED(argc);
	ARG_UNUSED(argv);

	shell_print(sh, "Running motor test patterns...");

	shell_print(sh, "  [1/5] Short tap...");
	cmd_motor_pattern(sh, 0, (char *[]){"", "short"});
	k_sleep(K_MSEC(500));

	shell_print(sh, "  [2/5] Double tap...");
	cmd_motor_pattern(sh, 0, (char *[]){"", "double"});
	k_sleep(K_MSEC(500));

	shell_print(sh, "  [3/5] Long hold...");
	cmd_motor_pattern(sh, 0, (char *[]){"", "long"});
	k_sleep(K_MSEC(700));

	shell_print(sh, "  [4/5] SOS...");
	cmd_motor_pattern(sh, 0, (char *[]){"", "sos"});
	k_sleep(K_MSEC(1000));

	shell_print(sh, "  [5/5] Alert...");
	cmd_motor_pattern(sh, 0, (char *[]){"", "alert"});

	shell_print(sh, "Motor test completed!");
	return 0;
}

/* Shell command table */
SHELL_STATIC_SUBCMD_SET_CREATE(sub_motor,
	SHELL_CMD(on, NULL, "Turn motor ON (hold Ctrl+C to stop)", cmd_motor_on),
	SHELL_CMD(off, NULL, "Turn motor OFF", cmd_motor_off),
	SHELL_CMD_ARG(pulse, NULL, "Motor pulse [duration_ms]", cmd_motor_pulse, 0, 1),
	SHELL_CMD_ARG(pattern, NULL, "Vibration pattern [short|double|long|sos|alert]", cmd_motor_pattern, 0, 1),
	SHELL_CMD(test, NULL, "Run all test patterns", cmd_motor_test),
	SHELL_SUBCMD_SET_END
);

/* Root command: motor */
SHELL_CMD_REGISTER(motor, &sub_motor, "Vibration motor commands", NULL);
