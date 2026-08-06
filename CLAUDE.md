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

`CONFIG_PM_DEVICE_RUNTIME=y` enables automatic peripheral power management. UART, I2C, SPI drivers automatically suspend when idle and resume on access.

**The debug UART console still leaks ~570µA at idle** — the UARTE peripheral stays enabled between log outputs (baud-independent; 115200 and 921600 both leak the same). The `production` snippet disables the console + UART log backend, bringing idle to ~170µA. The debug build (console on) idles higher. This was the single largest idle leak after the regulators and SD card were fixed.

Idle power budget (3V3 rail, v0.0.5): nRF5340 main/radio regulators on **DCDC** (`vregmain`/`vregradio` = `NRF5X_REG_MODE_DCDC`, ~500–600µA vs LDO); SD card **idle power-gated** after `CLIP_SD_IDLE_DELAY_MS` (45s) (unmount → disk deinit → SPI4 runtime-PM suspend → CS parked low → LDO2 off; lazy remount via `storage_ensure_mounted()`); SPI `bias-pull-up` removed from `spi3`/`spi4` (push-pull needs none) with `bias-pull-down` on `spi4_sleep`. Production (console off) reaches ~170µA.

`CONFIG_NRF70_QSPI_LOW_POWER=y` puts QSPI in low power when WiFi is not in use.

BLE slow advertising (~1s interval) adds ~0.1mA averaged to idle current.

### Build Snippets

Snippets are in `applications/clip/snippets/`. Each snippet has a conf file, optional overlay, and `snippet.yml`.

| Snippet | Purpose | Changes |
|---------|---------|---------|
| `production` | Low-power production firmware | Disables UART console + UART log backend (`CONFIG_CONSOLE=n`, `CONFIG_UART_CONSOLE=n`, `CONFIG_LOG_BACKEND_UART=n`); FS log default follows (off). Idle ~170µA vs ~higher for the debug build. |

The default (no-snippet) build is the **debug** image: UART console on, FS log to `/SD:/LOG` at INF level (`CLIP_LOG_FS_DEFAULT_ON` defaults to `LOG_BACKEND_UART`). Use the `production` snippet for battery/production builds where the console leak matters.

Build with snippet: `west build ... -- -DSNIPPET_ROOT=$(pwd)/applications/clip -DSNIPPET=production` (SNIPPET_ROOT must be an absolute path).

### Dev Build (console over USB CDC)

For users without a J-Link / UART adapter, a **dev** variant redirects the console to USB:

```sh
west build --build-dir build-clip-dev --board clip/nrf5340/cpuapp applications/clip -- -DFILE_SUFFIX=dev
```

- `FILE_SUFFIX=dev` makes sysbuild pick up `applications/clip/sysbuild/clip_dev.conf`
  (`CONFIG_CLIP_USB_AUTO_ENABLE=y`, a board-level Kconfig symbol so the conf is broadcast-safe)
  and `applications/clip/boards/clip_nrf5340_cpuapp_dev.overlay` (console + shell-uart →
  `cdc_acm_uart`). The suffixed overlay REPLACES the base overlay — keep them in sync.
- `main.c` calls `usb_cdc_enable()` at boot when `CLIP_USB_AUTO_ENABLE` is set, and skips
  auto-enabling the FS log backend (SD is MSC-owned while USB is up). Log level follows
  `prj.conf` (`CONFIG_CLIP_LOG_LEVEL`) — no runtime filtering.
- Verified isolation: mcuboot / b0n / ipc_radio configs are byte-identical to the default build.
- Gotcha: suffixed files are only discovered at configure time. Adding/removing one requires
  `--pristine`; otherwise the stale `DTC_OVERLAY_FILE` stays cached in the image's CMakeCache.
- Trade-offs: pre-enumeration logs lost; no host -> output dropped (never blocks boot);
  console shares the CDC port with AT responses. This is a debug-convenience image only,
  not a release artifact.

### Output Firmware

Two images per release: **debug** (`build-clip`, console + SD log) and **production** (`build-clip-prod`, `-- -DSNIPPET_ROOT=$(pwd)/applications/clip -DSNIPPET=production`, console off). A third local-only variant, the **dev** build (`build-clip-dev`, `-DFILE_SUFFIX=dev`), exists for debugging over USB CDC without a J-Link — see "Dev Build" above; it is not exported by the release job.

**CI** — `.github/workflows/firmware.yml` builds the clip app on every push/PR to `main`. It installs the **Zephyr SDK 0.17.0** toolchain + **NCS v3.3.0 (Zephyr v4.3)** source via `west` (the `nrfutil toolchain-manager` subcommand was deprecated and removed, and the standalone pc-nrfutil binary has no toolchain install — the old CI failed on `nrfutil self-upgrade`/`install` for exactly this reason). It installs both `zephyr/scripts/requirements-base.txt` and `nrf/scripts/requirements.txt` (the nrf one is required for image-signing deps like `cryptography`; the *base* zephyr file is used instead of the full `requirements.txt` because the full one pulls `requirements-extras.txt` → `spsdk`, whose git `#egg=` deps make pip backtrack through every `setuptools_scm` version and hang), applies the MCUboot patches, and `west build`s the sysbuild (MCUboot + app + ipc-radio). Compilation check only; verified locally in a clean `ubuntu:22.04` container. `.github/workflows/mobile-ci.yml` (fast: analyze + unit tests, runs on PR) and `.github/workflows/mobile-verify.yml` (full: debug APK / assembleDebug / iOS smoke, push + manual) cover the `mobile/` SDKs. `.github/workflows/release.yml` is **tag-triggered** (push a `vX.Y.Z` tag): it builds the debug + production images, exports the 8 artifacts below, and publishes a GitHub Release whose body is `docs/release_notes/vX.Y.Z.md` (that file **must** exist before tagging, or the job fails). The manual export block below is the local-dev equivalent of what the release job produces automatically:

```sh
VERSION=$(grep APP_VERSION_STRING build-clip/clip/zephyr/include/generated/zephyr/app_version.h | cut -d'"' -f2)
mkdir -p output/$VERSION

# Debug
cp build-clip/merged.hex            output/$VERSION/clip-$VERSION-debug-merged.hex
cp build-clip/merged_CPUNET.hex     output/$VERSION/clip-$VERSION-debug-merged_CPUNET.hex
cp build-clip/dfu_application.zip   output/$VERSION/clip-$VERSION-debug-ota.zip
cp build-clip/clip/zephyr/zephyr.signed.bin output/$VERSION/clip-$VERSION-debug-signed.bin
# Production
cp build-clip-prod/merged.hex            output/$VERSION/clip-$VERSION-production-merged.hex
cp build-clip-prod/merged_CPUNET.hex     output/$VERSION/clip-$VERSION-production-merged_CPUNET.hex
cp build-clip-prod/dfu_application.zip   output/$VERSION/clip-$VERSION-production-ota.zip
cp build-clip-prod/clip/zephyr/zephyr.signed.bin output/$VERSION/clip-$VERSION-production-signed.bin
```

**To publish a release:** add `docs/release_notes/v$VERSION.md`, commit, then `git tag vX.Y.Z && git push origin vX.Y.Z` — CI builds and creates the GitHub Release with all artifacts.

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

### Factory & RF Test Firmware

Each is a standalone sysbuild image under `tests/<name>`, built like the hardware test above (`west build --build-dir build-<name> --pristine --board clip/nrf5340/cpuapp tests/<name>`). **Tests opt out of MCUboot** (factory/cert firmware, flashed directly via J-Link) via a per-test `sysbuild.conf` setting `SB_CONFIG_BOOTLOADER_NONE=y` (+ `SB_CONFIG_SECURE_BOOT_NETCORE=n`, and `SB_CONFIG_NETCORE_NONE=y` for tests that don't need BLE).

| Test | Purpose |
|------|---------|
| `tests/clip` | Multi-image hardware test suite (also hosts the `lfxo`/`hfxo` shell below) |
| `tests/dtm` | BLE Direct Test Mode for RF conformance/certification (2-wire UART @19200; cpunet runs DTM, cpuapp bridges IPC→UART) |
| `tests/wifi_radio` | nRF70 WiFi radio test for RF certification (TX/RX, tone, IQ, FICR) |
| `tests/re` | Reference-board bring-up variant |

`tests/tools/poweroff.py` is a host-side helper.

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
- `docs/whitepaper.md` / `docs/patent_disclosure.md` - Firmware whitepaper and patent disclosure (CN)

## Application Architecture

The application (`applications/clip/`) uses an event-driven architecture with triple transport support (BLE + WiFi UDP + USB CDC). All three are AT-command channels; the active one is auto-selected per response.

### Event System

Central event dispatcher (`clip_event.c`) with async (non-blocking, from button ISRs) and sync (blocking, from AT commands) posting. Events: START, STOP, PAUSE, RESUME, MARK, WIFI_ON, WIFI_OFF, etc.

### States

UNINITIALIZED → IDLE → RECORDING → TRANSMITTING / WIFI_SYNC → IDLE. Also PAUSED, ERROR, OTA.

### Transport Abstraction

`transport.c` provides a unified interface over BLE (`transport_ble.c`), UDP (`transport_udp.c`), and USB CDC (`usb_cdc.c`). Auto-selects active transport (BLE priority over UDP). Max 512 bytes per packet. Separate send vs send_file_data (BLE uses FILE_DATA characteristic). `TRANSPORT_TYPE_USB` carries AT commands over the USB CDC ACM serial port.

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
- `battery.c` - NPM1300 PMIC battery monitoring + nRF Fuel Gauge (model in `battery_model.inc`). Polls every 60 s. Displayed % is the fuel gauge's integer SoC estimate directly (no application-level smoothing, rate limiting, directional clamp, reserve, or full latch). Charge termination 4.25V. `vbatlow-charge-enable` lets the charger recover a deeply discharged/protected cell. No low-battery auto-shutdown (removed); low battery shows a UI warning only.

## Known Pitfalls

- **`%llu` not supported**: Zephyr's minimal printf on nRF5340 outputs `"lu"` literally. Use `%u` with `(unsigned int)` cast for 64-bit values.
- **UDP `sendto()` reliability**: Returns success even when WiFi TX queue silently drops packets. CRC is only updated after confirmed send. File-level retry handles lost data.
- **`except Exception` doesn't catch `KeyboardInterrupt`**: It's a `BaseException`, not `Exception`. Use bare `except:` or handle it explicitly.
- **FAT directory order**: Not chronological. Session listing uses a cached sorted buffer invalidated on mutations.
- **Transfer thread safety**: AT commands and transfer run on different threads. Use volatile flags for coordination (e.g., `transfer_cancel_requested`).
- **Logs persist to SD card**: `CONFIG_LOG_BACKEND_FS=y` writes logs to `/SD:/LOG` (rotating 64 KiB files). `CONFIG_LOG_DEFAULT_LEVEL=0` compiles logs out at runtime — enable via `LOG_RUNTIME_FILTERING` / per-module level when debugging. Inspect the SD `/LOG/` files post-mortem.
- **Corrupt settings boot loop**: A corrupt `/lfs/settings/run` (typically from repeated pair/unpair) blocks `settings_load` ~40s. A watchdog on the system workqueue thread wipes the file + reboots if it doesn't return in `CLIP_SETTINGS_LOAD_TIMEOUT_MS` (3s). Guards both the `config` and `bt` bond-key loads.

## MCUboot Patch Development

MCUboot source is in the NCS tree (`~/ncs/<version>/bootloader/mcuboot`). Patches are stored in `patches/mcuboot/` and the bootloader image is configured by the board sysbuild files in `boards/seeed/clip/sysbuild/` (`mcuboot.conf`, `mcuboot.overlay`, `ipc_radio/prj.conf`, signing key `root-rsa-2048.pem` — a copy of the mcuboot default key; generate your own for production). See `docs/custom_app_guide.md` for the full custom app / OTA / recovery guide. The workflow is: **modify source → build → verify → export patches**.

### Current patches (`patches/mcuboot/`)

| Patch | Purpose |
|-------|---------|
| `0001-require-vbus-for-gpio-serial-recovery.patch` | Only allow GPIO/serial recovery when VBUS is present |
| `0002-add-oled-display-support.patch` | OLED status UI in the bootloader (new `io_display.c`) |
| `0003-add-serial-upload-progress-hook.patch` | Serial upload progress hook |
| `0004-add-custom-mcumgr-commands.patch` | Custom mcumgr commands (erase SD on-demand LDO2, erase settings 128KB) |
| `0005-add-swap-copy-progress-hook.patch` | Swap/copy progress hook |

See `patches/mcuboot/README.md` for per-patch details.

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
git diff boot/zephyr/main.c > /path/to/reSpeaker_Clip/patches/mcuboot/XXXX.patch

# For new files (io_display.c), use sed to prefix '+'
{ echo "diff --git a/boot/zephyr/io_display.c b/boot/zephyr/io_display.c"
  echo "new file mode 100644"
  echo "--- /dev/null"
  echo "+++ b/boot/zephyr/io_display.c"
  printf "@@ -0,0 +1,%d @@\n" $(wc -l < boot/zephyr/io_display.c)
  sed 's/^/+/' boot/zephyr/io_display.c
} >> /path/to/reSpeaker_Clip/patches/mcuboot/XXXX.patch

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
- **SPI3**: External SPI flash PY25Q64H (CS: gpio0.20, 8MB), powered by `flash_vdd` (gpio0.27)
- **SPI4**: SD card via SDHC-SPI (CS: gpio0.9)
- **QSPI**: nRF7002 WiFi module
- **USBD**: CDC ACM serial (3rd AT channel) + MSC (SD card mass storage)
- **nrf_radio_coex**: WiFi/BLE PTA coexistence (req/status0/grant/swctrl1 on P0.28/25/31/30)
- **GPIO1.15**: User button (pull-up, active-low)

The DTS is split across includes: `clip-pinctrl.dtsi`, `clip-cpuapp_partitioning.dtsi`, `clip-shared_sram.dtsi`, `nrf70_common.dtsi`, plus `clip_nrf5340_cpunet.dts` (network core) and `_ns.dts` (non-secure/TrustZone). `boot_mode0` (retention register in `gpregret1`, `zephyr,boot-mode`) gates MCUboot serial-recovery entry. Battery profile is the "240" cell (HSZ 362123, 170 mAh).

### Power Management

`CONFIG_PM_DEVICE_RUNTIME=y` enables automatic peripheral power management. UART, I2C, SPI drivers automatically suspend when idle and resume on access.

**The debug UART console still leaks ~570µA at idle** — the UARTE peripheral stays enabled between log outputs (baud-independent; 115200 and 921600 both leak the same). The `production` snippet disables the console + UART log backend, bringing idle to ~170µA. The debug build (console on) idles higher. This was the single largest idle leak after the regulators and SD card were fixed.

Idle power budget (3V3 rail, v0.0.5): nRF5340 main/radio regulators on **DCDC** (`vregmain`/`vregradio` = `NRF5X_REG_MODE_DCDC`, ~500–600µA vs LDO); SD card **idle power-gated** after `CLIP_SD_IDLE_DELAY_MS` (45s) (unmount → disk deinit → SPI4 runtime-PM suspend → CS parked low → LDO2 off; lazy remount via `storage_ensure_mounted()`); SPI `bias-pull-up` removed from `spi3`/`spi4` (push-pull needs none) with `bias-pull-down` on `spi4_sleep`. Production (console off) reaches ~170µA.

`CONFIG_NRF70_QSPI_LOW_POWER=y` puts QSPI in low power when WiFi is not in use.

BLE slow advertising (~1s interval) adds ~0.1mA averaged to idle current.

### PMIC & Regulators

PMIC regulators (I2C1 @ 0x6b): BUCK1 (motor), BUCK2 (main 3.3V), LDO1 (mic 1.8V), LDO2 (SD 3.3V).
GPIO-controlled: mic_vdd (gpio1.14), oled_vdd (gpio1.8), rfsw_vdd (gpio0.29), flash_vdd (gpio0.27).

### External Flash Partitions

8MB SPI flash: OTA slot 0 (960KB), OTA slot 1 (256KB), LittleFS (~6.8MB).

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
  - `src/` - main.c, at_commands.c, at_server.c, audio.c, battery.c (+ generated `battery_model.inc`), ble.c, button.c, clip_event.c, config.c, display.c, haptic.c, icons.c, storage.c, transfer.c, transport.c, transport_ble.c, transport_udp.c, usb_cdc.c, wifi.c, wifi_udp.c
  - `include/` - Headers for each module
  - `sysbuild/` - MCUboot + network-core radio sysbuild config
  - `tests/clip/` - Python library (wifi.py, codec.py, transfer.py, etc.)
  - `tests/tools/` - Tools: record.py, udp_sync.py, udp_terminal.py, clip-cli.py, clip-web.py
  - `tests/tests/` - Application tests
  - `prj.conf` - Kconfig
- `samples/` - Examples (hello_world, button_demo, lua_repl, opus_encode, t5838, http_server, wifi_ap_iperf, wifi_ble_coex, suspend_to_ram)
- `drivers/` - Custom device drivers (input)
- `lib/` - Third-party libraries (opus, speexdsp, lua)
- `tests/` - Firmware test/bench tools (all opt out of MCUboot — direct J-Link flash): `clip` (HW suite), `dtm` (BLE DTM RF cert), `wifi_radio` (nRF70 WiFi RF cert), `re` (reference bring-up); `tests/ble_test.py` (BLE protocol test)
- `docs/` - Protocol, architecture, requirements, development, audio quality, MCUboot/OTA, whitepaper docs
