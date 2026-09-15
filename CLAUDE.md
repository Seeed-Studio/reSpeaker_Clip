# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commit Rules

- Do not add `Co-Authored-By` lines to commit messages.
- Code must compile with zero warnings. Fix all compiler warnings before committing.

## Project Overview

reSpeaker Clip is a Zephyr RTOS firmware project for the Seeed reSpeaker Clip board, based on the Nordic nRF5340 dual-core MCU. It is a voice recording device with BLE, WiFi AP, and USB connectivity, AT command control, and UDP file transfer.

- **RTOS**: Zephyr RTOS v3.3.0 (via Nordic nRF Connect SDK) — active on `main`. v3.2.1 is no longer supported (`main` requires v3.3.0-only Kconfig).
- **Hardware**: nRF5340 (dual-core: Application core + Network core)
- **Key Features**: PDM microphone array, OLED display (CH1115), SD card, WiFi (nRF7002), external SPI flash, haptic motor, battery monitoring (NPM1300 + nRF Fuel Gauge, custom "240"/HSZ 362123 model), USB CDC serial + USB MSC (SD card mass storage)

This repo (`module.yml` → `board_root`/`dts_root`) also carries the lineage of the related **reSpeaker Lav** lavalier product (see the `reSpeaker Lav/` tree, the `240` battery, and DTS comments referencing "Lav"). The Clip is the active target.

## Environment Setup

Active development uses **NCS v3.3.0** (`main` is the active branch):
```sh
source ~/ncs/v3.3.0/zephyr/zephyr-env.sh
export ZEPHYR_EXTRA_MODULES=$(pwd)
```

`ZEPHYR_EXTRA_MODULES` must be an environment variable (not CMake), because Kconfig module discovery happens before CMake configuration.

> **v3.2.1 is dropped.** `main` migrated to v3.3.0-only Kconfig (e.g. the WPA3 `..._WPA3_IMPLEMENTATION_NONE` choice, commit `099f62f`) and will no longer build against NCS v3.2.1. The `ncs/v3.3.0` branch is an older, diverged v3.3.0 line (~12 commits behind `main`); the local `master` is only the ancient initial import.

Every app on this board builds as a Zephyr **sysbuild** (MCUboot + app core + network-core radio) **by default, with no per-app sysbuild config**. The board provides it all:

- `boards/seeed/clip/Kconfig.sysbuild` — auto-sourced by sysbuild (Zephyr `hwm_v2.cmake`). Defaults `BOOTLOADER_MCUBOOT`, overwrite-only mode, dual-image OTA, `NETCORE_IPC_RADIO` (note: a `choice` symbol — set via `choice NETCORE`, not `config ... default y`), `SECURE_BOOT_NETCORE`, and the RSA signing key (`$(ZEPHYR_RESPEAKER_CLIP_MODULE_DIR)/boards/seeed/clip/sysbuild/root-rsa-2048.pem`).
- `sysbuild/CMakeLists.txt` (module root, registered via `sysbuild-cmake:` in `zephyr/module.yml`) — points the `mcuboot` and `ipc_radio` images at the board's shared config as a **fallback** (an app overrides by providing its own `<app>/sysbuild/<image>.{conf,overlay}`).
- `boards/seeed/clip/sysbuild/` — the real shared files: `mcuboot.conf`, `mcuboot.overlay`, `ipc_radio/prj.conf`, `root-rsa-2048.pem`.
- `boards/seeed/clip/pm_static_clip_nrf5340_cpuapp.yml` — auto-discovered by the NCS partition manager.

So a sample is just `CMakeLists.txt` + `prj.conf` + `src/` and still boots under the custom signed MCUboot. See `docs/custom_app_guide.md`. Pattern copied from `xiao_esp32c6`.

## Building & Flashing

```sh
# Build (incremental)
west build --build-dir build-clip --board clip/nrf5340/cpuapp applications/clip

# Build (clean)
west build --build-dir build-clip --pristine --board clip/nrf5340/cpuapp applications/clip

# Flash and reset (required: west flash --reset does NOT work on this board)
west flash --build-dir build-clip && nrfutil device reset

# View serial output
minicom -D /dev/ttyACM0 -b 921600  # Clip UART0 debug console @921600 (board default). When a J-Link probe is also connected, the J-Link takes ttyACM0 and the Clip's UART0 bridge is ttyACM1 — adjust to whichever is the "USB Single Serial" / non-J-Link port.
```

**Board identifier**: `clip/nrf5340/cpuapp` (NOT `respeaker/...`)

### Power Management

`CONFIG_PM_DEVICE_RUNTIME=y` enables automatic peripheral power management (UART/I2C/SPI suspend when idle). The debug UART console leaks ~570µA at idle; the `production` snippet disables it, reaching ~170µA. Full idle power budget, regulator map, and measurement procedure: **docs/power.md** (that file owns the power figures).

### Build Snippets

Snippets are in `applications/clip/snippets/`. Each snippet has a conf file, optional overlay, and `snippet.yml`.

| Snippet | Purpose | Changes |
|---------|---------|---------|
| `production` | Low-power production firmware | Disables UART console + UART log backend (`CONFIG_CONSOLE=n`, `CONFIG_UART_CONSOLE=n`, `CONFIG_LOG_BACKEND_UART=n`); FS log default follows (off). Idle ~170µA vs ~higher for the debug build. |

The default (no-snippet) build is the **debug** image: UART console on, FS log to `/SD:/LOG` at INF level (`CLIP_LOG_FS_DEFAULT_ON` defaults to `LOG_BACKEND_UART`). Use the `production` snippet for battery/production builds where the console leak matters.

Build with snippet: `west build ... -- -DSNIPPET=production` (app-dir snippets are auto-discovered under NCS v3.3.0; no SNIPPET_ROOT needed).

### Output Firmware

Two images per release: **debug** (`build-clip`, console + SD log) and **production** (`build-clip-prod`, `-- -DSNIPPET=production`, console off); 8 artifacts each (merged/CPUNET hex, ota.zip, signed.bin per variant). Version: `applications/clip/VERSION` → `APP_VERSION_STRING`; release.yml derives the release version from the tag itself. Full artifact table, tag+push procedure, manual export block, and botched-release fix: **docs/release_process.md**.

**CI** — `firmware.yml` (push/PR to `main`): west + Zephyr SDK 0.17.0 + NCS v3.3.0, compile check only; SDK/requirements-install gotchas documented in docs/release_process.md ("CI internals" appendix). `mobile-ci.yml` (PR) and `mobile-verify.yml` (push+manual) cover the `mobile/` SDKs. `release.yml` is **tag-triggered**: builds both variants, exports the 8 artifacts, publishes a GitHub Release whose body is `docs/release_notes/vX.Y.Z.md` (must exist before tagging or the job fails).

**To publish a release:** add `docs/release_notes/v$VERSION.md` + bump `applications/clip/VERSION`, commit, then `git tag vX.Y.Z && git push origin vX.Y.Z` — CI builds and creates the GitHub Release with all artifacts.

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

### BLE Testing

```sh
# Interactive BLE AT terminal (auto-discovers the device, or pass an address)
python applications/clip/tests/tools/ble_terminal.py
python applications/clip/tests/tools/ble_terminal.py AA:BB:CC:DD:EE:FF
```

Application-level pytest suite lives in `applications/clip/tests/tests/` (run `pytest` from `applications/clip/tests/`).

### Hardware Tests (Zephyr sysbuild)

```sh
west build --build-dir build-test --board clip/nrf5340/cpuapp --pristine tests/clip
west flash --build-dir build-test && nrfutil device reset
```

### Factory & RF Test Firmware

Each is a standalone sysbuild image under `tests/<name>`, built like the hardware test above (`west build --build-dir build-<name> --pristine --board clip/nrf5340/cpuapp tests/<name>`). **Tests opt out of MCUboot** (factory/cert firmware, flashed directly via J-Link) via a per-test `sysbuild.conf` setting `SB_CONFIG_BOOTLOADER_NONE=y` (+ `SB_CONFIG_SECURE_BOOT_NETCORE=n`, and `SB_CONFIG_NETCORE_NONE=y` for tests that don't need BLE).

| Test | Purpose |
|------|---------|
| `tests/clip` | Multi-image hardware test suite (also hosts the `lfxo`/`hfxo` shell below); per-board unique BLE name + AP SSID `Clip_<6hex>` derived from chip id (FICR), read via the `ident` shell command |
| `tests/dtm` | BLE Direct Test Mode for RF conformance/certification (2-wire UART @19200; cpunet runs DTM, cpuapp bridges IPC→UART) |
| `tests/wifi_radio` | nRF70 WiFi radio test for RF certification (TX/RX, tone, IQ, FICR) |
| `tests/re` | Reference-board bring-up variant |
| `tests/battery_cycle` | Battery cycle-life test image — voltage-hysteresis charge/discharge state machine (3.5V/4.12V), discharging via WiFi TX load, fuel-gauge % + state on OLED, temp-hysteresis charge cutoff |

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
- `docs/audio_quality_standard.md` - Audio recording quality test standard (ASR/transcription target)
- `docs/custom_app_guide.md` - Custom app development guide (build, flash, BLE OTA, USB serial DFU recovery, signing key, MCUboot features)
- `docs/usb_dfu.md` - Firmware upgrade guide (USB serial DFU via mcumgr/nrfutil, BLE OTA, programmer)
- `docs/release_process.md` - Release versions, artifacts, tag+CI procedure, botched-release fix
- `docs/power.md` - Idle power budget and regulator map (owns the power figures)
- `docs/troubleshooting.md` - Symptom→cause→fix table (build, console, runtime, storage, recovery)

## Application Architecture

The application (`applications/clip/`) uses an event-driven architecture with triple transport support (BLE + WiFi UDP + USB CDC). All three are AT-command channels; the active one is auto-selected per response.

### Event System

Central event dispatcher (`clip_event.c`) with async (non-blocking, from button ISRs) and sync (blocking, from AT commands) posting. Events: START, STOP, PAUSE, RESUME, MARK, WIFI_ON, WIFI_OFF, etc.

### States

UNINITIALIZED → IDLE → RECORDING → TRANSMITTING / WIFI_SYNC → IDLE. Also PAUSED, ERROR, OTA.

### Transport Abstraction

`transport.c` provides a unified interface over BLE (`transport_ble.c`), UDP (`transport_udp.c`), and USB CDC (`usb_cdc.c`). Auto-selects active transport (UDP priority over BLE). Max 512 bytes per packet. Separate send vs send_file_data (BLE uses FILE_DATA characteristic). `TRANSPORT_TYPE_USB` carries AT commands over the USB CDC ACM serial port.

### RTC Live Streaming (`rtc_stream.c`)

`AT+START=RTC` runs the mic pipeline without touching the SD card; encoded
Opus frames go to a bounded drop-oldest queue (`CONFIG_CLIP_RTC_QUEUE_FRAMES`
× `CONFIG_CLIP_RTC_FRAME_MAX_BYTES`). `AT+DOWNLOAD=<session>` on the active
RTC session **discards** whatever was queued before it (RTC delivers "now" —
pre-DOWNLOAD audio is never sent) and streams `STREAM_START/DATA/END` frames
(0x13/0x14/0x15) over the BLE FILE_DATA characteristic — BLE only, no UDP.
Backpressure drops frames (never blocks/retries); since `seq` advances only
after a successful BLE send, drops don't create seq jumps — the SDK counts
seq discontinuities as a protocol-drift defense, not a loss metric.
Session auto-aborts 5 s after START without DOWNLOAD, or on BLE disconnect.
AT+PAUSE/RESUME pause/resume the stream (pause discards queued data);
AT+MARK is rejected. The audio `data_callback` hook (audio.c) feeds the
queue from the audio thread — callbacks there must stay O(1).

### USB Interface (`usb_cdc.c`)

The device enumerates over USB (Seeed VID `0x2886`) with two classes:
- **CDC ACM serial** — a third AT-command channel (`TRANSPORT_TYPE_USB`), wired into `at_server` exactly like BLE/UDP.
- **MSC mass storage** — exposes the SD card as a drive (LUN `"SD"`).

It is **VBUS-aware**: auto-disables USB immediately on VBUS removal, and auto-disables after 10 min if USB is enabled but no cable is present (`USB_NO_VBUS_TIMEOUT_MS`). State changes are pushed to the app via `ble_notify_event("usb", ...)`.

### AT Commands

All commands return JSON responses. Key commands:
- `AT+RECORD` / `AT+STOP` - Recording control
- `AT+LIST` / `AT+LIST?page&per_page` - Session listing (sorted newest-first)
- `AT+DOWNLOAD=<session_id>` - Start file transfer
- `AT+CANCEL` - Cancel transfer (thread-safe via volatile flag)
- `AT+DELETE=<session_id>` - Session management
- `AT+MODE`, `AT+NOISE`, `AT+DEREVERB`, `AT+AUTODEL`, `AT+BRIGHTNESS` - Configuration
- `AT+WIFI=on|off` - WiFi AP control
- `AT+LOG=off|info|debug` - SD log backend level (debug default: info); off lets the SD card idle power-gate
- `AT+TIME=<timestamp>` - Time sync
- `AT+MARKS=<session_id>` - Bookmark management

### Audio Pipeline

`audio.c`: PDM microphone → SpeexDSP preprocessing (noise suppression, dereverb — SpeexDSP AGC is NOT available in the FIXED_POINT build) → lightweight custom integer AGC/high-pass (enhanced/merge mode) → Opus encoding. Modes: mono (L), merge (L+R), stereo. Enhanced mode uses higher bitrate.

### Storage & Transfer

- `transfer.c` - File transfer engine with pause/resume/cancel. Runs on dedicated thread. Cancel is thread-safe via volatile flag checked in transfer loop.
- `storage.c` - FAT filesystem on SD card, session management (session.json per session), file numbering (0001.opus, 0002.opus...), binary bookmark storage (marks.bin)

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
- `battery.c` - NPM1300 PMIC battery monitoring + nRF Fuel Gauge (model in `battery_model.inc`). Polls every 60 s. Displayed % is a directionally rate-limited view of the fuel-gauge SoC (`CONFIG_CLIP_BATTERY_DISPLAY_MAX_STEP`, default 3%/poll, 0=raw), persisted across reboot. Charge termination 4.25V. `vbatlow-charge-enable` lets the charger recover a deeply discharged/protected cell. No low-battery auto-shutdown (removed); low battery shows a UI warning only (≤15%).

## Known Pitfalls

Names + one-liners for AI recall; full symptom→cause→fix detail in **docs/troubleshooting.md**:

- **`%llu` not supported**: minimal printf prints `"lu"` — use `%u` + `(unsigned int)` cast. + details: docs/troubleshooting.md
- **UDP `sendto()` silent drops**: returns success even when the WiFi TX queue drops packets; CRC only after confirmed send; file-level retry recovers.
- **`except Exception` misses `KeyboardInterrupt`** (BaseException) — use bare `except:`.
- **FAT directory order** is not chronological — sorted cached listing invalidated on mutations.
- **Transfer thread safety**: coordinate AT vs transfer thread via volatile flags (`transfer_cancel_requested`).
- **Logs persist to SD** (`/SD:/LOG`, rotating 64KiB) — read post-mortem; `LOG_DEFAULT_LEVEL=0` compiles logs out.
- **Corrupt settings boot loop**: corrupt `/lfs/settings/run` blocks `settings_load` ~40s; watchdog (3s) wipes + reboots; manual recovery via MCUboot erase-settings. Reflashing the app does NOT clear it (external flash).
- Build/console pitfalls (ZEPHYR_EXTRA_MODULES must be env var; v3.2.1 unsupported; ttyACM0/ACM1 with J-Link attached, Clip port = USB PID `2886:0069`): docs/troubleshooting.md.

## MCUboot Patch Development

MCUboot source is in the NCS tree (`~/ncs/v3.3.0/bootloader/mcuboot`). Patches are stored in `patches/mcuboot/` and the bootloader image is configured by the board sysbuild files in `boards/seeed/clip/sysbuild/` (`mcuboot.conf`, `mcuboot.overlay`, `ipc_radio/prj.conf`, signing key `root-rsa-2048.pem` — a copy of the mcuboot default key; generate your own for production). See `docs/custom_app_guide.md` for the full custom app / OTA / recovery guide.

The full development workflow (modify NCS-tree source → pristine build → verify on hardware → export patch via `git diff` + the sed trick for new files → verify clean apply on a fresh tree → update the README) lives in **patches/mcuboot/README.md** ("Patch development workflow"). CI applies these patches idempotently (`git apply --check` loop) before building.

### Current patches (`patches/mcuboot/`)

| Patch | Purpose |
|-------|---------|
| `0001-require-vbus-for-gpio-serial-recovery.patch` | Only allow GPIO/serial recovery when VBUS is present |
| `0002-add-oled-display-support.patch` | OLED status UI in the bootloader (new `io_display.c`) |
| `0003-add-serial-upload-progress-hook.patch` | Serial upload progress hook |
| `0004-add-custom-mcumgr-commands.patch` | Custom mcumgr commands (erase SD on-demand LDO2, erase settings 128KB) |
| `0005-add-swap-copy-progress-hook.patch` | Swap/copy progress hook |

See `patches/mcuboot/README.md` for per-patch details.

## Board & Hardware

### Device Tree (`boards/seeed/clip/clip_nrf5340_cpuapp.dts`)

- **PDM0**: Microphone array (alias: `dmic0`)
- **I2C1**: NPM1300 PMIC at 0x6b (5 GPIOs, battery, regulators)
- **I2C2**: CH1115 OLED at 0x3c (88x48, reset: gpio1.9)
- **SPI3**: External SPI flash PY25Q64H (CS: gpio0.20, 8MB), powered by `flash_vdd` (gpio0.27)
- **SPI4**: SD card via SDHC-SPI (CS: gpio0.9)
- **QSPI**: nRF7002 WiFi module
- **USBD**: CDC ACM serial (3rd AT channel) + MSC (SD card mass storage)
- **nrf_radio_coex**: WiFi/BLE PTA coexistence (req/status0/grant/swctrl1 on P0.28/25/31/30)
- **GPIO1.15**: User button (pull-up, active-low)

The DTS is split across includes: `clip-pinctrl.dtsi`, `clip-cpuapp_partitioning.dtsi`, `clip-shared_sram.dtsi`, `nrf70_common.dtsi`, plus `clip_nrf5340_cpunet.dts` (network core) and `_ns.dts` (non-secure/TrustZone). `boot_mode0` (retention register in `gpregret1`, `zephyr,boot-mode`) gates MCUboot serial-recovery entry. Battery profile is the "240" cell (HSZ 362123, 240 mAh).

### Power Management

`CONFIG_PM_DEVICE_RUNTIME=y` (UART/I2C/SPI suspend when idle, resume on access). Debug UART console leaks ~570µA at idle (baud-independent); the `production` snippet disables it → ~170µA. Full idle-power budget (DCDC ~500–600µA saving, SD idle power-gating after 45s, NRF70 QSPI low power, BLE advertising adder), regulator map, and how to measure: **docs/power.md**.

### PMIC & Regulators

PMIC (I2C1 @ 0x6b): BUCK1 (motor), BUCK2 (main 3.3V), LDO1 (mic 1.8V), LDO2 (SD 3.3V); GPIO-controlled mic_vdd (gpio1.14), oled_vdd (gpio1.8), rfsw_vdd (gpio0.29), flash_vdd (gpio0.27). Details: docs/power.md.

### External Flash Partitions

8MB SPI flash: OTA slot 0 (960KB), OTA slot 1 (256KB), LittleFS (~6.8MB).

## Custom Drivers & Libraries

### Drivers (`drivers/`)

- **Input** (`input/`): GPIO button driver with multi-level long press and double-click. Enable: `CONFIG_GPIO_BUTTON=y` (+ `CONFIG_INPUT_GPIO_BUTTON_OWN_THREAD=y`, stack/priority via `CONFIG_INPUT_GPIO_BUTTON_THREAD_*`)

### Libraries (`lib/`)

- **Opus** (`opus/`): Audio compression. Enable: `CONFIG_OPUS_CODEC=y`
- **SpeexDSP** (`speexdsp/`): Audio preprocessing. Enable: `CONFIG_SPEEXDSP=y`
- **Lua 5.5.0** (`lua/`): Scripting with REPL. Enable: `CONFIG_LUA=y`
- **USB DFU trigger** (`clip_usb_dfu/`): Board-level 1200-baud USB CDC reboot-into-MCUboot-recovery trigger. Enable: `CONFIG_CLIP_USB_DFU=y` (plus `CONFIG_CLIP_USB_DFU_DEFAULT_CDC=y` for a minimal auto-enabled CDC ACM)

## Project Structure

- `boards/seeed/clip/` - Board Support Package (device trees, Kconfig, CMake)
- `applications/clip/` - Main application
  - `src/` - main.c, at_commands.c, at_server.c, audio.c, battery.c (+ generated `battery_model.inc`), ble.c, button.c, clip_event.c, config.c, display.c, haptic.c, icons.c, storage.c, transfer.c, transport.c, transport_ble.c, transport_udp.c, usb_cdc.c, wifi.c, wifi_udp.c
  - `include/` - Headers for each module
  - `sysbuild/` - MCUboot + network-core radio sysbuild config
  - `tests/clip/` - Python library (wifi.py, codec.py, transfer.py, etc.)
  - `tests/tools/` - Tools: ble_terminal.py, clip-cli.py, clip-web.py, decode_opus.py, record.py, serial_terminal.py, sync.py, test_cancel_handoff.py, udp_sync.py, udp_terminal.py
  - `tests/tests/` - Application pytest suite (test_basic, test_config, test_edge_cases, test_recording, test_storage, test_transfer, test_unit)
  - `prj.conf` - Kconfig
- `samples/` - Examples (hello_world, button_demo, lua_repl, opus_encode, t5838, http_server, wifi_ap_iperf, wifi_ble_coex, suspend_to_ram)
- `drivers/` - Custom device drivers (input)
- `lib/` - Libraries (opus, speexdsp, lua, clip_usb_dfu)
- `tests/` - Firmware test/bench tools (all opt out of MCUboot — direct J-Link flash): `clip` (HW suite), `battery_cycle` (battery cycle-life), `dtm` (BLE DTM RF cert), `wifi_radio` (nRF70 WiFi RF cert), `re` (reference bring-up)
- `docs/` - Protocol, architecture, requirements, development, audio quality, MCUboot/OTA/DFU docs, release notes (`release_notes/`)
