# Device BLE and AT protocol

> SenseCraft Voice Clip talks to the host app over BLE with an AT(JSON) protocol.
> This document is the **canonical protocol reference** for the
> [SenseCraft Voice SDK](../README.md). Host apps may add product-specific
> business flows (download resume, DB sync, etc.) on top.

---

## 1. BLE UUIDs and characteristics

**File**: `lib/src/ble/ble_uuids.dart` (`SenseCraftVoiceBleUuids`)

### 1.1 AT transport service (Nordic UART–style)

| Role | UUID | Direction | Notes |
|------|------|-----------|-------|
| Service | `6E400001-B5A3-F393-E0A9-E50E24DCCA9E` | - | Main Clip AT service |
| Command | `6E400002-B5A3-F393-E0A9-E50E24DCCA9E` | App → device | Write / WriteWithoutResponse |
| Response / progress | `6E400003-B5A3-F393-E0A9-E50E24DCCA9E` | Device → app | Notify — JSON responses + progress |
| File data | `6E400004-B5A3-F393-E0A9-E50E24DCCA9E` | Device → app | Notify — raw file bytes |

### 1.2 Standard BLE services

| Role | UUID | Notes |
|------|------|-------|
| Battery | `0000180F` / `00002A19` | Standard Battery Service / Level |
| Device info | `0000180A` | Standard Device Information |
| OTA (SMP) | `00001530-1212-EFDE-1523-785FEABCD123` | Zephyr/mcumgr firmware update |
| SMP characteristic | `DA2E7828-FBCE-4E01-AE9E-261174997C48` | Write / WriteWithoutResponse / Notify |

---

## 2. AT response conventions

**File**: `lib/src/at/at_transport.dart` (`AtTransport`)

### 2.1 Response format

The device pushes **JSON objects** on the **response characteristic (Notify)**.
Payloads may arrive in fragments; `_JsonObjectFramer` reassembles a full object.

### 2.2 Success / failure fields

| Field | Type | Meaning |
|-------|------|---------|
| `ok` | bool | `true` = success; `false` or missing = failure |
| `error` | string | Error text when failed |
| `data` | object | Optional nested payload (`session`, `event`, …) |
| `session` | string | Recording session id (START/STOP, …) |
| `event` | string | Event type (`state_change`, `file_complete`, `transfer_complete`, …) |

### 2.3 Event messages vs command replies

- **Event only**: `event` set and no `session` → `send()` ignores it as a command response
- **AT+STOP**: firmware may send `state_change` then a message with `session`; the SDK waits for the message **with `session`** as the STOP reply
- **Invalid JSON**: parse error → yield `{'ok': false, 'error': 'JSON decode failed', 'raw': ...}`

### 2.4 Common AT commands

| Command | Meaning | Timeout |
|---------|---------|---------|
| AT+VERSION | Firmware version | 5s |
| AT+GSTAT | Record/transfer state | 3–5s |
| AT+TIME=ts | Set device time (unix seconds) | 4s |
| AT+TIME? | Read device time | 4s |
| AT+PAIR? | Pairing status | 6s |
| AT+PAIR=reset | Reset pairing | 6s |
| AT+START / AT+START=mode | Start recording | 5s |
| AT+PAUSE | Pause | 5s |
| AT+RESUME | Resume | 5s |
| AT+STOP | Stop recording, returns `session` | 8s |
| AT+LIST | List sessions (pagination: `?page&per_page`) | 8–10s |
| AT+LIST=sessionId | List files in session | 8s |
| AT+DOWNLOAD=sessionId | Download session (continuous / resume) | - |
| AT+DOWNLOAD=sessionId:filename | Resume from named slice | - |
| AT+MARKS=sessionId | Bookmarks (paginated like LIST) | 6s |
| AT+DELETE=sessionId | Delete session on device | 8s |
| AT+CANCEL | Cancel active transfer | 5s |
| AT+MODE=val | Recording mode | 4s |
| AT+FACTORY=confirm | Factory reset | 10s |
| AT+PURGE | Clear all sessions | 10s |

**AT+START and notify ordering**: replies share the same BLE notify stream as other
JSON (e.g. `AT+GSTAT`). `AtTransport.send` treats the **first non-`event`** JSON as
the command completion; if the firmware sends a GSTAT-style JSON **before** the
START ack, older code could mis-handle it (stuck a few seconds, session not
written). **AT+START** is filtered: skip explicit GSTAT replies until the START
ack (or 5s timeout).

### 2.5 WiFi hotspot and UDP sync

**BLE side (control hotspot, read credentials)**

| Command | Meaning | Timeout |
|---------|---------|---------|
| AT+WIFI? | Hotspot state, SSID, **password** (fixed in NVS from pairing until factory reset), IP, UDP port | 5s |
| AT+WIFI=ON | Enable hotspot (Clip firmware preferred; SDK may fall back to `AT+WIFI=on`) | 10s |
| AT+WIFI=OFF | Disable hotspot (fallback `AT+WIFI=off`) | 5s |

If `AT+WIFI=ON` returns `Cannot start WiFi in current state` (firmware log often
`Invalid transition`, `AT+GSTAT` still `WIFI_SYNC`), the SDK sends `AT+WIFI=OFF`,
polls `AT+GSTAT` until **state is no longer `WIFI_SYNC`**, then retries
`AT+WIFI=ON` (`lib/src/wifi/hotspot_connector.dart`).

**Example `AT+WIFI?` response:**

```json
{
  "ok": true,
  "data": {
    "enabled": true,
    "ssid": "ClipAP_XXXX",
    "password": "<Written to NVS at pairing; fixed until next factory reset>",
    "ip": "192.168.4.1",
    "port": 8089,
    "channel": 6
  }
}
```

**After joining the AP: UDP `ip:port` (default `192.168.4.1:8089`)**

Same AT **semantics** as BLE, with two frame kinds:

1. **Plain-text AT**: client sends `AT+...\n` (e.g. `AT+LIST`, `AT+LIST=sessionId`, `AT+DOWNLOAD=sessionId`, `AT+DOWNLOAD=sessionId:0003.opus`, `AT+CANCEL`, `AT+GSTAT`).
2. **Binary frames** (file transfer): `0x10` FILE_START, `0x01` DATA (seq, len, CRC32), `0x11` FILE_END, `0x12` TRANSFER_DONE; ACK `0x03` FILE_ACK; `0x30` heartbeat; JSON AT responses wrapped as `0x20` AT_RESP (2-byte little-endian length + UTF-8 JSON).

**Flow sketch (matches `WifiHotspotConnector.enable()`):** optionally `AT+WIFI?`
(skip ON if already up) → `AT+WIFI=ON` (state in response) → **`AT+WIFI?` again**
for authoritative SSID/password/IP/port (fallback to ON response if query fails) →
phone joins AP → UDP `AT+GSTAT` probe → `AT+LIST=session` → `AT+DOWNLOAD=session`
until binary stream ends at `TRANSFER_DONE` → BLE `AT+WIFI=OFF` (optional).

**SDK files**:

| File | Purpose |
|------|---------|
| `lib/src/wifi/hotspot_connector.dart` | BLE hotspot on/off, phone WiFi join |
| `lib/src/wifi/udp_sync_client.dart` | UDP framing + session download |
| `lib/src/wifi/transfer_client.dart` | Thin wrapper over `ClipUdpSyncClient` |

### 2.6 Pagination

- `AT+LIST`: page 1 has no params; later `AT+LIST?page&per_page`, default 10 per page
- `AT+LIST=sessionId`: send only `AT+LIST=sessionId` without pagination suffix (current firmware)
- `AT+MARKS=sessionId`: `AT+MARKS=sessionId?page&per_page`
- Older firmware without pagination: fall back to parameterless requests

---

## 3. File transfer events

Consumed on the `jsonMessages` stream; typical `event` values:

| `event` | Meaning |
|---------|---------|
| `file_complete` | One file slice finished |
| `transfer_complete` | Whole session done → merge |
| `state_change` | Device state changed |

Continuous recording and resume both use `continuous: true` and **rely on
`transfer_complete` to finish** — no AT+GSTAT polling for completion.

Typed parsing: `lib/src/session/device_event.dart` (`parseDeviceEvent`).

---

## 4. MTU and chunking

**File**: `lib/src/ble/mtu_manager.dart` (`MtuManager`)

- Per-write payload: `MTU - 3`
- Long commands: try `allowLongWrite` first; on failure chunk by `min(MTU-3, 512)`; firmware reassembles
- Default negotiated MTU: 185 (compat); when stable, 247 is OK

---

## 5. BLE file-data notifications

**File**: `lib/src/ble/clip_file_data.dart` (`parseClipFileDataNotify`)

Raw bytes on the file-data characteristic are parsed into typed frames
(`ClipFileDataParsed` family) used by `RecordingSession.download`.
