# RE Test Firmware

Reference-board bring-up / peripheral reliability test for the reSpeaker
Clip board. An infinite loop exercises every peripheral each round and keeps
running pass/fail totals, so a board can soak-test overnight.

## Building

```bash
# Set environment (NCS v3.3.0)
source ~/ncs/v3.3.0/zephyr/zephyr-env.sh
export ZEPHYR_EXTRA_MODULES=$(pwd)

west build --build-dir build-re --pristine --board clip/nrf5340/cpuapp tests/re

# Flash and reset
west flash --build-dir build-re && nrfutil device reset
```

> **MCUboot build** (default): inherits the board sysbuild defaults — signed
> dual-image MCUboot + NETCORE ipc_radio — the same bootloader as the
> application firmware. Flash `build-re/merged.hex` via J-Link once
> (`nrfutil device program --firmware build-re/merged.hex --serial-number <SN>`),
> then upgrade over USB serial DFU: hold the button while plugging USB
> (VBUS-gated; enumerates as PID `8069` "reSpeaker Clip DFU") and
> `nrfutil mcu-manager serial image-upload --firmware build-re/re/zephyr/zephyr.signed.bin --serial-port /dev/ttyACMx`.
> Note `west flash` programs the unsigned default app image — slot 0 then
> fails MCUboot's signature check; program `merged.hex` instead.
> The old no-bootloader J-Link-direct variant is kept as commented lines in
> `sysbuild.conf`.

## Serial Configuration

- **Baud Rate**: 921600
- **Connect**: `minicom -D /dev/ttyACM0 -b 921600`

## What It Tests

`src/main.c` initializes all peripherals (button, SD card, mic, OLED, PMIC,
motor, WiFi AP, BLE), then `re_test_loop()` (`src/re_test.c`) runs the test
list in an infinite loop:

- SD Card — mount / file I/O
- Flash — external SPI flash
- OLED — CH1115 display
- Motor — haptic motor
- PMIC — NPM1300 battery/charger read
- MIC — PDM microphone capture
- WiFi AP — nRF7002 AP bring-up
- BLE — advertising/connectivity

Each round prints a per-test PASS/FAIL summary and running totals:

```
=== RE Test Round #1 ===
  SD Card    : PASS
  Flash      : PASS
  ...
--- Round #1 done ---
Running totals: 8 pass, 0 fail, 1 rounds
```

- **BLE**: advertises as `Clip_Test`
- **Button**: double-click enters NPM1300 ship mode
- A serial shell is enabled (file system, flash, regulator, GPIO, I2C shells)
