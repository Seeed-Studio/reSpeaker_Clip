# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commit Rules

- Do not add `Co-Authored-By` lines to commit messages.
- Code must compile with zero warnings. Fix all compiler warnings before committing.

## Project Overview

ReSpeaker Clip is a Zephyr RTOS firmware project for the Seeed ReSpeaker Clip board, based on the Nordic nRF5340 dual-core MCU. It is a voice recording device with BLE and WiFi AP connectivity, AT command control, and UDP file transfer.

- **RTOS**: Zephyr RTOS v3.2.1 (via Nordic nRF Connect SDK) — `main` branch
- **RTOS**: Zephyr RTOS v3.3.0 (via Nordic nRF Connect SDK) — `ncs/v3.3.0` branch
- **Hardware**: nRF5340 (dual-core: Application core + Network core)
- **Key Features**: PDM microphone array, OLED display (CH1115), SD card, WiFi (nRF7002), external SPI flash, haptic motor, battery monitoring

## Environment Setup

**main branch (v3.2.1):**
```sh
source ~/ncs/v3.2.1/zephyr/zephyr-env.sh
export ZEPHYR_EXTRA_MODULES=$(pwd)
```

**ncs/v3.3.0 branch:**
```sh
source ~/ncs/v3.3.0/zephyr/zephyr-env.sh
export ZEPHYR_EXTRA_MODULES=$(pwd)
```
source ~/ncs/v3.2.1/zephyr/zephyr-env.sh
export ZEPHYR_EXTRA_MODULES=$(pwd)
```

`ZEPHYR_EXTRA_MODULES` must be an environment variable (not CMake), because Kconfig module discovery happens before CMake configuration.

## Building & Flashing

```sh
# Build (incremental)
west build --build-dir build-clip --board clip/nrf5340/cpuapp applications/clip

# Build (clean)
west build --build-dir build-clip --pristine --board clip/nrf5340/cpuapp applications/clip

# Flash and reset (required: west flash --reset does NOT work on this board)
west flash --build-dir build-clip && nrfutil device reset

# View serial output
minicom -D /dev/ttyACM0 -b 115200
```

**Board identifier**: `clip/nrf5340/cpuapp` (NOT `respeaker/...`)

### Power Management

`CONFIG_PM_DEVICE_RUNTIME=y` enables automatic peripheral power management. UART, I2C, SPI drivers automatically suspend when idle and resume on access. No separate production snippet needed — the debug console is retained without power penalty since UART auto-suspends between log outputs.

`CONFIG_NRF70_QSPI_LOW_POWER=y` puts QSPI in low power when WiFi is not in use.

BLE slow advertising (1s interval) adds ~0.1mA averaged to idle current.

### Build Snippets

Snippets are in `applications/clip/snippets/`. Each snippet has a conf file, optional overlay, and `snippet.yml`.

| Snippet | Purpose | Changes |
|---------|---------|---------|
| `production` | Production firmware (legacy) | Disables debug UART and console |

Note: With `PM_DEVICE_RUNTIME`, the production snippet is no longer necessary for power savings.

Build with snippet: `west build ... -- -DSNIPPET_ROOT=applications/clip -DSNIPPET=<name>`

### Output Firmware

```sh
VERSION=$(grep APP_VERSION_STRING build-clip/clip/zephyr/include/generated/zephyr/app_version.h | cut -d'"' -f2)
mkdir -p output/$VERSION

cp build-clip/merged.hex output/$VERSION/
cp build-clip/merged_CPUNET.hex output/$VERSION/
cp build-clip/dfu_application.zip output/$VERSION/clip-$VERSION-ota.zip
```

## Testing

### Python Tools

```sh
# Install dependencies
pip install -r applications/clip/tests/requirements.txt

# UDP file sync (WiFi AP mode)
python applications/clip/tests/tools/udp_sync.py --session <session_id>
python applications/clip/tests/tools/udp_sync.py --all-sessions

# Recording tool
python applications/clip/tests/tools/record.py

# UDP terminal
python applications/clip/tests/tools/udp_terminal.py
```

WiFi AP: SSID `ClipAP_XXXX` (last 4 hex of chip ID), Password `12345678`, IP `192.168.4.1`, UDP Port `8089`

### BLE Protocol Tests

```sh
python tests/ble_test.py
python tests/ble_test.py --interactive
python tests/ble_test.py --device AA:BB:CC:DD:EE:FF
```

### Hardware Tests (Zephyr sysbuild)

```sh
west build --build-dir build-test --board clip/nrf5340/cpuapp --pristine tests/clip
west flash --build-dir build-test && nrfutil device reset
```

### nRF70 OTP Programming (Factory Tool)

```sh
west build --build-dir build-otp --board clip/nrf5340/cpuapp --pristine tests/otp
west flash --build-dir build-otp && nrfutil device reset
```

Shell commands: `nrf70 otp status/read/write_mac0/write_mac1/lock`

See `tests/otp/README.md` for full usage.

### Crystal Capacitance Tuning (tests/clip)

The board has no external load capacitors for LFXO/HFXO. Internal capacitors must be enabled via registers. Use the test firmware shell commands to tune:

```
lfxo get                — Read 32.768kHz crystal capacitance
lfxo set <0-3>          — Set (0=external, 1=6pF, 2=7pF, 3=9pF)
hfxo get                — Read 32MHz crystal capacitance
hfxo set <pF>           — Set in pF (7.0-20.0, step 0.5, 0=external)
```

After finding optimal values, configure in device tree:
```dts
&lfxo {
    load-capacitors = "internal";
    load-capacitance-picofarad = <7>;
};
&hfxo {
    load-capacitors = "internal";
    load-capacitance-picofarad = <9>;
};
```

## Documentation

- `docs/protocol.md` - BLE AT command protocol specification
- `docs/udp_protocol.md` - UDP file transfer protocol
- `docs/architecture.md` - System architecture design
- `docs/requirements.md` - Product requirements
- `docs/development.md` - Development log

## Application Architecture

The application (`applications/clip/`) uses an event-driven architecture with dual transport support (BLE + WiFi UDP).

### Event System

Central event dispatcher (`clip_event.c`) with async (non-blocking, from button ISRs) and sync (blocking, from AT commands) posting. Events: START, STOP, PAUSE, RESUME, MARK, WIFI_ON, WIFI_OFF, etc.

### States

UNINITIALIZED → IDLE → RECORDING → TRANSMITTING / WIFI_SYNC → IDLE. Also PAUSED, ERROR, OTA.

### Transport Abstraction

`transport.c` provides a unified interface over BLE (`transport_ble.c`) and UDP (`transport_udp.c`). Auto-selects active transport (BLE priority over UDP). Max 512 bytes per packet. Separate send vs send_file_data (BLE uses FILE_DATA characteristic).

### AT Commands

All commands return JSON responses. Key commands:
- `AT+RECORD` / `AT+STOP` - Recording control
- `AT+LIST` / `AT+LIST?page&per_page` - Session listing (sorted newest-first)
- `AT+DOWNLOAD=<session_id>` - Start file transfer
- `AT+CANCEL` - Cancel transfer (thread-safe via volatile flag)
- `AT+DELETE=<session_id>` / `AT+PURGE` - Session management
- `AT+MODE`, `AT+NOISE`, `AT+DEREVERB`, `AT+AUTODEL`, `AT+BRIGHTNESS` - Configuration
- `AT+WIFI=on|off` - WiFi AP control
- `AT+TIME=<timestamp>` - Time sync
- `AT+MARKS=<session_id>` - Bookmark management

### Audio Pipeline

`audio.c`: PDM microphone → SpeexDSP preprocessing (noise suppression, AGC, dereverb) → Opus encoding. Modes: mono (L), merge (L+R), stereo. Enhanced mode uses higher bitrate.

### Storage & Transfer

- `storage.c` - FAT filesystem on SD card, session management (session.json per session), file numbering (0001.opus, 0002.opus...)
- `transfer.c` - File transfer engine with pause/resume/cancel. Runs on dedicated thread. Cancel is thread-safe via volatile flag checked in transfer loop.
- `bookmarks.c` - Binary bookmark storage (marks.bin)

### UDP File Transfer Protocol

Binary frame protocol with per-file CRC32 verification:
- Frame types: DATA (0x01), FILE_ACK (0x03), FILE_START (0x10), FILE_END (0x11), TRANSFER_DONE (0x12), AT_RESP (0x20), HEARTBEAT (0x30)
- FILE_DATA: type(1) + seq(2) + length(2) + data(variable)
- FILE_ACK: type(1) + status(1) + received_count(2) + crc32(4)

### Display & UI

- `display.c` - CH1115 OLED (88x48) with custom icon rendering
- `icons.c` - XBM-format display icons
- `button.c` - Multi-press, long-press support via custom input driver
- `haptic.c` - Vibration motor feedback via PMIC GPIO
- `battery.c` - NPM1300 PMIC battery monitoring + nRF Fuel Gauge

## Known Pitfalls

- **`%llu` not supported**: Zephyr's minimal printf on nRF5340 outputs `"lu"` literally. Use `%u` with `(unsigned int)` cast for 64-bit values.
- **UDP `sendto()` reliability**: Returns success even when WiFi TX queue silently drops packets. CRC is only updated after confirmed send. File-level retry handles lost data.
- **`except Exception` doesn't catch `KeyboardInterrupt`**: It's a `BaseException`, not `Exception`. Use bare `except:` or handle it explicitly.
- **FAT directory order**: Not chronological. Session listing uses a cached sorted buffer invalidated on mutations.
- **Transfer thread safety**: AT commands and transfer run on different threads. Use volatile flags for coordination (e.g., `transfer_cancel_requested`).

## MCUboot Patch Development

MCUboot source is in the NCS tree (`~/ncs/<version>/bootloader/mcuboot`). Patches are stored in `patches/mcuboot/`. The workflow is: **modify source → build → verify → export patches**. Patches apply to both v3.2.1 and v3.3.0.

### Step 1: Modify MCUboot source directly

```sh
# Edit files in the NCS tree (use ~/ncs/v3.2.1/ or ~/ncs/v3.3.0/)
vim ~/ncs/v3.2.1/bootloader/mcuboot/boot/zephyr/main.c
vim ~/ncs/v3.2.1/bootloader/mcuboot/boot/zephyr/io_display.c
vim ~/ncs/v3.2.1/bootloader/mcuboot/boot/boot_serial/src/boot_serial.c
vim ~/ncs/v3.2.1/bootloader/mcuboot/boot/bootutil/src/loader.c
```

### Step 2: Build (must be pristine for mcuboot changes)

```sh
west build --build-dir build-clip --pristine --board clip/nrf5340/cpuapp applications/clip
```

### Step 3: Verify and test

```sh
# Flash both mcuboot + app
west flash --build-dir build-clip && nrfutil device reset

# Or export for OTA test
cp build-clip/dfu_application.zip output/
```

### Step 4: Export patches from modified source

```sh
cd ~/ncs/v3.2.1/bootloader/mcuboot

# For existing tracked files (main.c, Kconfig, CMakeLists, etc.)
git diff boot/zephyr/main.c > /path/to/ReSpeaker_Clip/patches/mcuboot/XXXX.patch

# For new files (io_display.c), use sed to prefix '+'
{ echo "diff --git a/boot/zephyr/io_display.c b/boot/zephyr/io_display.c"
  echo "new file mode 100644"
  echo "--- /dev/null"
  echo "+++ b/boot/zephyr/io_display.c"
  printf "@@ -0,0 +1,%d @@\n" $(wc -l < boot/zephyr/io_display.c)
  sed 's/^/+/' boot/zephyr/io_display.c
} >> /path/to/ReSpeaker_Clip/patches/mcuboot/XXXX.patch

# Multiple file changes can be combined into one patch:
git diff boot/zephyr/CMakeLists.txt boot/zephyr/Kconfig boot/zephyr/main.c >> patch.diff
```

### Step 5: Verify patches apply cleanly

```sh
# Reset mcuboot source to clean state first
cd ~/ncs/v3.2.1/bootloader/mcuboot
git checkout -- .

# Apply patches in order
git apply /path/to/0001-xxx.patch
git apply /path/to/0002-xxx.patch
git apply /path/to/0003-xxx.patch

# Verify and build
west build --build-dir build-clip --pristine --board clip/nrf5340/cpuapp applications/clip
```

### Step 6: Update patches/mcuboot/README.md

Document what each patch does, which files it touches, and any constraints.

## Board & Hardware

### Device Tree (`boards/seeed/clip/clip_nrf5340_cpuapp.dts`)

- **PDM0**: Microphone array (alias: `dmic0`)
- **I2C1**: NPM1300 PMIC at 0x6b (5 GPIOs, battery, regulators)
- **I2C2**: CH1115 OLED at 0x3c (88x48, reset: gpio1.9)
- **SPI3**: External SPI flash PY25Q64H (CS: gpio0.20, 64MB)
- **SPI4**: SD card via SDHC-SPI (CS: gpio0.9)
- **QSPI**: nRF7002 WiFi module
- **GPIO1.15**: User button (pull-up, active-low)

### Power Management

`CONFIG_PM_DEVICE_RUNTIME=y` enables automatic peripheral power management. UART, I2C, SPI drivers automatically suspend when idle and resume on access. No separate production snippet needed — the debug console is retained without power penalty since UART auto-suspends between log outputs.

`CONFIG_NRF70_QSPI_LOW_POWER=y` puts QSPI in low power when WiFi is not in use.

BLE slow advertising (1s interval) adds ~0.1mA averaged to idle current.

### PMIC & Regulators

PMIC regulators (I2C1 @ 0x6b): BUCK1 (motor), BUCK2 (main 3.3V), LDO1 (mic 1.8V), LDO2 (SD 3.3V).
GPIO-controlled: mic_vdd (gpio1.14), oled_vdd (gpio1.8), rfsw_vdd (gpio0.29).

### External Flash Partitions

64MB SPI flash: OTA slot 0 (960KB), OTA slot 1 (256KB), LittleFS (~6.8MB).

## Custom Drivers & Libraries

### Drivers (`drivers/`)

- **Input** (`input/`): GPIO button driver with multi-level long press and double-click. Enable: `CONFIG_INPUT_CLIP=y`

### Libraries (`lib/`)

- **Opus** (`opus/`): Audio compression. Enable: `CONFIG_OPUS_EMBEDDED=y`
- **SpeexDSP** (`speexdsp/`): Audio preprocessing. Enable: `CONFIG_SPEEXDSP=y`
- **Lua 5.5.0** (`lua/`): Scripting with REPL. Enable: `CONFIG_LUA=y`

## Project Structure

- `boards/seeed/clip/` - Board Support Package (device trees, Kconfig, CMake)
- `applications/clip/` - Main application
  - `src/` - main.c, at_commands.c, at_server.c, audio.c, battery.c, ble.c, button.c, clip_event.c, config.c, display.c, haptic.c, icons.c, storage.c, transfer.c, transport.c, transport_ble.c, transport_udp.c, wifi.c, wifi_udp.c
  - `include/` - Headers for each module
  - `tests/clip/` - Python library (wifi.py, codec.py, transfer.py, etc.)
  - `tests/tools/` - Tools: record.py, udp_sync.py, udp_terminal.py, clip-cli.py, clip-web.py
  - `tests/tests/` - Application tests
  - `prj.conf` - Kconfig
- `samples/` - Examples (hello_world, button_demo, lua_repl, opus_encode, t5838)
- `drivers/` - Custom device drivers (input)
- `lib/` - Third-party libraries (opus, speexdsp, lua)
- `tests/clip/` - Multi-image hardware test suite
- `tests/otp/` - nRF70 OTP programming tool (factory MAC address burning)
- `tests/ble_test.py` - BLE protocol test script
- `docs/` - Protocol, architecture, requirements, development docs
