# reSpeaker Clip Firmware

Zephyr RTOS firmware for the **Seeed reSpeaker Clip** — a wearable voice
recording device based on the Nordic nRF5340 dual-core MCU, with BLE, WiFi AP,
USB, AT-command control, and UDP file transfer.

> **Note**: Product name is spelled **reSpeaker** (lowercase `r`).

## Hardware

| Component | Part |
|-----------|------|
| MCU | nRF5340 (Application core + Network core, dual-core) |
| WiFi | nRF7002 (QSPI, AP mode) |
| PMIC / Charger | NPM1300 + nRF Fuel Gauge |
| Display | CH1115 OLED (88×48) |
| Audio | PDM microphone array (DMIC) |
| Storage | microSD (FAT) + 64 Mbit external SPI flash (LittleFS) |
| Connectivity | BLE 5.x + WiFi 2.4/5G AP + USB CDC ACM + USB MSC |

## Key Features

- **Audio**: PDM mic → SpeexDSP preprocessing (noise suppression / dereverb; custom integer AGC) → Opus encoding
- **BLE**: AT-command protocol, OTA DFU (MCUmgr), GATT notifications
- **WiFi**: AP mode (`ClipAP_XXXX`) with UDP file transfer (CRC32-verified)
- **USB**: CDC ACM serial (3rd AT channel) + MSC mass storage (SD card) + 1200-baud → DFU recovery trigger
- **Power**: Production idle ~170µA (DCDC, SD power-gating, console off)
- **Battery**: NPM1300 charging + nRF Fuel Gauge SoC, custom "240" cell model
- **OTA**: MCUboot (custom) with signed images, BLE/USB serial DFU

## Getting Started

### Prerequisites

- [nRF Connect SDK (NCS) v3.3.0](https://docs.nordicsemi.com/bundle/ncs-latest/page/nrf/index.html)
- Zephyr SDK (toolchain)
- `west` (Zephyr's meta-tool)
- nRF Connect for Desktop (flashing) or `nrfutil`
- Python 3.10+ (for test tools)

### Installing the toolchain

This repo is a Zephyr **module**, not a standalone west workspace — you need an
NCS v3.3.0 workspace *beside* it first.

```sh
# 1. Install west
pip install west

# 2. Initialize an NCS v3.3.0 workspace (manifest tag verified against the
#    local dev workspace: nrf repo at tag v3.3.0, a.k.a. ncs-v3.3.0)
west init -m https://github.com/nrfconnect/sdk-nrf --mr v3.3.0 ~/ncs/v3.3.0
cd ~/ncs/v3.3.0
west update

# 3. Zephyr SDK 0.17.0 (toolchain)
west sdk install --sdk-version 0.17.0

# 4. Python requirements (same combo CI uses — the nrf one carries
#    image-signing deps like cryptography)
pip install zephyr/scripts/requirements-base.txt nrf/scripts/requirements.txt
```

Then clone this repo anywhere and pick up the Build steps below (the
`source .../zephyr-env.sh` + `export ZEPHYR_EXTRA_MODULES=$(pwd)` pair registers
the module). Canonical fallback:
[Nordic — Install nRF Connect SDK](https://docs.nordicsemi.com/bundle/ncs-latest/page/nrf/installation.html).

### Build

```sh
# 1. Source the NCS v3.3.0 environment
source ~/ncs/v3.3.0/zephyr/zephyr-env.sh

# 2. Set the module path (REQUIRED — enables Kconfig to discover this repo's
#    board/drivers/lib. Must be an env var, not -D, because Kconfig module
#    discovery runs before CMake.)
export ZEPHYR_EXTRA_MODULES=$(pwd)

# 3. Build the clip app (sysbuild: mcuboot + app + network-core radio)
west build --build-dir build-clip --board clip/nrf5340/cpuapp applications/clip
```

**Production (low-power, console off):**
```sh
west build --build-dir build-clip-prod --board clip/nrf5340/cpuapp applications/clip \
  -- -DSNIPPET_ROOT=$(pwd)/applications/clip -DSNIPPET=production
```

> **Board identifier**: `clip/nrf5340/cpuapp` (NOT `respeaker/...`)

### Firmware Upgrade (USB — no J-Link needed)

The reSpeaker Clip ships in an **enclosed housing**, so the SWD/J-Link pads are
not reachable for end users. Firmware upgrades happen over **USB** (or BLE) with
mcumgr — no probe, no opening the case. Every clip app has the **1200-baud DFU
trigger** built in (board-level, `lib/clip_usb_dfu`).

1. Enter MCUboot serial recovery — open the device's USB CDC-ACM port at
   **1200 baud** (the app reboots into recovery automatically):
   ```sh
   python3 -c "import serial; s=serial.Serial('/dev/ttyACMx',1200); s.close()"
   ```
   The clip app keeps USB off by default — send `AT+USB=on` over BLE first.
   Samples and custom apps with the default CDC auto-enable USB (no BLE step).
   (Holding the user button while plugging USB also enters recovery.)
2. A new CDC-ACM port appears — **PID `0x8069`** (the running app is `0x0069`;
   the `0x8000` bit marks bootloader mode; both Seeed VID `0x2886`). Upload the
   signed app:
   ```sh
   nrfutil mcu-manager serial image-upload --firmware clip-<v>-signed.bin --serial-port /dev/ttyACMx
   nrfutil mcu-manager serial reset     --serial-port /dev/ttyACMx
   ```
   MCUboot verifies the signature and boots the new app; the bootloader partition
   is never touched.

Full guide (BLE OTA, the button path, `mcumgr`/nRF Connect, troubleshooting):
[docs/usb_dfu.md](docs/usb_dfu.md).

### Flash (development — J-Link/SWD)

For development with a debug probe. The enclosed device has no user-accessible SWD
— end users use USB DFU (above).

```sh
# west flash handles the dual-core routing (app + net core)
west flash --build-dir build-clip && nrfutil device reset
```

> `west flash --reset` does NOT work on this board — use `nrfutil device reset`
> after flashing. If the net-core access port is b0n-locked (after a prior boot),
> add `--recover`.

### Serial Console

```sh
minicom -D /dev/ttyACM0 -b 921600
```

## Project Structure

| Path | Description |
|------|-------------|
| `applications/clip/` | Main application (AT commands, audio, BLE, WiFi, storage) |
| `boards/seeed/clip/` | Board support package (device trees, Kconfig) |
| `drivers/` | Custom drivers (GPIO button) |
| `lib/` | Libraries (Opus, SpeexDSP, Lua, 1200-baud USB DFU trigger) |
| `samples/` | Example apps (hello_world, opus_encode, wifi_ap_iperf, etc.) |
| `tests/` | Factory/RF test firmware (`clip`, `battery_cycle`, `dtm`, `wifi_radio`, `re`) |
| `patches/mcuboot/` | MCUboot customization patches (applied to the NCS tree) |
| `docs/` | Project documentation |

## Documentation

### Official References

- **[nRF Connect SDK](https://docs.nordicsemi.com/bundle/ncs-latest/page/nrf/index.html)** — NCS documentation (this firmware targets NCS v3.3.0)
- **[Zephyr Project](https://docs.zephyrproject.org/)** — Zephyr RTOS documentation
- **[nRF5340 Product Page](https://www.nordicsemi.com/Products/nRF5340)** — MCU datasheet & specs
- **[nRF7002](https://www.nordicsemi.com/Products/nRF7002)** — WiFi chipset
- **[NPM1300](https://www.nordicsemi.com/Products/npm1300)** — PMIC / battery charger

### Project Docs (`docs/`)

See [docs/README.md](docs/README.md) for the full documentation map.

| Doc | Description |
|-----|-------------|
| [architecture.md](docs/architecture.md) | System architecture & design |
| [protocol.md](docs/protocol.md) | BLE AT command protocol specification |
| [udp_protocol.md](docs/udp_protocol.md) | WiFi UDP file transfer protocol |
| [requirements.md](docs/requirements.md) | Product requirements |
| [custom_app_guide.md](docs/custom_app_guide.md) | **Custom app development guide** — build, flash, BLE OTA, USB serial DFU recovery |
| [usb_dfu.md](docs/usb_dfu.md) | Firmware upgrade guide (USB / BLE / programmer) |
| [release_process.md](docs/release_process.md) | Releasing — tagging, CI, artifacts |
| [audio_quality_standard.md](docs/audio_quality_standard.md) | Audio recording quality standard |
| [development.md](docs/development.md) | Development log |

Release artifacts (debug + production images, OTA zips) for every version are on
the [GitHub Releases page](https://github.com/Seeed-Studio/reSpeaker_Clip/releases).

See [CLAUDE.md](CLAUDE.md) for detailed build/flash/power-management guidance
and known pitfalls.

> English docs are canonical; a Chinese translation is maintained for the
> hardware test firmware (`tests/clip/README_zh.md`).

## Testing

```sh
# Interactive BLE AT terminal (auto-discovers the device, or pass a BLE address)
python applications/clip/tests/tools/ble_terminal.py
python applications/clip/tests/tools/ble_terminal.py AA:BB:CC:DD:EE:FF

# WiFi UDP file sync (connect to ClipAP_XXXX first; password 12345678 by default,
# becomes a random one after the first BLE pairing)
python applications/clip/tests/tools/udp_sync.py --session <session_id>

# Hardware test firmware
west build --build-dir build-test --board clip/nrf5340/cpuapp --pristine tests/clip

# Python test suite (unit tests, no device needed)
cd applications/clip/tests && pytest   # docs: tests/docs/testing.md
```

WiFi AP: SSID `ClipAP_XXXX` (last 4 hex of chip ID) · Password `12345678` (default; random after first pairing) · IP `192.168.4.1` · UDP Port `8089`

Note: that AP identity is for the **main app**. The **hardware test firmware**
(`tests/clip`) instead uses a per-device BLE name + AP SSID `Clip_<6hex>`
derived from the chip ID — see `tests/clip/README.md` ("Device Identity").

## Mobile App & SDK

The companion phone app and SDKs (Flutter, Android, iOS) live under
[`mobile/`](mobile/README.md). They talk to the Clip over BLE and the device
Wi-Fi AP — no API key or backend required. See the mobile monorepo README for
the layout, running the example/sample apps, and the integration & verification
guides in `mobile/docs/`. **The mobile SDKs are separately licensed** (see each
`mobile/sdk/*/LICENSE`) and are not covered by the repository Apache-2.0
license below.

## License

This firmware is licensed under the [Apache License 2.0](LICENSE). See
individual files for `SPDX-License-Identifier` details. Third-party libraries
(Opus, SpeexDSP, Lua) retain their respective licenses. The `mobile/` SDKs are
separately licensed (see above).

## Acknowledgements

- [Nordic Semiconductor](https://www.nordicsemi.com/) — nRF Connect SDK, nRF5340, nRF7002, NPM1300
- [Zephyr Project](https://zephyrproject.org/) — RTOS
- [Seeed Studio](https://www.seeedstudio.com/) — reSpeaker Clip hardware
