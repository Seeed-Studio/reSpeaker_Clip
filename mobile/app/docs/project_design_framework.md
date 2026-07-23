# respeaker-app design and architecture

> Architecture choices, layering, data flow, and backend API contracts for respeaker-app. Onboarding and AI-generated PRDs can anchor here.

---

## 1. System overview

**respeaker-app** connects ReSpeaker hardware to a cloud backend for recording → sync → transcription → summary:

```
┌──────────────┐      BLE         ┌──────────────────┐      HTTPS       ┌──────────────────┐
│ ReSpeaker    │◄────────────────►│  respeaker-app    │◄────────────────►│  Backend          │
│ device       │   audio / files   │  (Flutter)        │   OSS / ASR / LLM│  (self-hosted)    │
└──────────────┘                  │  UI, local       │                  │                   │
                                  │  SQLite + APIs   │                  └──────────────────┘
                                  └──────────────────┘
```

---

## 2. Architecture choices

**Feature-first + Clean Architecture + Riverpod + go_router**.

In one sentence: **split by feature folders**, inside each feature use **presentation / domain / data** layers, use **Riverpod** for state and DI, **go_router** for navigation.

### Why this split

Think of the app as a car:

- **Presentation**: steering wheel and screens—what you see and tap
- **Domain**: engine rules—e.g. start recording → files → sync list → upload → wait for STT
- **Data**: fuel lines—BLE, Wi‑Fi, SQLite, filesystem, HTTP

Benefits:

- Swap UI without touching domain rules
- Swap BLE stack or upload path without touching business rules
- Features stay navigable as the product grows

---

## 3. Directory layout

```
lib/src/
  app/
    app.dart                      # MaterialApp.router
    router/app_router.dart        # go_router + auth redirects
    theme/                        # Theme, fonts
  core/
    db/                           # SQLite bootstrap, providers
    log/                          # Logging
    server/                       # HTTP client, APIs (user/asr/llm/oss)
    audio/                        # Waveform, decode, local recording
    l10n/                         # Localization
  features/
    home/                         # Shell (Files + AI config tabs)
    device/                       # Devices, BLE, download, OTA
    recordings/                   # Files, detail, STT, summary, recycle bin
    settings/                     # Profile, language, help, about
    ai_config/                    # STT/LLM configs, templates, onboarding
    auth/                         # Login, register, linked accounts
```

---

## 4. Feature maturity

| Feature | Status | Notes |
|---------|--------|-------|
| device | Done | BLE scan/connect, AT, continuous recording + download, resume, OTA |
| recordings | Done | Device/local lists, download, upload, STT, summary, folders, recycle bin |
| ai_config | Done | Multi-vendor STT/LLM, template CRUD, sharing, guided flow |
| auth | Done | OAuth (Google/Apple/GitHub), email login/register, token refresh |
| settings | Done | Profile, language, permissions, policies, account deletion |

---

## 5. System layers (end-to-end)

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│  Device: ReSpeaker hardware                                                     │
│  Recording, storage, AT commands, BLE notifications, OTA firmware               │
└─────────────────────────────────────────────────────────────────────────────────┘
                                    │
                                    │ BLE (GATT) / AT
                                    ▼
┌─────────────────────────────────────────────────────────────────────────────────┐
│  App: respeaker-app                                                             │
│  Presentation / domain / data: BLE, SQLite, HTTP client                         │
└─────────────────────────────────────────────────────────────────────────────────┘
                                    │
                                    │ HTTPS (JWT)
                                    ▼
┌─────────────────────────────────────────────────────────────────────────────────┐
│  Backend service (self-hosted)                                                │
│  Routing, auth, ASR/LLM adapters, OSS, MySQL                                    │
└─────────────────────────────────────────────────────────────────────────────────┘
                                    │
                                    │ HTTP / vendor SDKs
                                    ▼
┌─────────────────────────────────────────────────────────────────────────────────┐
│  Third parties: OSS, ASR vendors, LLM vendors                                    │
└─────────────────────────────────────────────────────────────────────────────────┘
```

---

## 6. Core data flows

### 6.1 Recording → sync → transcription → summary

```
[Device record] → [while recording / after stop] → [local .opus] → [decode WAV + OSS] → [ASR] → [LLM summary]
     │                      │                            │              │                   │              │
   AT+START            AT+DOWNLOAD                  mergeAllParts   opus→WAV→         POST /asr/jobs    POST /llm/chat
   AT+STOP             fileDataBytes                local_path      uploadToOss       or /asr/binary   (SSE)
                                                     remote_url      server Ogg→WAV fallback
```

Step-by-step detail, **post-connect resume, index sync, validation**: [recording_flow.md](recording_flow.md) from section 3 onward.

### 6.2 Device ↔ app

- **BLE**: discovery, connection, AT (START/STOP/DOWNLOAD/LIST/GSTAT/WIFI, …), notifications. BLE is always the **control** channel.
- **Wi‑Fi**: device AP mode; phone gets credentials via BLE (`AT+WIFI=on`), joins AP, HTTP (or UDP per protocol doc) for fast bulk transfer (often 10–100× BLE). After transfer, hotspot off (`AT+WIFI=off`). Code under `data/wifi/`.
- **Strategy**: small payloads on BLE (simple, no network switch); large payloads on Wi‑Fi. Upper layers hide channel differences.
- **MTU & chunking**: BLE write payload is `MTU-3`; some Android phones negotiate small MTU. Chunk long AT writes; firmware reassembles before handling.

Protocol details: [device_ble_protocol.md](device_ble_protocol.md).

---

## 7. App ↔ backend contracts

### 7.1 Auth

- Login: `POST /api/v1/user/app/login` (OAuth), `POST /api/v1/user/email/login` (email/password)
- Refresh: `POST /api/v1/user/refresh` (`refresh_token` → `access_token`)
- Header: `Authorization: Bearer <access_token>`

See the backend service's own API reference for the OAuth app-login and token-refresh contracts.

### 7.2 Main API groups

| Group | Prefix | Typical endpoints | Purpose |
|-------|--------|-------------------|---------|
| User | `/api/v1/user` | GET/PUT user, logout, refresh | Account, profile, session |
| OSS | `/api/v1/oss` | upload, upload/init→chunk→complete | File upload |
| ASR | `/api/v1/asr` | POST url, POST binary, config CRUD, jobs, result | STT, config |
| LLM | `/api/v1/llm` | POST chat (SSE), config CRUD, prompt CRUD, sessions | Summary, LLM/templates |

### 7.3 Key flows

| Flow | APIs | Notes |
|------|------|-------|
| Upload recording | `POST /api/v1/oss/upload` or init→chunk→complete | Yields `remote_url` |
| Transcription (URL) | `POST /api/v1/asr/jobs` → poll `GET /api/v1/asr/jobs/:id` → `GET /api/v1/asr/result/:id` | Async job; `asr_result_id` when done |
| Transcription (binary) | `POST /api/v1/asr/binary` | Stream audio |
| Summary | `POST /api/v1/llm/chat`, `stream=true` | SSE |
| ASR config | CRUD `/api/v1/asr/config` | Multi-vendor STT |
| LLM config | CRUD `/api/v1/llm/config` | Multi-vendor LLM |

---

## 8. Local storage (app)

- **SQLite**: `respeaker_app.db` — tables `recordings`, `folders`, `devices`, `jobs`, `stt_configs`, `llm_configs`, `prompt_templates`, `recording_summaries`, …
- **Files**: `{Documents}/recordings/device/{deviceId}/{sessionId}/` for part files; `{sessionId}.opus` after merge

See [local_db.md](local_db.md).

---

## 9. Documentation index

| Doc | Description |
|-----|-------------|
| [This file](project_design_framework.md) | Architecture framework |
| [README.md](README.md) | Doc hub and reading order |
| [recording_flow.md](recording_flow.md) | **Main business doc**: recording → sync (resume, index) → STT → summary → playback |
| [device_ble_protocol.md](device_ble_protocol.md) | BLE / AT / WiFi protocol |
| [api_reference.md](api_reference.md) | Backend API cheat sheet |
| [app_routes.md](app_routes.md) | Routes vs screens |
| [local_db.md](local_db.md) | SQLite schema, paths, repos, state machine |
| [ota_firmware_update.md](ota_firmware_update.md) | OTA firmware |
| [ai_provider_params.md](ai_provider_params.md) | AI vendor mapping |
| [enums_and_constants.md](enums_and_constants.md) | Enums and constants |
