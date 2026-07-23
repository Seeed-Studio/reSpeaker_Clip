# respeaker-app

**reSpeaker** — companion app for the wearable AI microphone (Flutter, cross-platform iOS / Android).

---

## Overview

respeaker-app connects the ReSpeaker hardware device with cloud services, giving users a one-stop voice pipeline: **record → sync → transcribe → summarize**.

```
┌──────────────┐      BLE         ┌──────────────────┐      HTTPS       ┌──────────────────┐
│ ReSpeaker    │◄────────────────►│  respeaker-app    │◄────────────────►│  Backend service  │
│ hardware     │  recording/files │  (Flutter)        │   OSS/ASR/LLM    │  (self-hosted)    │
└──────────────┘                  └──────────────────┘                  │                   │
                                                                        └──────────────────┘
```

---

## Core features

| Module | Description |
|------|------|
| **Device management** | BLE scan/connect, record-while-transfer, resumable transfer, OTA firmware update |
| **Recording management** | Device & local file lists (paged home list + pull-to-load-more), folder management, search, trash |
| **Speech-to-text** | Multi-vendor ASR (Aliyun, Azure, etc.), multi-language, async job mode |
| **AI summary** | Multi-vendor LLM (OpenAI, Tongyi Qianwen, etc.), streaming SSE, customizable prompt templates |
| **AI configuration** | STT/LLM multi-vendor config, template CRUD, config sharing, onboarding |
| **Accounts** | OAuth (Google/Apple/GitHub) + email login/registration, automatic token refresh |

---

## Tech stack

| Aspect | Technology |
|------|------|
| Framework | Flutter (Dart) |
| Architecture | Feature-first + Clean Architecture |
| State management | Riverpod |
| Routing | go_router |
| Local storage | sqflite (SQLite) |
| Device communication | BLE (GATT) / AT command protocol |
| Firmware update | SMP (mcumgr) over BLE |

---

## Running the app

### Prerequisites

- Flutter 3.27+ (Dart 3.6+) and a **physical** Android phone or iPhone — BLE, Wi-Fi transfer, and OTA cannot be tested on a simulator/emulator.
- Android: JDK 17, Android SDK 36.
- iOS: macOS + Xcode, CocoaPods, and an Apple Developer account for device signing.

No backend keys or Firebase config files are required to build and run. Third-party login and crash reporting are optional (see below) and simply stay disabled when not configured.

### Quick start

From the repository root:

```bash
cd app
flutter pub get
flutter devices        # confirm your phone is listed
flutter run            # pick your device
```

Out of the box the app targets the production backend and uses **email login**. Core flows — BLE scan/connect, recording, transfer, and OTA — work on a real device without any extra configuration.

### Optional build-time configuration

These are injected with `--dart-define` and default to empty (the related feature is disabled if omitted):

| Key | Purpose | Default |
|-----|---------|---------|
| `APP_ENV` | Environment bucket: `release` / `test` / `dev` (drives backend + OAuth + Sentry selection) | `release` |
| `AUTH_BASE_URL` | SenseCraft auth host override | prod host (release); placeholder for test/dev |
| `PAAS_BASE_URL` | SenseCAP PaaS host override | prod host (release); placeholder for test/dev |
| `API_BASE_URL` | Business REST host override | per-env host in `server_providers.dart` |
| `GOOGLE_WEB_CLIENT_ID_PROD` / `GOOGLE_WEB_CLIENT_ID_DEV` | Google Sign-In web client id (also set `default_web_client_id` in `android/app/src/main/res/values/strings.xml` and the reversed client id in iOS) | empty (Google login disabled) |
| `GITHUB_CLIENT_ID` | GitHub OAuth App client id (callback `sensecraftvoice://oauth-callback`) | empty (GitHub login disabled) |
| `SENTRY_DSN` | Crash reporting DSN (only active in a release build with `APP_ENV=release`) | empty (disabled) |
| `API_KEY` + `API_BASE` | In-app feedback workflow key + host | empty (feedback disabled) |

Example — run against a dev backend with Google/GitHub login enabled:

```bash
flutter run \
  --dart-define=APP_ENV=dev \
  --dart-define=AUTH_BASE_URL=https://your-auth-host/authapi/ \
  --dart-define=PAAS_BASE_URL=https://your-paas-host/portalapi/ \
  --dart-define=API_BASE_URL=https://your-business-host/ \
  --dart-define=GOOGLE_WEB_CLIENT_ID_DEV=xxxxx.apps.googleusercontent.com \
  --dart-define=GITHUB_CLIENT_ID=Iv1xxxxxxxx
```

### iOS signing

Open `ios/Runner.xcworkspace` in Xcode, select **your own** development Team (no Team is committed), and enable the **Hotspot Configuration** capability for the App ID so the phone can auto-join the device Wi-Fi AP.

### Build release artifacts

```bash
flutter build apk --release        # Android
flutter build ipa                  # iOS (requires signing)
```

---

## Documentation

See **[docs/README.md](docs/README.md)** for the full index and reading order. Common entries:

| Doc | Description |
|------|------|
| [Design framework & architecture](docs/project_design_framework.md) | Layering, architecture choices, data flow, App↔backend interface contracts |
| [Recording & sync flow](docs/recording_flow.md) | Record → device sync (with resume, indexing) → transcribe → summarize → playback |
| [Device BLE protocol](../sdk/flutter/docs/DEVICE_BLE_PROTOCOL.md) | BLE UUIDs, AT commands, return-value conventions (authoritative SDK doc) |
| [OTA firmware update](docs/ota_firmware_update.md) | Firmware update steps and error handling |
| [Route reference](docs/app_routes.md) | Route paths and their pages |
| [Local database](docs/local_db.md) | SQLite table schema and business logic |
| [API reference](docs/api_reference.md) | Backend APIs called by the app |
| [AI vendor parameters](docs/ai_provider_params.md) | STT/LLM per-vendor field mapping |

---

## Device compatibility & troubleshooting

- **Large-font devices (e.g. Samsung)**: globally clamp text scaling (0.9–1.2x) to avoid layout breakage from the system's large-font setting.
- **Huawei devices**: Ogg Opus playback compatibility handling, with automatic fallback to WAV decoding.
- **iOS**: auto-reconnect BLE when the screen locks and the link drops; skip Ogg Opus and go straight to WAV. If a sync gets stuck at 0% and the log shows `JSON decode failed`, it is usually non-JSON bytes mixed onto the **JSON notify characteristic** or a truncated **`"bytes"` progress field** (e.g. `"bytes":lu` appears in `raw`). The app then: (1) tries to repair a corrupted `bytes` value to `0` and re-parse, so `AT+DOWNLOAD` does not wait forever for valid JSON; (2) ignores stray **GSTAT (IDLE)** frames while waiting for the `AT+DOWNLOAD` reply, so a status query isn't mistaken for a download reply; (3) still ignores pure synthesized parse-failure frames. Firmware should still keep the **response Notify** and **file-data Notify** strictly separated and emit complete progress JSON.
- **BLE throughput troubleshooting (logs)**: after a successful connection the app prints `BLE MTU stream:`, `BLE Clip link:`, `BLE link RSSI:`, `BLE link +500ms:`. `BLE Clip link` includes `connected`, `mtuManager` (this connection's listener), `mtuFbpNow` (FBP global cache, for comparison), the number of discovered **GATT services**, and each characteristic's `write` / `writeWithoutResp` / `notify`; the `+500ms` line compares `mtuManager` and `mtuFbpNow` again. **Android** calls `requestMtu(185)` (negotiated to the min with the peer) and, after enabling notify, calls `requestConnectionPriority(high)` to request a shorter **connection interval** (the peripheral may still reject it or apply it partially). **iOS**: FBP has no `requestMtu`, and there is **no** app-side public API equivalent to Android's "set connection interval" — the MTU is **auto-negotiated by CoreBluetooth**. If the payload is already large but throughput is still low, the bottleneck is usually the **connection interval / link layer / firmware packet pacing**.
- **Recording still reads the old session**: while transferring files the firmware's GSTAT is sometimes still `IDLE`, or after `AT+START` the GSTAT `session` hasn't switched to the new session yet; if the app resumes purely based on "idle" it may send `AT+DOWNLOAD` for **a different session**. Current logic: (1) before resuming, if GSTAT does not report a recording session, use the local `activeRecordingSessionId` (written after `AT+START` succeeds) and only sync that session; (2) in the "recording → GSTAT idle" callback, do **not** auto-trigger resume if there is still an active local recording session, still active BLE transfer tracking, or we're in the recording-start protection window; (3) **always** send another `AT+CANCEL` before starting a recording to reduce the race of `START` firing immediately while the firmware is still draining the previous transfer.
- **Older dates transferred first when multiple are pending**: resume once used `COALESCE(transfer_started_at, created_at)` in **ascending** order, so Apr 3 was sent before Apr 7. Changed to **descending** to match the list (newest first).
- **"Resync" seems to do nothing**: (1) `retryTransfer` in the list/banner checks whether `downloadSessionToLocal` actually started; if it did **not** start (blocked by recording protection, occupied by Wi-Fi fast sync, or mutually exclusive with the current BLE transfer), it surfaces `resyncCouldNotStart` instead of falsely reporting "started". (2) Tapping the list sync icon while no device is connected prompts to connect first. (3) The top transfer card also shows "resync" during **record-while-transfer with unknown total length** (the cancel button is still only available when the total is known or the transfer has ended).
- **Multiple rows "syncing" at once, with many duplicate `TRANSFER_DONE` / `FILE_START` in the same millisecond**: the firmware can only transfer one stream at a time; previously `downloadSessionToLocal` had an async preparation window before writing `_activeTransferRecordingId`, so **resync, auto-resume, and the resume loop** could enter concurrently, with multiple flows subscribing to the same BLE notify — showing multiple files starting together, jumpy progress, `PathNotFound` temp files, and `AT+DOWNLOAD` / "Transfer already in progress" fighting each other. Now serialized globally via **`_bleDownloadExclusiveChain`**: only one `downloadSessionToLocal` instance runs (including its finally) before the next begins.
- **Progress bar still 100% when the next slice starts after the previous finishes**: `_AnimatedTransferProgress` in `TransferProgressBanner` uses `_progressFloor` to prevent jitter/regressions; with multiple files, after a new `FILE_START` the **ratio drops from ~99% back to the current slice's ratio**, but **received bytes still increase monotonically**, and the old logic never reset the floor, so the display stayed clamped at 100%. Now the floor is lowered in sync when the **target progress drops noticeably (>4%) and received bytes have not regressed**, letting the bar and "syncing n%" keep up with the next slice.
- **Shows 100% while syncing but there is still throughput**: during a transfer the DB/UI clamp the ratio to **0.995** (an unfinished transfer isn't truly 100%), but `(0.995*100).round()` is **100** in Dart, so the bar looks nearly full. Now: **while syncing** the bar and text are capped at **0.99**, the percentage uses **floor** up to **99%**; only **after** completion is 100% shown.
- **New file still looks full when several slices transfer back to back**: the previous slice's `FILE_END` writes `transferProgress` close to 0.995, and nothing is written to the DB before the next `FILE_START` until the next slice's data meets the **8 KiB / 2 s** throttle — so the top banner still shows the previous slice's progress. Now: **each `BLE FILE_START` immediately recomputes progress from 0 bytes of the current slice and persists it**; the banner also relaxes the fall-back for "received bytes increased and ratio is slightly below floor", to avoid the cached `_progressFloor` briefly locking up.
- **Stuck for a long time at "syncing 99%"**: as long as `transfer_state` is still transferring, [`_wifiAlignedBleTransferProgress`](lib/src/features/device/presentation/device_controller.dart) **caps the DB ratio at 0.995**; the banner then shows **0.99 + floor**, which easily looks "stuck at 99%" for a while — especially when the current slice is in the **sliceBytes** branch, where a single slice pegs at the end while the overall session continues. **To diagnose**: in the Xcode / `flutter run` console search for `BLE transferProgress near 0.995 cap`, and check `branch=` (`sliceBytes` / `filesOnly` / `files+sessionBytes` / `expectedSession`), `rawRatio` (the un-capped real ratio), `slice=`, and `files=`; compare against SQLite `received_bytes`, `expected_bytes`, `transfer_progress`. If `rawRatio` is already far above 1 or `devSessBytes` is clearly too small, the denominator is usually inconsistent with the firmware.
- **Firmware already reported TRANSFER_DONE (e.g. 877/877) but still looks 99%**: `filesOnly` computing 1.0 is also clamped by 0.995, so it looks unfinished until the 800+ slices are merged. Now: when the **files** of `TRANSFER_DONE` / JSON `transfer_complete` match the **total** of `AT+DOWNLOAD` (or `fileCompleteCount` is reached), write **`transfer_progress=1.0`**; the banner shows **100%** for **`p==1.0` while still transferring** (the merge phase), to avoid the impression that BLE hasn't finished.
- **Large-file playback / waveform**: local playback falls back to 8 kHz WAV to shorten decoding; transcription upload is still 16 kHz; the waveform refreshes progressively by time block, and the detail page subscribes to the waveform stream lazily so audio comes out first.
