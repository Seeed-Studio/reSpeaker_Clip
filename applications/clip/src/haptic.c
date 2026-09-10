/*
 * Copyright (c) 2025 Seeed Technology Co., Ltd.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#include <zephyr/kernel.h>
#include <zephyr/device.h>
#include <zephyr/drivers/gpio.h>
#include <zephyr/logging/log.h>
#include "haptic.h"

LOG_MODULE_REGISTER(haptic, CONFIG_CLIP_LOG_LEVEL);

/* Motor control GPIO - P1.06 controls PMIC GPIO1 which controls BUCK1 (MOTOR_3V3)
 *
 * Hardware connection:
 *   nRF5340 P1.06 → NPM1300 GPIO1 → BUCK1 (VOUT1/MOTOR_3V3) enable
 */
#ifdef CONFIG_CLIP_HAPTIC_MOTOR_ENABLED
#define HAPTIC_MOTOR_GPIO_PIN  CONFIG_CLIP_HAPTIC_MOTOR_GPIO_PIN

static const struct device *gpio1_dev = DEVICE_DT_GET(DT_NODELABEL(gpio1));

/* Current motor state */
static volatile bool motor_is_on = false;

static int execute_pattern(enum haptic_pattern pattern);

/* Pattern execution moved to a dedicated low-priority thread: patterns are
 * on/off timing loops (100-500 ms of k_sleep), and callers (button driver
 * thread, clip event handler) must not be stalled while the motor runs. */
K_MSGQ_DEFINE(haptic_msgq, sizeof(enum haptic_pattern), 2, 1);

#define HAPTIC_THREAD_STACK_SIZE 512
static K_THREAD_STACK_DEFINE(haptic_stack, HAPTIC_THREAD_STACK_SIZE);
static struct k_thread haptic_thread;

static void haptic_thread_fn(void *p1, void *p2, void *p3)
{
	enum haptic_pattern pattern;

	ARG_UNUSED(p1);
	ARG_UNUSED(p2);
	ARG_UNUSED(p3);

	while (1) {
		k_msgq_get(&haptic_msgq, &pattern, K_FOREVER);
		(void)execute_pattern(pattern);
	}
}

#endif /* CONFIG_CLIP_HAPTIC_MOTOR_ENABLED */

int haptic_init(void)
{
#ifdef CONFIG_CLIP_HAPTIC_MOTOR_ENABLED

	if (!device_is_ready(gpio1_dev)) {
		LOG_ERR("GPIO1 not ready (haptic)");
		return -ENODEV;
	}

	/* Configure motor control GPIO as output, initial state LOW (motor off) */
	int ret = gpio_pin_configure(gpio1_dev, HAPTIC_MOTOR_GPIO_PIN,
				     GPIO_OUTPUT_LOW);
	if (ret != 0 && ret != -EEXIST) {
		LOG_ERR("haptic GPIO config %d", ret);
		return ret;
	}


	k_thread_create(&haptic_thread, haptic_stack,
			K_THREAD_STACK_SIZEOF(haptic_stack),
			haptic_thread_fn, NULL, NULL, NULL,
			K_PRIO_PREEMPT(10), 0, K_NO_WAIT);
	k_thread_name_set(&haptic_thread, "haptic");
	return 0;
#else
	LOG_WRN("Haptic motor disabled via Kconfig");
	return -ENOTSUP;
#endif
}

int haptic_set_motor(bool enable)
{
#ifdef CONFIG_CLIP_HAPTIC_MOTOR_ENABLED
	int ret = gpio_port_set_masked_raw(gpio1_dev, BIT(HAPTIC_MOTOR_GPIO_PIN),
					   enable ? BIT(HAPTIC_MOTOR_GPIO_PIN) : 0);
	if (ret == 0) {
		motor_is_on = enable;
		LOG_DBG("Motor %s via GPIO1.%d", enable ? "ON" : "OFF", HAPTIC_MOTOR_GPIO_PIN);
	} else {
		LOG_ERR("Failed to set motor state: %d", ret);
	}

	return ret;
#else
	return -ENOTSUP;
#endif
}

bool haptic_is_busy(void)
{
#ifdef CONFIG_CLIP_HAPTIC_MOTOR_ENABLED
	/* A queued or running pattern counts: the motor's mechanical noise
	 * couples into the PDM mics, so audio capture must wait it out. */
	return k_msgq_num_used_get(&haptic_msgq) > 0 || motor_is_on;
#else
	return false;
#endif
}

bool haptic_is_running(void)
{
#ifdef CONFIG_CLIP_HAPTIC_MOTOR_ENABLED
	return motor_is_on;
#else
	return false;
#endif
}

/* Execute haptic pattern (blocking) */
static int execute_pattern(enum haptic_pattern pattern)
{
#ifdef CONFIG_CLIP_HAPTIC_MOTOR_ENABLED
	switch (pattern) {
	case HAPTIC_SHORT:
		/* Short tap: 100ms */
		LOG_DBG("Haptic: SHORT");
		haptic_set_motor(true);
		k_sleep(K_MSEC(100));
		haptic_set_motor(false);
		break;

	case HAPTIC_DOUBLE:
		/* Double tap: 100ms on, 100ms off, 100ms on */
		LOG_DBG("Haptic: DOUBLE");
		haptic_set_motor(true);
		k_sleep(K_MSEC(100));
		haptic_set_motor(false);
		k_sleep(K_MSEC(100));
		haptic_set_motor(true);
		k_sleep(K_MSEC(100));
		haptic_set_motor(false);
		break;

	case HAPTIC_LONG:
		/* Long: 500ms on */
		LOG_DBG("Haptic: LONG");
		haptic_set_motor(true);
		k_sleep(K_MSEC(500));
		haptic_set_motor(false);
		break;

	case HAPTIC_ALERT:
		/* Alert: 2 short, 1 long */
		LOG_DBG("Haptic: ALERT");
		haptic_set_motor(true);
		k_sleep(K_MSEC(150));
		haptic_set_motor(false);
		k_sleep(K_MSEC(150));
		haptic_set_motor(true);
		k_sleep(K_MSEC(150));
		haptic_set_motor(false);
		k_sleep(K_MSEC(150));
		haptic_set_motor(true);
		k_sleep(K_MSEC(400));
		haptic_set_motor(false);
		break;

	default:
		LOG_WRN("Unknown haptic pattern: %d", pattern);
		return -EINVAL;
	}

	return 0;
#else
	return -ENOTSUP;
#endif
}

int haptic_play_pattern(enum haptic_pattern pattern)
{
#ifdef CONFIG_CLIP_HAPTIC_MOTOR_ENABLED
	/* Non-blocking: queue for the haptic thread (drops if one is already
	 * queued — feedback patterns are idempotent-ish, a dropped duplicate
	 * is fine). */
	return k_msgq_put(&haptic_msgq, &pattern, K_NO_WAIT);
#else
	return -ENOTSUP;
#endif
}
