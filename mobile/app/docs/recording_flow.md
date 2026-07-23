# Recording → sync → transcription → summary (business flow)

> **Single entry point**: device recording, BLE/WiFi sync, resume, index alignment, transcription and summary, playback and UI state are all covered here by section.  
> Protocol detail (UUIDs, AT table): [device_ble_protocol.md](device_ble_protocol.md). Architecture overview: [project_design_framework.md](project_design_framework.md).

---

## 1. End-to-end overview

```
[Device record] → [while recording / after stop] → [local .opus] → [upload OSS] → [ASR] → [LLM summary]
     │                    │                          │              │              │              │
   AT+START            AT+DOWNLOAD              mergeAllParts   uploadToOss   asr/jobs or    llm/chat
   AT+STOP             fileDataBytes            local_path      remote_url    asr/binary     summary
```

---

## 2. Recording phase

### 2.1 Entry

- Device detail / recording sheet: user taps **Start recording**
- Preconditions: device connected over BLE

### 2.2 Key steps

1. **AT+TIME**: best-effort set device time (failure does not block)
2. **AT+START**: start recording; firmware returns `session` (some builds use `data.session` vs root)
3. **Continuous download**: immediately `AT+DOWNLOAD=sessionId` to stream while recording
4. **AT+STOP**: on user stop; firmware returns `session`; if missing, wait ~0.9s then `AT+LIST` fallback for latest session

### 2.3 Timing logic

- **Continuous download**: **do not** poll AT+GSTAT; use phone local clock
- **Recording sheet**: pull AT+GSTAT only when **opening / re-entering** the sheet (or reconnecting from “disconnected” inside the sheet); no periodic GSTAT inside the sheet. Brief GSTAT alignment still after `AT+START`/`AT+STOP` (`RecordingSessionSheet`)
- **Not continuous**: timing uses local anchors / local clock like continuous mode; no periodic GSTAT inside the sheet

---

## 3. Sync phase (device → app)

### 3.1 Triggers

- **Continuous download**: `downloadSessionToLocal` right after AT+START succeeds
- **Download after stop**: after AT+STOP create/update row, then `downloadSessionToLocal`
- **Resume**: after reconnect, `_resumeIncompleteTransfers()` continues `transferring` / `failed` rows

### 3.2 Data path

```
AT+DOWNLOAD → fileDataBytes stream → part files (*.opus.part) → file_complete → *.opus
                                                                    ↓
                                            transfer_complete → mergeAllParts → {sessionId}.opus
                                                                    ↓
                                            local_path persisted, transfer_state='done'
```

### 3.3 Progress and state

| Moment | transfer_state | transfer_progress |
|--------|----------------|-------------------|
| Download starts | transferring | 0 |
| ~8KB received | transferring | received/expectedBytes (cap 0.995) |
| Before STOP | transferring | estimate from received (~10MB = 100%) |
| transfer_complete | done | 1.0 |
| Merge done | done | 1.0, local_path written |

### 3.4 Resume (command layer)

- Compute `startFile` from `synced` in `AT+LIST=sessionId` or local `.part` files
- `AT+DOWNLOAD=sessionId:filename` continues from that slice
- If firmware says resume at 0006 but local lacks 0001–0005, fall back to 0001 from the start

### 3.5 Auto-resume after connect (code path)

After connect, run: walk device list → align local rows → validate incomplete → resume (same idea as `py_test`):

```
connect() completes
    ↓
syncConnectedDeviceInfo()
    ├── AT+VERSION / AT+GSTAT (device info)
    └── (async) syncDeviceFileIndex()
            → _ensurePendingTransfersForNewSessions()
            → invalidate(recordingsListProvider)
            → _verifyAndResumeTransfers()
                    ├── _verifyAndRepairDoneTransfers()   // verify each file for rows marked done; incomplete → transferring
                    └── _resumeIncompleteTransfers()      // downloadSessionToLocal for transfer_state == transferring
```

**Query**: `listIncompleteTransfers(deviceId)` is usually `source=device` and `transfer_state=transferring`.

**UI**: list may show “syncing” while disconnected; after connect the list `invalidate`s—if DB progress is not written yet, the bar can flicker; **DB** `transfer_progress` / `transfer_state` is authoritative.

**Fast Sync (recording list banner)**: while BLE is transferring **this** row, user may tap **Fast sync**: during `startWifiHandoff(recordingId)` **all** BLE `downloadSessionToLocal` and the whole `_resumeIncompleteTransfers` path **pause**, so another still-`transferring` row (e.g. a short session already synced on device) cannot steal `AT+DOWNLOAD` after Wi‑Fi hotspot fails (firmware log `transport type 0`). Flow: only if `activeTransferRecordingId == this row`, `cancelTransfer(..., errorCode: 'wifi_handoff')` and wait until cleared; if there is **no** active BLE stream (sheet dismissed, firmware IDLE, no in-memory transfer), **skip** `cancelTransfer` and go straight to `WifiTransferController.transferSession` to avoid false “cannot stop Bluetooth transfer”. Sheet can close anytime (hotspot off, `endWifiHandoff`); it auto-dismisses when Wi‑Fi transfer phase starts (`fast_sync_wifi_sheet.dart`). **Manual dismiss** (not auto after UDP started) later calls `DeviceController.resumeBleTransfersAfterFastSyncDismiss()` → `_resumeIncompleteTransfers()` for rows stuck `transferring` / `failed` after `wifi_handoff` or Wi‑Fi failure.

**List “retry sync”**: if AT+GSTAT shows **recording/paused** and **session** ≠ the `devicePath` row you want to sync, reject `retryTransfer` / inside `downloadSessionToLocal(continuous)` do not preempt the active BLE transfer. Otherwise an old session’s `AT+DOWNLOAD` cancels **live** continuous recording; the recording UI binds `_activeTransferRecordingId` to the wrong row and uses old `startedAt` for duration → fake “timer jumped to tens of minutes”.

### 3.6 Continuous recording and multi-session queue (design rules)

Firmware typically allows **one** BLE file transfer (`AT+DOWNLOAD` stream) at a time. App rules:

| Rule | Behavior |
|------|----------|
| **Global mutex** | If `_activeTransferRecordingId != null`, `_resumeIncompleteTransfers()` **returns** immediately—no second download for other `transferring`/`failed` rows. |
| **While recording** | When `getRecordingStatus` is **recording** with `session`, resume list **keeps only** rows matching that session root id; others wait until this continuous session ends or recording stops, then next `_resumeIncompleteTransfers`. |
| **Serial queue** | When multiple rows may resume, `await downloadSessionToLocal` **runs in row order**; no parallel BLE downloads in one pass. |
| **Order** | `listTransfersToResume` and controller sorts use `COALESCE(transfer_started_at, created_at)` **DESC**—newest first like the home list. |
| **Chain** | After a download **merges successfully**, still `unawaited(_resumeIncompleteTransfers())` after clearing `_activeTransferRecordingId` to pick the next row. |
| **Re-entrancy** | `_resumeIncompleteTransfersBusy` blocks concurrent loops from reconnect, STOP, idle notify, etc., avoiding duplicate `AT+DOWNLOAD`. |
| **Recording start guard** | `startRecording` sets `_bleTransferGuardForRecordingStart`: until UI calls `downloadSessionToLocal(..., allowDuringRecordingStartGuard: true)` to claim the BLE slot, `_resumeIncompleteTransfers` and **normal** `downloadSessionToLocal` do not start. `_stopBleTransferAndDeviceWifiForRecording` does `_waitForResumeLoopIdle`, cancels in-memory transfers, and **best-effort `AT+CANCEL`** for firmware still sending when app lost `_activeTransferRecordingId`. |

### 3.7 Local `.part` and “synced” validation

Before resume, **done** rows get **repair** validation (not only file count):

1. **Device still has files**: `_listSessionFiles(sessionId)` (`AT+LIST=session`) vs local filenames.
2. **Local completeness**:
   - `*.opus.part` → incomplete (interrupted)
   - `*.opus` size == 0 → incomplete
   - `*.opus` size > 0 → tentatively complete

If device still has the file but local is incomplete → reset to `transferring` with `startFile` and re-download.

**Firmware metadata limits** (validation accuracy):

| Source | per-file size/CRC |
|--------|-------------------|
| Typical `AT+LIST=session` | `size` often **session total**, not per slice |
| Mid-transfer `file_ready` | May include `{filename, size}` |
| `file_complete` | Often only `filename` |

Without per-slice metadata, rely on `.opus.part` / zero-length files; if firmware later returns `[{name,size},…]` in LIST, validation can be tightened.

**Resume offset**: prefer firmware `synced` from `AT+LIST=session` (`{files, size, synced}`), start at `(synced+1).opus`; if `synced` missing, derive from local `.part` or `local max+1`.

### 3.8 BLE disconnect during recording

| Scenario | Handling |
|----------|----------|
| Still on recording UI | disconnect listener → `reconnectToLastDevice` → `syncConnectedDeviceInfo` → `_verifyAndResumeTransfers` |
| Sheet closed, re-open | `_syncFromDeviceOnce` sees disconnect + `lastConnectedDeviceId` → reconnect → resume via `syncConnectedDeviceInfo` |
| App foreground | `DeviceStatusPoller` on `resumed` tries reconnect if needed |

### 3.9 Large files: disk and memory (long recordings)

| Risk | Notes |
|------|-------|
| Disk peak | Before merge, parts + merged copy ≈ up to **2×**; long Opus can be hundreds of MB |
| Memory | Merge uses streaming `openRead`, not full-file `readAsBytes` |

**Mitigations**: stream in `mergeAllParts`; delete parts after success + DB update.

- **Slice rename on Android**: if `rename` right after `IOSink.close()`, some devices don’t see the temp `.part` on `exists()` yet → **slice missing** (log `tmp file missing before rename`). App adds longer settle + **poll `exists()`** on Android.
- **Merge contiguity**: if only `0001.opus`, `0002.opus`, `0004.opus` (**gaps**), **do not** merge to final file; keep `transferring` + `transfer_gap_missing_slices` to avoid corrupt short files / wrong duration.

**Possible future**: check free disk before transfer; firmware caps slice duration (e.g. 5–10 min) to limit slice size.

### 3.10 Session-level rows and `syncDeviceFileIndex`

| Item | Notes |
|------|-------|
| Granularity | **1 session = 1 recording row**; `devicePath` is sessionId (e.g. `20250101_120000`), same as Python `sync.py` |
| Row creation | `createPendingDeviceRecording` (e.g. after STOP), `syncDeviceFileIndex` (paginated `AT+LIST` after connect) |

**`syncDeviceFileIndex` summary**:

1. **Default** (`fetchAllPages: true`): `AT+LIST` / `AT+LIST?page&per_page` until complete; yield with `Future.delayed(Duration.zero)` per page.
2. **Optional** (`fetchAllPages: false` + `syncDeviceFileIndexContinue`): on-demand pages; no “session deleted on device” cleanup until the full remote set is known (avoid wrong deletes).
3. Per session: `upsertFromDeviceFile(devicePath: sessionId)`; yield every **20** upserts. Cleanup: when `remoteSessionIds` is **complete**, if `sessionId` missing: no `localPath` → delete row; has `localPath` → `updateDevicePresent(present: false)`.

**When it runs**: after BLE connect in `syncConnectedDeviceInfo`; recording page `_maybeAutoSyncDeviceIndex` (both default full sync). Home list scroll-end only loads more from local SQLite `loadMore`, not device LIST.

**Removed**: “sync all sessions”–style entry that duplicated one file as many list rows.

### 3.11 BLE binary frames: CRC, cancel, preemption delay

- **Serialize GATT notifies**: independent `async` per notify on `fileDataBytes` can reorder `FILE_END` vs `DATA`/`FILE_START` and break CRC → **false CRC** and wrong `AT+CANCEL`. App uses a **Future chain** so frames on one transfer leg are strictly ordered.
- **Stale FILE_END**: if CRC fails but `FILE_END` slice index **≤** `fileCompleteCount` (slices already flushed), treat as duplicate/late: **log only, no CANCEL**.
- **FILE_END CRC mismatch** (not stale): drop temp slice → `AT+CANCEL` → ~400ms → auto re-pull next slice **`(fileCompleteCount + 1)`** as `AT+DOWNLOAD=sessionId:0003.opus` (up to **3** resyncs inside one `downloadSessionToLocal`), then error + DB failure.
- **`AT+DOWNLOAD` busy** (e.g. `Transfer already in progress`): `AT+CANCEL` → ~600ms → retry (shares retry budget with `Session not found`).
- **`cancelTransfer`**: after successful `AT+CANCEL`, complete the waiting `Completer` on the leg and poll until `_activeTransferRecordingId` clears in `finally` (max ~**2.5s**), not only the 10s watchdog.
- **`retryTransfer` / `continuous` preemption**: after `cancelTransfer` drain, fixed trailing delay **2s → 200ms**.

### 3.12 Parity with Python helpers

| Capability | Notes |
|------------|-------|
| ensure_idle | Before record, poll `AT+GSTAT`; if still recording, `AT+STOP` and wait IDLE |
| Cancel transfer | `cancelTransfer` → `AT+CANCEL` + wait for leg to finish; UI may expose cancel |
| delete_after | `downloadSessionToLocal(deleteAfterSync)` + prefs like `delete_after_sync` |
| Recording mode | `AT+MODE` / device normal vs enhanced |
| Bookmarks | After transfer `AT+MARKS=session_id`; local `{sessionId}_bookmarks.json` |

---

## 4. Transcription (ASR)

### 4.1 Trigger

- Recording detail: user chooses **Transcribe** or **Transcribe + summarize**
- Sheet: STT config, language (Auto/zh/en), template if summarizing too

### 4.2 Flow

1. Ensure `asr_result_id` (`ensureAsrResultId`)
2. If upload needed:
   - **App**: decode `.opus` via `decodeAudioToWavForPlayback` (default **16 kHz** PCM for ASR quality) → WAV → `uploadToOss` → `remote_url`
   - Reason: many ASR vendors (e.g. Alibaba DashScope `fun-asr`) reject Ogg Opus; WAV/PCM only
3. `POST /api/v1/asr/jobs` body `{ url, id, language }`
4. Poll `GET /api/v1/asr/jobs/:id`
5. On success use returned `asr_result_id` → `GET /api/v1/asr/result/:id`
6. Persist result and set `recordings.asr_result_id`

### 4.3 Server Ogg→WAV fallback

`asrCtrl.RecognizeByURL` can convert automatically when the URL is `.opus`/`.ogg`:

1. Detect extension
2. Download → `asr.DecodeOggOpusToPCM` → `asr.PCMToWAVBytes` → upload WAV → ASR with new URL
3. Code: `pkg/controller/asr/asr.go` (`convertOggToWAV`), `pkg/asr/opus.go`

### 4.4 Timeouts

- URL ASR: job mode, client polls
- 504/502: UI “Transcription timed out, retry later” + retry button

---

## 5. Summary (LLM)

### 5.1 Trigger

- Detail: **Summarize** or **Transcribe + summarize**
- Sheet: LLM config, template, language

### 5.2 Flow

1. If transcript exists: use as `input`
2. Else: run transcription first, then summary
3. `POST /api/v1/llm/chat`, SSE stream
4. Template `content` as system prompt for format
5. Store in `recording_summaries` or LLM session

### 5.3 Timeout

- LLM chat: **180s**

---

## 6. Recording detail — audio playback

> Files: `recording_detail_page.dart`, `audio_waveform_peaks.dart`, `ogg_opus_muxer.dart`, `raw_opus_decoder.dart`

### 6.1 Format chain

Device audio is **raw Opus** (length-prefixed frames, not a standard container). Playback needs conversion:

```
raw Opus (.opus)
  │
  ├─► Ogg Opus (rawOpusToOggOpus, compute isolate)  ─► just_audio
  │       ↑ Standard container; many Android devices decode natively
  │       × Huawei MediaCodec / iOS AVPlayer may not
  │
  └─► WAV PCM (decodeRawOpusToWav, opus_dart)        ─► just_audio (ultimate fallback)
```

### 6.2 Platform-aware playback

`_sOggOpusFailed` skips Ogg attempt when set:

| Platform | Initial | Behavior |
|----------|---------|----------|
| **iOS** | `true` (`Platform.isIOS`) | Always WAV |
| **Android (typical)** | `false` | Try Ogg first |
| **Android (Huawei, …)** | `false` then `true` after fail | First Ogg fail sets flag; same session later pages skip Ogg |

`_bindJustAudio` flow:

```
if _preferWavForDeviceOpus (= _sOggOpusFailed):
  decodeAudioToWavForPlayback(sampleRate: 8000) → setFilePath(wav)   // 8k for smaller local decode
else:
  try setFilePath(rawOpus)
  catch → try decodeAudioForPlayback(rawOpus → Ogg) → setFilePath(ogg)
         catch → _sOggOpusFailed = true → decodeAudioToWavForPlayback(sampleRate: 8000) → setFilePath(wav)
```

Full WAV decode path also uses **8 kHz** (matches `_ensureDecodedWavCached(..., sampleRate: 8000)` for waveform, faster first frame).

### 6.3 Waveform decode

`audio_waveform_peaks.dart`:

- **Raw Opus**: no `OggS` magic → `decodeRawOpusToWav` via `opus_dart`, **no FFmpeg**; preview may cap PCM with **`maxPcmOutputBytes`** (first N seconds)
- **Standard containers** (Ogg/CAF): FFmpeg with `-nostdin -loglevel error -threads 0 -vn`; preview may use **`-t 900`** (first 15 min)
- **Waveform**: short files (≤12MB and ≤15 min est.) decode full **8 kHz** temp WAV then `extractWavPeaksStreamWithFraction` in chunks; **longer / larger** decode **first 15 min** PCM once; `parsedFraction` from DB `duration_seconds` (`waveformPeaksProvider`) or size estimate; large local **.wav** (≥~12MB) also uses chunked peak stream
- **Detail page**: `waveformPeaksProvider` subscribes ~**450ms** after local path playable so `just_audio` `setFilePath` wins the race with WAV fallback CPU

### 6.4 Ogg mux in isolate

`rawOpusToOggOpus` runs in `compute()` to avoid blocking the UI isolate.

### 6.5 Duration sync

Player duration syncs to DB (`_syncDurationToDbIfNeeded`). When `boundPlayableIsOgg=true` (trying Ogg, not yet stable), **skip DB sync** so Huawei-style Ogg crashes before stable decode don’t flash wrong duration in UI.

---

## 7. State ↔ UI mapping

| Condition | List / detail |
|-----------|---------------|
| transfer_state=transferring | Syncing + progress bar |
| transfer_state=done, job_state=processing | Transcribing / summarizing |
| transfer_state=done, job_state=done | Done; open transcript / summary |
| `local_path` set, **existence check pending** | Blank placeholder (same rounded box as player, no text) |
| `local_path` empty or file **confirmed missing** | “Local audio missing; sync to phone first.” |
| `local_path` set, file exists, player binding | Blank placeholder (same as above) |

> **Async exists check**: `File(p).exists()` is async. Until it completes, show placeholder not error to avoid flicker; `_localExistsChecking` distinguishes “checking” vs “confirmed missing”.

---

## 8. Related files

| Area | Main files |
|------|------------|
| Recording sheet | `recording_session_sheet.dart` |
| Device / download / resume | `device_controller.dart` |
| WiFi hotspot path | `data/wifi/`, `wifi_transfer_controller.dart` |
| AT transport | `clip_at_transport.dart` |
| STT / LLM APIs | `asr_api.dart`, `llm_api.dart` |
| Detail / playback / STT | `recording_detail_page.dart` |
| Recordings repo | `recordings_repository.dart` |
| Ogg mux | `core/audio/ogg_opus_muxer.dart` |
| Raw Opus decode | `core/audio/raw_opus_decoder.dart` |
| Waveform | `core/audio/audio_waveform_peaks.dart` |
| Server ASR | backend ASR controller (server-side) |
| Server Opus | backend Opus handling (server-side) |
