# SPDX-License-Identifier: Apache-2.0

cmake_minimum_required(VERSION 3.20)

find_package(Zephyr REQUIRED HINTS $ENV{ZEPHYR_BASE})
project(clip)

# Include directories
target_include_directories(app PRIVATE include)

# Source files
target_sources(app PRIVATE
    src/main.c
    src/clip_event.c
    src/config.c
    src/ble.c
    src/transport.c
    src/transport_ble.c
    src/at_server.c
    src/at_commands.c
    src/audio.c
    src/storage.c
    src/transfer.c
    src/rtc_stream.c
    src/haptic.c
    src/button.c
    src/display.c
    src/icons.c
    src/wifi.c
    src/wifi_udp.c
    src/transport_udp.c
    src/battery.c
    src/usb_cdc.c
)
