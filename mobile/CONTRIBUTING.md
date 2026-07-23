# Contributing

Run the checks for every area you change:

```bash
(cd sdk/flutter && flutter pub get && flutter analyze && flutter test)
(cd sdk/flutter/example && flutter pub get && flutter analyze && flutter test)
(cd sdk/android && ./gradlew test :sample:assembleDebug)
(cd sdk/ios && swift test)
```

Platform changes must keep the Flutter SDK example and the corresponding
native sample buildable. BLE, Wi-Fi, and OTA behavior should also be verified
on a physical device before release.

Do not commit API keys, signing certificates, provisioning profiles, fixed
Apple development Teams, absolute local paths, or Android `local.properties`.
