# Troubleshooting

Symptoms → cause → fix, grouped by area. Each entry is deliberately short.

## Build

| Symptom | Cause | Fix |
|---------|-------|-----|
| App/module Kconfig not found, board files missing | `ZEPHYR_EXTRA_MODULES` not set, or set as a CMake variable | `export ZEPHYR_EXTRA_MODULES=$(pwd)` — must be an **environment variable**; Kconfig module discovery happens before CMake configuration |
| Mysterious Kconfig errors (e.g. WPA3 `..._WPA3_IMPLEMENTATION_NONE` missing) | Building against NCS v3.2.1 | `main` requires **NCS v3.3.0** (`source ~/ncs/v3.3.0/zephyr/zephyr-env.sh`); v3.2.1 is unsupported |
| `snippet not found` / snippet ignored | Under sysbuild the app dir is not on the snippet search path (or `SNIPPET_ROOT` was passed relative) | Use `-- -DSNIPPET_ROOT=$(pwd)/applications/clip -DSNIPPET=production` — `SNIPPET_ROOT` must be an absolute path |
| MCUboot changes don't appear in the image | Incremental build | MCUboot changes require a **pristine** build (`--pristine`) |
| Compiler warnings block commit | Repo rule | Fix all warnings before committing; zero-warning policy |

## Console / serial

| Symptom | Cause | Fix |
|---------|-------|-----|
| Can't find the device console; `/dev/ttyACM0` shows J-Link traces | J-Link probe takes `ttyACM0` when attached | Clip's UART0 bridge moves to `/dev/ttyACM1` — use whichever port is the "USB Single Serial" / non-J-Link one. Identify the Clip port by USB PID `2886:0x0069` (`lsusb`) |
| `west flash --reset` doesn't reset the board | Board quirk | Run `nrfutil device reset` after `west flash` |
| No output at all | Wrong baud or console compiled out | Debug builds: 921600 baud. Production snippet builds have **no console** by design |

## Runtime

| Symptom | Cause | Fix |
|---------|-------|-----|
| Log prints `"lu"` literally for 64-bit values | Zephyr minimal printf has no `%llu` | Use `%u` with `(unsigned int)` cast for 64-bit values |
| Python tool won't exit on Ctrl+C | `except Exception` doesn't catch `KeyboardInterrupt` (it's a `BaseException`) | Use bare `except:` or handle `KeyboardInterrupt` explicitly |
| UDP transfer shows CRC/data mismatches, lost chunks | `sendto()` returns success even when the WiFi TX queue silently drops packets | Don't trust single-send success; CRC is only updated after confirmed send, file-level retry recovers losses |
| Transfer can't be cancelled or races with AT commands | AT commands and transfer run on different threads | Coordinate via `volatile` flags (e.g. `transfer_cancel_requested`) checked in the transfer loop |

## Storage

| Symptom | Cause | Fix |
|---------|-------|-----|
| Session list in wrong order after new recordings | FAT directory order is not chronological | Listing uses a cached sorted buffer invalidated on mutations — ensure every mutation invalidates it |
| Need post-mortem logs after a crash/field issue | Logs persist to SD (`CONFIG_LOG_BACKEND_FS=y`, rotating 64KiB files) | Read `/SD:/LOG/` off the card. Note `CONFIG_LOG_DEFAULT_LEVEL=0` compiles logs out — enable `LOG_RUNTIME_FILTERING` / per-module level when debugging |
| SD card dead after 45s idle | Not a fault — idle power-gating (unmount → LDO2 off) | Any access lazily remounts via `storage_ensure_mounted()` |

## Recovery / boot

| Symptom | Cause | Fix |
|---------|-------|-----|
| Boot hangs ~40s, loops (often after repeated BLE pair/unpair) | Corrupt `/lfs/settings/run` blocks `settings_load` | Normally auto-recovered by the watchdog on the system workqueue (wipes the file + reboots if load exceeds `CLIP_SETTINGS_LOAD_TIMEOUT_MS`=3s). Manual recovery: MCUboot custom mcumgr "erase settings" command (erase LFS 128KB). Reflashing the app does **not** clear it — settings live in external flash |
| App-only update via raw J-Link of `zephyr.signed.hex` to slot 0 doesn't boot | Image must be installed through MCUboot | Use USB serial DFU or BLE OTA (see `docs/usb_dfu.md`) |
