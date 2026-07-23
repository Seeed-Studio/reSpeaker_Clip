# Local database (SQLite) design

> Database initialization: `lib/src/core/db/app_database.dart`  
> Database provider: `lib/src/core/db/db_provider.dart`  
> Database file: `respeaker_app.db` (under app Documents)

---

## 1. Tables and columns

### 1.1 `recordings`

| Column | Type | Notes |
|--------|------|-------|
| `id` | TEXT PRIMARY KEY | Device rows: `{deviceId}_{devicePath}`; local rows: UUID |
| `device_id` | TEXT | Device id (BLE `remoteId`) |
| `device_path` | TEXT NOT NULL | Path on device |
| `session_id` | TEXT | Session id (continuous recording / resume) |
| `asr_result_id` | INTEGER | Server ASR id, unique |
| `recording_state` | TEXT NOT NULL | `idle \| recording \| stopping \| transferring \| done \| failed` |
| `started_at` | TEXT | Recording start |
| `ended_at` | TEXT | Recording end |
| `tmp_path` | TEXT | Temp path while transferring |
| `mtu` | INTEGER | BLE MTU |
| `last_packet_at` | TEXT | Last packet time |
| `transfer_started_at` | TEXT | Transfer start |
| `transfer_finished_at` | TEXT | Transfer end |
| `remote_id` | TEXT | OSS object id |
| `remote_url` | TEXT | Public OSS URL |
| `transport` | TEXT | Transport (e.g. `ble`) |
| `connection_id` | TEXT | Connection session id |
| `last_stt_job_id` | TEXT | Last STT job id |
| `last_summary_job_id` | TEXT | Last summary job id |
| `name` | TEXT | Display name |
| `size_bytes` | INTEGER | File size |
| `duration_seconds` | INTEGER | Duration |
| `created_at` | TEXT | Created |
| `local_path` | TEXT | Local file path |
| `format` | TEXT | Codec (alac/aac/wav, …) |
| `container` | TEXT | Container (m4a/caf/wav, …) |
| `sample_rate` | INTEGER | Sample rate |
| `channels` | INTEGER | Channels |
| `bit_depth` | INTEGER | Bit depth |
| `received_bytes` | INTEGER | Bytes received |
| `expected_bytes` | INTEGER | Expected total bytes |
| `last_seq` | INTEGER | Last slice index |
| `crc32` | INTEGER | CRC |
| `folder_id` | TEXT | Folder |
| `source` | TEXT NOT NULL | `device \| local` |
| `is_deleted` | INTEGER NOT NULL | In recycle bin |
| `deleted_at` | TEXT | Moved to bin at |
| `device_present` | INTEGER NOT NULL | Still on device |
| `transfer_state` | TEXT NOT NULL | `not_started \| transferring \| done \| failed` |
| `transfer_progress` | REAL | 0..1 |
| `transfer_error` | TEXT | Failure reason |
| `transfer_error_code` | TEXT | i18n error code |
| `upload_state` | TEXT NOT NULL | Upload state |
| `job_state` | TEXT NOT NULL | `none \| queued \| processing \| done \| failed` |
| `transcript` | TEXT | Small transcript |
| `summary` | TEXT | Summary preview (matches `current_summary_id`) |
| `current_summary_id` | TEXT | Active summary version id |
| `transcript_path` | TEXT | Large transcript file |
| `summary_path` | TEXT | Large summary file |
| `last_stt_config_id` | TEXT | Last STT config id |
| `last_llm_config_id` | TEXT | Last LLM config id |
| `last_template_id` | TEXT | Last template id |
| `last_language` | TEXT | Transcription language |
| `last_auto_speaker` | INTEGER NOT NULL | Auto diarization flag |
| `updated_at` | TEXT NOT NULL | Updated |

**Indexes**: `device_id`, `created_at`, `updated_at`, `folder_id`, `is_deleted`, `source`, `remote_id`, unique `asr_result_id`

---

### 1.2 `recording_summaries` (multi-version summaries)

| Column | Type | Notes |
|--------|------|-------|
| `id` | TEXT PRIMARY KEY | e.g. `{recordingId}__sum_v1` |
| `recording_id` | TEXT NOT NULL | FK to `recordings` |
| `version` | INTEGER NOT NULL | Version number |
| `title` | TEXT NOT NULL | e.g. “Summary V1” |
| `content` | TEXT NOT NULL | Body |
| `created_at` | TEXT NOT NULL | |
| `updated_at` | TEXT NOT NULL | |

**Indexes**: `recording_id`, `(recording_id, version)`

---

### 1.3 `folders`

| Column | Type | Notes |
|--------|------|-------|
| `id` | TEXT PRIMARY KEY | |
| `name` | TEXT NOT NULL | |
| `color` | INTEGER NOT NULL | |
| `icon` | INTEGER NOT NULL | |
| `sort_index` | INTEGER NOT NULL | |
| `created_at` | TEXT NOT NULL | |
| `updated_at` | TEXT NOT NULL | |

**Index**: `sort_index`

---

### 1.4 `devices`

| Column | Type | Notes |
|--------|------|-------|
| `id` | TEXT PRIMARY KEY | |
| `name` | TEXT NOT NULL | |
| `sn` | TEXT | Serial |
| `model` | TEXT NOT NULL | Model |
| `battery_percent` | INTEGER | Battery % |
| `recording_mode` | INTEGER NOT NULL | Recording mode |
| `firmware_version` | TEXT | Firmware |
| `has_firmware_update` | INTEGER NOT NULL | Update available |
| `is_online` | INTEGER NOT NULL | Online |
| `last_seen` | TEXT | Last seen |
| `created_at` | TEXT NOT NULL | |
| `updated_at` | TEXT NOT NULL | |

**Index**: `is_online`

---

### 1.5 `stt_configs`

| Column | Type | Notes |
|--------|------|-------|
| `id` | TEXT PRIMARY KEY | |
| `provider` | TEXT NOT NULL | Vendor |
| `name` | TEXT NOT NULL | |
| `api_key` | TEXT NOT NULL | |
| `api_secret` | TEXT | |
| `app_id` | TEXT | |
| `access_key_id` | TEXT | |
| `access_key_secret` | TEXT | |
| `region` | TEXT | |
| `base_url` | TEXT | |
| `language` | TEXT | |
| `model_name` | TEXT | |
| `model_path` | TEXT | |
| `extra_json` | TEXT | |
| `sort_index` | INTEGER NOT NULL | |
| `created_at` | TEXT NOT NULL | |
| `updated_at` | TEXT NOT NULL | |

**Index**: `sort_index`

---

### 1.6 `llm_configs`

| Column | Type | Notes |
|--------|------|-------|
| `id` | TEXT PRIMARY KEY | |
| `provider` | TEXT NOT NULL | Vendor |
| `name` | TEXT NOT NULL | |
| `api_key` | TEXT NOT NULL | |
| `api_secret` | TEXT | |
| `app_id` | TEXT | |
| `access_key_id` | TEXT | |
| `access_key_secret` | TEXT | |
| `region` | TEXT | |
| `base_url` | TEXT | |
| `model_name` | TEXT | |
| `module_name` | TEXT | |
| `extra_json` | TEXT | |
| `sort_index` | INTEGER NOT NULL | |
| `created_at` | TEXT NOT NULL | |
| `updated_at` | TEXT NOT NULL | |

**Index**: `sort_index`

---

### 1.7 `prompt_templates`

| Column | Type | Notes |
|--------|------|-------|
| `id` | TEXT PRIMARY KEY | |
| `remote_id` | INTEGER | Server id |
| `name` | TEXT NOT NULL | |
| `prompt` | TEXT NOT NULL | |
| `is_default` | INTEGER NOT NULL | |
| `share_key` | TEXT | |
| `icon_code` | INTEGER NOT NULL | |
| `sort_index` | INTEGER NOT NULL | |
| `created_at` | TEXT NOT NULL | |
| `updated_at` | TEXT NOT NULL | |

**Index**: `sort_index`

---

### 1.8 `jobs` (async work)

| Column | Type | Notes |
|--------|------|-------|
| `id` | TEXT PRIMARY KEY | |
| `recording_id` | TEXT NOT NULL | FK to `recordings` |
| `type` | TEXT NOT NULL | `stt \| summary \| upload \| export \| share`, … |
| `state` | TEXT NOT NULL | |
| `progress` | REAL | |
| `payload_json` | TEXT | Params |
| `result_json` | TEXT | Result |
| `error` | TEXT | Error |
| `attempt` | INTEGER NOT NULL | Retry count |
| `created_at` | TEXT NOT NULL | |
| `updated_at` | TEXT NOT NULL | |

**Indexes**: `recording_id`, `(type, state, updated_at)`

---

### 1.9 `llm_sessions`

| Column | Type | Notes |
|--------|------|-------|
| `session_id` | TEXT PRIMARY KEY | |
| `title` | TEXT | |
| `created_at` | TEXT | |
| `updated_at` | TEXT | |

**Index**: `updated_at`

---

### 1.10 `llm_session_messages`

| Column | Type | Notes |
|--------|------|-------|
| `id` | INTEGER | Message seq (with `session_id` as PK) |
| `session_id` | TEXT NOT NULL | |
| `role` | TEXT | |
| `content` | TEXT | |
| `created_at` | TEXT | |

**Primary key**: `(session_id, id)`  
**Indexes**: `session_id`, `created_at`

---

## 2. File path conventions

| Use | Path pattern |
|-----|--------------|
| Part file directory | `{Documents}/recordings/device/{deviceId}/{sessionId}/` |
| Merged file | `{Documents}/recordings/device/{deviceId}/{sessionId}.opus` |
| Part naming | `0001.opus`, `0002.opus`, …; in-flight `_part_*.opus.part`, renamed to `NNNN.opus` when done |
| Local-only recordings | Under `{Documents}/recordings/`, `source='local'`, `device_id` null |

---

## 3. Repositories and when they run

| Repository | Key methods | When |
|------------|-------------|------|
| RecordingsRepository | `createPendingDeviceRecording` | After device STOP, `syncDeviceFileIndex` finds new session |
| RecordingsRepository | `updateTransfer` | Progress / complete / fail |
| RecordingsRepository | `updateDeviceRecordingMeta` | After STOP, after trim |
| RecordingsRepository | `updateDevicePresent` | After device LIST validation |
| RecordingsRepository | `listIncompleteTransfers` / `listTransfersToResume` | Reconnect resume |
| RecordingsRepository | `clearInvalidLocalPaths` | Startup validation |
| RecordingsRepository | `purgeRecycleBinOlderThan` | Startup purge (>7 days in bin) |
| FoldersRepository | `deleteFolder` | Clear `recordings.folder_id` before delete |
| FoldersRepository | `moveToFolder` | Move into folder |

---

## 4. State machines

- **transfer_state**: `not_started` → `transferring` → `done` or `failed`
- **recording_state**: `idle` \| `recording` \| `stopping` \| `transferring` \| `done` \| `failed`
- **job_state**: `none` \| `queued` \| `processing` \| `done` \| `failed`

---

## 5. IDs and relationships

| Kind | Rule |
|------|------|
| Recording id (device) | `{deviceId}_{devicePath}` |
| Recording id (local) | UUID v4 |
| session_id | From device; if empty `ensureSessionId()` → UUID |
| asr_result_id | Random 1..(2³¹−1), globally unique |
| recordings ↔ folders | `recordings.folder_id` → `folders.id`; null = unclassified |
| recordings ↔ jobs | `last_stt_job_id` / `last_summary_job_id` → `jobs.id` |
| recordings ↔ recording_summaries | `recordings.current_summary_id` → `recording_summaries.id` |

---

## 6. Startup work

| Provider | Logic |
|----------|-------|
| `recycleBinPurgeProvider` | `purgeRecycleBinOlderThan(7 days)` |
| `validateLocalPathsProvider` | `clearInvalidLocalPaths()` |

---

## 7. Related docs

- [recording_flow.md](recording_flow.md): recording → sync → STT → summary; **transfer states, resume, post-connect checks, `syncDeviceFileIndex`**: section 3
