# OTA firmware upgrade

> For teammates and AI context. reSpeaker devices upgrade firmware over BLE using SMP (mcumgr).

---

## 1. Protocol and entry

- **Protocol**: SMP (mcumgr) over BLE
- **Service UUID**: `00001530-1212-EFDE-1523-785FEABCD123`
- **Characteristic UUID**: `DA2E7828-FBCE-4E01-AE9E-261174997C48`
- **Implementation**: `mcumgr_flutter`, aligned with noaflutterdemo and reSpeaker Clip AT docs

**Files**: `lib/src/features/device/presentation/firmware_update_page.dart`, `lib/src/features/device/data/ota_firmware_processor.dart`

**Cloud check** (optional): `FirmwareApi.checkUpdate` calls SenseCAP PaaS
`GET /portalapi/hardware/get_new_version` with query `ver`, `sku`, `is_prepub`.

---

## 2. Preconditions

- Device must be **connected over Bluetooth**
- Entry: Device detail → firmware version row → firmware update screen

---

## 3. Firmware format

| Format | Notes |
|--------|-------|
| ZIP | Contains `manifest.json` + `.bin` |
| BIN | Single file |

**Picker**: `FilePicker`, extensions `zip`, `bin`

---

## 4. Upgrade steps (UI)

| Step | Enum | Notes |
|------|------|-------|
| ready | `_FwUiStep.ready` | Pick file, check connection & recording state |
| uploading | `_FwUiStep.uploading` | Show progress and status copy |
| success | `_FwUiStep.success` | Done |
| failure | `_FwUiStep.failure` | Show error |

---

## 5. mcumgr states and copy

| State | User-facing text |
|-------|------------------|
| upload | Uploading firmware... |
| validate | Validating... |
| test | Testing... |
| confirm | Confirming... |
| reset | Resetting device... |
| eraseAppSettings | Erasing settings... |
| bootloaderInfo | Getting bootloader info... |
| requestMcuMgrParameters | Requesting parameters... |

**File**: `_stateToText()` in `firmware_update_page.dart`

---

## 6. Error handling

- On failure: `_step = _FwUiStep.failure`, `_errorMessage = e.toString()`
- UI: `_FailureView` shows the message with a back action
- Log: `AppLog.w('FirmwareUpdatePage: OTA failed', e, StackTrace.current)`

---

## 7. Configuration and timing

- `FirmwareUpgradeConfiguration`: `eraseAppSettings: true`, `estimatedSwapTime: Duration.zero`
- Minimum progress display: `_minProgressDisplayDuration = 2500ms` so tiny updates do not flash past
