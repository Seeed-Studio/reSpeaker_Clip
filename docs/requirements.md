# reSpeaker Clip - Product Requirements Document

## 1. Product Overview

### 1.1 Product Vision

reSpeaker Clip is a portable Bluetooth recording device that provides high-quality audio capture with seamless mobile app integration. The device enables users to record lectures, meetings, and personal notes with intelligent audio processing, convenient bookmarking, and wireless synchronization via BLE or WiFi UDP.

### 1.2 Target Users

- **Students**: Record lectures and study sessions with bookmarking for key topics
- **Professionals**: Capture meeting minutes and important discussions
- **Journalists**: Record interviews with marked highlights
- **Personal Users**: Voice memos, ideas, and daily notes

### 1.3 Use Case Scenarios

1. **Lecture Recording**: Student records a 2-hour lecture, adds bookmarks for important topics, syncs to phone for transcription
2. **Meeting Capture**: Professional records a team meeting, marks key decisions, transfers via WiFi UDP for faster download
3. **Interview**: Journalist records an interview, bookmarks significant quotes, transfers for editing
4. **Voice Memo**: Quick capture of personal ideas with a single button press
5. **WiFi Bulk Sync**: User connects to device WiFi AP, downloads all recordings at high speed via UDP

### 1.4 Product Positioning

- Portable, clip-on form factor
- High-quality audio processing (SpeexDSP + Opus encoding)
- Dual transport: BLE for mobile app, WiFi UDP for high-speed local sync
- Simple single-button operation with OLED display feedback
- Long battery life (recording duration target TBD with the 240 mAh cell; production idle measured at ~170µA)

## 2. User Stories

### 2.1 Core Recording Features

- **US-001**: As a user, I want to start recording with a long button press so I can quickly capture audio
- **US-002**: As a user, I want to stop recording with a long button press so I can end the session
- **US-003**: As a user, I want to add bookmarks during recording with a short button press so I can mark important moments
- **US-004**: As a user, I want to see the current recording state on the OLED display so I know if I'm recording
- **US-005**: As a user, I want to see recording time elapsed on the display so I can track session duration
- **US-006**: As a user, I want to pause and resume recording so I can skip interruptions

### 2.2 Mobile App Integration (BLE)

- **US-010**: As a user, I want to connect my phone via Bluetooth so I can transfer recordings
- **US-011**: As a user, I want to see all recording sessions in the app so I can browse them
- **US-012**: As a user, I want to download specific recordings so I can access them on my phone
- **US-013**: As a user, I want to see bookmarks in the app so I can jump to important moments
- **US-014**: As a user, I want to pause/resume/cancel file transfers so I can manage bandwidth

### 2.3 Device Management

- **US-020**: As a user, I want to see battery level on the OLED display so I know when to charge
- **US-021**: As a user, I want to see charging status on the display so I know it's charging
- **US-022**: As a user, I want to configure recording mode (Normal/Enhanced) so I can balance quality and storage
- **US-023**: As a user, I want to delete old recordings from the app so I can free up space
- **US-024**: As a user, I want to reset the device to factory settings so I can clear all data

### 2.4 Data Synchronization

- **US-030**: As a user, I want recordings to automatically organize into sessions so I can find them easily
- **US-031**: As a user, I want the app to show which files have been transferred so I don't download twice
- **US-032**: As a user, I want to pause/resume file transfers so I can manage bandwidth
- **US-033**: As a user, I want to see available storage so I know how much recording time remains

### 2.5 WiFi UDP Transfer

- **US-040**: As a user, I want to connect to the device's WiFi AP so I can transfer recordings at high speed
- **US-041**: As a user, I want to download sessions via UDP so I can sync faster than BLE
- **US-042**: As a user, I want to start/stop WiFi from the BLE app or AT commands so I can control when WiFi is active
- **US-043**: As a user, I want to use an interactive UDP terminal for debugging so I can troubleshoot issues

## 3. Functional Requirements

### 3.1 Audio Recording

#### 3.1.1 PDM Microphone Capture

**FR-1.1.1**: The system shall capture audio from PDM microphones at 16 kHz sample rate, 16-bit depth

**FR-1.1.2**: The system shall support stereo recording from dual microphones (Normal mode)

**FR-1.1.3**: The system shall support merged mode: stereo capture downmixed to mono (Enhanced mode)

**FR-1.1.4**: The PDM driver shall use double buffering (memory slab) to prevent audio overflow

**FR-1.1.5**: The system shall configure microphone gain at +20dB via nrfx_pdm_gain_set()

#### 3.1.2 Audio Processing Pipeline

**FR-1.2.1**: The system shall apply noise suppression using SpeexDSP (configurable 0-60 dB)

**FR-1.2.2**: The system shall apply dereverberation using SpeexDSP (enable/disable, default on; fixed level=40, decay=30)

**FR-1.2.3**: Automatic Gain Control: the SpeexDSP AGC is not available (the library is built with FIXED_POINT, which does not support AGC). Instead, a custom lightweight integer AGC + high-pass filter runs in Enhanced/MERGE mode alongside the SpeexDSP preprocessor.

**FR-1.2.4**: The system shall provide two recording mode presets:
- **Normal mode**: Stereo capture, no DSP processing, 32 kbps/channel (64 kbps total)
- **Enhanced mode**: Mono (merged L+R), noise suppression + dereverb + integer AGC, 32 kbps

**FR-1.2.5**: Audio processing shall be applied only in Enhanced (merge) mode; Normal (stereo) mode passes PCM data directly to the encoder

**FR-1.2.6**: The system shall process audio in real-time with < 50ms latency

#### 3.1.3 Opus Encoding

**FR-1.3.1**: The system shall encode audio using the Opus codec

**FR-1.3.2**: Bitrate is mode-specific, set at compile time via Kconfig (not user-configurable at runtime):
- Normal mode: 32 kbps per channel (CONFIG_CLIP_NORMAL_BITRATE=32000; stereo encoder runs at 2x = 64 kbps total)
- Enhanced mode: 32 kbps (CONFIG_CLIP_ENHANCED_BITRATE=32000), mono

**FR-1.3.3**: Encoding complexity is mode-specific, set at compile time via Kconfig (not user-configurable at runtime):
- Normal mode: complexity 1 (CONFIG_CLIP_NORMAL_COMPLEXITY=1)
- Enhanced mode: complexity 1 (CONFIG_CLIP_ENHANCED_COMPLEXITY=1)

**FR-1.3.4**: The encoder shall use VBR enabled, unconstrained quality, voice-optimized signal, 16-bit LSB depth, DTX/FEC/packet loss compensation disabled

**FR-1.3.5**: The system shall write Opus frames with 2-byte little-endian length prefix to storage files

**FR-1.3.6**: The system shall split recordings into time-based segments with dynamic duration:
- During active transfer (sync): CONFIG_CLIP_AUDIO_SEGMENT_DURATION_SYNC seconds (default: 60s)
- When not transferring: CONFIG_CLIP_AUDIO_SEGMENT_DURATION_NO_SYNC seconds (default: 300s)

**FR-1.3.7**: When transitioning from non-transferring to transferring, the system shall immediately slice the current file if it exceeds the sync segment duration

#### 3.1.4 Recording Modes

**FR-1.4.1**: Normal mode: stereo recording, no DSP, 32 kbps/channel (64 kbps total)

**FR-1.4.2**: Enhanced mode: mono (merged L+R), SpeexDSP noise suppression + dereverb + custom integer AGC, 32 kbps

**FR-1.4.3**: Recording mode shall be stored in NVS and configurable via AT+MODE command

### 3.2 Storage Management

#### 3.2.1 SD Card File System

**FR-2.1.1**: The system shall use FAT32 file system on SD card via SDHC-SPI

**FR-2.1.2**: The system shall store recordings in `/SD:/REC/` directory

**FR-2.1.3**: The system shall detect SD card insertion/removal

**FR-2.1.4**: The system shall report SD card errors to user via AT command responses

**FR-2.1.5**: The system shall handle SD card write errors gracefully (close file, continue recording without storage)

**FR-2.1.6**: The system shall persist logs to the SD card for field debugging (`CONFIG_LOG_BACKEND_FS=y`, stored in `/SD:/LOG/`, rotating 128 KiB files x20 max, circular overwrite; default INF level in the debug build, runtime-switchable via `AT+LOG=off|info|debug`)

#### 3.2.2 Session Organization

**FR-2.2.1**: The system shall store a `YYYYMMDDHHMMSS` session in the fixed
timestamp bucket `/SD:/REC/YYYYMMDD/HH/MM/SS/`. The complete 14-digit session ID
remains the external identifier used by AT commands.

**FR-2.2.2**: The system shall create `session.json` with session metadata (channels, sample_rate, mode, file_count, synced_files, duration_sec, total_bytes)

**FR-2.2.3**: Audio files shall be stored in numbered group directories below
the session directory and named `{NNNN}.opus` (e.g., `0/0001.opus`,
`0/0002.opus`). Each group contains at most
`CONFIG_CLIP_STORAGE_FILES_PER_GROUP` files.

**FR-2.2.4**: The system shall create `marks.bin` for bookmark data (magic "BMRK", 2-byte count, N * 4-byte offsets)

**FR-2.2.5**: Session metadata shall include: session_id, channels, sample_rate, mode, file_count, synced_files, duration_sec, total_bytes

#### 3.2.3 Bookmark System

**FR-2.3.1**: The system shall add bookmarks on short button press during recording

**FR-2.3.2**: Bookmarks store offset in seconds from session start (4-byte uint32)

**FR-2.3.3**: Bookmarks are stored in binary format (`marks.bin`): magic "BMRK" + count + offset array

**FR-2.3.4**: The system shall support AT+MARK command to add bookmark during recording

**FR-2.3.5**: The system shall support AT+MARKS command with pagination to retrieve bookmarks

#### 3.2.4 Auto-Purge Policies

**FR-2.4.1**: The system shall support auto-delete policies configurable via AT+AUTODEL:
- `off` (-1): Manual delete only
- `0`: Delete immediately after transfer
- `1-30`: Delete N days after transfer

**FR-2.4.2**: The system shall identify fully synced sessions (synced_files == file_count) for cleanup

**FR-2.4.3**: The system shall provide AT+DELETE=<session_id> command to delete a specific session

### 3.3 Transport Layer

#### 3.3.1 Transport Abstraction

**FR-3.1.1**: The system shall implement a transport abstraction layer supporting BLE, UDP, and USB CDC transports

**FR-3.1.2**: Transport priority: UDP > BLE for active transport selection (UDP preferred for large transfers); USB CDC is a third AT-command channel with responses routed directly back over USB

**FR-3.1.3**: The transport layer shall support send, send_file_data, send_file_start, send_file_end, send_transfer_done, is_connected operations

#### 3.3.2 BLE Communication

**FR-3.2.1**: The system shall implement BLE GATT service with UUID `6E400001-B5A3-F393-E0A9-E50E24DCCA9E`

**FR-3.2.2**: The system shall provide Command Receive characteristic (Write): `6E400002-B5A3-F393-E0A9-E50E24DCCA9E`

**FR-3.2.3**: The system shall provide Response Send characteristic (Notify): `6E400003-B5A3-F393-E0A9-E50E24DCCA9E`

**FR-3.2.4**: The system shall provide File Data characteristic (Notify): `6E400004-B5A3-F393-E0A9-E50E24DCCA9E`

**FR-3.2.5**: The system shall require LE Secure Connections pairing

**FR-3.2.6**: The system shall require encrypted connection

**FR-3.2.7**: The system shall support audio visualization data via BLE (7-byte packed energy level history, sent every ~200ms)

**FR-3.2.8**: The system shall send BLE event notifications for real-time state monitoring. Events shall include: state changes (IDLE/RECORDING/PAUSED with session ID and duration), bookmark additions (session ID, mark count), and status events (BLE connected/disconnected, WiFi on/off, USB on/off). Events are JSON objects sent via GATT notify on the Response characteristic.

**FR-3.2.9**: BLE event notifications shall be dispatched immediately when events occur (not deferred), enabling the mobile app to update its UI without polling.

#### 3.3.3 WiFi UDP Communication

**FR-3.3.1**: The system shall support WiFi AP mode via nRF7002 (SSID: `ClipAP_XXXX`, default password `12345678`; a random 8-character password is generated on first BLE pairing). Channel and regulatory domain are runtime settings (`AT+WIFICFG=channel:CC`)

**FR-3.3.2**: WiFi AP shall use static IP `192.168.4.1` with DHCP server

**FR-3.3.3**: UDP file transfer server shall listen on port 8089

**FR-3.3.4**: UDP protocol shall use binary frame format with sequence numbers, CRC32 verification, and heartbeat

**FR-3.3.5**: Frame types: DATA (0x01), FILE_ACK (0x03), FILE_START (0x10), FILE_END (0x11), TRANSFER_DONE (0x12), AT_RESP (0x20), HEARTBEAT (0x30)

**FR-3.3.6**: WiFi shall be started manually (not auto-start) to save power when not in use

**FR-3.3.6a**: WiFi AP shall automatically disable after a configurable timeout (`CONFIG_CLIP_WIFI_TIMEOUT_MS`, default 3 minutes) to prevent unnecessary power drain when left enabled but unused. Timer restarts on client disconnect. Set to 0 to disable.

**FR-3.3.7**: WiFi driver shall use WiFi/BLE coexistence (MPSL_CX + NRF70_SR_COEX)

#### 3.3.4 AT Command Protocol

**FR-3.4.1**: The system shall support EXEC commands: `AT+XX`

**FR-3.4.2**: The system shall support SET commands: `AT+XX=<value>`

**FR-3.4.3**: The system shall support GET commands: `AT+XX?`

**FR-3.4.4**: The system shall use JSON format for all responses

**FR-3.4.5**: The system shall return success response: `{"ok": true, "data": {...}}`

**FR-3.4.6**: The system shall return error response: `{"ok": false, "error": "message"}`

**FR-3.4.7**: AT commands shall be accepted from BLE, UDP, and USB CDC transports

#### 3.3.5 AT Command Reference

| Command | Type | Description |
|---------|------|-------------|
| `AT+GSTAT` | EXEC | Get device status (state, recording, battery, mode, bitrate, free space) |
| `AT+BATT` | QUERY/EXEC | Get battery status (%, charging, voltage, temperature) |
| `AT+STORAGE` | QUERY/EXEC | Get SD card storage info (total/free/used MB, used %) |
| `AT+DFU` | EXEC | Reboot into MCUboot recovery mode |
| `AT+DEVICE` | QUERY/EXEC | Get device name |
| `AT+VERSION` | EXEC | Get firmware version |
| `AT+TIME` | SET/GET/EXEC | Set time (Unix timestamp) or get current time (ISO 8601) |
| `AT+MODE` | SET/GET/EXEC | Set/get recording mode (normal/enhanced/stereo/merge) |
| `AT+AUTODEL` | SET/GET/EXEC | Set/get auto-delete policy (off/0-30 days) |
| `AT+BRIGHTNESS` | SET/GET/EXEC | Set/get OLED brightness (0-255) |
| `AT+POWEROFF` | EXEC | Shutdown device |
| `AT+FACTORY` | SET/EXEC | Factory reset (requires "confirm" or "yes") |
| `AT+PAIR` | SET/GET | Query pairing status or `AT+PAIR=reset` to clear bonds |
| `AT+REBOOT` | EXEC | Reboot device |
| `AT+START` | EXEC/SET | Start recording (optional mode parameter) |
| `AT+STOP` | EXEC | Stop recording |
| `AT+PAUSE` | EXEC | Pause recording |
| `AT+RESUME` | EXEC | Resume recording |
| `AT+MARK` | EXEC | Add bookmark at current position |
| `AT+LIST` | SET/GET/EXEC | List sessions with pagination, or session details, or file list |
| `AT+MARKS` | SET/GET/EXEC | List bookmarks with pagination |
| `AT+DOWNLOAD` | SET/EXEC | Start file transfer (session or session:file) |
| `AT+CANCEL` | EXEC | Cancel active transfer |
| `AT+DELETE` | SET | Delete a specific session |
| `AT+FORMAT` | EXEC | Format SD card (delete all data) |
| `AT+WIFI` | SET/GET/EXEC | Start/stop WiFi AP, query status |
| `AT+WIFICFG` | SET/GET | Set/get WiFi AP channel + regulatory domain (channels 1-13 or 36-165) |
| `AT+USB` | SET/GET | Enable/disable USB CDC (default: off, auto-off on disconnect) |
| `AT+NAME` | SET/GET | Set/get custom BLE device name |
| `AT+LOG` | SET/GET/EXEC | SD log backend level: off \| info \| debug |

#### 3.3.6 File Transfer Protocol

**FR-3.6.1**: The system shall support streaming file transfer via BLE notify or UDP

**FR-3.6.2**: Transfer chunk size is a compile-time constant: CONFIG_CLIP_TRANSFER_CHUNK_SIZE=4096 bytes

**FR-3.6.3**: The system shall support transfer cancel via AT+CANCEL

**FR-3.6.4**: The system shall allow non-blocking commands during transfer

**FR-3.6.5**: The system shall update synced_files count in session.json on successful file transfer

**FR-3.6.6**: The system shall support continuous transfer mode: when recording while transferring, newly completed files are automatically queued

**FR-3.6.7**: The transfer subsystem shall coordinate with storage to wait for files to finish writing before transfer

#### 3.3.7 Connection Management

**FR-3.7.1**: The system shall auto-advertise when not connected

**FR-3.7.2**: The system shall support bonding/pairing with mobile app (max 1 bonded device)

**FR-3.7.3**: The system shall store bond information in NVS

**FR-3.7.4**: The system shall allow AT+PAIR=reset to clear pairing (clears bonds and reboots)

**FR-3.7.5**: The system shall reconnect automatically to bonded device

### 3.4 User Interface

#### 3.4.1 Button Input

**FR-4.1.1**: The system shall detect long press (> 1 second) on user button (GPIO1.15)

**FR-4.1.2**: The system shall detect short press on user button

**FR-4.1.3**: Long press shall toggle recording state:
- IDLE -> RECORDING (start new session)
- RECORDING -> IDLE (stop recording)

**FR-4.1.4**: Short press during recording shall add bookmark

**FR-4.1.5**: Button input shall work even when BLE is connected

**FR-4.1.6**: The system shall use a custom GPIO button driver (CONFIG_GPIO_BUTTON) with dedicated thread

#### 3.4.2 OLED Display

**FR-4.2.1**: The system shall drive a CH1115 OLED display (88x48 pixels, I2C interface)

**FR-4.2.2**: Display shall use an event-driven UI state machine with dedicated UI thread

**FR-4.2.3**: UI states: OFF, PAIRING_GUIDE, STATUS_BAR, REC_WAVE, REC_DOT, MARKING, PAUSED, POWER_OFF, USB_CONNECTED, OTA, LOW_BATTERY (one-shot fullscreen warning until recharged)

**FR-4.2.4**: Display shall show recording state with wave/dot animation during recording

**FR-4.2.5**: Display shall show recording time during recording

**FR-4.2.6**: Display shall show battery level and charging indicator

**FR-4.2.7**: Display shall show pairing guide when not bonded

**FR-4.2.8**: Display shall show status bar with battery, connection, and mode info

**FR-4.2.9**: Display shall show bookmark animation on AT+MARK

**FR-4.2.10**: Display brightness shall be configurable via AT+BRIGHTNESS (0-255, stored in NVS)

**FR-4.2.11**: Display shall show fullscreen low battery warning when displayed battery level falls to 15% or below while discharging (one-shot until recharged; no automatic shutdown)

**FR-4.2.12**: Display shall update every 50ms for animation (DISPLAY_ANIMATION_PERIOD)

#### 3.4.3 Haptic Feedback

**FR-4.3.1**: The system shall provide haptic feedback on recording start (HAPTIC_SHORT: 100ms)

**FR-4.3.2**: The system shall provide haptic feedback on recording stop (HAPTIC_SHORT: 100ms)

**FR-4.3.3**: The system shall provide haptic feedback on bookmark addition (via display event)

**FR-4.3.4**: The system shall provide haptic feedback on power off (HAPTIC_DOUBLE: 100-100-100ms)

**FR-4.3.5**: Haptic motor control is via PMIC GPIO1 -> BUCK1 (MOTOR_3V3), enabled by CONFIG_CLIP_HAPTIC_MOTOR_ENABLED (default: disabled)

### 3.5 Power Management

#### 3.5.1 Battery Monitoring

**FR-5.1.1**: The system shall monitor battery via NPM1300 PMIC with nRF Fuel Gauge for accurate State of Charge estimation

**FR-5.1.2**: The system shall report a directionally rate-limited view of the nRF Fuel Gauge SoC: the displayed % moves at most `CONFIG_CLIP_BATTERY_DISPLAY_MAX_STEP` (default 3 points) per 60s poll, is persisted across reboot, and setting the step to 0 restores the raw gauge value

**FR-5.1.3**: The system shall report battery level in AT+GSTAT response

**FR-5.1.4**: The system shall display battery level on OLED

#### 3.5.2 Charging Status

**FR-5.2.1**: The system shall detect charging state via NPM1300 PMIC

**FR-5.2.2**: The system shall report charging status in AT+GSTAT response

**FR-5.2.3**: The system shall display charging indicator on OLED

#### 3.5.3 CPU Frequency Scaling

**FR-5.3.1**: The system shall boost CPU to 128MHz during recording (nrfx_clock_divider_set HFCLK_DIV_1)

**FR-5.3.2**: The system shall drop CPU to 64MHz when idle (nrfx_clock_divider_set HFCLK_DIV_2)

**FR-5.3.3**: CPU boost shall be reference-counted to support concurrent audio and transfer operations

#### 3.5.4 PMIC Control

**FR-5.4.1**: The system shall control microphone power via GPIO (gpio1.14, mic_vdd)

**FR-5.4.2**: The system shall control OLED power via GPIO (gpio1.8, oled_vdd)

**FR-5.4.3**: The system shall control WiFi RF switch via GPIO (gpio0.29, rfsw_vdd)

**FR-5.4.4**: The system shall communicate with NPM1300 PMIC via I2C (address 0x6b)

**FR-5.4.5**: The system shall support ship mode power-off via regulator_parent_ship_mode()

### 3.6 Configuration & Settings

**FR-7.1**: The system shall store configuration in Zephyr settings subsystem (backed by LittleFS on external flash)

**FR-7.2**: The system shall provide AT commands for all configuration options (see AT Command Reference)

**FR-7.3**: The system shall support factory reset via AT+FACTORY=confirm (clears config, formats SD card, clears BLE bonds, reboots)

**FR-7.4**: Configuration shall persist across reboots

**FR-7.5**: The system shall store Unix timestamp in settings for time persistence across reboots

### 3.7 Mobile App Requirements

**FR-6.1**: The mobile app shall discover and connect to device via BLE

**FR-6.2**: The mobile app shall send AT commands to control device

**FR-6.3**: The mobile app shall receive and parse JSON responses

**FR-6.4**: The mobile app shall stream file data from device (BLE or UDP)

**FR-6.5**: The mobile app shall display recording sessions with pagination

**FR-6.6**: The mobile app shall display session bookmarks with pagination

**FR-6.7**: The mobile app shall start/stop WiFi AP for high-speed transfer

## 4. State Machine

### 4.1 Device States

| State | Description |
|-------|-------------|
| UNINITIALIZED | Boot, not yet ready |
| IDLE | Ready, not recording, not transferring |
| RECORDING | Active audio recording |
| TRANSMITTING | File transfer in progress |
| WIFI_SYNC | WiFi AP active, UDP transfer mode |
| PAUSED | Recording paused |
| ERROR | Error state |

### 4.2 State Transition Table

```
                  START    STOP     PAUSE    RESUME   MARK     WIFI_ON  WIFI_OFF  POFF_S  POFF_E  STATUS  USB     OTA_S   OTA_D
UNINITIALIZED       -        -        -        -        -        -        -        -       -       -       -       -       -
IDLE             RECORDING   -        -        -        -     WIFI_SYNC    -      same    same    same    same    same    same
RECORDING           -      IDLE    PAUSED      -      same      -        -      same    same      -      same    same    same
TRANSMITTING        -        -        -        -        -        -        -      same    same      -      same    same    same
WIFI_SYNC           -        -        -        -        -        -      IDLE    same    same    same    same    same    same
PAUSED              -      IDLE      -    RECORDING  same      -        -      same    same      -      same    same    same
ERROR           RECORDING   -        -        -        -        -        -      same    same    same    same    same    same
```

### 4.3 State Constraints

**SC-1**: No recording during WiFi: RECORDING state blocks WIFI_ON event (TRANS_INVALID)

**SC-2**: No WiFi during recording: WIFI_SYNC state blocks START event (TRANS_INVALID)

**SC-3**: Pause/resume only during recording

**SC-4**: Transfer can occur independently of recording (RECORDING and TRANSMITTING are orthogonal)

## 5. Non-Functional Requirements

### 5.1 Performance Requirements

**NFR-1.1**: Audio latency from microphone to encoded data shall be < 50ms

**NFR-1.2**: File transfer speed over BLE shall be > 20 KB/s

**NFR-1.3**: File transfer speed over WiFi UDP shall be significantly faster than BLE

**NFR-1.4**: Battery life for continuous recording: TBD — to be re-measured against the actual 240 mAh cell (the earlier ">8 hours" figure was derived from a wrong 500 mAh assumption; production idle is ~170µA)

**NFR-1.5**: Button response time shall be < 100ms

**NFR-1.6**: Display update time shall be < 50ms (50ms animation period)

**NFR-1.7**: AT command response time shall be < 200ms (excluding file transfer)

### 5.2 Reliability Requirements

**NFR-2.1**: The system shall handle SD card removal without data corruption

**NFR-2.2**: The system shall handle BLE disconnect during transfer without data loss (transfer can resume)

**NFR-2.3**: The system shall recover from audio buffer overflow (DMIC timeout recovery with retrigger)

**NFR-2.4**: The system shall maintain data integrity on unexpected power loss

**NFR-2.5**: The system shall handle concurrent button and BLE/UDP commands

### 5.3 Security Requirements

**NFR-3.1**: BLE connection shall require LE Secure Connections pairing

**NFR-3.2**: All BLE communication shall be encrypted

**NFR-3.3**: The system shall support only one bonded device at a time (CONFIG_BT_MAX_PAIRED=1)

**NFR-3.4**: The system shall allow unpairing via AT+PAIR=reset

**NFR-3.5**: Factory reset shall clear all sensitive data (config, SD card, BLE bonds)

**NFR-3.6**: USB CDC serial interface shall be disabled by default. It shall only be enabled via the `AT+USB=on` command over BLE, and shall automatically disable when the USB cable is physically disconnected. This prevents unauthorized serial console access in production devices.

### 5.4 Compatibility Requirements

**NFR-4.1**: The system shall be compatible with BLE 5.0+ central devices

**NFR-4.2**: The system shall support iOS BLE Central API

**NFR-4.3**: The system shall support Android BLE GATT API

**NFR-4.4**: The system shall support SDHC cards

**NFR-4.5**: WiFi AP default: 5GHz channel 36, US regulatory domain (runtime-configurable via AT+WIFICFG, channels 1-13 or 36-165)

### 5.5 Maintainability Requirements

**NFR-5.1**: The system shall support firmware updates via BLE (MCUmgr SMP OTA DFU, dual-image)

**NFR-5.2**: The system shall log errors for debugging (configurable log level via Kconfig)

**NFR-5.2a**: The system shall persist logs to the SD card (`/SD:/LOG/`) for field debugging. Logs are stored in rotating files (128 KiB each, max 20 files) with circular overwrite; the debug build defaults to INF level and the level is runtime-controlled by `AT+LOG=off|info|debug`. This enables post-mortem analysis of issues that occur in the field without requiring a live serial connection.

**NFR-5.3**: The system shall provide version information via AT+VERSION

**NFR-5.4**: The system shall provide diagnostic information via AT+GSTAT

## 6. Hardware Requirements & Constraints

### 6.1 nRF5340 Specifications

**HC-1.1**: Application Core: ARM Cortex-M33 @ 128MHz (boost) / 64MHz (idle)

**HC-1.2**: Network Core: ARM Cortex-M33 @ 64MHz

**HC-1.3**: Total SRAM: 512KB (split between cores)

**HC-1.4**: Total Flash: 1MB (split between cores)

### 6.2 Memory Constraints

**HC-2.1**: Internal flash (1 MB): 88 KB MCUboot bootloader + 936 KB application (single primary slot, overwrite-only — no A/B swap)

**HC-2.2**: Network-core image runs from RAM (`ram_flash`), not internal flash

**HC-2.2a**: External SPI flash OTA staging: 960 KB app-core secondary slot + 256 KB network-core secondary slot (MCUboot overwrite-only); remainder ~6.8 MB LittleFS

**HC-2.3**: External SPI Flash: 8MB total (PY25Q64H), ~6.8MB LittleFS for settings

**HC-2.4**: Heap: 128KB (CONFIG_HEAP_MEM_POOL_SIZE=131072)

### 6.3 Power Constraints

**HC-3.1**: Battery: 4.20V-rated 240 mAh LiPo ("240" / HSZ 362123 cell)

**HC-3.2**: PMIC: NPM1300 with multiple regulators

**HC-3.3**: Charging: USB-C

**HC-3.4**: Power consumption targets:
- Recording: < 80mA
- Idle: < 10mA
- Transfer: < 40mA
- Sleep: < 1mA

**HC-3.5**: WiFi AP shall auto-disable after 3 minutes of inactivity (`CONFIG_CLIP_WIFI_TIMEOUT_MS=180000`) to maintain idle power targets when WiFi is left on but unused.

### 6.4 Peripheral Utilization

**HC-4.1**: PDM0: Microphone array interface (alias: dmic0)

**HC-4.2**: SPI4: SD card via SDHC-SPI (CS: gpio0.9)

**HC-4.3**: BLE via nRF5340 radio

**HC-4.4**: QSPI: nRF7002 WiFi module

**HC-4.5**: GPIO1.15: User button (with custom input driver)

**HC-4.6**: I2C1: NPM1300 PMIC (address 0x6b) -- power, battery, 5 GPIOs

**HC-4.7**: I2C2: CH1115 OLED display (address 0x3c, 88x48, reset: gpio1.9)

**HC-4.8**: SPI3: External SPI flash PY25Q64H (CS: gpio0.20, 8MB)

## 7. Data Requirements

### 7.1 Audio Data Format

**DR-1.1**: Audio codec: Opus (Ogg Encoded Format)

**DR-1.2**: Sample rate: 16 kHz

**DR-1.3**: Bit depth: 16-bit

**DR-1.4**: Frame format: [2-byte little-endian length][Opus frame data]

**DR-1.5**: Frame size: 20ms (320 samples @ 16kHz)

**DR-1.6**: Max packet size: 4000 bytes

### 7.2 File Naming Convention

**DR-2.1**: Session directory: `YYYYMMDDHHMMSS` (14 digits, e.g., `20260328100500`)

**DR-2.2**: Audio files: `{NNNN}.opus` (e.g., `0001.opus`, `0002.opus`)

**DR-2.3**: Session metadata: `session.json`

**DR-2.4**: Bookmark data: `marks.bin`

### 7.3 Session Metadata (session.json)

```json
{
  "channels": 2,
  "sample_rate": 16000,
  "mode": "normal",
  "file_count": 5,
  "synced_files": 0,
  "duration_sec": 600,
  "total_bytes": 3600000
}
```

### 7.4 Bookmark Format (marks.bin)

Binary format (little-endian):
```
[Header: 4 bytes magic "BMRK"]
[Count: 2 bytes uint16]
[Entry 1: 4 bytes uint32 - offset in seconds from session start]
[Entry 2: 4 bytes uint32]
...
```

### 7.5 Configuration Storage (Settings/NVS)

**DR-5.1**: All configuration stored in Zephyr settings subsystem (backed by LittleFS on external SPI flash)

**DR-5.2**: Settings file path: `/lfs/settings/run`

**DR-5.3**: NVS keys (5 total):

| Key | Settings Path | Type | Default | Description |
|-----|--------------|------|---------|-------------|
| mode | config/mode | uint8 | 0 (Normal) | Recording mode |
| noise_suppress | config/noise_suppress | uint8 | 12 | Noise suppression level (dB) |
| auto_delete_days | config/auto_delete_days | int8 | -1 (off) | Auto-delete policy |
| dereverb_enabled | config/dereverb_enabled | bool | true | Dereverberation enabled |
| oled_brightness | config/oled_brightness | uint8 | 32 | OLED brightness (0-255) |

**DR-5.4**: Time persistence: `time/unix_timestamp` (int64, saved/restored on boot)

### 7.6 UDP Protocol

**DR-6.1**: Binary frame protocol with sequence numbers and CRC32 verification

**DR-6.2**: Frame types: DATA (0x01), FILE_ACK (0x03), FILE_START (0x10), FILE_END (0x11), TRANSFER_DONE (0x12), AT_RESP (0x20), HEARTBEAT (0x30)

**DR-6.3**: Max UDP data per frame: 1024 bytes (CONFIG_CLIP_UDP_MAX_DATA_SIZE)

**DR-6.4**: Heartbeat interval: 5000ms (CONFIG_CLIP_UDP_HEARTBEAT_INTERVAL_MS)

**DR-6.5**: Connection timeout: 30000ms (CONFIG_CLIP_UDP_CONNECTION_TIMEOUT_MS)

## 8. Storage Capacity Planning

### 8.1 Bitrate and Storage

| Mode | Channels | Bitrate (total) | Storage per Hour | Notes |
|------|----------|-----------------|-------------------|-------|
| Normal | Stereo | 64 kbps (32k x 2) | ~28.8 MB/hour | No DSP processing |
| Enhanced | Mono | 32 kbps | ~14.4 MB/hour | SpeexDSP noise suppress + dereverb + integer AGC |

The capacity examples below are computed against the Enhanced-mode rate (~14.4 MB/hour); Normal (stereo) mode consumes about twice as much.

### 8.2 Capacity Examples

| SD Card Size | Recording Hours (approx) |
|-------------|------------------------|
| 1 GB | ~69 hours |
| 4 GB | ~278 hours |
| 8 GB | ~556 hours |
| 32 GB | ~2222 hours |

## 9. User Interface Requirements

### 9.1 Button Interaction Design

**UI-1.1**: Long press (> 1s): Toggle recording state (IDLE <-> RECORDING)

**UI-1.2**: Short press (< 1s): Add bookmark (during recording)

**UI-1.3**: Button debounce: handled by custom GPIO input driver

**UI-1.4**: Haptic feedback on press confirmation (when haptic motor enabled)

### 9.2 OLED Screen Layout (88x48 pixels)

**UI-3.1**: Pairing guide screen: shown when BLE not bonded

**UI-3.2**: Recording screen: wave/dot animation with real-time audio energy visualization

**UI-3.3**: Paused screen: static paused indicator

**UI-3.4**: Status bar: battery level (24x24 icons with 0/25/50/75/100% + charging), connection status (BLE/WiFi/client), mode, OTA

**UI-3.5**: Power-off confirmation screen

**UI-3.6**: USB connected screen

**UI-3.7**: OTA update progress screen

**UI-3.8**: Low battery fullscreen warning (<=15%, discharging; one-shot until recharged)

### 9.3 Audio Visualization

**UI-4.1**: Recording display shows real-time audio energy level (0-10 scale)

**UI-4.2**: Energy history (13 samples) is packed into 7 bytes and sent via BLE every ~200ms

**UI-4.3**: Display animation uses fast bars (Enhanced mode) or slow dot (Normal mode)

## 10. Glossary

| Term | Definition |
|------|------------|
| BLE | Bluetooth Low Energy |
| GATT | Generic Attribute Profile (BLE protocol) |
| PDM | Pulse Density Modulation (microphone interface) |
| Opus | Open-source audio codec |
| SpeexDSP | Audio processing library (noise suppression, dereverb) |
| NVS | Non-Volatile Storage (Zephyr settings/KV store) |
| PMIC | Power Management IC (NPM1300) |
| AT Command | Hayes-style command protocol |
| Session | A complete recording event with metadata |
| Bookmark | User-marked timestamp within a recording |
| Chunk | Segment file (time-based split of a recording) |
| Transport | Abstraction layer for BLE, UDP, and USB CDC communication |
| UDP | User Datagram Protocol (WiFi file transfer) |

## 11. References

- Zephyr RTOS Documentation: https://docs.zephyrproject.org/
- nRF5340 Product Specification: https://infocenter.nordicsemi.com/
- Opus Codec RFC: https://datatracker.ietf.org/doc/html/rfc6716
- BLE GATT Specification: https://www.bluetooth.com/specifications/gatt/
- NPM1300 PMIC Datasheet: Nordic Semiconductor
- CH1115 OLED Datasheet: Wuxi Cloud
