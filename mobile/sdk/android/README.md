# SenseCraft Voice Android SDK

Kotlin port of the Flutter `sensecraft-voice` SDK.

Implemented in this first pass:
- BLE scan/connect/disconnect
- AT(JSON) transport
- recording session helpers
- device runtime snapshot, mark, list files, list bookmarks, device time sync
- device management AT helpers (pause/resume/time/pair/mode/bookmarks/delete/purge/factory reset)
- Wi-Fi hotspot BLE control (`AT+WIFI?`, `AT+WIFI=ON`, `AT+WIFI=OFF`)
- phone Wi-Fi association via `WifiNetworkSpecifier` (API 29+) and `WifiConfiguration` fallback
- Wi-Fi UDP transfer (`AT+GSTAT`, `AT+DOWNLOAD`, file frame parsing, CRC ACK/NACK, session file writes)
- Wi-Fi fast sync orchestration (single/batch download, verification, BLE fallback reason, teardown)
- periodic Android process binding to the device AP for the prepared session lifetime
- BLE download merge and finalize flows
- reusable resume markers, canonical expected-byte verification, slice inventory, and merge helpers
- OTA firmware package parsing (`.bin`, `.zip` manifest, size/hash validation)
- OTA SMP/mcumgr transfer via `NordicMcuMgrOtaTransport`
- file-data frame parsing
- BLE transfer frame state helper (`BleTransferFrameHandler`)
- BLE permission facade (`SenseCraftVoiceBlePermissions`)
- Wi-Fi transfer progress helper (`TransferProgress`)
- Wi-Fi AP network error helper (`WifiNetworkErrors`)
- device status and event models

`WifiTransferClient.downloadSession` / `WifiFastSyncSession.downloadSession` also accept `onOverallProgress` for a unified 0.0-1.0 progress value.

## Requirements

- Android API 24+
- Android SDK 36 for building this repository
- JDK 17+ (published bytecode target: Java 11)
- A physical Android device for BLE, Wi-Fi and OTA verification

## Add the SDK

Inside this monorepo, add the Android SDK project as a dependency:

```kotlin
dependencies {
    implementation(project(":"))
}
```

For an AAR or Maven consumer, use the coordinates described in
[Maven / AAR](#maven--aar). A remote Maven repository is not configured yet.

The SDK Manifest contributes Bluetooth, network and Wi-Fi permissions. The host
Activity must still request runtime permissions:

```kotlin
val permissions =
    SenseCraftVoicePermissions.requiredPermissions(includeWifi = true)
requestPermissions(permissions, 1001)
```

Wi-Fi requires fine location through Android 12L and
`NEARBY_WIFI_DEVICES` on Android 13+. Reinstall the app after changing Manifest
permissions.

## BLE quick start

`startScan()` defaults to name-based Clip discovery because some firmware does
not advertise the custom AT service UUID. Set `filterByService = true` only
when the target firmware is known to advertise it.

```kotlin
val client = SenseCraftVoiceClient(context)

client.startScan(timeoutMs = 12_000)
val result = client.scanResults.first { it.isNotEmpty() }.first()

val connection = client.connect(result)
val at = AtTransport(connection)
val session = RecordingSession(connection, at)

val status = session.getStatus()
val started = session.start()
val stopped = session.stop()

client.disconnect(connection)
```

Run these suspend calls from a coroutine owned by the host lifecycle. Stop any
active scan before starting a connection, keep the returned connection alive
for AT operations and disconnect it when the screen or service is disposed.

## Host integration sequence

1. Request `SenseCraftVoicePermissions.requiredPermissions(...)`.
2. Scan and let the user select a Clip.
3. Connect and wait for notification setup to complete.
4. Create `AtTransport`, then `RecordingSession`.
5. Stop recording before Wi-Fi transfer or OTA.
6. Tear down Wi-Fi and disconnect BLE on every success, failure or cancellation
   path.

## Wi-Fi batch fast sync

`WifiFastSyncSession.downloadBatch` keeps one device hotspot session alive for all
items, checks UDP reachability before transfer, stops when recording starts, and
returns a typed `WifiBleFallbackReason` when the caller should hand off to BLE.
Each `WifiBatchItem` carries the local/device ids, destination directory,
expected bytes, and resume metadata. A `WifiBatchResolveStartFile` callback can
resolve the marker immediately before each transfer.

While prepared, the SDK reapplies `forceWifiUsage(true)` every 10 seconds.
`teardown` cancels that coroutine, disposes UDP jobs/sockets, unbinds the process,
and unregisters the Android `NetworkCallback`, including failure paths.

## Public session file helpers

The package-level APIs `resolveSessionResumeStartFile`,
`resolveSessionResumeMarkers`, `resolveResumeByteFloor`,
`canonicalTransferExpectedBytes`, `inventorySessionOpusParts`, and
`mergeSessionOpusPartsInDirectory` are shared by `RecordingSession` and direct
SDK consumers. Merge inventory ignores partial files and does not append stale
`part_last.opus` after numbered slices appear.

## Maven / AAR

Coordinates are currently:

```text
io.sensecraft:sensecraft-voice-android:0.1.0
```

The Gradle `release` Maven publication includes the release AAR and sources JAR.
No remote repository or credentials are configured. To validate artifacts
locally without publishing externally:

```shell
./gradlew assembleRelease generatePomFileForReleasePublication
```

Integration notes:
- Pass an Android `Context` to `WifiFastSyncSession(at, context)` or `WifiHotspotConnector(at, context)` for automatic AP join.
- Request `SenseCraftVoicePermissions.requiredPermissions(includeWifi = true)`;
  Wi-Fi uses fine location through Android 12L and `NEARBY_WIFI_DEVICES` on Android 13+.
- Use `OtaSession(deviceId, NordicMcuMgrOtaTransport(context, bluetoothDevice))` for OTA.

## Troubleshooting

- No scan results: verify Bluetooth/runtime permissions and confirm that the
  advertised name contains `Clip`. Try service filtering only for compatible
  firmware.
- Pairing or connection failure: disconnect other clients, clear a stale
  Android bond after a device factory reset and retry from a fresh scan.
- `BluetoothUnauthorized`: the Manifest declaration alone is insufficient;
  request runtime permissions before scanning or connecting.
- Wi-Fi join failure: stop recording, request the API-level-specific Wi-Fi
  permission and accept Android's network suggestion/specifier prompt.
- Always inspect the concrete exception and bind `SdkLog` in the host app while
  integrating.

## Verification

- `./gradlew test`
- `./gradlew :sample:assembleDebug`
- `./gradlew :sample:installDebug`
- sample Activity covers scan/connect, recording controls, runtime snapshot,
  mark, list files/bookmarks, time sync, BLE merge/finalize, Wi-Fi
  prepare/ping/download, OTA file selection/upgrade, and basic smoke checks
- See [`sample/README.md`](sample/README.md) for clean-environment setup and the
  recommended hardware verification order.
- See [`../../docs/native-sdk-verification.md`](../../docs/native-sdk-verification.md)
  for BLE and hardware smoke steps.

License:
- Commercial — see [`LICENSE`](LICENSE).
