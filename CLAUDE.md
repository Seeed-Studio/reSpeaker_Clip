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

Set the `ZEPHYR_EXTRA_MODULES` environment variable to enable Kconfig to discover custom modules (board, lib, drivers). This must be an environment variable, not a CMake parameter, because Kconfig module discovery happens before CMake configuration.

### Building the Main Application

```sh
# Set environment (once per terminal session)
source ~/ncs/v3.2.1/zephyr/zephyr-env.sh
export ZEPHYR_EXTRA_MODULES=$(pwd)

# Build main application
west build --build-dir build-clip --board clip/nrf5340/cpuapp applications/clip

# Clean build
west build --build-dir build-clip --pristine --board clip/nrf5340/cpuapp applications/clip
```

### Building Sample Applications

```sh
# Build a sample
west build --build-dir build --board clip/nrf5340/cpuapp samples/hello_world
```

### Build Parameters

| Parameter | Purpose |
|-----------|---------|
| `export ZEPHYR_EXTRA_MODULES=$(pwd)` | Enables Kconfig to discover custom modules |
| `--board clip/nrf5340/cpuapp` | Board identifier (NOT `respeaker/...`) |

**Note**: The `zephyr/module.yml` already configures `board_root` and `dts_root`.

### Flash to device

**IMPORTANT**: This board requires a reset after flashing. Use `nrfutil device reset`:

```sh
# Flash and reset in one command
west flash --build-dir build-clip && nrfutil device reset
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
   west build --build-dir build-clip --board clip/nrf5340/cpuapp applications/clip
   ```

4. **Flash and reset**:
   ```sh
   west flash --build-dir build-clip && nrfutil device reset
   ```

5. **Test and verify**

6. **Repeat from step 2**

### Common Development Commands

```sh
# Incremental build (faster)
west build --build-dir build-clip

# Clean build
west build --build-dir build-clip --pristine --board clip/nrf5340/cpuapp applications/clip

# Flash only (no reset)
west flash --build-dir build-clip

# Reset only
nrfutil device reset

# Flash and reset in one command
west flash --build-dir build-clip && nrfutil device reset

# View serial output
minicom -D /dev/ttyACM0 -b 115200
# or
screen /dev/ttyACM0 115200
```

## Testing

### Hardware Tests (Zephyr sysbuild)

The project includes a multi-image test suite using Zephyr's sysbuild framework:

```sh
# Build and run tests
west build --build-dir build-test --board clip/nrf5340/cpuapp --pristine tests/clip
west flash --build-dir build-test && nrfutil device reset
```

Test coverage includes BLE, WiFi, button input, SD card, and microphone functionality.

### BLE Protocol Tests (Python)

Use the Python test script for BLE AT command protocol testing:

```sh
# Install dependencies
pip install -r tests/requirements.txt

# Run automated tests
python tests/ble_test.py

# Interactive mode for manual testing
python tests/ble_test.py --interactive

# Test specific device
python tests/ble_test.py --device AA:BB:CC:DD:EE:FF
```

## Documentation

- `docs/protocol.md` - Complete BLE AT command protocol specification (command reference, response formats, error codes, state machines)
- `docs/architecture.md` - System architecture design (layered architecture, module decomposition, data flow, thread architecture)
- `docs/requirements.md` - Product requirements document
- `docs/development.md` - Development log with implementation progress and notes

## Main Application Architecture

The main application (`applications/clip/`) implements a BLE audio recording device with AT command control:

**Core Modules:**
- `ble_svc.c` - BLE GATT service with AT command protocol
- `at_cmd.c` - AT command parser and handlers (GSTAT, VERSION, START, STOP, MARK, BITRATE, MODE, DOWNLOAD, etc.)
- `state_machine.c` - Device state management (IDLE, RECORDING, TRANSMITTING, PAUSED, ERROR)
- `config.c` - NVS-based persistent configuration

**Audio Pipeline:**
- `audio.c` - PDM microphone capture, Opus encoding, SpeexDSP preprocessing
- Audio modes: mono (L channel), merge (L+R mixed), stereo

**Storage & Transfer:**
- `storage.c` - SD card file management (FAT filesystem)
- `transfer.c` - BLE file transfer with pause/resume/cancel support
- `bookmarks.c` - Binary bookmark storage (marks.bin format)

**User Interface:**
- `button_handler.c` - Button input with multi-press support
- `display_ctrl.c` - Display control
- `battery.c` - Battery monitoring via NPM1300 PMIC

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
- `applications/clip/` - Main application (BLE recording with AT command protocol)
  - `src/` - Source files: main.c, ble_svc.c, at_cmd.c, audio.c, storage.c, transfer.c, bookmarks.c, battery.c, button_handler.c, display_ctrl.c, state_machine.c, config.c, json_helper.c
  - `include/` - Headers for each module
  - `prj.conf` - Application-specific Kconfig
- `samples/` - Example applications (hello_world, button_demo, lua_repl, opus_encode, t5838)
- `drivers/` - Custom device drivers (input)
- `lib/` - Third-party libraries (opus, speexdsp, lua)
- `dts/` - Additional device tree overlays
- `tests/clip/` - Multi-image test suite (BLE, WiFi, button, SD card, microphone)
- `tests/ble_test.py` - Python BLE protocol test script
- `docs/` - Protocol specification (`protocol.md`), architecture (`architecture.md`), requirements (`requirements.md`), development log (`development.md`)

## Adding New Code

**Custom Drivers**: Add to `drivers/` subdirectory, update `drivers/CMakeLists.txt` and `drivers/Kconfig`

**Custom Libraries**: Add to `lib/` subdirectory, update `lib/CMakeLists.txt` and `lib/Kconfig`

**Applications**: Place main application code in `applications/` or create new samples

## Zephyr Module Configuration

This repository is configured as a Zephyr module via `zephyr/module.yml`. When used as a module in another project, the board definitions and custom libraries/drivers are automatically available.
