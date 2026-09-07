/*
 * Copyright (c) 2023 Nordic Semiconductor ASA
 *
 * SPDX-License-Identifier: LicenseRef-Nordic-5-Clause
 */

#include <zephyr/kernel.h>
#include <zephyr/device.h>
#include <zephyr/drivers/gpio.h>
#include <zephyr/logging/log.h>
#include "button.h"
#include "oled.h"

LOG_MODULE_REGISTER(button, LOG_LEVEL_INF);

/* Get button from devicetree */
static const struct gpio_dt_spec button = GPIO_DT_SPEC_GET(DT_NODELABEL(usr_btn), gpios);
static struct gpio_callback button_cb_data;

/* Visual feedback on press: fill the OLED for ~1 s (the 1 s battery-display
 * refresh in pmic.c then restores the normal screen). Deferred to a work item
 * — the GPIO ISR can't touch I2C2. */
static struct k_work button_oled_work;
static void button_oled_flash_handler(struct k_work *work)
{
	ARG_UNUSED(work);
	oled_test_fill();
}

/* Button interrupt handler */
static void button_pressed(const struct device *dev, struct gpio_callback *cb, uint32_t pins)
{
	LOG_INF("Button pressed!");
	k_work_submit(&button_oled_work);
}

int button_init(void)
{
	int ret;

	LOG_INF("Initializing Button...");

	k_work_init(&button_oled_work, button_oled_flash_handler);

	/* Initialize button */
	if (!gpio_is_ready_dt(&button)) {
		LOG_ERR("Button device not ready");
		return -ENODEV;
	}

	ret = gpio_pin_configure_dt(&button, GPIO_INPUT);
	if (ret != 0) {
		LOG_ERR("Failed to configure button GPIO: %d", ret);
		return ret;
	}

	ret = gpio_pin_interrupt_configure_dt(&button, GPIO_INT_EDGE_TO_ACTIVE);
	if (ret != 0) {
		LOG_ERR("Failed to configure button interrupt: %d", ret);
		return ret;
	}

	gpio_init_callback(&button_cb_data, button_pressed, BIT(button.pin));
	gpio_add_callback(button.port, &button_cb_data);

	LOG_INF("Button ready on GPIO P0.%d - press to see log message", button.pin);

	return 0;
}
