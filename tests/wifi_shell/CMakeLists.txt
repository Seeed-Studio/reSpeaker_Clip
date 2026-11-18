#
# Copyright (c) 2026 Seeed Studio
#
# SPDX-License-Identifier: LicenseRef-Nordic-5-Clause
#

cmake_minimum_required(VERSION 3.20.0)

find_package(Zephyr REQUIRED HINTS $ENV{ZEPHYR_BASE})
project(nrf_wifi_shell)

# Port of NCS nrf/samples/wifi/shell (the Nordic-documented DUT firmware for
# EN 300 328 / EN 301 893 adaptivity testing, see nrf/doc/nrf/protocols/wifi/
# regulatory_certification/adaptivity_test_procedure.rst). Only main.c is
# compiled — the promiscuous/raw-tx shell add-ons are not needed here.
set(WIFI_SHELL_SRC ${ZEPHYR_NRF_MODULE_DIR}/samples/wifi/shell)

target_sources(app PRIVATE ${WIFI_SHELL_SRC}/src/main.c)
