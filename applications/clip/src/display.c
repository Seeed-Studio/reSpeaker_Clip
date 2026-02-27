/*
 * Simple OLED display driver test for CH1115
 * Basic screen-on functionality
 */

#include <zephyr/kernel.h>
#include <zephyr/device.h>
#include <zephyr/drivers/display.h>
#include <zephyr/drivers/gpio.h>
#include <zephyr/sys/printk.h>
#include <zephyr/logging/log.h>
#include <string.h>

LOG_MODULE_REGISTER(display, LOG_LEVEL_INF);

/* Display dimensions */
#define OLED_WIDTH  88
#define OLED_HEIGHT 48

/* Display buffer size (monochrome: 8 pixels per byte) */
#define OLED_BUF_SIZE (OLED_WIDTH * OLED_HEIGHT / 8)

/* Frame buffer */
static uint8_t display_buffer[OLED_BUF_SIZE];

/* Display device */
static const struct device *display_dev = NULL;

/* Initialize display hardware */
int display_init_hw(void)
{
	/* Get display device */
	display_dev = DEVICE_DT_GET(DT_CHOSEN(zephyr_display));
	if (!display_dev || !device_is_ready(display_dev)) {
		LOG_WRN("[DISPLAY] OLED device not ready, using log output");
		display_dev = NULL;
	} else {
		LOG_INF("[DISPLAY] Initialized (OLED: %dx%d)", OLED_WIDTH, OLED_HEIGHT);

		/* Initialize with white screen (all pixels set to 1 for MONO01) */
		memset(display_buffer, 0xFF, OLED_BUF_SIZE);

		struct display_buffer_descriptor desc = {
			.buf_size = OLED_BUF_SIZE,
			.width = OLED_WIDTH,
			.height = OLED_HEIGHT,
			.pitch = OLED_WIDTH,
		};

		display_write(display_dev, 0, 0, &desc, display_buffer);
	}

	return 0;
}

/* Clear display */
void oled_clear(void)
{
	struct display_buffer_descriptor desc;

	if (!display_dev) {
		return;
	}

	desc.buf_size = sizeof(display_buffer);
	desc.width = OLED_WIDTH;
	desc.height = OLED_HEIGHT;
	desc.pitch = OLED_WIDTH;

	memset(display_buffer, 0x00, sizeof(display_buffer));
	display_write(display_dev, 0, 0, &desc, display_buffer);
}

/* Fill display (all on) */
void display_fill(void)
{
	struct display_buffer_descriptor desc;

	if (!display_dev) {
		return;
	}

	desc.buf_size = sizeof(display_buffer);
	desc.width = OLED_WIDTH;
	desc.height = OLED_HEIGHT;
	desc.pitch = OLED_WIDTH;

	memset(display_buffer, 0xFF, sizeof(display_buffer));
	display_write(display_dev, 0, 0, &desc, display_buffer);
}
