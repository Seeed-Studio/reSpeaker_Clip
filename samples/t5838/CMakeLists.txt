# SPDX-License-Identifier: Apache-2.0

cmake_minimum_required(VERSION 3.20.0)


find_package(Zephyr REQUIRED HINTS $ENV{ZEPHYR_BASE})
include(${CMAKE_CURRENT_LIST_DIR}/../../CMakeLists.txt)
project(t5838)

target_sources(app PRIVATE src/main.c)
