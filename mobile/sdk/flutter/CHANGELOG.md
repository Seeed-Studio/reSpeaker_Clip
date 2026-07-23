# Changelog

## 0.1.0 — Initial preview release

Initial preview release, extracted from the SenseCraft Voice reference app.

### Added

- BLE scanning, connection, MTU management for SenseCraft Voice Clip devices
  (`SenseCraftVoiceClient`, `SenseCraftVoiceConnection`, `MtuManager`).
- AT(JSON) protocol transport with chunked write, JSON object framing, and
  reply matching (`AtTransport`).
- BLE permission helper for iOS/Android (`SenseCraftVoiceBlePermissions`).
- Battery level subscription.
- Device, `DeviceFileMeta`, `WifiHotspotInfo` data models.
- Pluggable logger (`SdkLog`).
- `OtaFirmwareProcessor` — parse `.zip` (with `manifest.json`) or `.bin`
  firmware packages into mcumgr `Image`s.
- `OtaSession` — high-level OTA orchestrator with normalised phases
  (`preparing → uploading → validating → resetting → success`), aggregated
  byte progress across multi-image archives, and `cancel()`.
- `WifiHotspotConnector` — enable / disable / probe device AP, join from the
  phone (Android + iOS).
- `ClipUdpSyncClient` + `WifiTransferClient` — UDP file sync on the device AP
  (port 8089).
- `RecordingSession` — high-level wrapper for `AT+START` / `AT+STOP` /
  `AT+CANCEL` / `AT+LIST` / `AT+GSTAT` / `AT+DOWNLOAD`. Exposes
  `Stream<DownloadEvent>`.
- `DeviceStatus` — typed view of `AT+GSTAT` reply.
- `parseDeviceEvent` — typed device push events on the JSON notify stream.
- Protocol reference: `docs/DEVICE_BLE_PROTOCOL.md`.
- Example app demonstrating scan, connect, `AT+VERSION`, and
  `RecordingSession.start/stop/getStatus`.

### Out of scope

- Cloud / ASR / LLM helpers — the SDK is backend-agnostic; bring your own cloud.

## Unreleased

### Added
- Unit tests for BLE file-data parsing, JSON framer, device events, AT reply
  heuristics, CRC-32, and `DeviceStatus` parsing.
- GitHub Actions CI (`flutter analyze` + `flutter test`).
- English host-app integration guide (`INTEGRATION.md`).
- `WifiFastSyncSession` — one-call WiFi fast sync (AP enable + phone join +
  UDP download + cleanup).
- Example app: BLE download, WiFi fast sync, and OTA demos.

### Changed
- Extracted `JsonObjectFramer` from `AtTransport` for testability.
- README platform setup documents WiFi fast-sync permissions (Android + iOS).
- Example README lists full demo flow (record / list / download / WiFi / OTA).
- SenseCraft Voice app firmware page uses SDK `OtaSession` instead of raw mcumgr.
