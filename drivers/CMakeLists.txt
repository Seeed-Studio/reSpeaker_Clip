# SPDX-License-Identifier: Apache-2.0

# ReSpeaker Lav custom drivers CMakeLists.txt

# Add input driver
add_subdirectory_ifdef(CONFIG_GPIO_BUTTON input)

# Add display driver
add_subdirectory_ifdef(CONFIG_OLED_DISPLAY display)
