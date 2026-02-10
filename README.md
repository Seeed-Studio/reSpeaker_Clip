# ReSpeaker Clip Firmware

This is a Zephyr RTOS based firmware project for ReSpeaker Clip. It is designed for voice recognition, audio processing and other embedded applications.

## Overview
- **Platform**: ReSpeaker Clip
- **RTOS**: Zephyr RTOS
- **Purpose**: Audio capture, voice recognition, device control

## Project Structure
- `applications/`: Application source code
- `boards/`: Board support packages (BSP)
- `drivers/`: Custom device drivers
- `dts/`: Device tree source files
- `lib/`: Libraries and utilities
- `samples/`: Example applications
- `scripts/`: Build and utility scripts

## Getting Started

### Prerequisites
- nRF Connect SDK v3.2.1
- Zephyr SDK
- west (Zephyr's meta-tool)
- CMake
- Python 3.10+

### Build Instructions

#### Environment Setup
Activate the NCS/Zephyr environment:
```sh
source ~/ncs/v3.2.1/zephyr/zephyr-env.sh
```

#### Method 1: Using the build script (Recommended)
The project includes a convenience build script that handles all required parameters:
```sh
./build.sh samples/hello_world
```

#### Method 2: Using environment variables
Set environment variable for module discovery:
```sh
# Set module path (run once per terminal session)
export ZEPHYR_EXTRA_MODULES=$(pwd)

# Build
source ~/ncs/v3.2.1/zephyr/zephyr-env.sh
west build --build-dir build --board respeaker/nrf5340/cpuapp samples/hello_world
```

**Important**: `ZEPHYR_EXTRA_MODULES` must be set as an **environment variable**, not as a CMake parameter (`-DZEPHYR_EXTRA_MODULES`). The environment variable is needed for Kconfig module discovery, which happens before CMake configuration.

#### Flash to Device
```sh
west flash
```

### Build Parameters

| Method | Purpose |
|--------|---------|
| `export ZEPHYR_EXTRA_MODULES` | **Environment variable** - enables Kconfig to discover custom modules (board, lib, drivers) |

**Note**: The `zephyr/module.yml` already configures `board_root` and `dts_root`, so only `ZEPHYR_EXTRA_MODULES` environment variable is needed.

## Documentation
- [Zephyr Project Documentation](https://docs.zephyrproject.org/latest/)
- [ReSpeaker Clip Hardware Documentation]

## License
This project is licensed under the Apache 2.0 License.
