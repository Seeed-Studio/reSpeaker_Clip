# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

ReSpeaker Clip is a Zephyr RTOS firmware project for the Seeed ReSpeaker Clip board, based on the Nordic nRF5340 dual-core MCU. It is designed for voice recognition, audio processing, and embedded IoT applications.

- **RTOS**: Zephyr RTOS v3.2.1 (via Nordic nRF Connect SDK)
- **Hardware**: nRF5340 (dual-core: Application core + Network core)
- **Key Features**: PDM microphone array, OLED display (CH1115), SD card, WiFi (nRF7002), external SPI flash, haptic motor

## Environment Setup

Before building, activate the Zephyr/NCS environment:
```sh
source ~/ncs/v3.2.1/zephyr/zephyr-env.sh
```

## Building

To properly load custom board definitions, libraries, and drivers, use `ZEPHYR_EXTRA_MODULES` environment variable.

### Method 1: Using the build script (Recommended)

```sh
./build.sh samples/hello_world
```

### Method 2: Using environment variables

Set environment variable once per terminal session:

```sh
# Set module path
export ZEPHYR_EXTRA_MODULES=$(pwd)

# Build
source ~/ncs/v3.2.1/zephyr/zephyr-env.sh
west build --build-dir build --pristine --board clip/nrf5340/cpuapp samples/hello_world
```

### Build Parameters

| Method | Purpose |
|--------|---------|
| `export ZEPHYR_EXTRA_MODULES` | **Environment variable** - enables Kconfig to discover custom modules (board, lib, drivers) |

**Note**: The `zephyr/module.yml` already configures `board_root` and `dts_root`, so only `ZEPHYR_EXTRA_MODULES` environment variable is needed. It must be set as environment variable (not `-DZEPHYR_EXTRA_MODULES`) because Kconfig module discovery happens before CMake.

**Board Name**: The correct board identifier is `clip/nrf5340/cpuapp` (not `respeaker/nrf5340/cpuapp`).

### Flash to device

**IMPORTANT**: This board requires a reset after flashing. Use `nrfutil device reset`:

```sh
# Flash and reset in one command
west flash && nrfutil device reset
```

**Note**: `west flash --reset` does NOT work on this board. Use `nrfutil device reset` which communicates via USB/serial with the bootloader.

## Development Workflow

When writing code, building, flashing, and testing:

1. **Set environment** (once per terminal session):
   ```sh
   source ~/ncs/v3.2.1/zephyr/zephyr-env.sh
   export ZEPHYR_EXTRA_MODULES=$(pwd)
   ```

2. **Make code changes**

3. **Build**:
   ```sh
   west build --build-dir build --board clip/nrf5340/cpuapp samples/<app_name>
   ```

4. **Flash and reset**:
   ```sh
   west flash && nrfutil device reset
   ```

5. **Test and verify**

6. **Repeat from step 2**

### Common Development Commands

```sh
# Incremental build (faster)
west build

# Clean build
west build --pristine

# Flash only (no reset)
west flash

# Reset only
nrfutil device reset

# View serial output
minicom -D /dev/ttyACM0 -b 115200
# or
screen /dev/ttyACM0 115200
```

## Testing

The project includes a multi-image test suite using Zephyr's sysbuild framework:

```sh
# Build and run tests
west build --build-dir build-test --board clip/nrf5340/cpuapp --pristine tests/clip
west flash --build-dir build-test && nrfutil device reset
```

Test coverage includes BLE, WiFi, button input, SD card, and microphone functionality.

## Architecture

### Board Variants

The board supports three configurations:
- `clip/nrf5340/cpuapp` - Secure firmware (application core)
- `clip/nrf5340/cpuapp_ns` - Non-secure firmware (application core)
- `clip/nrf5340/cpunet` - Network core firmware

### Memory Layout

The nRF5340 uses ARM TrustZone-M with partitioned memory:
- **Flash**: MCUboot (64K), Secure image (256K), Non-secure image (192K), with fallback slots
- **SRAM**: Secure (256K), Non-secure (192K), Shared (64KB for IPC)

See `clip-cpuapp_partitioning.dtsi` and `clip-shared_sram.dtsi` for details.

### Hardware Interfaces

Device tree configuration in `boards/seeed/clip/clip_nrf5340_cpuapp.dts`:

- **PDM0**: Microphone array interface (alias: `dmic0`)
- **I2C1**: Nordic NPM1300 PMIC at address 0x6b
  - Provides 5 GPIOs, battery charging, and power regulators
- **I2C2**: CH1115 OLED display at address 0x3c (88x48, reset: gpio1.9)
- **SPI3**: External SPI flash PY25Q64H (CS: gpio0.20, 64MB)
- **SPI4**: SD card via SDHC-SPI (CS: gpio0.9)
- **QSPI**: nRF7002 WiFi module
- **GPIO1.15**: User button (with pull-up, active-low, multi-level long-press and double-click support)

### Power Management

The board uses Nordic NPM1300 PMIC for advanced power management:

**PMIC Regulators (I2C1 @ 0x6b)**:
- **BUCK1**: MOTOR_3V3 (3.3V) - Vibration motor power, controlled via PMIC GPIO2
- **BUCK2**: VDD_3V3 (3.3V) - Main system power, always-on
- **LDO1**: VDDMIC_1V8 (1.8V) - Microphone power
- **LDO2**: VDD_SD (3.3V) - SD card power

**GPIO-controlled Regulators**:
- `mic_vdd` - Microphone power enable (gpio1.14)
- `oled_vdd` - OLED display power enable (gpio1.8)
- `rfsw_vdd` - WiFi RF switch power (gpio0.29)

### External Flash Partitions

The 64MB external SPI flash (PY25Q64H) is partitioned:
- `ext-nvs` (0x0-0xFFFF): 64KB NVS storage for key-value data
- `ext-storage` (0x10000-end): 15MB general user storage (rest of 64MB available for future use)

## Custom Drivers and Libraries

### Custom Drivers (`drivers/`)

- **Input Driver** (`input/`): GPIO button driver with multi-level long press and double-click support
  - Enable with Kconfig `CONFIG_INPUT_CLIP`
  - Provides advanced button event handling beyond basic GPIO

### Third-Party Libraries (`lib/`)

- **Opus Codec** (`opus/`): Audio compression library
  - Enable with Kconfig `CONFIG_OPUS_EMBEDDED`
- **SpeexDSP** (`speexdsp/`): Audio processing library
  - Enable with Kconfig `CONFIG_SPEEXDSP`
- **Lua 5.5.0** (`lua/`): Scripting language with REPL
  - Enable with Kconfig `CONFIG_LUA`
  - Includes custom print function for Zephyr logging

### Enabling Custom Components

To use custom drivers or libraries in your application, add to your `prj.conf`:

```sh
# Enable custom input driver
CONFIG_INPUT_CLIP=y

# Enable Opus codec
CONFIG_OPUS_EMBEDDED=y

# Enable Lua
CONFIG_LUA=y
```

## Project Structure

- `boards/seeed/clip/` - Board Support Package (device trees, Kconfig, CMake)
- `samples/` - Example applications
- `applications/` - Main application code (currently empty)
- `drivers/` - Custom device drivers (input, display)
- `lib/` - Third-party libraries (opus, speexdsp, lua)
- `dts/` - Additional device tree overlays
- `tests/clip/` - Multi-image test suite

## Adding New Code

**Custom Drivers**: Add to `drivers/` subdirectory, update `drivers/CMakeLists.txt` and `drivers/Kconfig`

**Custom Libraries**: Add to `lib/` subdirectory, update `lib/CMakeLists.txt` and `lib/Kconfig`

**Applications**: Place main application code in `applications/` or create new samples

## Zephyr Module Configuration

This repository is configured as a Zephyr module via `zephyr/module.yml`. When used as a module in another project, the board definitions and custom libraries/drivers are automatically available.
