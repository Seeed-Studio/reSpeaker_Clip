# reSpeaker Clip - BLE AT Protocol Specification

## 1. Protocol Overview

### 1.1 Design Principles

The reSpeaker Clip uses a JSON-based AT command protocol for communication between the mobile application and the device. All commands follow the Hayes AT command standard with a unified JSON response format.

**Key Design Principles:**
- **Human-readable**: JSON format for easy debugging and parsing
- **Extensible**: Easy to add new commands without breaking compatibility
- **Non-blocking**: File transfer allows concurrent command processing
- **Robust**: Comprehensive error handling and recovery
- **Efficient**: Binary data transfer over separate characteristic

### 1.2 Transport Layer (BLE GATT)

**Service UUID**: `6E400001-B5A3-F393-E0A9-E50E24DCCA9E`

The protocol uses Bluetooth Low Energy with GATT (Generic Attribute Profile) as the transport layer. Three characteristics are provided:
1. **Command Receive** (Write): App sends AT commands to device
2. **Response Send** (Notify): Device sends JSON responses and progress updates
3. **File Data** (Notify): Device streams binary file data

### 1.3 Command Syntax

Three command types are supported:

| Type | Format | Example | Description |
|------|--------|---------|-------------|
| EXEC | `AT+XX` | `AT+GSTAT` | Execute operation without parameters |
| SET | `AT+XX=<value>` | `AT+BITRATE=24000` | Set parameter value |
| GET | `AT+XX?` | `AT+BITRATE?` | Query current parameter value |

### 1.4 Response Format

All responses use unified JSON format:

**Generic Response Schema:**
```json
{
  "ok": true,
  "data": { ... },
  "error": null
}
```

**Success Response:**
```json
{
  "ok": true,
  "data": { ... }
}
```

**Error Response:**
```json
{
  "ok": false,
  "error": "Error message"
}
```

### 1.5 Error Handling

All errors return JSON with `"ok": false` and an `"error"` field containing a descriptive message. Error codes are categorized by type (see Section 8).

## 2. BLE GATT Service Definition

### 2.1 Service UUID: 6E400001-B5A3-F393-E0A9-E50E24DCCA9E

This custom UUID defines the reSpeaker Clip communication service.

### 2.2 Characteristics

#### 2.2.1 Command Receive (Write)

**UUID**: `6E400002-B5A3-F393-E0A9-E50E24DCCA9E`
**Properties**: Write
**Max Length**: 512 bytes
**Purpose**: Receive AT commands from mobile app

The app writes AT command strings to this characteristic. Each write is processed as a complete command.

#### 2.2.2 Response Send (Notify)

**UUID**: `6E400003-B5A3-F393-E0A9-E50E24DCCA9E`
**Properties**: Notify
**Max Length**: MTU - 3 (typically 244 bytes for MTU 247)
**Purpose**: Send JSON responses and progress notifications

The device sends:
- Command responses (success/error)
- Progress updates during file transfer
- Unsolicited event notifications

#### 2.2.3 File Data (Notify)

**UUID**: `6E400004-B5A3-F393-E0A9-E50E24DCCA9E`
**Properties**: Notify
**Max Length**: MTU - 3 (typically 244 bytes for MTU 247)
**Purpose**: Stream binary file data during transfer

Raw Opus file data is sent through this characteristic without JSON wrapping. Each notification contains a chunk of file data.

### 2.3 Connection Requirements

| Requirement | Specification |
|-------------|---------------|
| Pairing | LE Secure Connections (mandatory) |
| Bonding | Required (stored for auto-reconnect) |
| Encryption | AES-128 CCM (mandatory) |
| MTU | Negotiated up to 517 (default 23) |
| Connection Interval | 15-80 ms (adaptive) |

### 2.4 MTU Negotiation

The device should negotiate MTU to optimal size:
- **Default MTU**: 23 bytes (BLE specification)
- **Maximum MTU**: 517 bytes (nRF5340 support)
- **Recommended MTU**: 247 bytes (optimal for throughput)

Larger MTU = fewer notifications = higher throughput.

## 3. Command Protocol

### 3.1 Command Types (EXEC, SET, GET)

#### EXEC Commands (No Parameters)
Format: `AT+XX`

Execute an operation or retrieve status:
- `AT+GSTAT` - Get device status
- `AT+START` - Start recording (uses mode parameter)
- `AT+STOP` - Stop recording
- `AT+PAUSE` - Pause file transfer
- `AT+RESUME` - Resume file transfer
- `AT+CANCEL` - Cancel file transfer
- `AT+PROGRESS` - Query transfer progress
- `AT+PURGE` - Delete transferred sessions
- `AT+VERSION` - Get version info
- `AT+RESET` - Reboot device

#### SET Commands (With Parameters)
Format: `AT+XX=<value>`

Set configuration or execute with parameters:
- `AT+BITRATE=<bps>` - Set Opus bitrate
- `AT+COMPLEXITY=<0-10>` - Set encoding complexity
- `AT+MODE=<normal|enhanced>` - Set recording mode
- `AT+NOISE=<0-60>` - Set noise suppression level
- `AT+DEREVERB=<on/off>,<level>,<decay>` - Set dereverberation
- `AT+AGC=<on/off>,<target>,<max_gain>` - Set AGC
- `AT+CHUNKSIZE=<bytes>` - Set transfer chunk size
- `AT+AUTODEL=<off|0|1-30>` - Set auto-delete policy
- `AT+TIME=<unix_ts>` - Set system time
- `AT+PAIR=<reset>` - Manage pairing
- `AT+FACTORY=<confirm>` - Factory reset
- `AT+START=<mode>` - Start recording with mode
- `AT+MARK=<note>` - Add bookmark with note
- `AT+DELETE=<session>` - Delete session
- `AT+LIST=<session>` - List session files
- `AT+MARKS=<session>` - Get session bookmarks
- `AT+DOWNLOAD=<session/file>` - Download file

#### GET Commands (Query)
Format: `AT+XX?`

Query current configuration:
- `AT+BITRATE?` - Get current bitrate
- `AT+COMPLEXITY?` - Get current complexity
- `AT+MODE?` - Get current mode
- `AT+NOISE?` - Get noise suppression level
- `AT+DEREVERB?` - Get dereverberation settings
- `AT+AGC?` - Get AGC settings
- `AT+CHUNKSIZE?` - Get current chunk size
- `AT+AUTODEL?` - Get auto-delete policy
- `AT+TIME?` - Get current time
- `AT+PAIR?` - Get pairing status

### 3.2 JSON Message Format

All responses use JSON with consistent structure:

**Success with data:**
```json
{
  "ok": true,
  "data": {
    "key": "value"
  }
}
```

**Success without data:**
```json
{
  "ok": true
}
```

**Error:**
```json
{
  "ok": false,
  "error": "Error message description"
}
```

**Progress notification:**
```json
{
  "ok": true,
  "progress": 50,
  "transferred": 360000,
  "total": 720000
}
```

### 3.3 Command Reference

#### 3.3.1 Status Commands

##### AT+GSTAT - Get Device Status

Get current device state and information.

**Request:**
```
AT+GSTAT
```

**Response:**
```json
{
  "ok": true,
  "data": {
    "state": "IDLE",
    "battery": 85,
    "charging": true,
    "mode": "normal",
    "bitrate": 48000,
    "free_space": 1024000000,
    "session_count": 3
  }
}
```

**Fields:**
- `state`: Current device state (IDLE/RECORDING/TRANSMITTING/PAUSED/ERROR)
- `battery`: Battery percentage (0-100)
- `charging`: Charging status (true/false)
- `mode`: Recording mode (normal/enhanced)
- `bitrate`: Current bitrate in bps
- `free_space`: Available bytes on SD card
- `session_count`: Number of recording sessions

**Error Cases:**
- Never fails (always returns current state)

---

##### AT+TIME - System Time

Get or set system time (Unix timestamp).

**Request (Set):**
```
AT+TIME=1706918430
```

**Request (Get):**
```
AT+TIME?
```

**Response (Set):**
```json
{
  "ok": true
}
```

**Response (Get):**
```json
{
  "ok": true,
  "value": "2024-02-03T10:00:30Z"
}
```

**Error Cases:**
- `1001`: Invalid timestamp format

---

##### AT+VERSION - Version Information

Get firmware, hardware, and SDK versions.

**Request:**
```
AT+VERSION
```

**Response:**
```json
{
  "ok": true,
  "firmware": "1.0.0",
  "hardware": "1.0",
  "sdk": "3.2.1",
  "build": "2024-02-03"
}
```

**Fields:**
- `firmware`: Firmware version string
- `hardware`: Hardware revision
- `sdk`: Zephyr/Nordic SDK version
- `build`: Build date

---

#### 3.3.2 Recording Control

##### AT+START - Start Recording

Start a new recording session.

**Request:**
```
AT+START=normal
```

**Parameters:**
- `mode`: "normal" or "enhanced"

**Response:**
```json
{
  "ok": true,
  "data": {
    "session": "20240203100000",
    "mode": "normal",
    "bitrate": 48000
  }
}
```

**Error Cases:**
- `4001`: Already recording
- `4002`: SD card not present
- `4003`: SD card full
- `4004`: Battery too low (< 10%)

**State Change:** IDLE → RECORDING

**Side Effects:**
- Creates new session directory
- Initializes session.json
- Starts audio capture
- Enables button bookmarking

---

##### AT+STOP - Stop Recording

Stop current recording session.

**Request:**
```
AT+STOP
```

**Response:**
```json
{
  "ok": true,
  "data": {
    "session": "20240203100000",
    "duration": 600,
    "file_count": 5,
    "total_size": 3600000
  }
}
```

**Fields:**
- `session`: Session ID
- `duration`: Recording duration in seconds
- `file_count`: Number of Opus files created
- `total_size`: Total bytes of all files

**Error Cases:**
- `4005`: Not currently recording

**State Change:** RECORDING → IDLE

**Side Effects:**
- Finalizes session.json
- Closes all files
- Stops audio capture
- Disables button bookmarking

---

##### AT+MARK - Add Bookmark

Add a bookmark at current recording position.

**Request (with note):**
```
AT+MARK=Important discussion
```

**Request (without note):**
```
AT+MARK
```

**Response:**
```json
{
  "ok": true,
  "data": {
    "offset": 123,
    "note": "Important discussion"
  }
}
```

**Fields:**
- `offset`: Seconds from session start
- `note`: Optional note text

**Error Cases:**
- `4006`: Not recording (can only bookmark during recording)

**Side Effects:**
- Writes bookmark to marks.bin
- Sends unsolicited bookmark notification
- Triggers haptic feedback

---

#### 3.3.3 Session Management

##### AT+LIST - List Sessions/Files

List all sessions, get session details, or list files with pagination.

**Request (All Sessions):**
```
AT+LIST
```

**Request (Session Details):**
```
AT+LIST=20240203100000
```

**Request (Paginated File List):**
```
AT+LIST=20240203100000?1&20
```

**Response (All Sessions):**
```json
{
  "ok": true,
  "data": [
    {"id": "20240203100000", "files": 30, "size": 5242880, "bookmarks": 5},
    {"id": "20240203_120000", "files": 15, "size": 2621440, "bookmarks": 0}
  ]
}
```

**Response (Session Details):**
```json
{
  "ok": true,
  "data": {
    "files": 30,
    "size": 5242880,
    "synced": 15,
    "bookmarks": 5,
    "channels": 2,
    "sample_rate": 16000,
    "mode": "normal"
  }
}
```

**Response (Paginated File List):**
```json
{
  "ok": true,
  "data": {
    "total": 200,
    "page": 1,
    "per_page": 10,
    "files": [
      "0001.opus",
      "0002.opus",
      "0003.opus"
    ]
  }
}
```

**Fields:**
- `id`: Session ID
- `files`: Total number of audio files in session
- `size`: Total bytes of all files
- `synced`: Number of files successfully transferred (only in session details)
- `bookmarks`: Number of bookmarks in session
- `channels`: Audio channels - 1=mono, 2=stereo (only in session details)
- `sample_rate`: Sample rate in Hz, e.g., 16000 (only in session details)
- `mode`: Recording mode - "normal" (stereo) or "enhanced" (mono with DSP) (only in session details)
- `total`: Total number of files (paginated response)
- `page`: Current page number (paginated response)
- `per_page`: Items per page (paginated response, default 10, max 50)

**Usage Examples:**
```
# List all sessions
AT+LIST
# → Returns list with id, files, size for each session

# Get session details (including synced count and audio format)
AT+LIST=20240203100000
# → Returns files, size, synced, channels, sample_rate for specific session

# List files with pagination (page 1, 10 items per page)
AT+LIST=20240203100000?1&10
# → Returns first 10 files

# Resume transfer from next file after synced count
# If synced=15, resume from file 0016.opus
AT+DOWNLOAD=20240203100000:0016.opus
```

**Error Cases:**
- `3001`: Session not found (when listing files)

---

##### AT+DELETE - Delete Session

Delete a recording session and all its files.

**Request:**
```
AT+DELETE=20240203100000
```

**Response:**
```json
{
  "ok": true,
  "deleted": ["0001.opus", "0002.opus", "0003.opus"],
  "freed": 2160000
}
```

**Fields:**
- `deleted`: List of deleted files
- `freed`: Bytes freed from storage

**Error Cases:**
- `3001`: Session not found
- `3003`: File system error

**Side Effects:**
- Deletes session directory
- Updates session count in GSTAT

---

##### AT+MARKS - Get Session Bookmarks

Retrieve bookmarks for a session. Supports summary and paginated formats.

**Request (Summary):**
```
AT+MARKS=20240203100000
```

**Response (Summary):**
```json
{
  "ok": true,
  "data": {
    "total": 50,
    "marks_file": "marks.bin"
  }
}
```

**Request (Paginated, page 1):**
```
AT+MARKS=20240203100000?1&10
```

**Response (Paginated):**
```json
{
  "ok": true,
  "data": {
    "total": 50,
    "page": 1,
    "per_page": 10,
    "bookmarks": [
      {"offset": 30, "note": "Important point"},
      {"offset": 60, "note": ""}
    ]
  }
}
```

**Request (Page 2):**
```
AT+MARKS=20240203100000?2&10
```

**Fields:**
- `total`: Total number of bookmarks
- `page`: Current page number (1-based)
- `per_page`: Items per page (default 10, max 50)
- `bookmarks`: Array of bookmark entries
- `marks_file`: Filename for full bookmark data (summary only)
  - Per bookmark:
    - `offset`: Seconds from session start
    - `note`: Optional note text (omitted if empty)

**Pagination Logic:**
- Without `?`: Returns summary with total count
- With `?page&per_page`: Returns specific page
  - Default: page=1, per_page=10
  - Maximum per_page: 50
- Client increments `page` to get next page

**Error Cases:**
- `3001`: Session not found
- `3005`: Bookmark file corrupted

---

#### 3.3.4 File Transfer

##### AT+DOWNLOAD - Download File

Start file transfer from device to app. Supports three modes:

**Request (Entire Session):**
```
AT+DOWNLOAD=<session_id>
```

**Request (Single File):**
```
AT+DOWNLOAD=<session_id>/<filename>
```

**Request (Resume from File):**
```
AT+DOWNLOAD=<session_id>:<start_file>
```

**Examples:**
```
# Download all files from session
AT+DOWNLOAD=20250225_143000

# Download single file
AT+DOWNLOAD=20250225_143000/015.opus

# Resume from specific file (skips files before start_file)
# Use format: 4-digit number with leading zeros + .opus extension
AT+DOWNLOAD=20250225_143000:0016.opus
```

**Resume Logic:**
1. Client queries session details: `AT+LIST=<session_id>`
2. Response includes `synced` count (e.g., 15 files already transferred)
3. Client calculates next file: `synced + 1` → file 0016.opus
4. Client sends: `AT+DOWNLOAD=<session_id>:0016.opus`
5. Device transfers from 0016.opus onwards

**Response (Start):**
```json
{
  "ok": true
}
```

**Events During Transfer:**

File Ready Event:
```json
{
  "ok": true,
  "event": "file_ready",
  "filename": "0001.opus",
  "size": 52598
}
```

File Complete Event:
```json
{
  "ok": true,
  "event": "file_complete",
  "filename": "0001.opus"
}
```

**Data Flow:**
1. Device sends start response
2. For each file:
   - Device sends `file_ready` event (optional, may be lost)
   - Device streams file data via File Data characteristic
   - Device sends `file_complete` event
3. Client can resume by sending `AT+DOWNLOAD=session:next_file`
4. Transfer continues until all files transferred

**Disconnect/Resume Flow:**
1. During transfer, BLE disconnects
2. Device automatically cancels transfer
3. Device continues recording (if in RECORDING state)
4. Client reconnects
5. Client sends `AT+DOWNLOAD=session:last_received_file`
6. Transfer resumes from next file

**Example Session:**
```
# Initial transfer start
AT+DOWNLOAD=20250225_143000

# ... transfer progresses ...

# [BLE disconnects - file 015.opus was last sent]

# [Client reconnects]

# Resume from next file (016.opus)
AT+DOWNLOAD=20250225_143000:016.opus

# Transfer continues from 016.opus onwards
```

**Error Cases:**
- `5001`: Session not found
- `5002`: Transfer already in progress
- `5003`: SD card not mounted
- `5004`: Invalid file format

**State Change:** IDLE → TRANSMITTING

---

##### AT+CHUNKSIZE - Set Chunk Size

Configure data block size for file transfer.

**Request (Set):**
```
AT+CHUNKSIZE=500
```

**Request (Get):**
```
AT+CHUNKSIZE?
```

**Response:**
```json
{
  "ok": true,
  "value": 500
}
```

**Valid Range:** 100 - 4096 bytes
**Default:** 500 bytes

**Trade-offs:**
- Smaller chunks: More frequent progress updates, slower transfer
- Larger chunks: Faster transfer, higher memory usage

**Error Cases:**
- `6001`: Invalid chunk size (out of range)

---

##### AT+PROGRESS - Query Transfer Progress

Get current file transfer progress.

**Request:**
```
AT+PROGRESS
```

**Response:**
```json
{
  "ok": true,
  "progress": 50,
  "transferred": 360000,
  "total": 720000
}
```

**Fields:**
- `progress`: Percentage complete (0-100)
- `transferred`: Bytes transferred
- `total`: Total file size

**Note:** This command can be used during transfer (non-blocking).

---

#### 3.3.5 Recording Control

##### AT+PAUSE - Pause Recording

Pause ongoing recording.

**Request:**
```
AT+PAUSE
```

**Response:**
```json
{
  "ok": true
}
```

**State Change:** RECORDING → PAUSED

**Side Effects:**
- Stops DMIC capture
- Closes current file
- Keeps session open
- Recording can be resumed with `AT+RESUME`

**Error Cases:**
- `5004`: Not recording

---

##### AT+RESUME - Resume Recording

Resume paused recording.

**Request:**
```
AT+RESUME
```

**Response:**
```json
{
  "ok": true
}
```

**State Change:** PAUSED → RECORDING

**Side Effects:**
- Creates new file with incremented index
- Resumes DMIC capture
- Continues in same session

**Error Cases:**
- `5005`: Not paused

---

##### AT+CANCEL - Cancel Transfer

Cancel ongoing or paused transfer.

**Request:**
```
AT+CANCEL
```

**Response:**
```json
{
  "ok": true,
  "cancelled": true
}
```

**State Change:** TRANSMITTING/PAUSED → IDLE

**Side Effects:**
- Closes file
- Discards progress
- Does NOT create .transferred marker

---

#### 3.3.6 Storage Management

##### AT+PURGEABLE - Query Cleanable Space

Get information about transferred sessions that can be deleted.

**Request:**
```
AT+PURGEABLE
```

**Response:**
```json
{
  "ok": true,
  "count": 3,
  "bytes": 2160000,
  "sessions": ["20240201_100000", "20240201_120000", "20240201_140000"]
}
```

**Fields:**
- `count`: Number of transferred sessions
- `bytes`: Total bytes that would be freed
- `sessions`: List of session IDs with .transferred marker

---

##### AT+PURGE - Delete Transferred Sessions

Delete all sessions that have been transferred (have .transferred marker).

**Request:**
```
AT+PURGE
```

**Response:**
```json
{
  "ok": true,
  "deleted": ["20240201_100000", "20240201_120000"],
  "freed": 1440000
}
```

**Side Effects:**
- Deletes all session directories with .transferred marker
- Updates session count

---

##### AT+AUTODEL - Auto-Delete Policy

Configure automatic deletion policy for transferred sessions.

**Request (Set):**
```
AT+AUTODEL=7
```

**Request (Get):**
```
AT+AUTODEL?
```

**Response:**
```json
{
  "ok": true,
  "value": "7"
}
```

**Policy Values:**
| Value | Description |
|-------|-------------|
| `off` | Manual delete only (default) |
| `0` | Delete immediately after transfer |
| `1-30` | Delete N days after transfer |

**Error Cases:**
- `6002`: Invalid policy value

---

#### 3.3.7 Configuration

##### AT+BITRATE - Set Bitrate

Configure Opus encoding bitrate.

**Request (Set):**
```
AT+BITRATE=24000
```

**Request (Get):**
```
AT+BITRATE?
```

**Response:**
```json
{
  "ok": true,
  "value": 24000
}
```

**Valid Values:**
- Mono: 12000, 16000, 24000, 32000
- Stereo: 24000, 32000, 48000, 64000

**Error Cases:**
- `6003`: Invalid bitrate for current channel mode

---

##### AT+COMPLEXITY - Encoding Complexity

Configure Opus encoder complexity.

**Request (Set):**
```
AT+COMPLEXITY=5
```

**Request (Get):**
```
AT+COMPLEXITY?
```

**Response:**
```json
{
  "ok": true,
  "value": 5
}
```

**Valid Range:** 0 - 10
**Default:** 5

**Description:**
- 0: Fastest encoding, lowest quality
- 5: Balanced (default)
- 10: Slowest encoding, highest quality

---

##### AT+MODE - Recording Mode

Set recording mode preset.

**Request (Set):**
```
AT+MODE=enhanced
```

**Request (Get):**
```
AT+MODE?
```

**Response:**
```json
{
  "ok": true,
  "value": "enhanced"
}
```

**Valid Values:** "normal", "enhanced"

**Mode Presets:**
- **Normal**: Standard quality, 10-minute file segments
- **Enhanced**: High quality, 2-minute file segments

---

##### AT+NOISE - Noise Suppression

Configure SpeexDSP noise suppression.

**Request (Set):**
```
AT+NOISE=40
```

**Request (Get):**
```
AT+NOISE?
```

**Response:**
```json
{
  "ok": true,
  "value": 40
}
```

**Valid Range:** 0 - 60 dB
**Default:** 0 (off)

---

##### AT+DEREVERB - Dereverberation

Configure SpeexDSP dereverberation.

**Request (Set):**
```
AT+DEREVERB=on,40,20
```

**Request (Get):**
```
AT+DEREVERB?
```

**Response:**
```json
{
  "ok": true,
  "value": "on,40,20"
}
```

**Parameters:** `<on|off>,<level>,<decay>`
- `on|off`: Enable/disable
- `level`: 0-100 (strength)
- `decay`: 0-100 (decay factor)

---

##### AT+AGC - Automatic Gain Control

Configure SpeexDSP AGC.

**Request (Set):**
```
AT+AGC=on,8000,30
```

**Request (Get):**
```
AT+AGC?
```

**Response:**
```json
{
  "ok": true,
  "value": "on,8000,30"
}
```

**Parameters:** `<on|off>,<target>,<max_gain>`
- `on|off`: Enable/disable
- `target`: 0-32768 (target level)
- `max_gain`: 0-60 dB (maximum gain)

---

##### AT+BRIGHTNESS - OLED Brightness

Get or set the OLED display brightness (contrast). The value is saved to NVS and applied automatically on every boot.

**Request (Set):**
```
AT+BRIGHTNESS=<value>
```

**Request (Query):**
```
AT+BRIGHTNESS?
```

**Response (Set):**
```json
{
  "ok": true,
  "data": {"value": 200}
}
```

**Response (Query):**
```json
{
  "ok": true,
  "data": {"value": 128}
}
```

**Parameters:**
- `value`: Integer 0–255 (0 = dimmest, 255 = maximum brightness, default = 128)

---

##### AT+PAIR - Bluetooth Pairing

Manage BLE pairing.

**Request (Query):**
```
AT+PAIR?
```

**Request (Reset):**
```
AT+PAIR=reset
```

**Response (Query):**
```json
{
  "ok": true,
  "value": "paired",
  "addr": "AA:BB:CC:DD:EE:FF"
}
```

**Response (Reset):**
```json
{
  "ok": true,
  "rebooting": true
}
```

**Values:**
- "paired": Bonded to device
- "unpaired": Not bonded

**Side Effects of Reset:**
- Clears bond information
- Reboots device
- Requires re-pairing

---

##### AT+FACTORY - Factory Reset

Restore all settings to factory defaults.

**Request:**
```
AT+FACTORY=confirm
```

**Response:**
```json
{
  "ok": true,
  "rebooting": true
}
```

**Side Effects:**
- Clears all NVS configuration
- Clears BLE pairing
- Deletes ALL recordings from SD card
- Reboots device

**Warning:** Requires "confirm" parameter to prevent accidental execution.

---

##### AT+RESET - Reboot Device

Restart the device.

**Request:**
```
AT+RESET
```

**Response:**
```json
{
  "ok": true,
  "rebooting": true
}
```

**Side Effects:**
- Terminates current recording (if any)
- Stops file transfer (if any)
- Reboots device

---

## 4. File Transfer Protocol

### 4.1 Transfer States

```
┌─────────────────────────────────────────────────┐
│                    File Transfer State Machine          │
├─────────────────────────────────────────────────────────┤
│                                                         │
│   ┌─────────┐    AT+DOWNLOAD    ┌──────────────┐       │
│   │   IDLE  │ ─────────────────>│ TRANSMITTING │──────>│ IDLE │
│   └─────────┘                    └──────┬───────┘       └───────┘
│        ▲                                │               │           ▲
│        │                          AT+CANCEL│              │           │
│        │                          disconnect│              │           │
│        ▼                                ▼               │           │
│   TRANSMITTING <───────────────────────────────────────────────┘
│        │                                                         │
│        │                                                         │
│        ▼                                                         │
│      IDLE <──────────────────────────────────────────────────────────
│                                                                  │
└───────────────────────────────────────────────────────────────────┘
```

**States:**
- **IDLE**: No transfer in progress
- **TRANSMITTING**: Actively sending file data
- **COMPLETED**: Transfer finished (transient state, returns to IDLE)

### 4.2 Flow Control (Non-blocking Commands)

Critical design feature: Commands can be processed during file transfer!

**How it works:**
1. File transfer runs in background
2. AT commands interrupt transfer
3. Transfer pauses during command processing
4. Transfer resumes after command response

**Supported Commands During Transfer:**
- `AT+GSTAT` - Query status (returns "TRANSMITTING" state)
- `AT+PROGRESS` - Get transfer progress
- `AT+CANCEL` - Cancel transfer

**Sequence:**
```
App: AT+DOWNLOAD=session/file.opus
Device: {"ok":true}
Device: <data chunk 1>
Device: <data chunk 2>
App: AT+GSTAT  (Non-blocking!)
Device: {"ok":true, "state":"TRANSMITTING"}
Device: <data chunk 3>
Device: <data chunk 4>
...
Device: {"ok":true, "done":true, "size":720000}
```

### 4.3 Data Format

**Raw Opus Frames:**

Each file consists of concatenated Opus frames:
```
[2 bytes length][Opus frame data][2 bytes length][Opus frame data]...
```

- **Length field**: 2 bytes, little-endian uint16
- **Frame data**: Raw Opus encoded audio

**Transfer Chunk:**

Each BLE notification contains a chunk of the file:
```
Opus data chunk (N bytes, where N = chunk_size or less)
```

Last chunk will be smaller than `chunk_size` (unless file size is exact multiple).

**Example:**
```
File: 720000 bytes
Chunk size: 500 bytes
Notifications: 1440 (1439 full + 1 partial)

Notification 1-1439: 500 bytes each
Notification 1440: 500 bytes (exact)
```

### 4.4 Progress Reporting

Progress notifications are sent periodically:

**Triggers:**
- Every 10% of file transferred
- On completion

**Progress Notification:**
```json
{
  "ok": true,
  "progress": 50,
  "transferred": 360000,
  "total": 720000
}
```

**Completion Notification:**
```json
{
  "ok": true,
  "done": true,
  "size": 720000
}
```

### 4.5 Error Recovery

**Connection Dropout:**
1. Detect disconnection
2. Pause transfer (state → PAUSED)
3. Wait for reconnection
4. Auto-resume if within timeout
5. Cancel if timeout expires

**File Write Errors:**
1. Detect write failure
2. Send error response
3. Close file
4. Delete incomplete file (if created)
5. Return to IDLE

**SD Card Removal:**
1. Detect removal
2. Send error response: "SD card removed"
3. Close all files
4. Return to ERROR state

### 4.6 Transfer Examples

#### Single File Transfer

```
App                          Device
 │                              │
 │─ AT+DOWNLOAD=2024/0001.opus ─>│
 │                              │  Open file
 │                              │  Get size
 │<─ {"ok":true} ────────────────│
 │<════ [500 bytes] ════════════│
 │<════ [500 bytes] ════════════│
 │<════ [500 bytes] ════════════│
 │<─ {"progress":10} ────────────│
 │<════ [500 bytes] ════════════│
 ...                            │
 │<════ [120 bytes] ════════════│  Last chunk (<500)
 │<─ {"ok":true,"done":true,     │
 │     "size":720000} ───────────│
 │                              │  Create .transferred
```

#### Session Transfer (Multiple Files)

```
App                          Device
 │                              │
 │─ AT+LIST ───────────────────>│
 │<─ ["20240203100000"] ────────│
 │                              │
 │─ AT+LIST=20240203100000 ───>│
 │<─ ["0001.opus","0002.opus"] ────│
 │                              │
 │─ AT+MARKS=20240203100000 ──>│
 │<─ [{offset:10,note:"..."}] ───│
 │                              │
 │─ AT+DOWNLOAD=20240203/0001.opus>│
 │<─ {"ok":true} ────────────────│
 │<════ [Opus data...] ═════════│
 ...                            │
 │<─ {"ok":true,"done":true} ────│
 │                              │
 │─ AT+DOWNLOAD=20240203/0002.opus>│
 │<─ {"ok":true} ────────────────│
 │<════ [Opus data...] ═════════│
 ...                            │
 │<─ {"ok":true,"done":true} ────│
 │                              │
 │─ AT+DELETE=20240203100000 ──>│
 │<─ {"ok":true,"freed":1440000} │
```

## 5. State Machines

### 5.1 Device State Machine

```
┌─────────────────────────────────────────────────────────────┐
│                      Global Device State                     │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  ┌──────────────┐                                          │
│  │ UNINITIALIZED│                                          │
│  └───────┬──────┘                                          │
│          │ boot complete                                    │
│          ▼                                                  │
│  ┌──────────────┐  AT+START/Long press  ┌──────────┐       │
│  │     IDLE     │<────────────────────────│RECORDING │       │
│  └───────┬──────┘                        └─────┬────┘       │
│          │                                      │            │
│          │ AT+DOWNLOAD                          │ AT+STOP/   │
│          │                                      │ Long press │
│          ▼                                      │            │
│  ┌──────────────┐                        ┌─────┴────┐       │
│  │ TRANSMITTING │<───────────────────────│   IDLE   │       │
│  └──────┬───────┘    AT+PAUSE            └──────────┘       │
│          │                                  ▲                │
│          │ AT+PAUSE                         │                │
│          ▼                                  │                │
│  ┌──────────────┐    AT+RESUME             │                │
│  │    PAUSED    │──────────────────────────┘                │
│  └──────┬───────┘                                       │
│         │                                               │
│         │ AT+CANCEL / Error                             │
│         ▼                                               │
│  ┌──────────────┐                                       │
│  │    ERROR     │──────────────────────────────────────┘
│  └──────────────┘         Recovery / AT+RESET          │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

**States:**
- **UNINITIALIZED**: Booting, hardware initialization
- **IDLE**: Ready to record or transfer
- **RECORDING**: Actively recording audio
- **TRANSMITTING**: Actively transferring file
- **PAUSED**: Transfer paused
- **ERROR**: Error state, requires intervention

### 5.2 Recording State Machine

```
┌─────────────────────────────────────────────────────────┐
│                    Recording State                       │
├─────────────────────────────────────────────────────────┤
│                                                         │
│   ┌──────────┐   Long press (1s) / AT+START   ┌────────┐│
│   │   IDLE   │ ─────────────────────────────> │RECORDING│
│   └──────────┘                                  └────┬───┘
│        ▲                                             │   │
│        │                Long press (1s) / AT+STOP    │   │
│        │ <───────────────────────────────────────────┘   │
│        │                                                     │
│   Short press (add bookmark - only during recording)        │
│                                                         │
└─────────────────────────────────────────────────────────┘
```

**Transitions:**
- IDLE → RECORDING: Long button press OR `AT+START`
- RECORDING → IDLE: Long button press OR `AT+STOP`

**Recording-Specific Actions:**
- Short press during RECORDING: Add bookmark

### 5.3 Transfer State Machine

```
┌─────────────────────────────────────────────────────────┐
│                    Transfer State                        │
├─────────────────────────────────────────────────────────┤
│                                                         │
│   ┌──────────┐      AT+DOWNLOAD       ┌──────────────┐ │
│   │   IDLE   │ ──────────────────────>│ TRANSMITTING │ │
│   └──────────┘                        └──────┬───────┘ │
│        ▀                                      │        │
│         │            AT+PAUSE /               │        │
│         │            Disconnect               │        │
│         └─────────────────────────────────────┘        │
│                  │                                    │
│                  ▼                                    │
│           ┌──────────┐                               │
│           │  PAUSED  │                               │
│           └────┬─────┘                               │
│                │                                     │
│    ┌───────────┴─────────────┐                       │
│    │                         │                       │
│    ▼                         ▼                       │
│ AT+RESUME              AT+CANCEL                    │
│    │                         │                       │
│    └─────────────────────────┼───────────────────────┘
│                              ▼
│                         ┌──────────┐
│                         │   IDLE   │
│                         └──────────┘
│                                                         │
└─────────────────────────────────────────────────────────┘
```

**Transitions:**
- IDLE → TRANSMITTING: `AT+DOWNLOAD`
- TRANSMITTING → PAUSED: `AT+PAUSE` OR disconnect
- PAUSED → TRANSMITTING: `AT+RESUME`
- TRANSMITTING/PAUSED → IDLE: `AT+CANCEL` OR completion OR timeout

### 5.4 Connection State Machine

```
┌─────────────────────────────────────────────────────────┐
│                   BLE Connection State                  │
├─────────────────────────────────────────────────────────┤
│                                                         │
│   ┌─────────────┐                                      │
│   │ DISCONNECTED│<─────────────────────────┐           │
│   └──────┬──────┘                          │           │
│          │                                 │           │
│          │ Connect / Auto-advertise        │           │
│          ▼                                 │           │
│   ┌─────────────┐                          │           │
│   │  CONNECTING │                          │           │
│   └──────┬──────┘                          │           │
│          │                                 │           │
│          │ Connected                       │           │
│          ▼                                 │           │
│   ┌─────────────┐   Pairing required? ┌───┴──────┐    │
│   │  CONNECTED  │ ──────────────────>│  PAIRING  │    │
│   └──────┬──────┘                    └─────┬─────┘    │
│          │                                 │          │
│          │ Paired                          │          │
│          ▼                                 │          │
│   ┌─────────────┐                          │          │
│   │   BONDED    │<─────────────────────────┘          │
│   └──────┬──────┘                                     │
│          │                                             │
│          │ Disconnect / AT+PAIR=reset                  │
│          └─────────────────────────────────────────────┘
│                                                         │
└─────────────────────────────────────────────────────────┘
```

**States:**
- **DISCONNECTED**: Not connected, advertising
- **CONNECTING**: Connection in progress
- **CONNECTED**: Connected but not paired
- **PAIRING**: Pairing process active
- **BONDED**: Connected and bonded (secure)

## 6. Data Formats

### 6.1 Session Metadata (session.json)

Stored in each session directory, contains session information, sync progress, and audio format.

**Created**: When recording starts (session is created)
**Updated**: When recording stops (duration, files updated) and when transfer ends (synced count)

```json
{
  "id": "20240203100000",
  "duration": 600,
  "files": 30,
  "synced": 15,
  "channels": 2,
  "sample_rate": 16000,
  "mode": "normal"
}
```

**Fields:**
- `id`: Session ID (timestamp format: YYYYMMDDHHMMSS, 14 digits)
- `duration`: Recording length in seconds (0 while recording)
- `files`: Total number of audio files in session (0 while recording)
- `synced`: Number of files that have been successfully transferred
- `channels`: Audio channels (1=mono, 2=stereo)
- `sample_rate`: Sample rate in Hz (e.g., 16000)
- `mode`: Recording mode ("normal" or "enhanced")

**Purpose:**
- Track transfer progress for resume functionality
- Store audio format for proper decoding/playback
- Enable cleanup of already-transferred files
- Support disconnect/reconnect scenarios

**Example Usage:**
```
# Session has 30 files, 15 have been transferred
# Audio is normal mode (stereo, 2 channels) at 16kHz
# Next transfer should start from file 0016.opus
AT+DOWNLOAD=20240203100000:0016.opus
```

### 6.2 File List (files.lst)

Plain text file with one filename per line (append-only).

```
0001.opus
0002.opus
0003.opus
```

Used for efficient session file listing.

### 6.3 Bookmark Data (marks.bin)

Binary format for efficient bookmark storage.

**Header (6 bytes):**
```
[4 bytes magic: "BMRK"]
[2 bytes count: uint16_t]
```

**Entry (78 bytes):**
```
[4 bytes timestamp: uint32]
[4 bytes offset: uint32 - seconds from session start]
[2 bytes file_index: uint16]
[4 bytes file_offset: uint32]
[64 bytes note: null-terminated UTF-8 string]
```

**Total entry size:** 78 bytes (fixed)

**Example C struct:**
```c
struct __attribute__((packed)) mark_entry {
    uint32_t timestamp;
    uint32_t offset_sec;
    uint16_t file_index;
    uint32_t file_offset;
    char note[64];
};
```

**Usage:**
- Stored on device: `/SD:/REC/{session_id}/marks.bin`
- Created when session starts
- Updated when bookmarks are added (in-memory, flushed on save)

### 6.4 Bookmarks JSON (bookmarks.json)

JSON format exported after sync for frontend visualization.

**File location:** `recordings/{session_id}/bookmarks.json`

**Format:**
```json
[
  {"offset": 30, "note": "Important point"},
  {"offset": 60},
  {"offset": 90, "note": "End"}
]
```

**Fields per bookmark:**
- `offset`: Seconds from session start (for positioning in merged audio)
- `note`: Optional note text (omitted if empty)

**Usage:**
- Generated by sync tools (sync.py, record.py)
- Used by frontend to display markers on audio timeline
- Position calculation: `byte_offset = offset * sample_rate * channels * bytes_per_sample`

### 6.5 Opus Frame Format

Each Opus file is a sequence of frames:

```
[2 bytes length][Opus frame data][2 bytes length][Opus frame data]...
```

- **Length**: uint16, little-endian
- **Frame data**: Raw Opus encoded bytes
- **Frame size**: Typically 20ms @ 16kHz = 320 samples

### 6.5 Transfer Marker (.transferred)

Empty file created upon successful transfer completion.

```
touch /SD:/REC/20240203100000/.transferred
```

**Purpose:**
- Marks session as successfully transferred
- Used by AT+PURGEABLE to identify deletable sessions
- Used by auto-delete policy

## 7. Notifications and Events

### 7.1 Unsolicited Notifications

The device sends unsolicited notifications via the Response characteristic for important events.

#### 7.1.1 Recording Started

```json
{
  "ok": true,
  "event": "recording_started",
  "session": "20240203100000"
}
```

**Trigger:** Recording starts (AT+START or button long press)

#### 7.1.2 Recording Stopped

```json
{
  "ok": true,
  "event": "recording_stopped",
  "session": "20240203100000",
  "duration": 600
}
```

**Trigger:** Recording stops (AT+STOP or button long press)

#### 7.1.3 Bookmark Added

```json
{
  "ok": true,
  "event": "bookmark_added",
  "timestamp": 1706918430,
  "offset": 123,
  "file": "0002.opus",
  "note": "Important point"
}
```

**Trigger:** Bookmark added (AT+MARK or button short press)

#### 7.1.4 Battery Low Warning

```json
{
  "ok": true,
  "event": "battery_low",
  "level": 10
}
```

**Trigger:** Battery falls below 10%

#### 7.1.5 Storage Low Warning

```json
{
  "ok": true,
  "event": "storage_low",
  "free_mb": 100
}
```

**Trigger:** Free space < 100MB

#### 7.1.6 Error Notification

```json
{
  "ok": false,
  "event": "error",
  "code": 3003,
  "error": "SD card write error"
}
```

**Trigger:** Any error condition

### 7.2 Progress Events

During file transfer, progress updates are sent every 10%:

```json
{
  "ok": true,
  "progress": 50,
  "transferred": 360000,
  "total": 720000
}
```

**Triggers:** Every 10% of file transferred

### 7.3 System Events

#### Connection Event

```json
{
  "ok": true,
  "event": "connected",
  "addr": "AA:BB:CC:DD:EE:FF"
}
```

#### Disconnection Event

```json
{
  "ok": true,
  "event": "disconnected",
  "reason": "timeout"
}
```

## 8. Error Codes

### 8.1 Error Response Format

All errors use consistent format:

```json
{
  "ok": false,
  "error": "Human-readable error message"
}
```

Some errors include additional fields:

```json
{
  "ok": false,
  "error": "Error message",
  "code": 1001,
  "detail": "Additional context"
}
```

### 8.2 Error Categories

| Category | Range | Description |
|----------|-------|-------------|
| Protocol Errors | 1000-1999 | Command syntax, parsing, validation |
| System Errors | 2000-2999 | Device initialization, hardware |
| Storage Errors | 3000-3999 | SD card, file system |
| Recording Errors | 4000-4999 | Audio capture, encoding |
| Transfer Errors | 5000-5999 | BLE transfer, file download |
| Configuration Errors | 6000-6999 | Settings, parameters |

### 8.3 Complete Error Code List

#### Protocol Errors (1000-1999)

| Code | Message | Description |
|------|---------|-------------|
| 1000 | "Invalid command" | Unknown AT command |
| 1001 | "Invalid parameter format" | Parameter syntax error |
| 1002 | "Missing required parameter" | Command requires parameter |
| 1003 | "Command too long" | Exceeds buffer size |
| 1004 | "JSON parse error" | Invalid JSON in parameter |
| 1005 | "Invalid command type" | GET/SET/EXEC mismatch |

#### System Errors (2000-2999)

| Code | Message | Description |
|------|---------|-------------|
| 2000 | "Initialization failed" | Hardware init error |
| 2001 | "Out of memory" | Memory allocation failed |
| 2002 | "Not implemented" | Feature not available |
| 2003 | "Busy" | Device busy with another operation |
| 2004 | "Timeout" | Operation timed out |
| 2005 | "Internal error" | Unexpected internal error |

#### Storage Errors (3000-3999)

| Code | Message | Description |
|------|---------|-------------|
| 3000 | "SD card not present" | No SD card detected |
| 3001 | "Session not found" | Session directory doesn't exist |
| 3002 | "File not found" | Requested file doesn't exist |
| 3003 | "File system error" | FAT filesystem error |
| 3004 | "SD card full" | No space remaining |
| 3005 | "Write error" | Failed to write file |
| 3006 | "Read error" | Failed to read file |
| 3007 | "Directory creation failed" | Cannot create directory |
| 3008 | "File corrupted" | File data invalid |

#### Recording Errors (4000-4999)

| Code | Message | Description |
|------|---------|-------------|
| 4000 | "Recording failed" | Generic recording error |
| 4001 | "Already recording" | Cannot start (already recording) |
| 4002 | "Not recording" | Cannot stop/mark (not recording) |
| 4003 | "Microphone error" | PDM microphone failure |
| 4004 | "Encoder error" | Opus encoding failed |
| 4005 | "Buffer overflow" | Audio buffer overflow |
| 4006 | "Buffer underrun" | Audio buffer underrun |
| 4007 | "Recording stopped" | Recording stopped unexpectedly |

#### Transfer Errors (5000-5999)

| Code | Message | Description |
|------|---------|-------------|
| 5000 | "Transfer failed" | Generic transfer error |
| 5001 | "File not found" | Requested file doesn't exist |
| 5002 | "Transfer in progress" | Another transfer active |
| 5003 | "Transfer canceled" | Transfer was canceled |
| 5004 | "No transfer in progress" | Cannot pause/resume (not transferring) |
| 5005 | "Nothing to resume" | Cannot resume (not paused) |
| 5006 | "Connection lost" | BLE disconnected during transfer |
| 5007 | "Transfer timeout" | Transfer took too long |
| 5008 | "Invalid chunk size" | Chunk size out of range |

#### Configuration Errors (6000-6999)

| Code | Message | Description |
|------|---------|-------------|
| 6000 | "Invalid configuration" | Generic config error |
| 6001 | "Invalid value" | Parameter out of range |
| 6002 | "Invalid policy" | Auto-delete policy invalid |
| 6003 | "Invalid bitrate" | Bitrate not supported |
| 6004 | "Invalid mode" | Recording mode invalid |
| 6005 | "Configuration locked" | Cannot change during operation |
| 6006 | "Read-only" | Cannot modify read-only setting |

### 8.4 Error Recovery Guidelines

**Recoverable Errors (can retry):**
- Connection timeout (2004): Retry command
- Transfer timeout (5007): Retry transfer
- Buffer overflow (4005): Skip frame, continue

**Non-Recoverable Errors (user intervention):**
- SD card not present (3000): Insert SD card
- SD card full (3004): Delete files
- Battery low (4006): Charge device

**Fatal Errors (require reset):**
- Internal error (2005): AT+RESET
- File system error (3003): Reformat SD card
- Encoder error (4004): Reboot device

## 9. Timing and Constraints

### 9.1 Command Timeouts

| Operation | Timeout |
|-----------|---------|
| Command processing | 5 seconds |
| File open | 2 seconds |
| Recording start | 3 seconds |
| Factory reset | 10 seconds |
| Reboot | 5 seconds |

### 9.2 Transfer Timeouts

| Operation | Timeout |
|-----------|---------|
| Transfer start | 10 seconds |
| Between chunks | 30 seconds |
| Pause resume | 5 minutes |
| Total transfer | 1 hour |

### 9.3 Rate Limiting

To prevent BLE congestion:
- **Max commands per second**: 10
- **Min interval between notifications**: 20ms

### 9.4 Buffer Sizes

| Buffer | Size |
|--------|------|
| Command buffer | 512 bytes |
| Response buffer | 512 bytes |
| File chunk buffer | 4096 bytes (configurable) |
| Audio buffer | 32KB |
| SD card buffer | 4KB |

## 10. Security Considerations

### 10.1 Authentication

**LE Secure Connections (mandatory)**
- Uses Elliptic Curve Diffie-Hellman (ECDH)
- Provides MITM protection
- Numeric comparison or Passkey entry

### 10.2 Encryption

**AES-128 CCM (mandatory)**
- All BLE traffic encrypted
- Keys derived from pairing process
- Bonded devices store keys for reconnection

### 10.3 Authorization

**Single Bond Policy**
- Device stores bond for one central device
- New pairing clears previous bond
- AT+PAIR=reset clears bond manually

## 11. Command Sequences

### 11.1 Typical Recording Workflow

```
1. Connect: App discovers device, connects, pairs
2. Check status: AT+GSTAT
3. Set mode: AT+MODE=enhanced
4. Start recording: AT+START
5. [Optional] Add bookmarks: AT+MARK=Important point
6. Stop recording: AT+STOP
7. [Later] Sync session (see 11.2)
```

### 11.2 Complete Sync Workflow

```
1. List sessions: AT+LIST
2. For each session:
   a. List files: AT+LIST=<session>
   b. Get bookmarks: AT+MARKS=<session>
   c. Download each file: AT+DOWNLOAD=<session>/<file>
   d. Wait for completion: {"done":true}
3. Delete session: AT+DELETE=<session>
```

### 11.3 Error Recovery Sequences

**Transfer Failure Recovery:**
```
1. Detect error (disconnect or timeout)
2. Wait for reconnection (auto-reconnect)
3. Query progress: AT+PROGRESS
4. Resume: AT+RESUME
5. If resume fails: AT+DOWNLOAD=<file> (restart)
```

**SD Card Error Recovery:**
```
1. Detect error: {"error":"SD card error"}
2. Stop current operation
3. Reinsert SD card
4. Wait for detection
5. Retry operation
```

## 12. Protocol Versioning

### 12.1 Version Scheme

**Protocol Version:** `major.minor.patch`
- `major`: Breaking changes (requires app update)
- `minor`: New commands (backward compatible)
- `patch`: Bug fixes (no API changes)

**Current Version:** `1.0.0`

### 12.2 Backward Compatibility

**Rules:**
- New commands are additive (old apps ignore unknown events)
- Never remove existing commands
- Never change command syntax in breaking ways
- Optional fields can be added to responses

**Deprecation Process:**
1. Mark command as deprecated in documentation
2. Maintain for 2 major versions
3. Remove in major version increment

## Appendix A: Complete Command Reference

### Quick Reference Table

| Command | Type | Purpose | Section |
|---------|------|---------|---------|
| AT+GSTAT | EXEC | Get device status | 3.3.1 |
| AT+TIME | GET/SET | System time | 3.3.1 |
| AT+VERSION | EXEC | Version info | 3.3.1 |
| AT+START | EXEC | Start recording | 3.3.2 |
| AT+STOP | EXEC | Stop recording | 3.3.2 |
| AT+MARK | EXEC | Add bookmark | 3.3.2 |
| AT+LIST | GET | List sessions/files | 3.3.3 |
| AT+DELETE | SET | Delete session | 3.3.3 |
| AT+MARKS | GET | Get bookmarks | 3.3.3 |
| AT+DOWNLOAD | SET | Download file | 3.3.4 |
| AT+CHUNKSIZE | GET/SET | Transfer chunk size | 3.3.4 |
| AT+PROGRESS | EXEC | Transfer progress | 3.3.4 |
| AT+PAUSE | EXEC | Pause transfer | 3.3.5 |
| AT+RESUME | EXEC | Resume transfer | 3.3.5 |
| AT+CANCEL | EXEC | Cancel transfer | 3.3.5 |
| AT+PURGEABLE | EXEC | Query cleanable space | 3.3.6 |
| AT+PURGE | EXEC | Delete transferred | 3.3.6 |
| AT+AUTODEL | GET/SET | Auto-delete policy | 3.3.6 |
| AT+BITRATE | GET/SET | Opus bitrate | 3.3.7 |
| AT+COMPLEXITY | GET/SET | Encoding complexity | 3.3.7 |
| AT+MODE | GET/SET | Recording mode | 3.3.7 |
| AT+NOISE | GET/SET | Noise suppression | 3.3.7 |
| AT+DEREVERB | GET/SET | Dereverberation | 3.3.7 |
| AT+AGC | GET/SET | Automatic gain | 3.3.7 |
| AT+BRIGHTNESS | GET/SET | OLED brightness | 3.3.7 |
| AT+PAIR | GET/SET | BLE pairing | 3.3.8 |
| AT+FACTORY | SET | Factory reset | 3.3.8 |
| AT+RESET | EXEC | Reboot | 3.3.8 |

## Appendix B: Example Sessions

### Session 1: First Time Setup

```
App: AT+GSTAT
Device: {"ok":true,"data":{"state":"IDLE","battery":100,"charging":false,...}}

App: AT+TIME=1706918430
Device: {"ok":true}

App: AT+MODE=enhanced
Device: {"ok":true}

App: AT+BITRATE=48000
Device: {"ok":true}
```

### Session 2: Recording and Transfer

```
App: AT+START
Device: {"ok":true,"data":{"session":"20240203100000",...}}
Device: {"ok":true,"event":"recording_started","session":"20240203100000"}

[Recording in progress...]

App: AT+MARK=Important point
Device: {"ok":true,"data":{"timestamp":1706918430,...}}
Device: {"ok":true,"event":"bookmark_added",...}

App: AT+STOP
Device: {"ok":true,"data":{"duration":600,...}}
Device: {"ok":true,"event":"recording_stopped",...}

App: AT+LIST
Device: {"ok":true,"data":["20240203100000"]}

App: AT+DOWNLOAD=20240203100000
Device: {"ok":true}
Device: <file data stream...>
Device: {"ok":true,"done":true,"size":3600000}
```

## Appendix C: Performance Characteristics

### Expected Transfer Rates

| MTU | Chunk Size | Throughput | 1MB Time |
|-----|------------|------------|----------|
| 23 | 500 | ~8 KB/s | ~2m 5s |
| 247 | 500 | ~22 KB/s | ~46s |
| 517 | 500 | ~25 KB/s | ~40s |
| 517 | 4096 | ~28 KB/s | ~36s |

**Optimal Configuration:** MTU 517, Chunk size 2000-4096

### Memory Usage

| Component | Usage |
|-----------|-------|
| Audio buffer | 32 KB |
| Opus encoder | 20 KB |
| SpeexDSP | 10 KB |
| Transfer buffer | 4 KB (configurable) |
| BLE stack | ~50 KB |
| Total fixed | ~116 KB |

**Available heap:** ~32 KB from 192 KB non-secure SRAM
