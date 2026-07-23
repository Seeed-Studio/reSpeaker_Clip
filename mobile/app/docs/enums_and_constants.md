# Enums and constants quick reference

## 1. AI config (STT / LLM)

### 1.1 `SttProvider` (STT vendors)

| Enum | Backend code | Notes |
|------|--------------|-------|
| aliyun | aliyun | Alibaba DashScope FunASR |
| funasr | funasr | Self-hosted FunASR |
| openAiWhisper | openai_whisper | OpenAI Whisper |
| googleGemini | google_gemini | Google Gemini |
| deepgram | deepgram | Deepgram |
| localWhisper | local_whisper | Local Whisper service |
| vosk | vosk | Vosk offline |
| iflytek | iflytek | iFlytek |
| tencent | tencent | Tencent Cloud ASR |
| baidu | baidu | Baidu |
| doubao | doubao | Doubao ASR |
| onDeviceLocalStt | (none) | On-device STT |

**File**: `lib/src/features/ai_config/domain/ai_providers.dart`

### 1.2 `LlmProvider` (LLM vendors)

| Enum | Backend code | Notes |
|------|--------------|-------|
| openAi | openai | OpenAI GPT |
| anthropic | anthropic | Anthropic Claude |
| googleGemini | google_gemini | Google Gemini |
| llama | llama | Llama (local Ollama) |
| doubao | doubao | Doubao |
| qwen | qwen | Qwen |
| deepseek | deepseek | DeepSeek |

**File**: `lib/src/features/ai_config/domain/ai_providers.dart`

---

## 2. Transcription and summary

### 2.1 Transcription language options

UI currently offers `Auto` / `zh` / `en` (`recording_detail_page.dart`).

- `Auto`: omit `language` on the request; ASR auto-detects language
- `zh`: Chinese
- `en`: English

**Extension**: add `ja`, `fr`, etc. in `items` and `labelOf` when needed; backend already forwards values.

---

## 3. Recording and device

### 3.1 `RecordingMode`

| Value | Meaning |
|-------|---------|
| normal | Standard mode |
| enhanced | Enhanced mode |

**File**: `lib/src/features/device/domain/device.dart`

### 3.2 `RetryTransferResult`

| Value | Meaning |
|-------|---------|
| ok | Retry started |
| notConnected | Not connected or device mismatch |
| failed | Transfer error |

**File**: `lib/src/features/device/presentation/device_controller.dart`

### 3.3 `_SessionView` / `_RecPhase` (recording sheet)

| Enum | Value | Meaning |
|------|-------|---------|
| _SessionView | noDevice | No device |
| | recording | Recording |
| | finished | Finished |
| _RecPhase | idle | Idle |
| | recording | Recording |
| | paused | Paused |

**File**: `lib/src/features/recordings/presentation/widgets/recording_session_sheet.dart`

---

## 4. Recording list and filters

### 4.1 `_SortBy` / `_SortOrder`

| Enum | Value | Meaning |
|------|-------|---------|
| _SortBy | createdAt | Created time |
| | operationTime | Operation time |
| _SortOrder | desc | Newest first |
| | asc | Oldest first |

**Persistence**: SharedPreferences `recordings_sort_by` / `recordings_sort_order`

**File**: `lib/src/features/recordings/presentation/recordings_page.dart`

### 4.2 `_FilterKind`

| Value | Meaning |
|-------|---------|
| all | All |
| downloaded | Downloaded |
| unclassified | Unclassified |
| recycleBin | Recycle bin |
| folder | Specific folder |

**File**: `lib/src/features/recordings/presentation/recordings_page.dart`

### 4.3 `_RecordingStatus` (list row)

| Value | Source | Meaning |
|-------|--------|---------|
| syncing | `transferState == 'transferring'` | Syncing |
| done | `transferState == 'done'` | Complete |
| processing | `jobState == 'processing'` | STT/summary in progress |

**File**: `lib/src/features/recordings/presentation/recordings_page.dart`

---

## 5. Server error codes

Aligned with the backend service's error definitions. Full constants in `lib/src/core/server/server_error_codes.dart`; localized messages in `server_error_localizer.dart`.

| Range | Codes | Module |
|-------|-------|--------|
| 0 / 200 | ok / okLegacy | Success |
| 1001–1007 | timeout … invalidParams | General |
| 2001–2011 | userNotFound … verifyCodeInvalid | User / auth |
| 6001–6004 | recordNotFound … duplicateRecord | Database |
| 7002 | clusterNotFound | External service |
| 11001–11002 | tenantNotFound / tenantExist | Tenant |
| 12001–12002 | auditNotFound / auditExists | Audit |
| 13001–13006 | rbacPolicyExists … rbacNoUserId | RBAC |
| 14001–14007 | asrVendorNotConfigured … asrJobNotFound | ASR |
| 15001–15006 | llmVendorNotConfigured … promptTemplateUnsupportedChars | LLM |

Vendor-specific `error_key` strings (ASR/LLM adapters) are documented in
the backend service's error reference and mapped in
`lib/src/core/server/server_error_localizer.dart`.

SenseCraft Auth (authapi) uses a separate code scheme — see `sensecraft_auth/sensecraft_error_codes.dart`.

**File**: `lib/src/core/server/server_error_codes.dart`

---

## 6. Network timeouts

| Scenario | Timeout | File |
|----------|---------|------|
| ASR (url/binary) | 600s | asr_api.dart |
| OSS upload | 600s | user_api.dart |
| LLM chat (summary) | 180s | llm_api.dart |
| Multipart init | 180s | user_api.dart |
| Multipart complete | 180s | user_api.dart |

---

## 7. Local DB versions

| Version | Notes |
|---------|-------|
| v11 | recordings schema v2: unified `local_path`, session/audio/bytes/seq/crc |
| v12 | recordings schema v3: `recording_state`, `started_at`/`ended_at`, `tmp_path`, `mtu`, `last_packet_at`, etc. |
| v13 | `remote_id`/`remote_url`, jobs, `last_stt_job_id`/`last_summary_job_id` |
| v14 | AI configs: STT/LLM add api_secret, app_id, access_key, etc. |
| v22 | `recordings.transfer_error_code` (i18n) |

**File**: `lib/src/core/db/app_database.dart`, `_dbVersion = 22`

---

## 8. Other product constants

| Constant | Value | Notes |
|----------|-------|-------|
| Multipart threshold | 5MB | Use multipart above this size |
| Auto-sync cooldown | 5 min | Interval after connecting device |
| Reconnect max retries | 3 | Auto-reconnect after drop |
| Reconnect interval | 1.5s | |
| AT+LIST page size | 10 | Pagination |
| Waveform bar count | 240 | Playback waveform UI |

---

## 9. Device & protocol (see dedicated docs)

| Topic | Doc | Notes |
|-------|-----|-------|
| BLE UUIDs & characteristics | [device_ble_protocol.md](device_ble_protocol.md) | 6E400001 service, command/response/fileData, OTA SMP |
| AT response conventions | [device_ble_protocol.md](device_ble_protocol.md) | success/fail shape, `ok`/`error`/`session`/`event` |
| Local DB schema & migrations | [local_db.md](local_db.md) | Tables, versions, v11–v22 |
| OTA firmware | [ota_firmware_update.md](ota_firmware_update.md) | Steps, states, errors |
| Recording → sync → STT → summary | [recording_flow.md](recording_flow.md) | Full business flow |
