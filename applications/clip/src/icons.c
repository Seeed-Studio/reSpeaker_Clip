/*
 * Copyright (c) 2024 Seeed Technology Co., Ltd.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#include "clip/icons.h"
#include <zephyr/kernel.h>

/* OLED display dimensions (must match display.c) */
#define OLED_WIDTH  88
#define OLED_HEIGHT 48

/* ========================================
 * Icon Bitmap Data (16x16 pixels, row-major)
 * ======================================== */

/**
 * @brief 16x16 WiFi Connected Icon
 */
static const uint8_t icon_wifi_connected[ICON_SIZE_BYTES] = {
	0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x07, 0xe0,
	0x1f, 0xf8, 0x70, 0x0e, 0x60, 0x06, 0x07, 0xe0,
	0x0e, 0x70, 0x08, 0x10, 0x00, 0x00, 0x03, 0xc0,
	0x01, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
};

/**
 * @brief 16x16 Mute Microphone Icon
 */
static const uint8_t icon_mute_micro[ICON_SIZE_BYTES] = {
	0x00, 0x00, 0x01, 0x80, 0x33, 0xc0, 0x1b, 0xc0, 0x0c, 0x40, 0x06, 0x40,
	0x03, 0x40, 0x1b, 0x98, 0x1b, 0xd8, 0x0c, 0xe0, 0x07, 0x70, 0x03, 0xf8,
	0x01, 0x9c, 0x01, 0x8c, 0x00, 0x00, 0x00, 0x00
};

/**
 * @brief 16x16 Battery Icon (Full)
 */
static const uint8_t icon_battery[ICON_SIZE_BYTES] = {
	0x00, 0x00, 0x01, 0x80, 0x07, 0xe0, 0x08, 0x10, 0x0b, 0xd0, 0x0b, 0xd0,
	0x0b, 0xd0, 0x0b, 0xd0, 0x0b, 0xd0, 0x0b, 0xd0, 0x0b, 0xd0, 0x0b, 0xd0,
	0x0b, 0xd0, 0x08, 0x10, 0x0f, 0xf0, 0x00, 0x00
};

/**
 * @brief 16x16 Transfer Icon
 */
static const uint8_t icon_transfer[ICON_SIZE_BYTES] = {
	0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x18, 0x01, 0xfc,
	0x01, 0xfc, 0x00, 0x18, 0x18, 0x00, 0x3f, 0x80, 0x3f, 0x80, 0x18, 0x00,
	0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
};

/**
 * @brief 16x16 USB Icon
 */
static const uint8_t icon_usb[ICON_SIZE_BYTES] = {
	0x00, 0x00, 0x01, 0x80, 0x03, 0xc0, 0x01, 0x80, 0x09, 0xb0, 0x1d, 0xb8,
	0x1d, 0xb8, 0x0d, 0xb0, 0x0f, 0xf0, 0x0f, 0xf0, 0x01, 0x80, 0x01, 0x80,
	0x01, 0x80, 0x03, 0xc0, 0x01, 0x80, 0x00, 0x00
};

/**
 * @brief 16x16 Battery Low Icon
 */
static const uint8_t icon_battery_low[ICON_SIZE_BYTES] = {
	0x00, 0x00, 0x01, 0x80, 0x07, 0xe0, 0x08, 0x10, 0x08, 0x10, 0x08, 0x10,
	0x08, 0x10, 0x08, 0x10, 0x08, 0x10, 0x08, 0x10, 0x08, 0x10, 0x08, 0x10,
	0x08, 0x10, 0x08, 0x10, 0x0f, 0xf0, 0x00, 0x00
};

/**
 * @brief 16x16 Charging Icon
 */
static const uint8_t icon_charge[ICON_SIZE_BYTES] = {
	0x00, 0x00, 0x01, 0x80, 0x07, 0xe0, 0x08, 0x10, 0x08, 0x10, 0x08, 0x10,
	0x08, 0x10, 0x09, 0x10, 0x09, 0x90, 0x08, 0x10, 0x0a, 0x50, 0x0b, 0xd0,
	0x0b, 0xd0, 0x08, 0x10, 0x0f, 0xf0, 0x00, 0x00
};

/**
 * @brief 16x16 BLE Icon
 */
static const uint8_t icon_ble[ICON_SIZE_BYTES] = {
	0x00, 0x00, 0x0c, 0x00, 0x0c, 0x00, 0x0c, 0x30, 0x0c, 0x30, 0x6d, 0xb6,
	0x6d, 0xb6, 0x6d, 0xb6, 0x6d, 0xb6, 0x6d, 0xb6, 0x6d, 0xb6, 0x0c, 0x30,
	0x0c, 0x30, 0x0c, 0x00, 0x0c, 0x00, 0x00, 0x00
};

/* ========================================
 * Icon Drawing Functions
 * ======================================== */

/**
 * @brief Set pixel directly without mirror transformation
 * Internal helper function
 */
static inline void set_pixel_direct(uint8_t *buf, int x, int y)
{
	if (x < 0 || x >= OLED_WIDTH || y < 0 || y >= OLED_HEIGHT)
		return;
	buf[(y / 8) * OLED_WIDTH + x] |= (1 << (y % 8));
}

/**
 * @brief Draw 16x16 bitmap icon to buffer
 *
 * Bitmap format: row-major order, 1 bit per pixel
 * Each row uses (width + 7) / 8 bytes
 */
void icon_draw_bitmap(uint8_t *buf, int x, int y,
                      const uint8_t *bitmap, uint8_t width, uint8_t height)
{
	if (!buf || !bitmap) {
		return;
	}

	/* Calculate bytes per row in the bitmap */
	uint8_t bytes_per_row = (width + 7) / 8;

	/* Draw each row */
	for (uint8_t row = 0; row < height; row++) {
		int draw_y = y + row;
		/* Skip if outside screen bounds */
		if (draw_y < 0 || draw_y >= OLED_HEIGHT) {
			continue;
		}
		for (uint8_t col = 0; col < width; col++) {
			int draw_x = x + col;
			/* Skip if outside screen bounds */
			if (draw_x < 0 || draw_x >= OLED_WIDTH) {
				continue;
			}
			/* Calculate which byte contains the current pixel */
			uint8_t byte_idx = row * bytes_per_row + (col / 8);
			uint8_t bit_idx = 7 - (col % 8);  /* MSB first */

			/* Check if pixel is set */
			if (bitmap[byte_idx] & (1 << bit_idx)) {
				/* Set pixel in frame buffer using direct pixel function */
				set_pixel_direct(buf, draw_x, draw_y);
			}
		}
	}
}

/**
 * @brief Get icon bitmap data by ID
 */
const uint8_t* icon_get_bitmap(icon_id_t id, uint8_t *width, uint8_t *height)
{
	if (width) {
		*width = ICON_WIDTH;
	}
	if (height) {
		*height = ICON_HEIGHT;
	}

	switch (id) {
	case ICON_WIFI_CONNECTED:
		return icon_wifi_connected;

	case ICON_WIFI_TRANSFER:
		/* WiFi transfer uses same icon for now */
		return icon_wifi_connected;

	case ICON_MIC_MUTED:
		return icon_mute_micro;

	case ICON_BATTERY_FULL:
		return icon_battery;

	case ICON_BATTERY_CHARGING:
		return icon_charge;

	case ICON_BATTERY_LOW:
		return icon_battery_low;

	case ICON_BLE_CONNECTED:
		return icon_ble;

	case ICON_BLE_TRANSFER:
		return icon_transfer;

	case ICON_USB_CONNECTED:
		return icon_usb;

	case ICON_MIC_NORMAL:
	case ICON_MIC_ENHANCED:
	case ICON_CONNECTED:
	case ICON_DISCONNECTED:
	default:
		return NULL;
	}
}
