# SenseCraft Voice Android Sample

This app is a manual verification host for the Android SDK. It covers BLE
scan/connect, recording start/stop/pause/resume, device status and management,
file listing, BLE download, WiFi prepare/ping/download, and `.zip` / `.bin`
firmware OTA.

## Prerequisites

- JDK 17 or newer (the SDK bytecode target remains Java 11)
- Android SDK 36
- A physical Android device with USB debugging enabled
- A SenseCraft Voice Clip for hardware operations

Set `ANDROID_HOME`, or create `local.properties` in `sdk/android`:

```properties
sdk.dir=/absolute/path/to/Android/sdk
```

No API key or backend configuration is required.

## Build and run

From the monorepo's `sdk/android` directory:

```shell
./gradlew test
./gradlew :sample:assembleDebug
./gradlew :sample:installDebug
adb shell am start -n io.sensecraft.voice.android.sample/.MainActivity
```

Alternatively, open `sdk/android` in Android Studio, select the `sample`
configuration and run it on a physical device. No API key or backend
configuration is required.

## First connection

1. Turn on the Clip and keep it near the phone. Disconnect it from other apps
   or phones before testing.
2. Tap **Request permissions**. Grant Bluetooth and location on Android 12L or
   older; Android 13+ also requests Nearby Wi-Fi Devices.
3. Tap **Scan Clip 12s**. The SDK filters out devices whose advertised name
   does not contain `Clip`.
4. Scroll to **Scan Results** at the bottom of the page and tap the Clip row.
   Tapping a result fills the BLE address and connects automatically.
5. Accept the Android Bluetooth pairing dialog if it appears.
6. Confirm that the header says `Connection: <address> <state>` and the log
   contains `PASS: AT+GSTAT`.

**Connect + Status** is an alternative connection path. It connects to the BLE
address in the first text field, so scan at least once or enter a valid Android
BLE address before tapping it.

## Recommended verification flow

After connecting:

1. Tap **Read Runtime**, **Sync Time**, **Read Device Time**, **Read Pairing**
   and **Read Name** to verify device-management commands.
2. Tap **Start Recording**. The returned session ID is filled into the
   `Recording session id` field.
3. Optionally use **Pause Recording**, **Resume Recording**, **Toggle Mode**
   and **Mark**.
4. Tap **Stop Recording**, then **List Files** and **List Bookmarks**.
5. Use **BLE Download + Merge** or **BLE Download + Finalize** while the
   recording session ID is present.

## Wi-Fi fast sync

Recording must be stopped and `Recording session id` must contain the device
session to download:

1. Tap **WiFi Prepare** and accept Android's request to join the Clip hotspot.
2. Tap **WiFi Ping** and confirm that the UDP probe succeeds.
3. Tap **WiFi Download**.
4. Tap **WiFi Teardown** when finished or before disconnecting.

The phone may temporarily show that the Clip Wi-Fi network has no internet.
That is expected. Downloads are written to the app-specific external files
directory under `SenseCraftDownloads`.

## OTA

Stay connected over BLE, stop recording, then tap **Choose Firmware + OTA**.
Select a valid `.zip` or `.bin` firmware package and keep the phone near the
Clip until the progress log reports completion. Do not power off the Clip
during an upgrade.

## Button notes

- **Run local smoke** tests parsers and progress helpers without hardware.
- **Disconnect** closes Wi-Fi, AT and BLE resources.
- **Set Name** uses the optional device-name field; an empty value clears it.
- **Start file (optional)** is a resume marker for a partial download.
- The **Logs** section at the bottom contains the actionable failure message.

## Troubleshooting

- **No Clip devices found:** confirm Bluetooth is on, all permissions are
  granted, the Clip is advertising and no other app is connected. Power-cycle
  the Clip and scan again.
- **Connection failed or timed out:** tap **Disconnect**, close other apps using
  the Clip, remove a stale system Bluetooth bond if the Clip was factory-reset,
  then scan and pair again.
- **`writeCharacteristic returned false`:** update to the latest SDK/sample;
  older builds could send an AT command before Android finished configuring
  GATT notifications.
- **Wi-Fi prepare fails:** stop recording, grant location on Android 12L or
  older and Nearby Wi-Fi Devices on Android 13+, then accept the system hotspot
  prompt.
- Reinstall after changing Manifest permissions:

  ```shell
  ./gradlew :sample:installDebug
  ```

BLE, WiFi, and OTA require a physical device; an emulator is only suitable for
the local smoke checks and UI inspection.
