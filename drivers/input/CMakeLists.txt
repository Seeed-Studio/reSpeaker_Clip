# SPDX-License-Identifier: Apache-2.0

# GPIO button input driver

zephyr_library_named(gpio_button)
zephyr_library_property(ALLOW_EMPTY TRUE)

# Only compile if CONFIG_GPIO_BUTTON is enabled
zephyr_library_sources_ifdef(CONFIG_GPIO_BUTTON gpio_button.c)
