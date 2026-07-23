# SenseCraft Voice Flutter Example

Complete Flutter demo for the SDK:

1. Forward SDK logs via `SdkLog.bind`
2. Scan for SenseCraft Voice Clip devices
3. Connect to one device
4. Send `AT+VERSION` and show the JSON reply
5. Stream battery level
6. Start / stop recording via `RecordingSession`
7. Read device status via `RecordingSession.getStatus()`
8. Download sessions over BLE or WiFi fast sync
9. Pick a `.zip` / `.bin` firmware package and run OTA

## Run

```bash
cd sdk/flutter/example
flutter pub get
flutter run   # use a physical device for reliable BLE
```

From the repository root you can also run `bash setup.sh android` or
`bash setup.sh ios` to validate the host environment and install dependencies.

The example already contains the Android BLE/WiFi permissions and the iOS
Bluetooth, Local Network, Bonjour, and Hotspot Configuration settings required
by these flows.

For iOS, open `ios/Runner.xcworkspace` once, select the Runner target, and choose
your own Apple Developer **Team**. No Seeed development team is committed to
the project. The Hotspot Configuration entitlement must be enabled for the
selected App ID. Then run `flutter run` on a physical iPhone.

For Android, make sure `ANDROID_HOME` is set (or create
`android/local.properties` with `sdk.dir=...`) and run on a physical Android
device. Android 13+ prompts for Nearby Wi-Fi Devices in addition to Bluetooth.

No API key or backend configuration is required. A SenseCraft Voice Clip is
required for BLE, WiFi, and OTA hardware verification. See the SDK
[README "Platform setup"](../README.md#platform-setup) and
[INTEGRATION.md](../INTEGRATION.md) for host-app integration
details.

## First connection

1. Turn on the Clip and disconnect it from other phones/apps.
2. Tap **Scan** and grant the requested Bluetooth/location permissions.
3. Tap the Clip row in the device list. Selecting a row connects
   automatically.
4. Accept the Bluetooth pairing prompt if shown.
5. Confirm that the log contains `Connected` and that the battery indicator
   appears when available.

The default scan matches the `Clip` advertised name because some firmware does
not advertise the custom service UUID.

## Button order

After connecting:

1. **Version** sends `AT+VERSION`.
2. **Status** reads the current device/recording status.
3. **Record** starts a recording and shows its session ID.
4. **Stop** stops the active recording and stores it as `Last session`.
5. **List** lists files for the last stopped or active session.
6. **BLE DL** downloads the selected session over BLE.
7. **WiFi sync** enables the Clip AP, joins it, transfers the session over UDP
   and tears the temporary network down.
8. **OTA** opens a `.zip` / `.bin` picker and starts an upgrade.
9. **Disconnect** closes BLE and associated subscriptions.

Stop recording before starting a download or OTA. Keep the phone near the Clip
and do not power it off during OTA.

## Wi-Fi fast sync

Record and stop a session first so `Last session` is populated, then tap
**WiFi sync**. Grant location on Android 12L or older, Nearby Wi-Fi Devices on
Android 13+, and Local Network on iOS. Accept the system request to join the
Clip hotspot. A no-internet warning for the Clip AP is expected.

## Troubleshooting

- No Clip appears: verify permissions, Bluetooth state and that another
  app/phone is not connected; power-cycle the Clip and scan again.
- Android permissions remain denied after a Manifest update: uninstall and
  reinstall the app, then grant permissions again.
- Pairing/connection fails: remove a stale system Bluetooth bond after a Clip
  factory reset and retry from a fresh scan.
- Wi-Fi sync fails: stop recording, confirm the last session ID exists and
  grant the platform Wi-Fi/local-network permission.
- iOS Wi-Fi fails: verify the selected development Team/App ID has Hotspot
  Configuration enabled.
- Use the lower log panel when reporting failures; it includes the concrete SDK
  operation and exception.
