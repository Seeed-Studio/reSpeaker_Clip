/*
 * Simple OLED display driver for CH1115
 * Basic screen-on functionality
 */

#ifndef DISPLAY_H
#define DISPLAY_H

#include <zephyr/kernel.h>
#include <stdint.h>
#include <stdbool.h>

/**
 * @brief Initialize OLED display hardware
 * @return 0 on success, negative errno on failure
 */
int display_init_hw(void);

/**
 * @brief Clear display (all pixels off)
 */
void oled_clear(void);

/**
 * @brief Fill display (all pixels on)
 */
void display_fill(void);

/**
 * @brief Show recording page with wave animation
 * @param enhanced_mode true for enhanced mode (fast animation), false for normal mode
 *
 * Normal mode: 13 thick bars (2px), slow wave animation
 * Enhanced mode: 13 thin bars (1px), fast wave animation with 3 peaks
 */
void display_show_recording(bool enhanced_mode);

/**
 * @brief Show info page with battery and status
 * @param battery_percent Battery percentage (0-100)
 * @param charging Charging status
 * @param ble_connected BLE connection status
 * @param transferring File transfer status
 *
 * Displays:
 * - Battery icon + percentage (e.g., "85%")
 * - BLE icon (if connected) or Transfer icon (if transferring)
 */
void display_show_info(uint8_t battery_percent, bool charging, bool ble_connected, bool transferring);

#endif /* DISPLAY_H */
