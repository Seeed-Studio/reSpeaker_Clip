# reSpeaker Clip - Product Requirements Document

## 1. Product Overview

### 1.1 Product Vision

reSpeaker Clip is a portable Bluetooth recording device that provides high-quality audio capture with seamless mobile app integration. The device enables users to record lectures, meetings, and personal notes with intelligent audio processing, convenient bookmarking, and wireless synchronization to a mobile application.

### 1.2 Target Users

- **Students**: Record lectures and study sessions with bookmarking for key topics
- **Professionals**: Capture meeting minutes and important discussions
- **Journalists**: Record interviews with marked highlights
- **Personal Users**: Voice memos, ideas, and daily notes

### 1.3 Use Case Scenarios

1. **Lecture Recording**: Student records 2-hour lecture, adds bookmarks for important topics, syncs to phone for transcription
2. **Meeting Capture**: Professional records team meeting, marks key decisions, transcribes via mobile app
3. **Interview**: Journalist records interview, bookmarks significant quotes, transfers for editing
4. **Voice Memo**: Quick capture of personal ideas with button press

### 1.4 Product Positioning

- Portable, clip-on form factor
- High-quality audio processing (SpeexDSP + Opus encoding)
- Mobile-first experience with BLE synchronization
- Simple single-button operation
- Long battery life (>8 hours recording)

## 2. User Stories

### 2.1 Core Recording Features

- **US-001**: As a user, I want to start recording with a long button press so I can quickly capture audio
- **US-002**: As a user, I want to stop recording with a long button press so I can end the session
- **US-003**: As a user, I want to add bookmarks during recording with a short button press so I can mark important moments
- **US-004**: As a user, I want to see the current recording state on the display so I know if I'm recording
- **US-005**: As a user, I want to see recording time elapsed so I can track session duration

### 2.2 Mobile App Integration

- **US-010**: As a user, I want to connect my phone via Bluetooth so I can transfer recordings
- **US-011**: As a user, I want to see all recording sessions in the app so I can browse them
- **US-012**: As a user, I want to download specific recordings so I can access them on my phone
- **US-013**: As a user, I want to see bookmarks in the app so I can jump to important moments
- **US-014**: As a user, I want to see transfer progress so I know when it's complete

### 2.3 Device Management

- **US-020**: As a user, I want to see battery level on the device so I know when to charge
- **US-021**: As a user, I want to see charging status so I know it's charging
- **US-022**: As a user, I want to configure audio quality settings so I can balance quality and storage
- **US-023**: As a user, I want to delete old recordings from the app so I can free up space
- **US-024**: As a user, I want to reset the device to factory settings so I can clear all data

### 2.4 Data Synchronization

- **US-030**: As a user, I want recordings to automatically organize into sessions so I can find them easily
- **US-031**: As a user, I want the app to show which recordings have been transferred so I don't download twice
- **US-032**: As a user, I want to pause/resume file transfers so I can manage bandwidth
- **US-033**: As a user, I want to see available storage so I know how much recording time remains

## 3. Functional Requirements

### 3.1 Audio Recording

#### 3.1.1 PDM Microphone Capture

**FR-1.1.1**: The system shall capture audio from PDM microphones at 16 kHz sample rate

**FR-1.1.2**: The system shall support mono recording from single microphone

**FR-1.1.3**: The system shall support stereo recording from dual microphones

**FR-1.1.4**: The system shall support merged mode (stereo capture downmixed to mono)

**FR-1.1.5**: The PDM driver shall use double buffering to prevent audio overflow

#### 3.1.2 Audio Processing Pipeline

**FR-1.2.1**: The system shall apply noise suppression using SpeexDSP (configurable 0-60 dB)

**FR-1.2.2**: The system shall apply dereverberation using SpeexDSP (configurable levels and decay)

**FR-1.2.3**: The system shall apply automatic gain control (AGC) to normalize audio levels

**FR-1.2.4**: The system shall provide normal/enhanced mode presets

**FR-1.2.5**: The system shall process audio in real-time with < 50ms latency

#### 3.1.3 Opus Encoding

**FR-1.3.1**: The system shall encode audio using Opus codec

**FR-1.3.2**: The system shall support configurable bitrates:
  - Mono: 12000, 16000, 24000, 32000 bps
  - Stereo: 24000, 32000, 48000, 64000 bps

**FR-1.3.3**: The system shall support configurable encoding complexity (0-10)

**FR-1.3.4**: The system shall write Opus frames with 2-byte length prefix

**FR-1.3.5**: The system shall split recordings into time-based segments:
  - Normal mode: 10 minutes per file
  - Enhanced mode: 2 minutes per file

#### 3.1.4 Recording Modes

**FR-1.4.1**: The system shall support Normal mode (standard quality, longer files)

**FR-1.4.2**: The system shall support Enhanced mode (high quality, shorter files for easier transfer)

**FR-1.4.3**: The system shall store mode configuration in NVS

### 3.2 Storage Management

#### 3.2.1 SD Card File System

**FR-2.1.1**: The system shall use FAT32 file system on SD card

**FR-2.1.2**: The system shall store recordings in `/SD:/REC/` directory

**FR-2.1.3**: The system shall detect SD card insertion/removal

**FR-2.1.4**: The system shall report SD card errors to user

**FR-2.1.5**: The system shall handle SD card write errors gracefully

#### 3.2.2 Session Organization

**FR-2.2.1**: The system shall create session directories named `YYYYMMDDHHMMSS`

**FR-2.2.2**: The system shall create `session.json` with session metadata

**FR-2.2.3**: The system shall maintain `files.lst` with list of audio files

**FR-2.2.4**: The system shall create `marks.bin` for bookmark data

**FR-2.2.5**: Session metadata shall include:
  - Session ID (timestamp)
  - Start time
  - End time
  - Duration
  - Mode (normal/enhanced)
  - Bitrate
  - Number of files
  - Total size

#### 3.2.3 Bookmark System

**FR-2.3.1**: The system shall add bookmarks on short button press during recording

**FR-2.3.2**: The system shall store bookmarks with:
  - Timestamp
  - Offset (in recording time)
  - File name
  - File offset
  - Optional note

**FR-2.3.3**: The system shall store bookmarks in binary format (`marks.bin`)

**FR-2.3.4**: The system shall support AT+MARK command with optional note text

#### 3.2.4 Auto-Purge Policies

**FR-2.4.1**: The system shall support auto-delete policies:
  - `off`: Manual delete only
  - `0`: Delete immediately after transfer
  - `1-30`: Delete N days after transfer

**FR-2.4.2**: The system shall identify transferred sessions via `.transferred` marker file

**FR-2.4.3**: The system shall provide `AT+PURGEABLE` command to query deletable space

**FR-2.4.4**: The system shall provide `AT+PURGE` command to delete all transferred sessions

### 3.3 BLE Communication

#### 3.3.1 GATT Service Definition

**FR-3.1.1**: The system shall implement BLE GATT service with UUID `6E400001-B5A3-F393-E0A9-E50E24DCCA9E`

**FR-3.1.2**: The system shall provide Command Receive characteristic (Write): `6E400002-B5A3-F393-E0A9-E50E24DCCA9E`

**FR-3.1.3**: The system shall provide Response Send characteristic (Notify): `6E400003-B5A3-F393-E0A9-E50E24DCCA9E`

**FR-3.1.4**: The system shall provide File Data characteristic (Notify): `6E400004-B5A3-F393-E0A9-E50E24DCCA9E`

**FR-3.1.5**: The system shall require LE Secure Connections pairing

**FR-3.1.6**: The system shall require encrypted connection

#### 3.3.2 AT Command Protocol

**FR-3.2.1**: The system shall support EXEC commands: `AT+XX`

**FR-3.2.2**: The system shall support SET commands: `AT+XX=<value>`

**FR-3.2.3**: The system shall support GET commands: `AT+XX?`

**FR-3.2.4**: The system shall use JSON format for all responses

**FR-3.2.5**: The system shall return success response: `{"ok": true, "data": {...}}`

**FR-3.2.6**: The system shall return error response: `{"ok": false, "error": "message"}`

#### 3.3.3 File Transfer Protocol

**FR-3.3.1**: The system shall support streaming file transfer via BLE notify

**FR-3.3.2**: The system shall support configurable chunk size (100-4096 bytes, default 500)

**FR-3.3.3**: The system shall send progress notifications every 10%

**FR-3.3.4**: The system shall support transfer pause/resume

**FR-3.3.5**: The system shall support transfer cancel

**FR-3.3.6**: The system shall allow non-blocking commands during transfer

**FR-3.3.7**: The system shall create `.transferred` marker on successful transfer

**FR-3.3.8**: The system shall handle connection dropout during transfer

#### 3.3.4 Connection Management

**FR-3.4.1**: The system shall auto-advertise when not connected

**FR-3.4.2**: The system shall support bonding/pairing with mobile app

**FR-3.4.3**: The system shall store bond information in NVS

**FR-3.4.4**: The system shall allow AT+PAIR=reset to clear pairing

**FR-3.4.5**: The system shall reconnect automatically to bonded device

### 3.4 User Interface

#### 3.4.1 Button Input

**FR-4.1.1**: The system shall detect long press (> 1 second) on user button

**FR-4.1.2**: The system shall detect short press on user button

**FR-4.1.3**: Long press shall toggle recording state:
  - IDLE → RECORDING (start new session)
  - RECORDING → IDLE (stop recording)

**FR-4.1.4**: Short press during recording shall add bookmark

**FR-4.1.5**: Button input shall work even when BLE is connected

**FR-4.1.6**: Double-click functionality shall be disabled

**FR-4.1.7**: The system shall provide haptic feedback on button events

#### 3.4.2 OLED Display

**FR-4.2.1**: The system shall display current device state (IDLE/RECORDING/TRANSMITTING/PAUSED/ERROR)

**FR-4.2.2**: The system shall display recording time in HH:MM:SS format during recording

**FR-4.2.3**: The system shall display battery level as percentage

**FR-4.2.4**: The system shall display charging status indicator

**FR-4.2.5**: The system shall display current mode (Normal/Enhanced)

**FR-4.2.6**: The system shall display bitrate and channel configuration

**FR-4.2.7**: Display shall update on state changes

**FR-4.2.8**: Display shall update recording time every second

**FR-4.2.9**: Display shall update battery level when changed > 5%

**FR-4.2.10**: **Initial Implementation**: Display via UART serial logging

**FR-4.2.11**: **Future Implementation**: Actual CH1115 OLED driver (88x48 pixels, I2C)

#### 3.4.3 Haptic Feedback

**FR-4.3.1**: The system shall provide haptic feedback on recording start

**FR-4.3.2**: The system shall provide haptic feedback on recording stop

**FR-4.3.3**: The system shall provide haptic feedback on bookmark addition

**FR-4.3.4**: The system shall provide different patterns for different events

**FR-4.3.5**: **Initial Implementation**: Haptic feedback via LOG_INF() logging (e.g., "[HAPTIC] Pulse: 100 ms")

**FR-4.3.6**: **Future Implementation**: Actual haptic motor control via PMIC GPIO2

### 3.5 Power Management

#### 3.5.1 Battery Monitoring

**FR-5.1.1**: The system shall monitor battery voltage via PMIC

**FR-5.1.2**: The system shall calculate battery percentage

**FR-5.1.3**: The system shall report battery level in AT+GSTAT response

**FR-5.1.4**: The system shall prevent new recording when battery < 10%

#### 3.5.2 Charging Status

**FR-5.2.1**: The system shall detect charging state via PMIC

**FR-5.2.2**: The system shall report charging status in AT+GSTAT response

**FR-5.2.3**: The system shall display charging indicator

#### 3.5.3 Low Power States

**FR-5.3.1**: The system shall enter low power mode when idle

**FR-5.3.2**: The system shall wake from low power on button press

**FR-5.3.3**: The system shall wake from low power on BLE connection

#### 3.5.4 PMIC Control

**FR-5.4.1**: The system shall control microphone power via GPIO

**FR-5.4.2**: The system shall control OLED power via GPIO

**FR-5.4.3**: The system shall control WiFi RF switch via GPIO

**FR-5.4.4**: The system shall communicate with NPM1300 PMIC via I2C

### 3.6 Mobile App Requirements

**FR-6.1**: The mobile app shall discover and connect to device via BLE

**FR-6.2**: The mobile app shall send AT commands to control device

**FR-6.3**: The mobile app shall receive and parse JSON responses

**FR-6.4**: The mobile app shall stream file data from device

**FR-6.5**: The mobile app shall display recording sessions

**FR-6.6**: The mobile app shall display session bookmarks

**FR-6.7**: The mobile app shall show transfer progress

**FR-6.8**: The mobile app shall support audio playback of downloaded files

### 3.7 Configuration & Settings

**FR-7.1**: The system shall store configuration in NVS

**FR-7.2**: The system shall provide AT commands for all configuration options

**FR-7.3**: The system shall support factory reset via AT+FACTORY

**FR-7.4**: Configuration shall persist across reboots

## 4. Non-Functional Requirements

### 4.1 Performance Requirements

**NFR-1.1**: Audio latency from microphone to encoded data shall be < 50ms

**NFR-1.2**: File transfer speed over BLE shall be > 20 KB/s

**NFR-1.3**: Battery life shall be > 8 hours continuous recording

**NFR-1.4**: Battery life shall be > 4 hours continuous file transfer

**NFR-1.5**: Boot time to ready state shall be < 3 seconds

**NFR-1.6**: Button response time shall be < 100ms

**NFR-1.7**: Display update time shall be < 50ms

**NFR-1.8**: AT command response time shall be < 200ms (excluding file transfer)

### 4.2 Reliability Requirements

**NFR-2.1**: Mean Time Between Failures (MTBF) shall be > 1000 hours

**NFR-2.2**: The system shall handle SD card removal without data corruption

**NFR-2.3**: The system shall handle BLE disconnect during transfer without data loss

**NFR-2.4**: The system shall recover from audio buffer overflow

**NFR-2.5**: The system shall maintain data integrity on unexpected power loss

**NFR-2.6**: The system shall handle concurrent button and BLE commands

### 4.3 Security Requirements

**NFR-3.1**: BLE connection shall require LE Secure Connections pairing

**NFR-3.2**: All BLE communication shall be encrypted

**NFR-3.3**: The system shall support only one bonded device at a time

**NFR-3.4**: The system shall allow unpairing via AT+PAIR=reset

**NFR-3.5**: Factory reset shall clear all sensitive data

### 4.4 Compatibility Requirements

**NFR-4.1**: The system shall be compatible with BLE 5.0+ central devices

**NFR-4.2**: The system shall support iOS BLE Central API

**NFR-4.3**: The system shall support Android BLE GATT API

**NFR-4.4**: The system shall support SDHC cards up to 32GB

**NFR-4.5**: The mobile app shall support iOS 14+

**NFR-4.6**: The mobile app shall support Android 10+

### 4.5 Maintainability Requirements

**NFR-5.1**: The system shall support firmware updates via BLE (future)

**NFR-5.2**: The system shall log errors for debugging

**NFR-5.3**: The system shall provide version information via AT+VERSION

**NFR-5.4**: The system shall provide diagnostic information via AT+GSTAT

## 5. Hardware Requirements & Constraints

### 5.1 nRF5340 Specifications

**HC-1.1**: Application Core: ARM Cortex-M33 @ 128MHz

**HC-1.2**: Network Core: ARM Cortex-M33 @ 64MHz

**HC-1.3**: Total SRAM: 512KB (split between cores)

**HC-1.4**: Total Flash: 1MB (split between cores)

### 5.2 Memory Constraints

**HC-2.1**: Total SRAM: 512KB, with 64KB allocated to BLE core, **448KB available** for application

**HC-2.2**: Non-secure Flash: 192KB available

**HC-2.3**: External SPI Flash: 64MB total, ~15MB user accessible

**HC-2.4**: Memory allocation budget:
  - BLE stack: 64KB (dedicated)
  - Audio buffer: ~64KB
  - Opus encoder state: ~20KB
  - SpeexDSP state: ~10KB
  - SD card buffer: 8KB
  - Protocol buffer: 8KB
  - Thread stacks: ~64KB
  - Heap: 64KB
  - Reserved: ~150KB
  - **Total**: ~448KB

### 5.3 Power Constraints

**HC-3.1**: Battery: 3.7V 500mAh LiPo

**HC-3.2**: PMIC: NPM1300 with multiple regulators

**HC-3.3**: Charging: USB-C 5V @ 500mA

**HC-3.4**: Power consumption targets:
  - Recording: < 80mA
  - Idle: < 10mA
  - Transfer: < 40mA
  - Sleep: < 1mA

### 5.4 Peripheral Utilization

**HC-4.1**: PDM microphone interface (I2S compatible)

**HC-4.2**: SD card via SDHC-SPI

**HC-4.3**: BLE via nRF5340 radio

**HC-4.4**: User button on GPIO1.15

**HC-4.5**: I2C for PMIC (NPM1300) and OLED (CH1115)

**HC-4.6**: External SPI flash (PY25Q64H)

## 6. Data Requirements

### 6.1 Audio Data Format

**DR-1.1**: Audio codec: Opus (Ogg Encoded Format)

**DR-1.2**: Sample rate: 16 kHz

**DR-1.3**: Bit depth: 16-bit

**DR-1.4**: Frame format: [2-byte length][Opus frame data]

**DR-1.5**: Frame size: 20ms (320 samples @ 16kHz)

### 6.2 File Naming Convention

**DR-2.1**: Session directory: `YYYYMMDDHHMMSS` (e.g., `20240203100000`)

**DR-2.2**: Audio files: `{NNN}.opus` (e.g., `001.opus`, `002.opus`)

**DR-2.3**: Session metadata: `session.json`

**DR-2.4**: File list: `files.lst`

**DR-2.5**: Bookmark data: `marks.bin`

**DR-2.6**: Transfer marker: `.transferred`

### 6.3 Session Metadata (session.json)

```json
{
  "session_id": "20240203100000",
  "start_time": "2024-02-03T10:00:00Z",
  "end_time": "2024-02-03T10:10:00Z",
  "duration": 600,
  "mode": "normal",
  "bitrate": 48000,
  "channels": "stereo",
  "file_count": 1,
  "total_size": 3600000,
  "mark_count": 3
}
```

### 6.4 Bookmark Format (marks.bin)

Binary format (little-endian):
```
[Header: 4 bytes magic "MRK1"]
[Count: 4 bytes uint32]
[Entry 1]
  [Timestamp: 8 bytes uint64]
  [Offset: 4 bytes uint32 - seconds from start]
  [File index: 2 bytes uint16]
  [File offset: 4 bytes uint32]
  [Note length: 2 bytes uint16]
  [Note: N bytes UTF-8 string]
[Entry 2]
...
```

### 6.5 Configuration Storage (NVS)

**DR-5.1**: All configuration stored in Zephyr NVS

**DR-5.2**: Keys:
  - `bitrate`: uint16 (default: 24000)
  - `complexity`: uint8 (default: 5)
  - `mode`: string "normal" | "enhanced" (default: "normal")
  - `noise`: uint8 (default: 0)
  - `dereverb`: string "on,level,decay" | "off"
  - `agc`: string "on,target,gain" | "off"
  - `chunksize`: uint16 (default: 500)
  - `autodel`: string "off" | "0" | "1-30" (default: "off")

## 7. User Interface Requirements

### 7.1 Button Interaction Design

**UI-1.1**: Long press (> 1s): Toggle recording state

**UI-1.2**: Short press (< 1s): Add bookmark (during recording)

**UI-1.3**: Button debounce: 50ms

**UI-1.4**: Haptic feedback on press confirmation

### 7.2 LED Status Patterns

**Note**: This device uses OLED display instead of LEDs

### 7.3 OLED Screen Layout

```
┌──────────────────────┐
│  reSpeaker Clip      │  Header (top row)
│                      │
│  State: RECORDING    │  Current state
│  [REC] 01:23:45      │  Icon + Time
│                      │
│  Batt: 85% ⚡        │  Battery + charging
│  Mode: Enhanced      │  Settings
│  48kHz Stereo        │  Bitrate/channels
└──────────────────────┘
```

**UI-3.1**: State display: IDLE, RECORDING, TRANSMITTING, PAUSED, ERROR

**UI-3.2**: Recording time: HH:MM:SS format

**UI-3.3**: Battery: 0-100% with ⚡ when charging

**UI-3.4**: Mode: Normal or Enhanced

**UI-3.5**: Bitrate: numeric value in bps

**UI-3.6**: Channels: Mono or Stereo

### 7.4 Haptic Feedback Patterns

**UI-4.1**: Recording start: 100ms pulse

**UI-4.2**: Recording stop: 50ms double pulse

**UI-4.3**: Bookmark added: 30ms triple pulse

**UI-4.4**: Error: 200ms long pulse

## 8. Quality Attributes

### 8.1 Audio Quality Metrics

**QA-1.1**: SNR (Signal-to-Noise Ratio): > 60dB with noise suppression

**QA-1.2**: THD (Total Harmonic Distortion): < 1%

**QA-1.3**: Frequency response: 100Hz - 8kHz ± 3dB

**QA-1.4**: Opus encoding quality: Complexity 5 (balanced)

### 8.2 Battery Life Expectations

**QA-2.1**: Recording time: > 8 hours @ 500mAh

**QA-2.2**: Transfer time: > 4 hours continuous BLE transfer

**QA-2.3**: Idle time: > 72 hours

**QA-2.4**: Charging time: < 2 hours (0-100%)

### 8.3 Transfer Speed Targets

**QA-3.1**: BLE throughput: > 20 KB/s average

**QA-3.2**: 1MB file transfer: < 1 minute

**QA-3.3**: 10MB session transfer: < 10 minutes

### 8.4 Storage Capacity Planning

**QA-4.1**: Bitrate 24kbps mono: ~3MB/hour (~260 hours on 8GB card)

**QA-4.2**: Bitrate 48kbps stereo: ~6MB/hour (~130 hours on 8GB card)

**QA-4.3**: Bitrate 64kbps stereo: ~8MB/hour (~100 hours on 8GB card)

## 9. Acceptance Criteria

### 9.1 Functional Acceptance Tests

**AC-1**: Recording Control
- [ ] Long press starts recording in IDLE state
- [ ] Long press stops recording in RECORDING state
- [ ] Short press adds bookmark during recording
- [ ] State changes displayed on screen
- [ ] Recording time updates every second

**AC-2**: File Transfer
- [ ] App can list all sessions
- [ ] App can list files in session
- [ ] App can download single file
- [ ] App can pause/resume transfer
- [ ] App can cancel transfer
- [ ] Progress updates every 10%
- [ ] Transfer creates .transferred marker

**AC-3**: Bookmark System
- [ ] AT+MARK adds bookmark during recording
- [ ] AT+MARKS returns bookmark list
- [ ] Bookmarks sync to mobile app
- [ ] Bookmark offset is accurate

**AC-4**: Configuration
- [ ] All config AT commands work
- [ ] Config persists across reboots
- [ ] AT+FACTORY resets all settings

### 9.2 Performance Benchmarks

**AC-5**: Audio Performance
- [ ] Audio latency < 50ms (measured)
- [ ] No buffer underruns in 1-hour recording
- [ ] No buffer overflows in 1-hour recording

**AC-6**: Transfer Performance
- [ ] Transfer speed > 20 KB/s (measured)
- [ ] 1MB file transfers in < 60s
- [ ] Non-blocking commands respond < 200ms during transfer

**AC-7**: Battery Life
- [ ] 8 hours continuous recording (measured)
- [ ] 4 hours continuous transfer (measured)

**AC-8**: Boot Time
- [ ] Device ready in < 3s from power-on

### 9.3 User Experience Validation

**AC-9**: Button Interaction
- [ ] Button response feels immediate (< 100ms)
- [ ] Haptic feedback provides clear confirmation
- [ ] No false triggers from debounce

**AC-10**: Display Clarity
- [ ] State is clearly visible
- [ ] Recording time is readable
- [ ] Battery status is clear
- [ ] Charging indicator is obvious

**AC-11**: Error Handling
- [ ] SD card removal shows error
- [ ] Low battery prevents recording
- [ ] BLE disconnect pauses transfer
- [ ] All errors have clear messages

## 10. Glossary

| Term | Definition |
|------|------------|
| BLE | Bluetooth Low Energy |
| GATT | Generic Attribute Profile (BLE protocol) |
| PDM | Pulse Density Modulation (microphone interface) |
| Opus | Open-source audio codec |
| SpeexDSP | Audio processing library (noise suppression, AGC) |
| NVS | Non-Volatile Storage (Zephyr KV store) |
| PMIC | Power Management IC |
| AT Command | Hayes-style command protocol |
| Session | A complete recording event with metadata |
| Bookmark | User-marked timestamp within a recording |
| Chunk | Data block size for BLE transfer |

## 11. References

- Zephyr RTOS Documentation: https://docs.zephyrproject.org/
- nRF5340 Product Specification: https://infocenter.nordicsemi.com/
- Opus Codec RFC: https://datatracker.ietf.org/doc/html/rfc6716
- BLE GATT Specification: https://www.bluetooth.com/specifications/gatt/
- NPM1300 PMIC Datasheet: Nordic Semiconductor
- CH1115 OLED Datasheet: Wuxi Cloud
