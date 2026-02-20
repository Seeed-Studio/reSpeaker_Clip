# SPDX-License-Identifier: Apache-2.0

cmake_minimum_required(VERSION 3.20)

find_package(Zephyr REQUIRED HINTS $ENV{ZEPHYR_BASE})
project(clip_recorder)

# Include directories
target_include_directories(app PRIVATE include)

# Source files
target_sources(app PRIVATE
    src/main.c
    src/ble_svc.c
    src/at_cmd.c
    src/state_machine.c
    src/config.c
    src/json_helper.c
    src/audio.c
    src/storage.c
    src/button_handler.c
)
