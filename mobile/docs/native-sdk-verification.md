# Native SDK Verification

The native SDK packages can be compiled and unit tested without hardware. Full BLE, Wi-Fi sync, and OTA validation still needs a phone and a Clip device.

## What The SDK Verifies

The native SDK is the integration layer for apps that need to talk to a SenseCraft Voice / Clip device. It is not the full product app or backend. The SDK mainly covers:

- BLE discovery, project-style Clip device filtering, connection, and GATT transport setup.
- AT JSON command send/receive, including `AT+GSTAT`, recording start/stop, pairing/status, and device events.
- Device Wi-Fi AP preparation through BLE, phone hotspot join where the OS permits it, UDP ping, and fast session download.
- OTA package selection and upgrade transport wiring.

The sample apps are manual verification hosts. Use them to prove each SDK layer works before wiring the SDK into the real app.

## iOS / Swift

Run package tests:

```bash
cd sdk/ios
env HOME=/private/tmp TMPDIR=/private/tmp swift test
```

Run the no-hardware verification harness:

```bash
swift run SenseCraftVoiceVerifyCLI smoke
```

Optional BLE smoke checks on macOS:

```bash
swift run SenseCraftVoiceVerifyCLI scan 12
swift run SenseCraftVoiceVerifyCLI status <peripheral-uuid>
```

For a real iPhone app, add the Swift package to an Xcode app target, select
your own signing Team, enable Bluetooth and Hotspot Configuration capabilities,
then repeat the BLE scan/connect/status flow on device. No Seeed development
Team is stored in the sample project.

An iPhone UI sample lives at `sdk/ios/Examples/iOSVerifyApp`. Open
`SenseCraftVoiceVerifyApp.xcodeproj` in Xcode and use the app tabs to verify
BLE, Wi-Fi transfer, and OTA flows. If the project needs to be regenerated,
run `ruby sdk/ios/Examples/iOSVerifyApp/Scripts/generate_xcodeproj.rb` from the
repository root.

### iPhone Sample Flow

Run this flow on a real iPhone. BLE, hotspot join, and UDP transfer cannot be fully validated in Simulator.

1. Open the sample app and confirm `Adapter = poweredOn`.
2. Keep `Only Clip devices` enabled. Keep `Use service UUID scan` disabled unless you specifically want to test service UUID advertising.
3. Tap `Scan`.
4. Tap the Clip device row and wait until `State = connected`.
5. Tap `Status`. A healthy connection returns an `AT+GSTAT` status line.
6. Test recording with `Start` and `Stop`.
7. Only after BLE is connected, open the `Wi-Fi` tab and tap `Prepare`.
8. If iOS shows a Wi-Fi join prompt, accept it. Then tap `Ping`.
9. Enter or keep the recording session id and tap `Download`.
10. To run OTA, add Nordic's
    `https://github.com/NordicSemiconductor/IOS-McuManager-Library.git` package
    and link the `iOSMcuManagerLibrary` product. Without it, the sample compiles
    but intentionally reports OTA as unsupported.

If `Prepare` fails:

- If the app says to connect first, BLE did not finish connecting. Go back to Control, tap the Clip device, and wait for `State = connected`.
- If connect fails with missing Clip AT service or characteristics, the selected BLE peripheral is not exposing the SDK protocol expected by this SDK/firmware.
- If the device enables Wi-Fi but phone auto-join fails, check that the Xcode target is signed with the Hotspot Configuration capability. You can still manually join the device AP in iOS Settings and then retry `Ping`.
- If `AT+WIFI=ON` fails, check the device state with `Status`; the firmware may already be in Wi-Fi sync or another state that rejects enabling AP.

## Android

Run library tests:

```bash
cd sdk/android
./gradlew test
```

Build the sample host app:

```bash
./gradlew :sample:assembleDebug
```

Install and run on a phone:

```bash
./gradlew :sample:installDebug
```

Use the sample app buttons in this order:

1. Request permissions.
2. Run local smoke.
3. Scan 12s.
4. Tap a scan result, or enter its BLE address and tap Connect + Status.
5. Verify Start/Stop Recording and the BLE download actions.
6. Stop recording, enter a session ID, then run WiFi Prepare, WiFi Ping, and
   WiFi Download in order.
7. For an approved firmware package, use Choose Firmware + OTA.

See `sdk/android/sample/README.md` for JDK/Android SDK setup and
clean-checkout build instructions.

## Hardware Checklist

- BLE scan finds the device.
- BLE connect succeeds and `AT+GSTAT` returns status.
- Wi-Fi AP can be enabled with `AT+WIFI=ON`.
- Phone joins the device AP.
- UDP ping succeeds.
- Session download writes files and reports `onOverallProgress`.
- OTA package parsing succeeds; real OTA upgrade should only be tested with approved firmware.
