#
# Copyright (c) 2022 Nordic Semiconductor ASA
#
# SPDX-License-Identifier: LicenseRef-Nordic-5-Clause
#

cmake_minimum_required(VERSION 3.20.0)

# The test uses the repository's custom gpio-button devicetree binding.
list(APPEND DTS_ROOT ${CMAKE_CURRENT_LIST_DIR}/../..)

find_package(Zephyr REQUIRED HINTS $ENV{ZEPHYR_BASE})
project(clip)

target_sources(app PRIVATE
	src/main.c
	src/ble.c
	src/wifi.c
	src/button.c
	src/sdcard.c
	src/mic.c
	src/oled.c
	src/pmic.c
	src/motor.c
	src/usb.c
	src/identity.c
	src/flash_test.c
	# The test image builds the CH1115 driver directly. CONFIG_OLED_DISPLAY is
	# deliberately disabled in prj.conf to prevent the module from adding the
	# same source a second time.
	${CMAKE_CURRENT_LIST_DIR}/../../drivers/display/ch1115.c
)

