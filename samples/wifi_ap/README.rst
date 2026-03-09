WiFi Sample
##############

.. contents::
   :local:
   :depth: 2

Overview
========

This sample demonstrates how to use the nRF7002 WiFi chip on the
ReSpeaker Clip board to scan for and connect to WiFi networks.

Features
========

- WiFi network scanning
- Display network information (SSID, RSSI, channel, security)
- Connection status monitoring
- Shell commands for WiFi control

Requirements
============

- ReSpeaker Clip board with nRF5340 and nRF7002
- WiFi access point in range

Building and Flashing
=====================

.. code-block:: bash

   # Set environment
   source ~/ncs/v3.2.1/zephyr/zephyr-env.sh
   export ZEPHYR_EXTRA_MODULES=$(pwd)

   # Build
   west build --build-dir build-wifi --board clip/nrf5340/cpuapp samples/wifi_ap

   # Flash and reset
   west flash --build-dir build-wifi && nrfutil device reset

Usage
=====

The sample runs automatically and performs an initial WiFi scan on startup.

Shell Commands
--------------

Connect via serial console (115200 baud) to use WiFi commands:

.. code-block:: console

   # Scan for networks
   wifi scan

   # Show connection status
   wifi status

   # Connect to a network (SSID with spaces need quotes)
   wifi connect "MyNetwork" password123

   # Disconnect
   wifi disconnect

Serial Output Example
=====================

.. code-block:: console

   *** Booting Zephyr OS build v3.2.1-ncs1 ***
   ReSpeaker Clip WiFi Sample
   ============================
   Scanning for networks...
   [1] HomeNetwork (RSSI: -45, Ch: 6)
   [2] GuestWiFi (RSSI: -60, Ch: 11)
   [3) Office_5G (RSSI: -72, Ch: 36)
   Scan complete: found 3 networks

   Found 3 networks

   WiFi shell commands available:
     wifi scan    - Scan for networks
     wifi status  - Show connection status

Troubleshooting
===============

No networks found
----------------
- Check that nRF7002 is properly powered
- Verify antenna is connected
- Try moving closer to WiFi router

Scan fails
----------
- Check serial output for error messages
- Verify QSPI pins are correctly configured
- Ensure WiFi chip is not in sleep mode

Cannot connect
-------------
- Verify SSID and password are correct
- Check that the network supports 2.4GHz (nRF7002 is 2.4GHz only)
- Try connecting with a phone to verify network availability
