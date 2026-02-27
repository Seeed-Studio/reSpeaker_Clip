/*
 * Simple OLED display driver for CH1115
 * Basic screen-on functionality
 */

#ifndef DISPLAY_H
#define DISPLAY_H

#include <zephyr/kernel.h>

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

#endif /* DISPLAY_H */
