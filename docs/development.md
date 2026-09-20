# reSpeaker Clip - Development Log

## Current State (2026-05-18)

### Implemented Features

| Feature | Notes |
|---------|-------|
| PDM Microphone Capture | 16kHz, stereo/mono/merge modes |
| Opus Encoding | Mode-specific bitrate/complexity via Kconfig |
| SpeexDSP Processing | Noise suppression, dereverberation (SpeexDSP AGC unavailable in FIXED_POINT; custom integer AGC + high-pass in Enhanced/MERGE mode) |
| Audio Modes | Normal (stereo, 32kbps/ch = 64kbps total, complexity 1), Enhanced (mono, 32kbps, complexity 1) |
| SD Card Storage | FAT32, timestamp buckets under `/SD:/REC/YYYYMMDD/HH/MM/SS/` with 100-file group directories |
| SD Card Log Persistence | LOG_BACKEND_FS, /SD:/LOG/, 128KB files x20; AT+LOG=off\|info\|debug (debug default INF) |
| Session Metadata | session.json and marks.bin per timestamp-bucket session |
| Bookmark System | Binary marks.bin with notes |
| BLE GATT Service | Command, Response, File Data, Event characteristics |
| BLE Event Notifications | State changes, marks, BLE/WiFi/USB events via notify |
| AT Command Protocol | 30 commands |
| File Transfer (BLE) | Pause/resume/cancel, session-level resume |
| File Transfer (UDP) | Fire-and-forget with per-file CRC32, file-level retransmit |
| Transport Abstraction | BLE + UDP + USB CDC channels via transport.h (active selection UDP > BLE) |
| WiFi AP Mode | SSID: ClipAP_XXXX, default password 12345678 (random 8-char password regenerated on first pairing), IP: 192.168.4.1, Port: 8089 |
| WiFi Auto-Off | 3 min timeout (CONFIG_CLIP_WIFI_TIMEOUT_MS=180000) |
| USB CDC Security | Disabled by default, AT+USB control, auto-off on disconnect |
| NVS Configuration | 5 settings persist: mode, noise, autodel, dereverb, brightness |
| Battery Monitoring | NPM1300 PMIC + nRF Fuel Gauge (directionally rate-limited, persisted SoC display) |
| Button Handler | Custom input driver: long-press record, short-press bookmark, single-click status |
| OLED Display | CH1115 driver (88x48, I2C), 24x24 icons, 8x16 font, status bar, recording time, battery/charging, low battery fullscreen |
| Haptic Motor | PMIC GPIO2 control (optional, Kconfig) |
| CPU Boost | 128MHz/64MHz reference-counted system |
| Event System | k_msgq + k_sem driven main loop |
| Factory Reset | Config reset + SD card format + reboot |
| Power Off | PMIC ship mode via AT+POWEROFF |
| Time Sync | Unix timestamp via AT+TIME, persisted to NVS |
| Firmware Update (DFU) | MCUmgr SMP OTA DFU via BLE, dual-image, OTA progress display |
| WiFi Client Detection | WiFi AP client connected icon in status bar |
| Session Sorting | AT+LIST sessions sorted newest-first via shared cache |
| Transfer Cancel | Thread-safe cancel via volatile flag (no race with transfer thread) |
| Device Naming | AT+NAME for custom BLE device name |

### AT Commands (30)

| Command | Type | Purpose |
|---------|------|---------|
| AT+GSTAT | EXEC | Get device status |
| AT+BATT | QUERY/EXEC | Get battery status (%, charging, voltage, temp) |
| AT+STORAGE | QUERY/EXEC | SD card storage info |
| AT+DEVICE | EXEC/GET | Device name |
| AT+VERSION | EXEC | Version info |
| AT+TIME | GET/SET | System time (Unix timestamp) |
| AT+START | EXEC/SET | Start recording |
| AT+STOP | EXEC | Stop recording |
| AT+MARK | EXEC/SET | Add bookmark |
| AT+PAUSE | EXEC | Pause recording |
| AT+RESUME | EXEC | Resume recording |
| AT+CANCEL | EXEC | Cancel transfer |
| AT+LIST | GET/SET | List sessions/files |
| AT+DELETE | SET | Delete session |
| AT+MARKS | GET/SET | Get bookmarks |
| AT+DOWNLOAD | SET | Download file/session |
| AT+AUTODEL | GET/SET | Auto-delete policy |
| AT+FORMAT | EXEC | Format SD card |
| AT+POWEROFF | EXEC | Power off (ship mode) |
| AT+WIFI | EXEC/GET/SET | WiFi AP control |
| AT+WIFICFG | SET/GET | WiFi AP channel + regulatory domain |
| AT+MODE | GET/SET | Recording mode |
| AT+BRIGHTNESS | GET/SET | OLED brightness |
| AT+PAIR | GET/SET | BLE pairing |
| AT+FACTORY | SET | Factory reset |
| AT+REBOOT | EXEC | Reboot |
| AT+USB | GET/SET | USB CDC control (default: off, auto-off on disconnect) |
| AT+DFU | EXEC | Reboot into MCUboot recovery mode |
| AT+LOG | SET | SD log backend level: off \| info \| debug (debug default info) |
| AT+NAME | GET/SET | Custom BLE device name |

### Thread Architecture

| Thread | Priority | Stack | Purpose |
|--------|----------|-------|---------|
| Main | 0 | Default | Event loop, status updates |
| Audio | 0 | 32768 | PDM capture, DSP, Opus encode |
| Transfer | 5 | 4096 | File transfer over BLE/UDP |
| UDP Server | 5 | 2048 | WiFi UDP packet handling |
| AT Server | 7 | 8192 | AT command parsing and dispatch |

### Memory Usage

- FLASH: ~915 KB (app core, secure + non-secure image)
- RAM: ~445 KB (total system SRAM, secure + non-secure + shared)

### Recording Modes

| Mode | Audio | Bitrate | Complexity | DSP | Segment Duration |
|------|-------|---------|------------|-----|-----------------|
| Normal | Stereo (L+R) | 32kbps/ch (64kbps total) | 1 | Disabled | 60s (sync) / 300s (no sync) |
| Enhanced | Mono (L+R merged) | 32kbps | 1 | Enabled | 60s (sync) / 300s (no sync) |

### Build & Flash

```sh
# Environment
source ~/ncs/v3.3.0/zephyr/zephyr-env.sh
export ZEPHYR_EXTRA_MODULES=$(pwd)

# Build
west build --build-dir build-clip --board clip/nrf5340/cpuapp applications/clip

# Flash and reset
west flash --build-dir build-clip && nrfutil device reset

# Serial output
minicom -D /dev/ttyACM0 -b 921600
```

### Not Yet Implemented

| Feature | Priority | Notes |
|---------|----------|-------|
| Low Power Mode | Medium | Sleep when idle |
| Auto-Purge Execution | Medium | Background task to delete old transferred sessions |

---

## Change History

### 2026-06-16 - v0.0.5 Release

- **Idle power: ~1.5mA → ~170µA (production)** via four changes, each measured on the 3V3 rail:
  - nRF5340 internal regulators switched to DCDC (`vregmain`/`vregradio` = `NRF5X_REG_MODE_DCDC`); ~500–600µA
  - SD card idle power-gating: after 45s of no record/transfer/AT/USB activity, unmount → disk deinit → SPI4 runtime-PM suspend → park CS low → LDO2 off; lazy remount on next access via `storage_ensure_mounted()`
  - SPI bias-pull-up removed from `spi3`/`spi4` (push-pull needs no pull-up) and `bias-pull-down` added to `spi4_sleep`; ~750µA
  - UART console keeps UARTE active at idle (~570µA, baud-independent); the `production` snippet disables console + UART log backend
- **Debug / production firmware split** via the `production` snippet: debug keeps UART console + SD log at INF; production strips both for low power. Both exported to `output/0.0.5/`
- **FS log backend (`/SD:/LOG`) now AT-controlled**: new `AT+LOG=off|info|debug` toggles it at runtime; boot default coupled to `LOG_BACKEND_UART` (debug on / production off) so the app-only Kconfig symbol is never broadcast into the mcuboot sysbuild image
- **Storage-full handling**: percentage-based (`CLIP_STORAGE_FULL_PERCENT`, default 95%) via `fs_statvfs`; recording refused with a "Storage Full" on-screen error and BLE event when SD is full
- **AT+NAME**: capacity 32B → 256B; surrounding quotes stripped from the argument
- **BLE reliability**: fixed slow-advertising interval (was a copy-paste of the fast interval); un-bonded devices also drop to slow advertising; connection params tightened (interval 15–30, supervision timeout 800); CCC handlers use a notify mask (`&`) instead of equality
- **Transfer cancel**: thread-safe, marks the transfer ERROR synchronously so re-download works after a BLE drop
- **Battery**: reserve capacity + early low-battery shutdown; SoC smoothing bypassed below reserve so a true low reading is acted on immediately
- **Python client (`tests/clip`)**: retries AT commands on BLE-notify drops; robust JSON parse around brace-matched notifications
- New storage API: `storage_idle_poweroff()` / `storage_resume()` / `storage_ensure_mounted()` / `storage_is_full()` / `storage_set_busy_cb()`

### 2026-05-18 - v0.0.1 Release

- Version reset to 0.0.1 for initial release
- SD card log persistence: LOG_BACKEND_FS writes WRN+ERR logs to /SD:/LOG/, 64KB files x10 max, circular overwrite
- USB CDC security: disabled by default, controlled via AT+USB command, auto-disables on USB disconnect
- BLE event notifications: state changes (recording/idle/paused), bookmark marks, BLE/WiFi/USB status events sent as JSON via GATT notify
- WiFi auto-off: 3 minute timeout (CONFIG_CLIP_WIFI_TIMEOUT_MS=180000), timer resets on client disconnect
- BLE security: LE Secure Connections pairing, encrypted link required
- Partition resize: mcuboot 96KB -> 84KB, app core slot0 940KB (268KB secure + 192KB non-secure + 256KB OTA slot + 192KB OTA non-secure)
- AT+NAME command: custom BLE device name, stored in NVS
- AT+USB command: enable/disable USB CDC, query status
- Memory: app core ~915KB FLASH, ~445KB RAM

### 2026-04-17 - UI Overhaul and Bug Fixes (v2.0.5)

- UI overhaul: 24x24 icons, 8x16 font, battery fix, charging display
- Low battery (<10%) full-screen display
- Disable idle BT/WiFi icons, add OTA icon, instant transfer display refresh
- Fuel gauge: nRF Fuel Gauge integration, SoC smoothing, charging status
- OTA progress display
- WiFi client connected icon
- Fix FILE_ACK NACK: skip CRC update on UDP send failure
- Fix AT+CANCEL race: cancel handled in transfer thread via volatile flag
- Fix AT+LIST sorting: sessions sorted newest-first with shared cache
- Fix DOWNLOAD response: add bytes field (use %u not %llu)
- Fix Ctrl+C in Python tools: gracefully merge downloaded files on interrupt
- Fix unexpected disconnect: merge files on disconnect/timeout
- Transfer file retry limit increased from 5 to 10

### 2026-03-28 - Documentation and Code Cleanup

### 2026-03-28 - Documentation and Code Cleanup

- Removed AT+BITRATE, AT+COMPLEXITY, AT+AGC, AT+CHUNKSIZE, AT+PROGRESS commands
- Bitrate and complexity are now mode-specific via Kconfig (not runtime configurable)
- AGC removed entirely (SpeexDSP FIXED_POINT build limitation)
- Transfer chunk size is compile-time only (CONFIG_CLIP_TRANSFER_CHUNK_SIZE)
- Unified all config defaults to Kconfig (removed hardcoded macros from config.h)
- Added DSP timing to encode log (avg/min/max for both Opus and DSP)
- Updated all documentation to match current codebase

### 2026-03-27 - WiFi/BLE Coexistence and Transport Refactoring

- Added WiFi/BLE coexistence configuration (nrf_wifi_coex_config_pta/non_pta)
- Added WiFi/BLE coex hardware reset on WiFi stop
- Fixed compiler warnings: net_if_ipv4_addr_add return type, deprecated net_if_ipv4_set_netmask
- Refactored transport layer: transport.h abstraction with BLE + UDP backends
- Rewrote UDP protocol: fire-and-forget with per-file CRC32 (replaced sliding window)
- Fixed button status bar in WIFI_SYNC state
- Added CPU boost system (128MHz/64MHz reference-counted)
- Event-driven main loop (k_msgq + k_sem)

### 2026-03-23 - Audio Recording Optimization

- On-demand encoder/DSP initialization
- Microphone power control (on/off with stabilization delay)
- Removed VBR settings (21ms → ~12ms encode time)
- Increased audio thread stack to 32KB and priority to 0
- Fixed AT command JSON format and buffer check
- Increased AT server thread stack from 2KB to 4KB (stack overflow fix)
- Set HFCLK divider to 1 for maximum CPU frequency (128MHz)

### 2026-02-26 - Mode Mapping Fix and DSP Restriction

- Fixed mode mapping: Normal=stereo (no DSP), Enhanced=mono (with DSP)
- DSP only enabled in enhanced mode
- Bitrate scaling: mono=1x, stereo=2x

### 2026-02-25 - Simultaneous Recording and BLE Transfer

- Added transfer_resume_from() for file-level resume
- Simultaneous recording and BLE transfer
- Disconnect callback cleanup
- Extended AT+DOWNLOAD with session/start_file syntax
- Python sync tool with auto-detection and resume support

### 2026-02-24 - Session Storage Structure

- Session directories: /SD:/REC/YYYYMMDDHHMMSS/
- session.json, files.lst, marks.bin per session
- AT+TIME command for time synchronization
- Fallback session IDs when time not synced

### 2026-02-20 - Initial Implementation

- BLE GATT service with 3 characteristics
- AT command parser (EXEC/SET/GET)
- State machine (IDLE/RECORDING/TRANSMITTING/PAUSED/ERROR)
- NVS configuration storage
- Opus encoding integration
- SpeexDSP noise suppression and dereverberation
- SD card FAT32 storage
- Audio recording thread
- Custom button input driver
