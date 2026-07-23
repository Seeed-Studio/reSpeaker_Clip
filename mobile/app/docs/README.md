# respeaker-app documentation hub

> This directory holds **technical and product notes for respeaker-app (Flutter)** so new contributors and AI-assisted development can find context quickly.

---

## Which document to open

| You want to learn about… | Open |
|--------------------------|------|
| Architecture, layering, directories, backend contracts | [project_design_framework.md](project_design_framework.md) |
| **Recording → device sync (resume, index) → transcription → summary → playback** | [recording_flow.md](recording_flow.md) (**main business doc**) |
| BLE UUIDs, AT command table, JSON conventions, WiFi AT | [DEVICE_BLE_PROTOCOL.md](../../sdk/flutter/docs/DEVICE_BLE_PROTOCOL.md) (app-side shortcut: [device_ble_protocol.md](device_ble_protocol.md)) |
| OTA (SMP/mcumgr) flow and errors | [ota_firmware_update.md](ota_firmware_update.md) |
| Routes and page paths | [app_routes.md](app_routes.md) |
| Local SQLite tables, paths, state fields | [local_db.md](local_db.md) |
| Backend HTTP APIs the app calls | [api_reference.md](api_reference.md) |
| STT/LLM vendor parameters and field mapping | [ai_provider_params.md](ai_provider_params.md) |
| Enums, magic numbers, transcription languages, etc. | [enums_and_constants.md](enums_and_constants.md) |

---

## How the docs relate (avoid duplicate reading)

```
project_design_framework.md  … architecture + data-flow overview + backend contract summary
         │
         ├─► recording_flow.md … end-to-end flow (device recording / sync / resume / transcription / summary / playback)
         │        ▲
         │        │ protocol details (UUID, AT table) in
         └────────┴─► device_ble_protocol.md
```

- **Business behavior and resume logic**: treat **section 3** of `recording_flow.md` as canonical (the former standalone “transfer resume” doc is merged here to avoid two sources of truth).
- **Raw protocol and characteristics**: use `device_ble_protocol.md`.

---

## Full index (by type)

### Architecture and design

| Doc | Description |
|-----|-------------|
| [project_design_framework.md](project_design_framework.md) | Feature-first, Riverpod, go_router, layering diagram, App↔backend API summary |
| [app_routes.md](app_routes.md) | Routes vs screens |
| [local_db.md](local_db.md) | SQLite, file paths, repositories |
| [api_reference.md](api_reference.md) | Backend API cheat sheet |
| [ai_provider_params.md](ai_provider_params.md) | AI vendor parameter mapping |
| [enums_and_constants.md](enums_and_constants.md) | Enums and constants |

### Device and protocol

| Doc | Description |
|-----|-------------|
| [device_ble_protocol.md](device_ble_protocol.md) | Shortcut to the SDK protocol doc |
| [ota_firmware_update.md](ota_firmware_update.md) | Firmware upgrade steps and states |

### Business flow (main)

| Doc | Description |
|-----|-------------|
| [recording_flow.md](recording_flow.md) | Recording, sync, **post-connect resume and index**, transcription, summary, playback and UI state |


