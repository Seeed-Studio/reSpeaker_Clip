#
# Copyright (c) 2022 Nordic Semiconductor ASA
#
# SPDX-License-Identifier: LicenseRef-Nordic-5-Clause
#

cmake_minimum_required(VERSION 3.20.0)

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
	src/imu.c
)





