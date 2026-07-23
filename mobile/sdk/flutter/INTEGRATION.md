# Host App Integration

> See [README.md](README.md) and [docs/DEVICE_BLE_PROTOCOL.md](docs/DEVICE_BLE_PROTOCOL.md).
> This SDK covers **BLE / AT / OTA / WiFi / RecordingSession** device-layer APIs.
> UI, cloud backends, local DB, and product-specific transfer/resume policies
> stay in the host app.

---

## Dependency options

### Local development (monorepo)

```yaml
dependencies:
  sensecraft_voice:
    path: ../sdk/flutter
```

### CI / release (Git reference)

```yaml
dependencies:
  sensecraft_voice:
    git:
      url: https://github.com/skye-xiao/sensecraft-voice.git
      path: sdk/flutter
      ref: v0.1.0
```

---

## What the host app must provide

| Item | Description | SenseCraft Voice app example |
|------|-------------|------------------------------|
| Platform permissions | BLE, Location (Android &lt; 12), Local Network (iOS WiFi) | `AndroidManifest.xml` / `Info.plist` |
| Device UI | Scan, connect, details, firmware update | `lib/src/features/device/` |
| Recording business | Multi-device, background resume, DB index, cloud sync | `device_controller.dart` |
| Cloud | ASR / LLM / storage — **not in SDK** | `lib/src/core/server/` |
| Log bridge | Optional `SdkLog.bind(...)` to your logger | `lib/src/bootstrap.dart` |

---

## SDK layer vs product layer

| Layer | Scope | This SDK |
|-------|-------|----------|
| Device protocol | BLE GATT, AT(JSON), UDP fast sync, OTA | Yes |
| High-level session | `RecordingSession` start/stop/list/download | Yes |
| Product business | Recording DB, Portal JWT, transcription flow | No |

---

## Known host apps

| App | Package / Bundle ID | SDK dependency | Business docs |
|-----|---------------------|----------------|---------------|
| SenseCraft Voice Flutter Example | Demo-specific | `path: ..` | `sdk/flutter/example/README.md` |

---

## Integration checklist

```
- [ ] pubspec references sensecraft_voice (path or git ref)
- [ ] Android: BLUETOOTH_SCAN / CONNECT / ADVERTISE; ACCESS_FINE_LOCATION through Android 12L for Wi-Fi; NEARBY_WIFI_DEVICES on Android 13+
- [ ] iOS: NSBluetoothAlwaysUsageDescription; Local Network usage for WiFi fast sync
- [ ] SdkLog.bind wired (optional, helps debugging)
- [ ] Minimal path works: scan → connect → AtTransport → RecordingSession
- [ ] OTA: OtaFirmwareProcessor + mcumgr, or OtaSession high-level wrapper
- [ ] WiFi fast sync: `WifiFastSyncSession.downloadSession(...)` or manual
      `WifiHotspotConnector.enable → WifiTransferClient.downloadSession`
- [ ] Update docs/DEVICE_BLE_PROTOCOL.md when device protocol behaviour changes
```

---

## What to read when integrating

```
1. sdk/flutter — protocol, public API, INTEGRATION.md
2. app — complete device demo and platform configuration
3. Product host app — UI, DB, cloud, business transfer/resume logic
```
