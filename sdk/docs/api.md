# API reference

```python
from clip import BleTransport, ClipClient, UdpTransport
```

Construct one transport, pass it to `ClipClient`, and use the client as
an async context manager. `connect()` performs no implicit time sync or
other state-changing work.

Exactly one command is in flight at a time (the protocol has no request
ID). If a command times out, the transport is desynchronized until you
disconnect and reconnect — see [troubleshooting.md](troubleshooting.md).

All firmware errors surface as `clip.exceptions.CommandError`; timeouts
as `CommandTimeoutError`; transfer failures as `TransferError` /
`TransferTimeoutError` (base class `ClipError`).

## Transports

| Transport | Constructor | Notes |
|-----------|-------------|-------|
| `BleTransport` | `(address=None, *, name="Clip", connect_timeout=15.0)` | `bleak` via the `ble` extra. Scans by name substring when no address given. GATT notifications; link-layer reliability. |
| `UdpTransport` | `(host="192.168.4.1", port=8089)` | Standard library only. Per-file CRC32 verified before `FILE_ACK`; failed files are NACKed for retransmission. |

## Device status & info

| Method | Returns | Command |
|--------|---------|---------|
| `await clip.status()` | `Status` — state, recording, session, duration, battery, charging, temp, voltage, mode, free_space, device | `AT+GSTAT` |
| `await clip.battery()` | `Battery` — percent, charging, voltage_mv, temperature_c | `AT+BATT` |
| `await clip.storage()` | `Storage` — total_mb, free_mb, used_mb, used_percent, recorded_mb | `AT+STORAGE?` |
| `await clip.device_name()` | `str` (advertised name) | `AT+DEVICE` |
| `await clip.firmware_version()` | `str` | `AT+VERSION` |
| `await clip.get_time()` | `datetime` | `AT+TIME?` |
| `await clip.set_time(value)` | `int` (unix ts) — accepts `int` or `datetime` | `AT+TIME=<ts>` |
| `await clip.request("AT+...")` | raw response `dict` — escape hatch, one current-firmware command | any |

## Configuration

| Method | Returns | Command |
|--------|---------|---------|
| `await clip.mode()` / `set_mode(value)` | `"normal" \| "enhanced"` | `AT+MODE` |
| `await clip.auto_delete_days()` / `set_auto_delete_days(days)` | `int \| None` (`None` = off) | `AT+AUTODEL` |
| `await clip.brightness()` / `set_brightness(value)` | `int` 0-255 | `AT+BRIGHTNESS` |
| `await clip.configured_name()` / `set_name(name)` / `clear_name()` | user-defined name, `""` if unset | `AT+NAME` |
| `await clip.log_mode()` / `set_log_mode(value)` | `"off" \| "info" \| "debug"` | `AT+LOG` |
| `await clip.pairing_status()` | `PairingStatus` | `AT+PAIR?` |

## Recording

| Method | Returns | Command |
|--------|---------|---------|
| `await clip.start_recording(mode=None)` | session id (or `None` if unknown yet) | `AT+START` / `AT+START=<mode>` |
| `await clip.stop_recording()` | `dict` — session, duration, frames, total_size | `AT+STOP` |
| `await clip.pause_recording()` / `resume_recording()` | — | `AT+PAUSE` / `AT+RESUME` |
| `await clip.bookmark()` | `Bookmark` — position_ms, note | `AT+MARK` |

`AT+PAUSE` / `AT+RESUME` control **recording only** — a file transfer
cannot be paused, only cancelled.

## Sessions & files

| Method | Returns | Command |
|--------|---------|---------|
| `await clip.list_sessions(page_number=1, per_page=10)` | `tuple[Session]` (one page) | `AT+LIST?page&per_page` |
| `await clip.list_all_sessions(per_page=50)` | `tuple[Session]` (auto-paginated, newest first) | `AT+LIST` pages |
| `await clip.session_details(session_id)` | `SessionDetails` — files, size, synced, bookmarks, channels, sample_rate | `AT+LIST=<id>` |
| `await clip.list_files(session_id, page_number=1, per_page=20)` | `tuple[str]` — `NNNN.opus` names | `AT+LIST=<id>?page&per_page` |
| `await clip.list_bookmarks(session_id, per_page=100)` | `tuple[Bookmark]` | `AT+MARKS=<id>` |
| `await clip.delete_session(session_id, *, confirm=False)` | — raises without `confirm=True` | `AT+DELETE=<id>` |

## Download

| Method | Returns | Notes |
|--------|---------|-------|
| `await clip.start_download(session_id, *, start_file=None)` | `dict` | begin streaming (`AT+DOWNLOAD[=id[:file]]`) |
| `await clip.cancel_download()` | — | `AT+CANCEL` |
| `await clip.download_session(session_id, destination, *, start_file=None, timeout=300.0, progress=None)` | `DownloadResult` | high-level: details → stream → per-file CRC + atomic publish. `progress` is an optional callback. |

Semantics (`*.part` files, CRC32, resume via `start_file`):
[transfers.md](transfers.md).

## Wi-Fi & USB

| Method | Returns | Command |
|--------|---------|---------|
| `await clip.wifi()` | `WifiAccessPoint` — running, ssid, password, host, port, connected | `AT+WIFI?` |
| `await clip.start_wifi()` / `stop_wifi()` | `WifiAccessPoint` / — | `AT+WIFI=on/off` |
| `await clip.wifi_config()` | `(channel, country)` | `AT+WIFICFG?` |
| `await clip.set_wifi_config(channel, country)` | `(channel, country)` — applied on the **next** WiFi start | `AT+WIFICFG=<ch>:<CC>` |
| `await clip.usb_enabled()` / `set_usb_enabled(enabled)` | `bool` | `AT+USB` |

## Power & maintenance (confirm-gated)

```python
await clip.reboot()                                # AT+REBOOT
await clip.enter_dfu()                             # AT+DFU — MCUboot recovery
await clip.power_off(confirm=True)                 # AT+POWEROFF
await clip.format_storage(confirm=True)            # AT+FORMAT — wipes the SD card
await clip.reset_pairing(confirm=True)             # AT+PAIR=reset — bonds + SD
await clip.factory_reset(confirm=True)             # AT+FACTORY=confirm — settings + SD + bonds
```

Every destructive call raises `ValueError` unless `confirm=True` is
passed explicitly.

## Data models (`clip.models`)

`Status`, `Battery`, `Storage`, `Session`, `SessionDetails`,
`Bookmark`, `WifiAccessPoint`, `PairingStatus`, `DownloadedFile`,
`DownloadResult` — immutable dataclasses; `DownloadResult.files` is the
tuple of published local paths.

## Wi-Fi handoff helper

```python
from clip.wifi import handoff_to_wifi
ap = await handoff_to_wifi(clip)   # AT+WIFI=on over BLE, join host via
                                   # nmcli/networksetup/netsh, verify AT+GSTAT over UDP
```

Raises `HostWifiError` if the host cannot join the AP. Full story in
[wifi.md](wifi.md).
