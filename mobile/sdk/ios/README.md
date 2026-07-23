# SenseCraft Voice iOS SDK

Swift Package port of the Flutter `sensecraft-voice` SDK.

Implemented capabilities:
- BLE scan/connect/disconnect
- direct reconnect by CoreBluetooth device identifier with connection timeout/retry
- post-connect `AT+GSTAT` verification with configurable timeout/retry
- AT(JSON) transport
- recording session helpers
- device management AT helpers (pause/resume/time/pair/mode/bookmarks/delete/purge/factory reset)
- Wi-Fi hotspot BLE control (`AT+WIFI?`, `AT+WIFI=ON`, `AT+WIFI=OFF`)
- phone Wi-Fi association via `NEHotspotConfiguration`
- Wi-Fi UDP transfer (`AT+GSTAT`, `AT+DOWNLOAD`, file frame parsing, CRC ACK/NACK, session file writes)
- Wi-Fi fast sync orchestration (single and batch download, AP reuse, failure classification, teardown)
- OTA firmware package parsing (`.bin`, `.zip` manifest, size/hash validation)
- OTA transport abstraction plus `NordicMcuMgrOtaTransport` when `iOSMcuManagerLibrary` is available
- file-data frame parsing
- BLE transfer frame state helper (`BleTransferFrameHandler`)
- BLE permission facade (`SenseCraftVoiceBlePermissions`)
- Wi-Fi transfer progress helper (`TransferProgress`)
- Wi-Fi AP network error helper (`WifiNetworkErrors`)
- device status and event models

## Requirements

- iOS 16+ for the provided UI sample
- Xcode with an iOS 16 SDK or newer
- A physical iPhone for BLE, Wi-Fi and OTA verification
- An Apple Developer team and Hotspot Configuration entitlement for automatic
  Wi-Fi joining

## Add the package

In Xcode, use **File → Add Package Dependencies** and select this package, or
add the local package at `sdk/ios`. Link the `SenseCraftVoiceIOS` product to the
host app target.

Swift Package Manager cannot select a package from a nested Git subdirectory.
Remote consumers therefore need a release repository/tag whose root contains
this `Package.swift`; use the local `sdk/ios` package until that release is
published.

## BLE quick start

The default scan publishes devices whose advertised name contains `Clip`.
This fallback is used because some firmware does not advertise the custom AT
service UUID.

```swift
let client = SenseCraftVoiceClient()

try await client.startScan(timeout: 12)

for await results in client.scanResults where !results.isEmpty {
    let connection = try await client.connectAndVerify(results[0])
    guard let connection else { break }

    let at = AtTransport(connection: connection)
    let session = RecordingSession(connection: connection, at: at)
    let status = try await session.getStatus()
    print(status)

    await client.disconnect(connection)
    break
}
```

Keep the client and connection alive for the full session. Stop scanning before
connecting, and disconnect during screen/service teardown.

## Host app integration sequence

1. Add Bluetooth and Local Network usage descriptions.
2. Enable Hotspot Configuration for automatic AP join.
3. Scan and let the user select a Clip.
4. Connect and verify `AT+GSTAT`.
5. Create `AtTransport`, then `RecordingSession`.
6. Stop recording before Wi-Fi transfer or OTA.
7. Tear down network/BLE resources on success, failure and cancellation.

## BLE connection readiness

```swift
let client = SenseCraftVoiceClient()

// iOS direct reconnect. `deviceId` is CBPeripheral.identifier.uuidString.
let connection = await client.connectByDeviceIdAndVerify(
    deviceId,
    connectTimeout: 8,
    connectAttempts: 2,
    policy: LinkReadyRetryPolicy(attempts: 3, retryGap: 0.45, timeout: 4)
)

// Or verify a discovered scan result before handing it to session code.
let verified = try await client.connectAndVerify(
    scanResult,
    connectTimeout: 15,
    policy: LinkReadyRetryPolicy()
)
```

`connectByDeviceId` is an iOS/CoreBluetooth fast path, not a BLE-address lookup.
It returns `nil` when the identifier is malformed, CoreBluetooth no longer knows
that peripheral, or all attempts fail. A new scan is then required.

## Wi-Fi fast sync

`WifiTransferClient.downloadSession` and
`WifiFastSyncSession.downloadSession` accept `onOverallProgress` for unified
0.0–1.0 progress.

For multiple recordings, `WifiFastSyncSession.downloadBatch` enables the device
AP once, verifies UDP reachability, downloads each `WifiBatchItem`, and tears
the AP down once. `WifiFastSyncBatchResult` reports counts, recording-state
abort, and whether BLE fallback is recommended:

- `phoneWifiDisconnected`: the AP route became unreachable.
- `phoneOnOtherWifi`: UDP verification timed out or the expected AP did not reply.
- `transferFailed`: the AP still replies but no item completed.

`ClipUdpSyncClient` uses Network.framework. On iOS its UDP connection requires
a Wi-Fi interface and prohibits cellular, so a device AP with no internet does
not silently route traffic through cellular. macOS keeps normal local route
selection for Ethernet/USB test setups while excluding cellular interfaces.

## Host app capabilities

- Enable **Hotspot Configuration** for automatic AP join through
  `NEHotspotConfiguration`.
- Add `NSLocalNetworkUsageDescription` to the host app `Info.plist`; UDP access
  to the device AP requires Local Network permission.
- Add the normal Bluetooth usage description(s) required by the host app's iOS
  deployment target.
- Add Nordic's `iOSMcuManagerLibrary` to the host app/package to activate `NordicMcuMgrOtaTransport`; otherwise the fallback returns an explicit unsupported error.

## Limits

- Automatic Wi-Fi association is iOS-only. The package still builds on macOS
  for tests and command-line verification, but it does not join an AP there.
- AP association success does not prove device reachability; batch download
  performs an explicit UDP `AT+GSTAT` probe.
- UDP file transfer resumes at a file marker (`startFile`), not a byte offset.
  `resumeByteOffset` is metadata for host progress/accounting.
- The SDK does not provide a Flutter bridge, playback, decoding, merging, or
  other audio processing.
- BLE/Wi-Fi behavior, entitlement approval, Local Network prompts, AP routing,
  and cellular coexistence still require validation on physical iOS devices.

## Verification

- `swift test`
- `swift run SenseCraftVoiceVerifyCLI smoke`
- Open
  [`Examples/iOSVerifyApp/SenseCraftVoiceVerifyApp.xcodeproj`](Examples/iOSVerifyApp/SenseCraftVoiceVerifyApp.xcodeproj)
  for physical-device verification.
- See the
  [iPhone sample guide](Examples/iOSVerifyApp/README.md) for signing, button
  order, Wi-Fi, OTA and troubleshooting instructions.
- See [`../../docs/native-sdk-verification.md`](../../docs/native-sdk-verification.md)
  for BLE and hardware smoke steps.

## Troubleshooting

- No scan results: confirm Bluetooth permission and that no other phone/app is
  connected. Use name-based scanning unless firmware advertises the service
  UUID.
- Direct reconnect returns `nil`: the saved CoreBluetooth UUID is invalid or no
  longer known; scan again.
- Wi-Fi join fails: confirm the signed App ID has Hotspot Configuration and
  Local Network permission is enabled in Settings.
- OTA reports unsupported: add and link Nordic's
  `iOSMcuManagerLibrary`.
- Use `SdkLog.bind` and the sample's **Logs** tab to retain the concrete error.

## License

Commercial — see [`LICENSE`](LICENSE).
