# Battery Cycle Test

Battery charge/discharge cycle test firmware for the reSpeaker Clip board.
Ported from the `re-discharge` branch's `tests/re`; runs an endless
discharge→charge cycle to characterize the "240" cell (HSZ 362123).

## Building

```bash
# Set environment (NCS v3.3.0)
source ~/ncs/v3.3.0/zephyr/zephyr-env.sh
export ZEPHYR_EXTRA_MODULES=$(pwd)

west build --build-dir build-battery-cycle --pristine --board clip/nrf5340/cpuapp tests/battery_cycle

# Flash and reset
west flash --build-dir build-battery-cycle && nrfutil device reset
```

> **No MCUboot**: `sysbuild.conf` sets `SB_CONFIG_BOOTLOADER_NONE=y`
> (plus `SB_CONFIG_PARTITION_MANAGER=n` so the image links at 0x0) — this is
> factory test firmware flashed directly via J-Link. The sysbuild also enables
> WiFi nRF70 (the discharge TX load) and the net-core BLE HCI IPC.

## Serial Configuration

- **Baud Rate**: 921600
- **Connect**: `minicom -D /dev/ttyACM0 -b 921600`

## What It Does

`src/main.c` initializes every peripheral (button, SD card, mic, OLED, PMIC,
motor, WiFi, BLE), then calls `discharge_run()` (`src/discharge.c`) — an
infinite voltage-hysteresis cycle:

- **DISCHARGE**: charger off, WiFi AP up with a continuous UDP TX load
  (`wifi_discharge_start()`) plus a continuous SD read load
  (`sdcard_discharge_load_enable()` — reads a 1 MB write-once
  `/SD:/discharge.bin`)
- Switches to **CHARGE** when the cell sinks to **3.5 V**
- Switches back to **DISCHARGE** when the cell rises to **4.12 V**

The state machine polls the NPM1300 every 1 s and keeps the OLED updated with
% (nRF Fuel Gauge, model in `src/battery_model.inc`), state, and voltage.
Charging is software-inhibited at ≥45 °C and resumes below 40 °C (matches the
clip app's thermal hysteresis).

Other behavior:

- **BLE**: advertises as `Clip_Test` (GATT notify service, MTU 247)
- **Button**: double-click enters NPM1300 ship mode (power off)
- A serial shell is available (Zephyr shell over UART)

## Expected Output

```
=== Battery Cycle Test ===
Battery charge/discharge cycle test
...
[WiFi] AP started: SSID=... ch=... IP=192.168.4.1
All peripherals initialized
Starting battery discharge/charge cycle test...

=== Battery discharge/charge cycle test ===
Discharging to 3500 mV, then charging to 4120 mV, repeat.
```

Then log lines on each threshold crossing, e.g.
`cycle 1: 4120 mV reached -> DISCHARGE` / `cycle 1: 3500 mV reached -> CHARGE`,
plus thermal gating messages (`Thermal: charge off/resume ...`). The OLED
shows the live state, %, voltage, temperature, and completed cycle count.
