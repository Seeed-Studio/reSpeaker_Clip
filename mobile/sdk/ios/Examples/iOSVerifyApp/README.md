# SenseCraft Voice iPhone UI Sample

This sample app is a small manual verification host for the native iOS SDK.

## What it covers

- BLE scan and connect
- `AT+GSTAT`
- `AT+START` / `AT+STOP`
- `AT+VERSION` / `AT+TIME?` / `AT+PAIR?`
- `AT+MARK`
- `AT+LIST`
- `AT+DOWNLOAD` merge and finalize flows
- device time sync
- Wi-Fi hotspot enable and join
- UDP ping
- session download
- OTA file pick and upgrade trigger
- local no-hardware smoke checks

## Prerequisites

- Xcode with iOS 16 SDK or newer
- An Apple Developer account for physical-device signing
- A physical iPhone and a SenseCraft Voice Clip

No API key or backend configuration is required.

## Build and run

From `sdk/ios`, first verify the Swift package:

```bash
swift test
swift run SenseCraftVoiceVerifyCLI smoke
```

Open the sample from the monorepo root:

```bash
open sdk/ios/Examples/iOSVerifyApp/SenseCraftVoiceVerifyApp.xcodeproj
```

1. Select the **SenseCraftVoiceVerifyApp** target.
2. Under **Signing & Capabilities**, select your own development **Team** and
   change the bundle identifier if needed. No development team is committed.
3. Ensure the App ID has **Hotspot Configuration** enabled. The entitlement is
   already present in `Entitlements/SenseCraftVoiceVerifyApp.entitlements`.
4. Select a physical iPhone and run.

If the project needs to be regenerated after moving files, run this from the
monorepo root:

```bash
ruby sdk/ios/Examples/iOSVerifyApp/Scripts/generate_xcodeproj.rb
```

## First connection

1. Open the **Control** tab and confirm the Bluetooth adapter state is powered
   on.
2. Leave **Only Clip devices** enabled. The default name-based scan is used
   because some firmware does not advertise the custom service UUID.
3. Tap **Scan**, then tap a row under **Scan Results** to connect.
4. Accept the iOS Bluetooth permission or pairing prompt if shown.
5. Confirm that **Connection** is populated and **Last** reports a successful
   status operation.

The `Peripheral UUID` and **Connect** controls are for reconnecting to a
CoreBluetooth identifier already known to this iPhone. This is not a Bluetooth
MAC address. Scan again if CoreBluetooth no longer knows that identifier.

## Recommended verification flow

After connecting in the **Control** tab:

1. Tap **Status**, **Runtime**, **Sync Time**, **Time**, **Pair** and
   **Read Name**.
2. Tap **Start** beside the recording session field.
3. Optionally test **Pause**, **Resume**, **Mode** and **Mark**.
4. Tap **Stop**, then **List Files** and **List Bookmarks**.
5. Enter or retain the recording session ID before downloading.

## Wi-Fi fast sync

Stop recording, open the **Wi-Fi** tab and:

1. Enable **Join phone Wi-Fi** if the sample should join the Clip AP
   automatically.
2. Tap **Prepare** and accept the Local Network and hotspot prompts.
3. Tap **Ping**.
4. Enter the recording session ID and tap **Download**.

The Clip hotspot has no internet connection; that is expected. Keep the App ID
Hotspot Configuration capability enabled and ensure Local Network permission
is allowed in iOS Settings.

## OTA

Open the **OTA** tab, select a valid `.zip` or `.bin` package and start the
upgrade while BLE remains connected. Do not background the app, move the phone
away or power off the Clip during the transfer.

Package parsing works without an extra dependency. Actual SMP/mcumgr transfer
requires Nordic's package:

```text
https://github.com/NordicSemiconductor/IOS-McuManager-Library.git
```

Link the `iOSMcuManagerLibrary` product to the app. The SDK detects it with
`canImport(iOSMcuManagerLibrary)` and activates
`NordicMcuMgrOtaTransport`. Without it, the sample builds but OTA reports an
explicit `unsupported` result.

## Logs and troubleshooting

- The **Logs** tab contains the detailed SDK operation history.
- No Clip appears: confirm Bluetooth permission, disconnect other phones/apps,
  power-cycle the Clip and scan again.
- Service-filter scan returns nothing: disable **Use service UUID scan** and
  use the default Clip-name scan.
- Reconnect by UUID fails: CoreBluetooth forgot the identifier; perform a new
  scan and select the result.
- Wi-Fi prepare fails: verify Hotspot Configuration signing, Local Network
  permission and that recording is stopped.
- OTA is unsupported: add and link `iOSMcuManagerLibrary` to the app target.

BLE, Wi-Fi and OTA require a physical iPhone. Simulator runs are only useful
for UI inspection and local smoke checks.

## Required configuration

- Bluetooth
- Hotspot Configuration
- `NSBluetoothAlwaysUsageDescription`
- `NSLocalNetworkUsageDescription`
