# Power Management

> **This file owns the power figures.** Other docs quote these numbers;
> if a number changes, change it here first.

All measurements are on the **3V3 rail** (firmware v0.0.5 baseline).

## Summary

| Configuration | Idle current |
|---------------|--------------|
| Production snippet (console off), all gating active | **~170µA** |
| Debug build (UART console on) | ~170µA + ~570µA console leak |
| BLE slow advertising (~1s interval) | add ~0.1mA averaged |
| Main/radio regulators on LDO instead of DCDC | add ~500–600µA |

## Budget breakdown

- **DCDC conversion** — nRF5340 main and radio regulators configured as DCDC
  (`vregmain`/`vregradio` = `NRF5X_REG_MODE_DCDC`), saving ~500–600µA vs LDO.
- **UART console leak (debug builds only)** — the UARTE peripheral stays
  enabled between log outputs, leaking **~570µA** at idle (baud-independent;
  115200 and 921600 leak the same). The `production` snippet disables the
  console + UART log backend, which is what brings production to ~170µA.
- **SD card idle power-gating** — after `CLIP_SD_IDLE_DELAY_MS` (default 45s,
  `applications/clip/Kconfig`) of no SD access: unmount → disk deinit → SPI4
  runtime-PM suspend → CS pin parked low → LDO2 off. Remount is lazy on the
  next access via `storage_ensure_mounted()`.
- **nRF70 (WiFi) QSPI low power** — `CONFIG_NRF70_QSPI_LOW_POWER=y` puts QSPI
  in low power whenever WiFi is not in use.
- **BLE advertising** — slow advertising (~1s interval) adds ~0.1mA averaged to
  idle current.
- **SPI bias resistors** — `bias-pull-up` removed from `spi3`/`spi4`
  (push-pull needs none), with `bias-pull-down` on `spi4_sleep`.
- **Runtime PM** — `CONFIG_PM_DEVICE_RUNTIME=y`: UART, I2C, SPI drivers
  suspend automatically when idle and resume on access.

## The production snippet

Mechanism: `applications/clip/snippets/production/` (conf + `snippet.yml`).
It disables the UART console and UART log backend (`CONFIG_CONSOLE=n`,
`CONFIG_UART_CONSOLE=n`, `CONFIG_LOG_BACKEND_UART=n`); the FS log backend
default follows (off). Use it for battery/production builds where the console
leak matters.

```sh
# app-dir snippets are auto-discovered under NCS v3.3.0:
west build --build-dir build-clip-prod --board clip/nrf5340/cpuapp applications/clip \
  -- -DSNIPPET=production
# (CI additionally passes -DSNIPPET_ROOT="$(pwd)/applications/clip"; equivalent.)
```

The default (no-snippet) build is the **debug** image: UART console on, FS log
to `/SD:/LOG` at INF level.

## Regulator map

PMIC (NPM1300, I2C1 @ 0x6b) regulators:

| Rail | Consumer | Notes |
|------|----------|-------|
| BUCK1 | Haptic motor | |
| BUCK2 | Main 3.3V | |
| LDO1 | Mic 1.8V | |
| LDO2 | SD card 3.3V | Turned off by SD idle power-gating |

GPIO-controlled regulators:

| GPIO | Rail | Consumer |
|------|------|----------|
| gpio1.14 | mic_vdd | PDM microphones |
| gpio1.8 | oled_vdd | CH1115 OLED |
| gpio0.29 | rfsw_vdd | RF switch |
| gpio0.27 | flash_vdd | External SPI flash (PY25Q64H) |

## How to measure

Measure on the 3V3 rail (series ammeter / power analyzer on BUCK2 output or
the 3V3 net). Ensure the device has been idle for >45s so SD power-gating has
engaged, WiFi is off, and (for the ~170µA figure) the production snippet build
is flashed. Compare against the summary table above.
