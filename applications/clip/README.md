# Clip Application

The main reSpeaker Clip firmware — a wearable voice recording device based on
the Nordic nRF5340. Records PDM microphone audio through SpeexDSP
preprocessing and Opus encoding to the SD card, and exposes everything over
three AT-command transports: BLE, WiFi (UDP), and USB CDC serial. For the
hardware overview, board support, and repo layout, see the
[repo README](../../README.md).

## Build

The app builds as a Zephyr **sysbuild** (MCUboot + app core + network-core
radio) — no per-app sysbuild config needed, the board provides it all.

```sh
# 1. Source NCS v3.3.0 (the only supported SDK)
source ~/ncs/v3.3.0/zephyr/zephyr-env.sh

# 2. Module path (REQUIRED, must be an env var — Kconfig runs before CMake)
export ZEPHYR_EXTRA_MODULES=$(pwd)   # run from the repo root

# 3. Debug build (UART console + SD log on)
west build --build-dir build-clip --board clip/nrf5340/cpuapp applications/clip
```

**Production build** (low power, console off — ~170µA idle) — the snippet
lives in `applications/clip/snippets/`; under sysbuild the app dir is not on
the snippet search path, so `SNIPPET_ROOT` (absolute) must point at it:

```sh
west build --build-dir build-clip-prod --board clip/nrf5340/cpuapp applications/clip \
  -- -DSNIPPET_ROOT=$(pwd)/applications/clip -DSNIPPET=production
```

## Flash

```sh
west flash --build-dir build-clip && nrfutil device reset
```

> `west flash --reset` does NOT work on this board — always reset with
> `nrfutil device reset` after flashing.

## Serial Console

```sh
minicom -D /dev/ttyACM0 -b 921600
```

If a J-Link probe is also connected it takes `ttyACM0`; the Clip's USB serial
bridge is then `ttyACM1` — use whichever is the "USB Single Serial" port.

## Architecture

Event-driven, triple-transport firmware in `src/`: `clip_event.c` (central
dispatcher) drives the UNINITIALIZED → IDLE → RECORDING → TRANSMITTING /
WIFI_SYNC state machine, with modules for audio (`audio.c`), storage
(`storage.c`), file transfer (`transfer.c`), transports
(`transport.c`, `transport_ble.c`, `transport_udp.c`, `usb_cdc.c`), AT
commands (`at_server.c`, `at_commands.c`), UI (`display.c`, `button.c`,
`haptic.c`, `icons.c`), and connectivity/power (`ble.c`, `wifi.c`,
`wifi_udp.c`, `battery.c`, `config.c`). See
[docs/architecture.md](../../docs/architecture.md).

## Connecting

All three transports speak the same JSON AT commands
([docs/protocol.md](../../docs/protocol.md)):

- **BLE**: advertises as `Clip XXXX` (last 4 hex of chip id) — also the
  BLE OTA channel
- **WiFi AP**: SSID `ClipAP_XXXX`, password `12345678` (default), IP
  `192.168.4.1`, UDP port `8089` ([docs/udp_protocol.md](../../docs/udp_protocol.md))
- **USB**: CDC ACM serial AT channel + MSC mass storage (SD card)

## Documentation

- [docs/protocol.md](../../docs/protocol.md) — BLE AT command protocol
- [docs/udp_protocol.md](../../docs/udp_protocol.md) — UDP file transfer protocol
- [docs/architecture.md](../../docs/architecture.md) — system architecture
- [docs/custom_app_guide.md](../../docs/custom_app_guide.md) — custom app
  development (build, flash, OTA, DFU recovery)
- [docs/usb_dfu.md](../../docs/usb_dfu.md) — firmware upgrade guide
- [CLAUDE.md](../../CLAUDE.md) — detailed build/flash/power guidance and known pitfalls
- [tests/](tests/README.md) — Python SDK and test tools
