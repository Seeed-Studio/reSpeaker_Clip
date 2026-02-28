# SPDX-License-Identifier: Apache-2.0

# CH1115 OLED display driver

zephyr_library_named(ch1115_oled)
zephyr_library_property(ALLOW_EMPTY TRUE)

# Only compile if CONFIG_OLED_DISPLAY is enabled
zephyr_library_sources_ifdef(CONFIG_OLED_DISPLAY ch1115.c)
