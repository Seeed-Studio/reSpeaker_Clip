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

/**
 * @brief Show a single frame of the dot circle animation
 * @param frame Animation frame number (0-7 for 8-frame loop)
 *
 * Renders an animated circle (●) that pulses in size.
 * Call repeatedly with incrementing frame numbers for smooth animation.
 */
void display_show_dot_circle_frame(int frame);

/**
 * @brief Show a single frame of the mark animation
 * @param frame Animation frame number (0 to total_frames-1)
 * @param fast_mode true for fast mode (30 frames), false for normal mode (60 frames)
 *
 * Renders the mark animation with:
 * - White circle: stable -> max -> stable
 * - Black circle: 0 -> max -> stable (inside white circle)
 * - Vertical lines: stable -> max -> stable (top and bottom)
 *
 * Call repeatedly with incrementing frame numbers for smooth animation.
 */
void display_show_mark_animation_frame(int frame, bool fast_mode);

/* ========================================
 * Display Buffer
 * ======================================== */

/**
 * @brief Display buffer (OLED_BUF_SIZE bytes)
 * External access for custom drawing operations
 */
extern uint8_t display_buffer[];

/* ========================================
 * 6x12 Font Functions
 * ======================================== */

/**
 * @brief Draw a single 6x12 character to display buffer
 * @param buf Frame buffer
 * @param c Character to draw (ASCII 32-126: space to ~)
 * @param x X position
 * @param y Y position
 *
 * Draws a single character using the 6x12 ASCII font.
 * Supports uppercase (A-Z), lowercase (a-z), digits (0-9), and common symbols.
 */
void display_draw_char_6x12(uint8_t *buf, char c, int x, int y);

/**
 * @brief Draw a string using 6x12 font
 * @param buf Frame buffer
 * @param str String to draw (null-terminated)
 * @param x Starting X position
 * @param y Starting Y position
 * @return X position after drawing (for chaining)
 *
 * Draws a string using the 6x12 ASCII font.
 * Each character is 6 pixels wide.
 * Supports uppercase (A-Z), lowercase (a-z), digits (0-9), and common symbols.
 *
 * Example:
 *   display_draw_string_6x12(display_buffer, "Hello", 0, 0);
 */
int display_draw_string_6x12(uint8_t *buf, const char *str, int x, int y);

#endif /* DISPLAY_H */
