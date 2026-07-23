# SenseCraft Voice SDK for Flutter

Flutter SDK for connecting to **SenseCraft Voice Clip** devices over Bluetooth
Low Energy (BLE). Provides scanning, GATT link management, the AT(JSON)
protocol transport, file-data frame parsing and data models.

The SDK is **backend-agnostic**: it does not depend on any cloud service. Bring
your own ASR / LLM / storage.

> Status: **0.1.0 preview** — BLE / AT / OTA / WiFi / high-level
> `RecordingSession` included. Native Swift and Kotlin SDKs live beside this
> package in the monorepo.

---

## Install

In your app's `pubspec.yaml`:

```yaml
dependencies:
  sensecraft_voice:
    # Local monorepo:
    path: ../sdk/flutter
    # CI / release (after pushing to GitHub):
    # git:
    #   url: https://github.com/skye-xiao/sensecraft-voice.git
    #   path: sdk/flutter
    #   ref: v0.1.0
```

Then:

```bash
flutter pub get
```

## Run the example demo

From the monorepo root:

```bash
bash setup.sh android   # or: bash setup.sh ios
cd sdk/flutter/example
flutter run
```

Use a physical Android phone or iPhone. The demo covers scan, connect,
`AT+VERSION`, battery, recording, status, file listing, BLE/Wi-Fi download and
OTA. See [`example/README.md`](example/README.md) for the complete button
order and platform-specific run instructions.

## Platform setup

The SDK uses `flutter_blue_plus` and `permission_handler`. The host app must
declare the matching permissions.

### Android

`android/app/src/main/AndroidManifest.xml`:

```xml
<uses-permission android:name="android.permission.BLUETOOTH_SCAN"
    android:usesPermissionFlags="neverForLocation" />
<uses-permission android:name="android.permission.BLUETOOTH_CONNECT" />
<uses-permission android:name="android.permission.BLUETOOTH_ADVERTISE" />
<!-- BLE on older devices and Wi-Fi APIs through Android 12L require location -->
<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION"
    android:maxSdkVersion="32" />
<!-- Required for WiFi fast sync (join device AP) -->
<uses-permission android:name="android.permission.ACCESS_WIFI_STATE" />
<uses-permission android:name="android.permission.CHANGE_WIFI_STATE" />
<uses-permission android:name="android.permission.ACCESS_NETWORK_STATE" />
<uses-permission android:name="android.permission.CHANGE_NETWORK_STATE" />
<uses-permission android:name="android.permission.INTERNET" />
<uses-permission android:name="android.permission.NEARBY_WIFI_DEVICES"
    android:usesPermissionFlags="neverForLocation" />
```

### iOS

`ios/Runner/Info.plist`:

```xml
<key>NSBluetoothAlwaysUsageDescription</key>
<string>This app uses Bluetooth to communicate with SenseCraft Voice devices.</string>
<key>NSBluetoothPeripheralUsageDescription</key>
<string>This app uses Bluetooth to communicate with SenseCraft Voice devices.</string>
<!-- Required for WiFi fast sync (join device AP, UDP transfer) -->
<key>NSLocalNetworkUsageDescription</key>
<string>This app connects to your SenseCraft Voice device over WiFi for faster file transfer.</string>
<key>NSBonjourServices</key>
<array>
  <string>_services._dns-sd._udp</string>
</array>
```

For WiFi hotspot join, add the **Hotspot Configuration** capability in Xcode
(Runner target → Signing & Capabilities). The Local Network permission prompt
is provided by `NSLocalNetworkUsageDescription`; it is not a separate Xcode
capability.

## Quick start

```dart
import 'package:logger/logger.dart';
import 'package:sensecraft_voice/sensecraft_voice.dart';

Future<void> main() async {
  // Optional: forward SDK logs to your favourite logger.
  final logger = Logger();
  SdkLog.bind((level, message, error, stack) {
    switch (level) {
      case SdkLogLevel.debug:   logger.d(message); break;
      case SdkLogLevel.info:    logger.i(message); break;
      case SdkLogLevel.warning: logger.w(message, error: error, stackTrace: stack); break;
      case SdkLogLevel.error:   logger.e(message, error: error, stackTrace: stack); break;
    }
  });

  final sdk = SenseCraftVoiceClient();

  // Scan
  await sdk.startScan(timeout: const Duration(seconds: 8));
  final results = await sdk.scanResults.firstWhere((r) => r.isNotEmpty);
  await sdk.stopScan();

  // Connect
  final conn = await sdk.connect(results.first);

  // Send AT commands
  final at = AtTransport(
    commandRx: conn.commandRx,
    responseTx: conn.responseTx,
    fileData: conn.fileData,
    mtu: conn.mtu,
  );

  final version = await at.send('AT+VERSION');
  print('Version reply: $version');

  // Subscribe to battery
  conn.batteryLevelStream?.listen((pct) => print('Battery: $pct%'));

  // Done
  await sdk.disconnect(conn);
}
```

## Public API surface

| Layer | Class | Purpose |
| --- | --- | --- |
| BLE | `SenseCraftVoiceClient` | Scan / connect / disconnect |
| BLE | `SenseCraftVoiceConnection` | Holds a live BLE link + characteristics + MTU + battery |
| BLE | `SenseCraftVoiceBleUuids` | UUID constants (service / characteristics / SMP / battery) |
| BLE | `SenseCraftVoiceBlePermissions` | Runtime BLE permissions helper |
| BLE | `MtuManager` | Tracks negotiated ATT MTU; requests high MTU on Android |
| BLE | `parseClipFileDataNotify` + `ClipFileDataParsed` family | Parse one BLE file-data notification |
| AT | `AtTransport` | Send AT commands, await JSON replies, observe notify stream |
| Session | `RecordingSession` | High-level `start/pause/resume/stop/cancel/list/getStatus/download` |
| Session | `DeviceStatus` | Typed view of `AT+GSTAT` |
| Session | `DownloadEvent` (sealed) | Stream events during `AT+DOWNLOAD` |
| Session | `DownloadStartRetryPolicy` | Configurable retry / cancel behavior for starting `AT+DOWNLOAD` |
| Session | `RecordingSession.deleteSessionAfterLocalVerification` | Safe remote delete after merged file verification |
| Session | `RecordingSession.downloadMergeFetchBookmarksAndMaybeDeleteSession` | Full download, merge, bookmarks, and cleanup flow |
| OTA | `OtaFirmwareProcessor` | Parse `.zip` / `.bin` into mcumgr images |
| OTA | `OtaSession` | High-level OTA upgrade with normalised phases and aggregated progress |
| WiFi | `WifiFastSyncSession` | One-call BLE AP + phone join + UDP download |
| WiFi | `WifiHotspotConnector` | Enable device AP + join from phone (Android/iOS) |
| WiFi | `WifiTransferClient` + `ClipUdpSyncClient` | UDP file sync over device AP |
| Models | `Device`, `DeviceFileMeta`, `WifiHotspotInfo`, `RecordingMode` | Data models |
| Utils | `SdkLog` | Pluggable logger facade |

### Typical end-to-end flow

```dart
import 'dart:io';
import 'package:sensecraft_voice/sensecraft_voice.dart';

final sdk = SenseCraftVoiceClient();
await sdk.startScan();
final result = (await sdk.scanResults.firstWhere((r) => r.isNotEmpty)).first;
final conn = await sdk.connect(result);
final at = AtTransport(
  commandRx: conn.commandRx,
  responseTx: conn.responseTx,
  fileData: conn.fileData,
  mtu: conn.mtu,
);
final session = RecordingSession(connection: conn, at: at);

// 1. Record
final start = await session.start();
await Future<void>.delayed(const Duration(seconds: 10));
final stopInfo = await session.stop();

// 2. List & download
final files = await session.listFiles(sessionId: start.sessionId);
print('Files: ${files.map((f) => f.name).toList()}');

session.download(sessionId: start.sessionId).listen((event) {
  switch (event) {
    case DownloadFileCompleted():
      File('/tmp/${event.filename}').writeAsBytesSync(event.bytes);
      break;
    case DownloadTransferDone():
      print('All ${event.fileCount} files received.');
      break;
    default:
      break;
  }
});

// 3. OTA upgrade
final ota = OtaSession(deviceId: conn.device.remoteId.str);
ota.events.listen((p) => print(p));
await ota.upgrade(File('/path/to/firmware.zip'));

await sdk.disconnect(conn);
```

## Recommended host-app flow

1. Bind `SdkLog` during integration.
2. Request platform permissions and start a name-based scan.
3. Show the returned Clip results and stop scanning before connecting.
4. Keep `SenseCraftVoiceConnection`, `AtTransport` and `RecordingSession`
   together for the connected lifetime.
5. Stop recording before BLE/Wi-Fi download or OTA.
6. Tear down Wi-Fi, stream subscriptions and BLE on success, failure,
   cancellation and widget disposal.

The default scan matches the `Clip` name because some firmware does not
advertise the custom AT service. Use `filterByService: true` only for firmware
known to advertise that UUID.

## Wi-Fi and OTA notes

- Wi-Fi fast sync requires a valid device recording session ID.
- Android 12L and older use fine location for Wi-Fi APIs; Android 13+ uses
  Nearby Wi-Fi Devices.
- The Clip hotspot intentionally has no internet connection.
- On iOS, automatic joining requires Hotspot Configuration signing and Local
  Network permission.
- OTA accepts `.zip` and `.bin` packages. Keep BLE connected and do not power
  off the Clip during an upgrade.

## Troubleshooting

- No devices: verify Bluetooth permissions, disconnect other clients and use
  the default Clip-name scan.
- Android scan or Wi-Fi permission remains denied after a Manifest change:
  uninstall/reinstall the host app and grant permissions again.
- Connection or pairing fails: remove a stale system bond after a Clip factory
  reset, power-cycle the device and scan again.
- Wi-Fi join fails: stop recording, grant the API-specific permission and
  accept the system hotspot prompt.
- iOS Wi-Fi fails: verify the signed App ID has Hotspot Configuration and Local
  Network access is enabled in Settings.
- Preserve the `SdkLog` output and the concrete exception when reporting an
  issue.

## Device protocol

The Clip AT(JSON) protocol is documented in
[`docs/DEVICE_BLE_PROTOCOL.md`](docs/DEVICE_BLE_PROTOCOL.md).
Host-app integration notes: [`INTEGRATION.md`](INTEGRATION.md).
Key UUIDs:

| Use | UUID |
| --- | --- |
| Clip AT service | `6E400001-B5A3-F393-E0A9-E50E24DCCA9E` |
| Command (Write) | `6E400002-...` |
| Response (Notify) | `6E400003-...` |
| File data (Notify) | `6E400004-...` |
| Battery service | `0000180F-...` |
| OTA (SMP) | `00001530-1212-EFDE-1523-785FEABCD123` |

## Roadmap

- **0.2** — Unit / integration tests; deeper retry & CRC resync in
  `RecordingSession.download`; migrate Android WiFi scan to `wifi_scan` plugin.
- **1.0** — API freeze, stable Flutter/Swift/Kotlin parity and published
  packages.

## License

Commercial — see [`LICENSE`](LICENSE).
