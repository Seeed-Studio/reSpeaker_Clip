# Getting Started

## Requirements

Common:

- Flutter 3.27 or newer
- A physical Android phone or iPhone
- A SenseCraft Voice Clip

Android:

- JDK 17 or newer
- Android SDK 36
- Android NDK required by the installed Flutter stable release

iOS:

- macOS and Xcode with iOS 13 or newer
- CocoaPods
- An Apple Developer account for physical-device signing

## Setup

```bash
bash setup.sh android
# or
bash setup.sh ios
```

The script validates the local toolchain and installs Flutter dependencies.
The iOS setup also runs CocoaPods. It does not download credentials, alter
signing identities, or create backend configuration.

## Run

```bash
cd sdk/flutter/example
flutter devices
flutter run
```

Grant Bluetooth, Nearby Wi-Fi Devices, and Local Network permissions when
prompted. On iOS, select your own Team in
`sdk/flutter/example/ios/Runner.xcworkspace` and enable Hotspot Configuration
for the App ID.

## Suggested hardware flow

1. Scan and connect to the Clip.
2. Read version and device status.
3. Start and stop a short recording.
4. List and download the session over BLE.
5. Stop recording, prepare Wi-Fi, ping, and download the session.
6. Only with approved firmware, select a `.zip` or `.bin` package and run OTA.

See [Native SDK Verification](native-sdk-verification.md) for the Kotlin and
Swift sample flows.
