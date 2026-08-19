# reSpeaker Clip - System Architecture

## 1. Architecture Overview

### 1.1 System Context

The reSpeaker Clip is an embedded audio recording device built on Zephyr RTOS, running on the Nordic nRF5340 dual-core microcontroller. It provides high-quality audio capture with BLE and WiFi synchronization to mobile devices.

**External Actors:**
- **End User**: Interacts via button and CH1115 OLED display
- **Mobile App**: Interacts via BLE GATT or WiFi UDP
- **SD Card**: Stores audio recordings (FAT32)
- **Charging Source**: Powers device via USB-C

**System Boundaries:**
- Hardware: nRF5340, NPM1300 PMIC, PDM microphones, SD card, nRF7002 WiFi
- Firmware: Zephyr RTOS v4.3 (NCS v3.3.0) + custom application
- Protocols: BLE AT command protocol, CLIP UDP transfer protocol

### 1.2 Architectural Drivers

**Primary Drivers:**
1. **Memory Constraints**: 192KB non-secure SRAM, 192KB flash for application
2. **Real-Time Audio**: Must process audio with < 20ms per-frame budget
3. **Power Efficiency**: CPU boost system (128MHz recording / 64MHz idle)
4. **Dual Transport**: BLE for always-available control, WiFi UDP for fast file transfer
5. **UI Simplicity**: Single button, 88x48 OLED display, haptic motor

**Quality Attributes:**
- Performance: Event-driven architecture, reference-counted CPU frequency scaling
- Reliability: File-level retransmit with per-file CRC32, DMIC timeout recovery
- Maintainability: Table-driven state machine, transport abstraction layer
- Power Efficiency: WiFi manual start/stop, microphone power gating, PMIC ship mode

### 1.3 Design Principles

1. **Event-Driven Main Loop**: All state transitions and side effects processed in the main thread via `k_msgq` event queue and `k_sem` notification
2. **Table-Driven State Machine**: State transitions defined in a static lookup table (`transition_table[][]`) with transition actions in a single `switch` statement
3. **Transport Abstraction**: BLE and UDP backends implement a common `transport_ops` interface
4. **CPU Boost (Reference Counted)**: 128MHz during recording, 64MHz idle; `clip_cpu_boost_acquire()` / `clip_cpu_boost_release()` via `atomic_t` counter
5. **Kconfig Per-Mode Parameters**: Bitrate and complexity are compile-time per-mode constants, not runtime configurable
6. **Graceful Degradation**: Optional subsystems (storage, WiFi, display, button) fail softly; init continues

## 2. High-Level Architecture

### 2.1 Layered Architecture

```
+---------------------------------------------------------+
|                   Application Layer                      |
|  +-------------+  +-------------+  +-----------------+  |
|  | Event       |  | AT Server   |  | Button          |  |
|  | Dispatcher  |  | (30 cmds)   |  | Handler         |  |
|  +-------------+  +-------------+  +-----------------+  |
+---------------------------------------------------------+
|                    Service Layer                         |
|  +-------------+  +-------------+  +-----------------+  |
|  | Transport   |  | Transfer    |  | Config          |  |
|  | (BLE/UDP/   |  | Manager     |  | (Settings/NVS)  |  |
|  |  USB)       |  |             |  |                 |  |
|  +-------------+  +-------------+  +-----------------+  |
+---------------------------------------------------------+
|                  Processing Layer                        |
|  +-------------+  +-------------+  +-----------------+  |
|  | Audio       |  | SpeexDSP    |  | Opus            |  |
|  | Capture     |  | (NS + DR)   |  | Encoder         |  |
|  +-------------+  +-------------+  +-----------------+  |
+---------------------------------------------------------+
|             Hardware Abstraction Layer                   |
|  +-------+  +-------+  +-------+  +------+  +--------+ |
|  | PDM   |  | SD    |  | BLE   |  | WiFi |  | PMIC   | |
|  | DMIC  |  | FAT32 |  | Stack |  | nRF  |  | NPM1300| |
|  +-------+  +-------+  +-------+  +------+  +--------+ |
+---------------------------------------------------------+
|                 Zephyr RTOS Kernel                       |
|  k_msgq | k_sem | k_mutex | k_thread | k_mem_slab      |
+---------------------------------------------------------+
```

### 2.2 Component Diagram

```
+----------------------------------------------------------+
|                      Mobile App                          |
+------------------------+---------------------------------+
                         | BLE (GATT) / WiFi (UDP)
+------------------------v---------------------------------+
|               reSpeaker Clip Device                      |
|                                                         |
|  +---------------------------------------------------+ |
|  |               User Interface                      | |
|  |  +----------+  +----------+  +------------------+  | |
|  |  | Button   |  | Display  |  | Haptic Motor     |  | |
|  |  | (input   |  | (CH1115  |  | (PMIC GPIO,      |  | |
|  |  |  driver) |  |  OLED)   |  |  optional)       |  | |
|  |  +----+-----+  +----+-----+  +------------------+  | |
|  +-------|-------------|-------------------------------+ |
|          |             |                                 |
|  +-------v-------------v-------------------------------+ |
|  |              Event Dispatcher                      | |
|  |  Table-driven state machine in main thread         | |
|  |  States: UNINITIALIZED, IDLE, RECORDING,           | |
|  |          TRANSMITTING, WIFI_SYNC, PAUSED, ERROR     | |
|  +-------|-------------------------------------------+ |
|          |                                               |
|  +-------v-------+  +----------------+  +-------------+  |
|  | AT Server     |  | Transport      |  | Transfer    |  |
|  | (dedicated    |  | Abstraction    |  | Manager     |  |
|  |  thread)      |  | Layer          |  | (dedicated  |  |
|  | 30 commands   |  | BLE/UDP/USB    |  |  thread)    |  |
|  +---------------+  +----------------+  +-------------+  |
|                                                         |
|  +---------------------------------------------------+ |
|  |              Audio Pipeline                         | |
|  |  PDM DMIC -> SpeexDSP (merge+NS+DR) -> Opus       | |
|  |  (dedicated thread, 32KB stack)                   | |
|  +---------------------------------------------------+ |
|                                                         |
|  +---------------------------------------------------+ |
|  |  Config (Zephyr Settings on LittleFS)              | |
|  |  Storage (FAT32 on SD card)                        | |
|  |  WiFi AP (nRF7002, 5GHz ch36)                      | |
|  |  UDP Server (port 8089, dedicated thread)          | |
|  +---------------------------------------------------+ |
|                                                         |
|  +---------------------------------------------------+ |
|  |               Hardware HAL                          | |
|  +---------------------------------------------------+ |
+----------------------------------------------------------+
```

### 2.3 Technology Stack

| Layer | Technology | Version |
|-------|-----------|---------|
| RTOS | Zephyr | 4.3 (NCS v3.3.0) |
| MCU | Nordic nRF5340 | Dual-core (App + Net) |
| Audio Codec | Opus | Embedded build |
| Audio DSP | SpeexDSP | Custom (noise suppress + dereverb) |
| WiFi | nRF7002 | AP mode (5GHz) |
| Display | CH1115 | I2C, 88x48 |
| PMIC | NPM1300 | I2C, battery + regulators |
| Build System | CMake / West | LTO + -Oz |
| Language | C | C11 |

## 3. Module Decomposition

### 3.1 Main Application (main.c)

**Purpose**: Application initialization and event loop.

The main thread runs a blocking event loop using `k_msgq` for events and `k_sem` for wake-up notification. All state transitions and side effects (audio start/stop, haptic, display, WiFi on/off) are handled in this thread, which has a large enough stack for WiFi operations.

**Initialization Order** (`clip_init()`):
1. Config (Zephyr Settings on LittleFS)
2. BLE (`bt_enable` must complete before other threads start)
3. Transport layer + BLE transport + UDP transport
4. Audio subsystem (creates audio thread)
5. Storage (SD card FAT32)
6. Transfer subsystem (creates transfer thread)
7. WiFi module (does NOT start AP; only initializes SSID)
8. WiFi UDP server (creates UDP thread)
9. AT command registration + AT server thread
10. Button handler (custom input driver)
11. Display (CH1115 OLED)
12. Event dispatcher

**Main Loop** (`clip_main_loop()`):
```c
while (true) {
    /* K_FOREVER when idle (allows deep idle); 1s tick while recording
     * to advance the recording-time counter. */
    k_timeout_t wait = (clip_event_get_state() == CLIP_STATE_RECORDING)
                       ? K_MSEC(1000) : K_FOREVER;
    clip_event_wait(wait);             // Wait for events (or 1s while recording)
    clip_event_process();              // Process all pending events
    if (clip_event_get_state() == CLIP_STATE_RECORDING) {
        g_ctx.status.recording_time++;
    }
}
```

### 3.2 Event Dispatcher (clip_event.c)

**Purpose**: Central table-driven state machine. All state transitions and side effects are handled here. Button and AT command modules only post events.

**States:**
```c
enum clip_state {
    CLIP_STATE_UNINITIALIZED = 0,
    CLIP_STATE_IDLE,
    CLIP_STATE_RECORDING,
    CLIP_STATE_TRANSMITTING,
    CLIP_STATE_WIFI_SYNC,
    CLIP_STATE_PAUSED,
    CLIP_STATE_ERROR,
};
```

**Events:**
```c
enum clip_event {
    CLIP_EVENT_START = 0,        // Start recording
    CLIP_EVENT_STOP,             // Stop recording
    CLIP_EVENT_PAUSE,            // Pause recording
    CLIP_EVENT_RESUME,           // Resume recording
    CLIP_EVENT_MARK,             // Add bookmark
    CLIP_EVENT_WIFI_ON,          // Turn on WiFi AP
    CLIP_EVENT_WIFI_OFF,         // Turn off WiFi AP
    CLIP_EVENT_POWER_OFF_SHOW,   // Show power-off screen
    CLIP_EVENT_POWER_OFF_EXEC,   // Execute power-off (ship mode)
    CLIP_EVENT_STATUS_SHOW,      // Show status display
    CLIP_EVENT_USB_CONNECTED,    // USB cable plugged in
    CLIP_EVENT_OTA_START,        // OTA update started
    CLIP_EVENT_OTA_DONE,         // OTA update completed
};
```

**Transition Table** (excerpt):
```
                  START  STOP   PAUSE  RESUME MARK   WIFI_ON WIFI_OFF
UNINITIALIZED       --     --     --     --    --      --       --
IDLE              REC     --     --     --    --    WIFI       --
RECORDING           --   IDLE   PAUSED   --   SAME     --       --
TRANSMITTING        --     --     --     --    --      --       --
WIFI_SYNC           --     --     --     --    --      --     IDLE
PAUSED              --   IDLE    --    REC   SAME     --       --
```

**CPU Boost System:**
```c
// Reference-counted: 128MHz when count > 0, 64MHz when count == 0
void clip_cpu_boost_acquire(void);  // Called on recording start
void clip_cpu_boost_release(void);  // Called on recording stop
```

**Event Submission:**
```c
// Non-blocking (for button presses)
int clip_post_event(enum clip_event event);

// Blocking with result (for AT commands)
int clip_post_event_sync(enum clip_event event, struct clip_event_result_info *info);
```

### 3.3 AT Server (at_server.c, at_commands.c)

**Purpose**: Parse and dispatch AT commands from BLE and UDP transports.

**Architecture**: The AT server runs on a dedicated thread (priority 7, stack 8192 in prj.conf). Commands arrive via a `k_msgq` queue (up to 10 items). Each queue item carries the raw command bytes, length, and transport type for response routing.

**Command Types:**
```c
#define AT_CMD_TYPE_TEST   0  // AT+CMD=?  - Query
#define AT_CMD_TYPE_SET    1  // AT+CMD=... - Set
#define AT_CMD_TYPE_EXEC   2  // AT+CMD     - Execute
#define AT_CMD_TYPE_READ   3  // AT+CMD?    - Read
```

**Command Registration:**
```c
struct at_command {
    const char *name;           // e.g., "GSTAT"
    uint8_t flags;              // AT_CMD_SET | AT_CMD_QUERY | AT_CMD_EXEC
    at_cmd_handler_t handler;
};
```

**Registered Commands (30):**

| Command | Operations | Description |
|---------|-----------|-------------|
| GSTAT | EXEC | Get device status (state, battery, session, time) |
| BATT | QUERY, EXEC | Get battery status (%, charging, voltage mV, temp C) |
| STORAGE | QUERY, EXEC | SD card storage info (total/free/used MB, used %) |
| DEVICE | QUERY, EXEC | Get device name |
| VERSION | EXEC | Get firmware version |
| TIME | SET, QUERY, EXEC | Set/get time (Unix timestamp or YYYYMMDDHHMMSS) |
| MODE | SET, QUERY, EXEC | Set/get recording mode (normal/enhanced) |
| AUTODEL | SET, QUERY, EXEC | Set/get auto-delete days |
| BRIGHTNESS | SET, QUERY, EXEC | Set/get OLED brightness (0-255) |
| POWEROFF | EXEC | Enter PMIC ship mode |
| FACTORY | SET, EXEC | Factory reset (requires confirmation; formats SD + reboot) |
| PAIR | SET, QUERY | Query pairing status or `AT+PAIR=reset` to clear bonds + reboot |
| REBOOT | EXEC | Reboot device (optionally clear bonds) |
| DFU | EXEC | Reboot into MCUboot recovery mode |
| START | EXEC, SET | Start recording (optional mode parameter) |
| STOP | EXEC | Stop recording |
| PAUSE | EXEC | Pause recording |
| RESUME | EXEC | Resume recording |
| MARK | EXEC | Add bookmark at current position |
| LIST | SET, QUERY, EXEC | List sessions (paginated) / session details / file list |
| MARKS | SET, QUERY, EXEC | Get bookmarks for a session (paginated) |
| DOWNLOAD | SET, EXEC | Start file transfer (session or session:file) |
| CANCEL | EXEC | Cancel file transfer |
| DELETE | SET | Delete a session |
| FORMAT | EXEC | Format SD card |
| WIFI | SET, QUERY, EXEC | Start/stop WiFi AP, query status |
| WIFICFG | SET, QUERY | Set/get WiFi AP channel + regulatory domain at runtime |
| NAME | SET, QUERY | Set/get custom BLE device name |
| USB | SET, QUERY, EXEC | Enable/disable USB CDC+MSC, query status (default: off) |
| LOG | SET, QUERY, EXEC | SD log backend level: off \| info \| debug |

**Response Format**: JSON over the originating transport.
```json
{"ok":true,"msg":"...","data":{...}}
{"ok":false,"msg":"Error description"}
```

**Factory Reset Flow**: `config_factory_reset()` (reset NVS defaults) -> `storage_format_card()` (FAT32 format) -> delayed `sys_reboot(SYS_REBOOT_COLD)` (sends response first, then reboots via `k_work_delayable`).

### 3.4 Transport Abstraction Layer (transport.h, transport.c)

**Purpose**: Abstract BLE and UDP transports behind a common interface.

**Transport Types:**
```c
#define TRANSPORT_TYPE_BLE  0
#define TRANSPORT_TYPE_UDP  1
#define TRANSPORT_TYPE_USB  2   // USB CDC ACM — third AT-command channel
```

**Transport Operations:**
```c
struct transport_ops {
    int (*send)(const uint8_t *data, uint16_t len);
    int (*send_file_data)(const uint8_t *data, uint16_t len);
    int (*send_file_start)(const char *session_id, const char *filename, uint32_t size);
    int (*send_file_end)(const char *filename);
    int (*send_transfer_done)(const char *session_id, uint32_t file_count);
    bool (*is_connected)(void);
    void *(*get_conn)(void);
};
```

**Priority**: `transport_get_active()` checks transports in explicit priority order **UDP > BLE** (UDP preferred for large transfers); the USB CDC channel receives responses directly for commands submitted over USB.

**Registration**: Transports register at init time:
```c
transport_register(transport_ble_get());
transport_register(transport_udp_get());
```

### 3.5 Audio Pipeline (audio.c)

**Purpose**: PDM microphone capture, DSP processing, Opus encoding, and storage writing.

**Audio Thread** (priority 0, stack 32768): The audio thread blocks on `audio_start_sem` when idle. When recording, it reads DMIC blocks, processes PCM, encodes Opus, writes to storage, and manages segment files.

**Pipeline:**
```
PDM DMIC (16kHz, 2ch, 20ms frames)
    |
    v
process_pcm_frame():
    STEREO mode: pass through (no DSP)
    MERGE mode: (L + R) / 2 -> SpeexDSP (noise suppress + dereverb)
                + custom lightweight integer AGC + high-pass
                (SpeexDSP AGC unavailable in FIXED_POINT)
    |
    v
Opus Encoder (20ms frames, 320 samples)
    |
    v
Storage write (2-byte length header + Opus packet)
```

**Recording Modes:**

| Mode | Audio Mode | Channels | Bitrate | Complexity | DSP |
|------|-----------|----------|---------|------------|-----|
| Normal | STEREO | 2 (stereo Opus) | 64kbps (32k/ch, Kconfig value x2) | 1 | None |
| Enhanced | MERGE | 1 (mono Opus) | 32kbps | 1 | Noise suppress + dereverb + integer AGC |

Bitrate and complexity are Kconfig per-mode constants, not runtime configurable
(stereo doubles the configured per-channel bitrate):
- Normal: `CONFIG_CLIP_NORMAL_BITRATE=32000` (x2 = 64kbps total), `CONFIG_CLIP_NORMAL_COMPLEXITY=1`
- Enhanced: `CONFIG_CLIP_ENHANCED_BITRATE=32000`, `CONFIG_CLIP_ENHANCED_COMPLEXITY=1`

**Audio Constants:**
```c
#define AUDIO_SAMPLE_RATE     16000
#define AUDIO_SAMPLE_BITS      16
#define AUDIO_CHANNELS         2
#define AUDIO_FRAME_MS         20
#define AUDIO_OPUS_FRAME_SIZE  320  // 16000 * 0.020
#define AUDIO_BLOCK_SIZE       1280 // ((16/8) * (16000 * 20/1000)) * 2
#define AUDIO_MAX_PACKET_SIZE  4000
```

**Segment File Management**: Recording is split into segment files. Segment duration adapts to transfer state:
- During sync: `CLIP_AUDIO_SEGMENT_DURATION_SYNC` (60s)
- Not syncing: `CLIP_AUDIO_SEGMENT_DURATION_NO_SYNC` (300s)
- When transfer starts mid-file: immediate slice if file exceeds sync duration

**Pause/Resume**: Pause stops DMIC, powers off microphone, closes current file. Resume creates a new segment file with incremented index, powers on microphone, restarts DMIC.

**Audio Visualization**: Energy level (0-10) calculated from RMS of each frame, sent as BLE notifications every ~200ms. 13-sample history packed into 7 bytes (4 bits per sample).

**DMIC Recovery**: After 5 consecutive timeouts, the DMIC is retriggered automatically.

**Memory**: Audio buffers allocated from `K_MEM_SLAB_DEFINE_STATIC(audio_mem_slab, AUDIO_BLOCK_SIZE, 16, 4)` (16 blocks of 1280 bytes).

### 3.6 Storage (storage.c)

**Purpose**: SD card file management with FAT32 filesystem.

**Mount Point**: `/SD:`
**Base Path**: `/SD:/REC/`

**Directory Structure:**
```
/SD:/REC/
+-- 20260328/                # Date
    +-- 12/                  # Hour
        +-- 05/              # Minute
            +-- 30/          # Second; full session ID is 20260328120530
                +-- session.json
                +-- marks.bin
                +-- 0/       # Up to 100 segment files per group
                    +-- 0001.opus
                    +-- 0002.opus
```

The timestamp-bucket layout is the only supported on-card recording format.
`AT+LIST`, `AT+DOWNLOAD`, and `AT+DELETE` continue to use the complete 14-digit
session ID; old `/SD:/REC/<session_id>/` directories are not read.

**Write Buffer**: 4KB buffered writes (`CONFIG_CLIP_STORAGE_CHUNK_SIZE=4096`) for efficient SD card I/O.

**Session Lifecycle**: `storage_create_session()` -> `storage_create_file()` -> `storage_write_frame()` -> `storage_close_file()` -> `storage_close_session()`

**File Coordination**: A `file_closed_sem` signals the transfer thread when a file is closed and ready for transfer, enabling live recording sync.

**Bookmarks**: Binary format (`marks.bin`): 4-byte magic "BMRK", 2-byte count, then N x 4-byte offset entries (uint32 seconds from session start).

**SD Card Idle Power-Gating** (low power): when no recording / transfer / AT / USB /
log activity occurs for 45s (`SD_IDLE_POWEROFF_DELAY_MS`), the SD stack is torn
down to recover idle current — `fs_unmount` → `disk deinit` → SPI4 runtime-PM
suspend → CS parked low → LDO2 off. The next access lazily remounts via
`storage_ensure_mounted()` (a no-op if already mounted). Safety: the filesystem is
flushed (unmount) before LDO2 is removed, and an active write/transfer cancels the
power-off (`storage_set_busy_cb`). API: `storage_idle_poweroff()` /
`storage_resume()` / `storage_ensure_mounted()` / `storage_is_sd_powered()` /
`storage_set_busy_cb()`.

**Storage-Full Protection**: usage is tracked via `fs_statvfs`.
`storage_is_full()` returns true when SD usage reaches
`CONFIG_CLIP_STORAGE_FULL_PERCENT` (default 95%). On full, recording is refused,
a "Storage Full" error is shown on the OLED, and a BLE event is posted.

**SD Card Log Persistence**: Logs persist to the SD card for field debugging.
- Enabled by `CONFIG_LOG_BACKEND_FS=y`
- Log directory: `/SD:/LOG/`
- Log files: `log.000001` ... (prefix `log.`, 128KB per file, up to 20 files,
  circular overwrite)
- Backend level is runtime-controlled by `AT+LOG=off|info|debug` (see §3.3)
- Boot default follows the build: `CLIP_LOG_FS_DEFAULT_ON` tracks
  `LOG_BACKEND_UART` (debug image → INF on; production image → off). While the
  backend is active the SD stays mounted (higher idle current); `off` lets it
  idle power-gate.

### 3.7 Transfer (transfer.c)

**Purpose**: File-level transfer over BLE or UDP with retransmit support.

**Transfer Thread** (priority 5, stack 4096 in prj.conf): Triggered by `transfer_start()` via semaphore. Reads files from SD card in chunks (`CONFIG_CLIP_TRANSFER_CHUNK_SIZE=4096`) and sends via the active transport.

**Features:**
- File-level retransmit (up to `TRANSFER_MAX_FILE_RETRIES=10` retries)
- Per-file CRC32 verification
- Pause/resume/cancel — cancel is thread-safe via a volatile flag and marks the
  transfer `TRANSFER_STATE_ERROR` synchronously, so a fresh download works
  correctly after a BLE drop (the transfer is fully inactive before the next start)
- Continuous mode (transfer while recording)
- Progress tracking (bytes, files, percent)
- Resume from specific file (reconnect scenario)

**Transfer States:**
```c
enum transfer_state {
    TRANSFER_STATE_IDLE = 0,
    TRANSFER_STATE_TRANSMITTING,
    TRANSFER_STATE_PAUSED,
    TRANSFER_STATE_COMPLETED,
    TRANSFER_STATE_ERROR
};
```

**Chunk Buffer**: Static 4KB buffer avoids stack allocation.

### 3.8 WiFi Module (wifi.c)

**Purpose**: WiFi AP mode control for nRF7002.

**Configuration** (defaults; channel/reg-domain are runtime settings persisted in settings key `config/wifi_channel` / the reg-domain value, settable at any time via `AT+WIFICFG=<channel>:<CC>` — channels 1-13 (2.4GHz) or 36-165 (5GHz)):
```c
#define WIFI_AP_SSID_PREFIX "ClipAP_"     // + 4 hex digits of chip ID
#define WIFI_AP_PASSWORD "12345678"       // default; random 8-char password
                                        // generated on first pairing
#define WIFI_AP_CHANNEL 36               // 5GHz default (CONFIG_CLIP_WIFI_AP_CHANNEL)
#define WIFI_AP_MAX_CLIENTS 1
#define WIFI_AP_REG_DOMAIN "US"          // CONFIG_CLIP_WIFI_AP_REG_DOMAIN
#define WIFI_AP_UDP_PORT 8089
```

**Static IP**: `192.168.4.1/24`

**Manual Start**: WiFi radio is NOT started at boot (`CONFIG_NRF_WIFI_IF_AUTO_START=n`). `wifi_on()` brings up the interface and starts the AP. `wifi_off()` stops AP and powers off radio. This saves ~30mA when WiFi is not in use.

**WiFi Auto-Off**: WiFi AP automatically disables after a configurable timeout (`CONFIG_CLIP_WIFI_TIMEOUT_MS`, default 180000ms = 3 minutes). The timeout timer starts when WiFi is enabled and restarts on client disconnect. Set to 0 to disable auto-off. This prevents unnecessary power drain when WiFi is left on but unused.

**BLE/WiFi Coexistence**: `CONFIG_NRF70_SR_COEX=y` with PTA configuration for 5GHz band.

### 3.8a USB CDC Security (usb_cdc.c)

**Purpose**: USB CDC serial interface with security controls for production use.

**Default State**: USB CDC is **disabled** at boot. This prevents unauthorized serial console access in the field.

**Control**: The `AT+USB` command enables/disables USB CDC:
- `AT+USB=on`: Enable USB CDC, serial console becomes available
- `AT+USB=off`: Disable USB CDC
- `AT+USB?`: Query current USB CDC status (returns `{"status":"on"}` or `{"status":"off"}`)

**Auto-Off**: USB CDC automatically disables when the USB cable is physically disconnected. This prevents the interface from remaining enabled after debugging sessions.

**Security Rationale**: In production, the USB CDC console exposes AT commands and log output. By defaulting to disabled and requiring explicit BLE-enabled activation, the attack surface is reduced for end-user deployments.

### 3.9 WiFi UDP Server (wifi_udp.c)

**Purpose**: Receive AT commands and ACK frames from WiFi clients.

**UDP Thread** (priority 5, stack 2048 in prj.conf): Listens on port 8089, dispatches incoming packets.

**Protocol** (CLIP UDP Transfer Protocol, see `docs/udp_protocol.md`):
- Server sends: DATA, FILE_START, FILE_END, TRANSFER_DONE, AT_RESP, HEARTBEAT
- Server receives: ACK, HEARTBEAT, AT commands (plain text)

**Heartbeat**: Server sends heartbeat every 5s. Connection timeout after 30s without heartbeat.

### 3.10 Configuration (config.c)

**Purpose**: Persistent configuration via Zephyr Settings subsystem on LittleFS.

**Storage Backend**: LittleFS mounted at `/lfs`, settings stored at `/lfs/settings/run`.

**Settings Keys (5):**

| Key | Settings Path | Type | Default | Description |
|-----|--------------|------|---------|-------------|
| CONFIG_KEY_MODE (0x03) | config/mode | uint8_t | 0 (normal) | Recording mode |
| CONFIG_KEY_NOISE (0x04) | config/noise_suppress | uint8_t | 12 | Noise suppression (dB) |
| CONFIG_KEY_AUTODEL (0x06) | config/auto_delete_days | int8_t | -1 (off) | Auto-delete days |
| CONFIG_KEY_DEREVERB (0x09) | config/dereverb_enabled | bool | true | Dereverberation |
| CONFIG_KEY_BRIGHTNESS (0x0A) | config/oled_brightness | uint8_t | 32 | OLED brightness |

**Time Persistence**: Unix timestamp saved to `time/unix_timestamp`. On boot, time is restored from storage and advanced by elapsed uptime. This allows session IDs to remain meaningful across reboots.

**Factory Reset**: Resets all 5 config keys to Kconfig defaults and saves.

### 3.11 BLE Module (ble.c, transport_ble.c)

**Purpose**: BLE GATT service with AT command protocol.

**Service UUID**: Nordic UART Service (NUS) compatible.

**Characteristics:**
- Command Receive: Write (AT commands from client)
- Response Send: Notify (JSON responses)
- File Data: Notify (binary file transfer data)
- Audio Visualization: Notify (packed energy level data)

**Pairing**: BLE SMP with bonding, 1 max paired device, encrypted connection.

**Advertising & Connection Parameters**: Fast advertising for a short window after
boot/connect-drop, then drops to **slow advertising** (~1s interval, ~0.1mA averaged
to idle) — including for un-bonded devices — to minimize idle current. Once
connected, the link requests a tight interval (15–30) with a supervision timeout of
800; parameter-update requests from the central are accepted (clamped) rather than
rejected, so iOS/Android centrals settle quickly and the link stays stable.

### 3.11a BLE Event Notifications

**Purpose**: Push real-time state and status events to the connected BLE client via the Response characteristic (notify).

Event notifications are JSON objects sent over the BLE GATT Response characteristic whenever the device state changes or a significant event occurs. The mobile app can subscribe to these notifications to update its UI without polling.

**Event Types:**

| Event | Format | Trigger |
|-------|--------|---------|
| State change | `{"event":"state","state":"RECORDING","session":"..."}` | Recording start/stop/pause/resume |
| State change (with duration) | `{"event":"state","state":"IDLE","session":"...","duration":120}` | Recording stop (includes duration in seconds) |
| Bookmark added | `{"event":"mark","session":"...","mark_count":3}` | Bookmark added during recording |
| BLE status | `{"event":"ble","status":"connected"}` / `"disconnected"` | BLE connection change |
| WiFi status | `{"event":"wifi","status":"on"}` / `"off"` | WiFi AP enabled/disabled |
| USB status | `{"event":"usb","status":"on"}` / `"off"` | USB CDC enabled/disabled |

**Implementation**: Events are dispatched immediately from the event processing context (not deferred). `ble_notify_state_change()` handles state transitions, `ble_notify_event()` handles status events (BLE/WiFi/USB). Both use the same GATT notify mechanism on the Response characteristic.

### 3.12 Battery Monitor (battery.c)

**Purpose**: Battery monitoring via NPM1300 PMIC with nRF Fuel Gauge.

**Fuel Gauge**: Uses `CONFIG_NRF_FUEL_GAUGE=y` with `CONFIG_NRF_FUEL_GAUGE_VARIANT_SECONDARY_CELL=y` and the profiled `clip_25C` 240 mAh cell model for State of Charge (SoC) estimation. The opaque gauge state is saved in LittleFS and explicitly loaded at boot, so SoC remains continuous across restart rather than being re-estimated from the recovered cell voltage. The saved state is tagged with a CRC of the battery model; it is discarded automatically after a model or state-format update.

**Displayed %**: a *directionally rate-limited* view of the fuel gauge's integer
SoC — the displayed value moves at most `CONFIG_CLIP_BATTERY_DISPLAY_MAX_STEP`
(default 3 percentage points) per 60s poll, so a normal charge/discharge tracks
with zero lag while a spurious jump (e.g., during charger plug-in) is clamped.
The displayed value is persisted across reboot (seeded on boot), and setting the
Kconfig step to 0 restores the raw gauge value.

**Reporting**: Battery level (0-100%), charging status reported via AT+GSTAT and displayed on OLED status bar. A low-battery warning (15% or below, discharging) shows a UI event; there is **no** automatic low-battery shutdown (removed — unreliable SoC during PMIC I2C failures caused false shutdowns). Power-off is manual (`AT+POWEROFF` / button).

**Charge Termination**: 4.25V (raised from 4.20V) so the fuel gauge reaches ~100% instead of settling at ~99%. The cell (240/HSZ 362123) is 4.20V-rated; 4.25V is a mild overcharge (reduced cycle life, accepted for accurate 100%).

**Deep-Discharge Recovery**: `vbatlow-charge-enable` in the DTS allows the charger to activate even when the cell is below the VBATLOW threshold (~2.4V), e.g. after the protection IC trips. The NPM1300 then trickle-charges (10% ICHG) until the cell recovers. No software watchdog is needed — the PMIC handles it in hardware.


### 3.13 Button Handler (button.c)

**Purpose**: Translate button hardware events into device events.

**Driver**: Custom GPIO input driver (`CONFIG_GPIO_BUTTON`) with own thread (stack 512, priority 5).

**Button Events and Actions:**

| Event | State | Action |
|-------|-------|--------|
| Single click | RECORDING / PAUSED | `CLIP_EVENT_MARK` (bookmark) |
| Single click | IDLE / ERROR / WIFI_SYNC | `CLIP_EVENT_STATUS_SHOW` |
| Long press | RECORDING | `CLIP_EVENT_STOP` |
| Long press | IDLE / ERROR | `CLIP_EVENT_START` |
| Long press level 1/2/3 | Any | `CLIP_EVENT_POWER_OFF_SHOW` |
| Release (after power-off show) | Any | `CLIP_EVENT_POWER_OFF_EXEC` |

**Power-Off Sequence**: Two-step shutdown. Hold button shows power-off confirmation screen. Release triggers PMIC ship mode via `regulator_parent_ship_mode()`.

### 3.14 Display Controller (display.c)

**Purpose**: Event-driven CH1115 OLED display with UI state machine.

**Specifications:**
- Controller: CH1115
- Resolution: 88x48 pixels
- Interface: I2C
- Address: 0x3c
- Icons: 24x24 pixel XBM format
- Font: 8x16 pixel

**UI States:**
```c
enum ui_state {
    UI_STATE_OFF,              // Display off
    UI_STATE_PAIRING_GUIDE,    // BLE not bonded
    UI_STATE_STATUS_BAR,       // Battery, connection, mode
    UI_STATE_REC_WAVE,         // Recording with wave animation (enhanced)
    UI_STATE_REC_DOT,          // Recording with dot animation (normal)
    UI_STATE_MARKING,          // Bookmark flash
    UI_STATE_PAUSED,           // Paused recording
    UI_STATE_POWER_OFF,        // Power-off confirmation
    UI_STATE_USB_CONNECTED,    // USB plugged in
    UI_STATE_OTA,              // OTA in progress
    UI_STATE_LOW_BATTERY,      // Low battery (<=15%, discharging) fullscreen
};
```

**Animations:**
- Normal mode: dot animation (slower, simpler)
- Enhanced mode: wave animation using real-time audio energy levels (13-bar histogram from BLE audio vis data)
- Bookmark: flash animation
- Status: auto-timeout after 3 seconds
- Low battery: fullscreen warning when battery falls to 15% or below (one-shot until recharged)

**Status Bar Icons** (24x24 XBM):
- Battery level (0/25/50/75/100% + charging)
- BLE connected
- WiFi AP active + client connected
- Recording mode (normal/enhanced)
- OTA in progress

**Brightness**: Configurable via `CONFIG_KEY_BRIGHTNESS` (0-255).

### 3.15 Haptic Motor (haptic.c)

**Purpose**: Haptic feedback via PMIC GPIO.

**Hardware**: nRF5340 P1.06 -> NPM1300 GPIO1 -> BUCK1 (MOTOR_3V3) enable.

**Kconfig**: `CONFIG_CLIP_HAPTIC_MOTOR_ENABLED=n` (disabled by default).

**Patterns:**

| Pattern | Description | Duration |
|---------|-------------|----------|
| HAPTIC_SHORT | Single tap | 100ms |
| HAPTIC_DOUBLE | Double tap | 100ms on, 100ms off, 100ms on |
| HAPTIC_LONG | Long pulse | 500ms |
| HAPTIC_ALERT | Alert sequence | 150ms x2 + 400ms |

**Usage**: Recording start/stop/bookmark use HAPTIC_SHORT. Power-off uses HAPTIC_DOUBLE.

## 4. Data Flow Architecture

### 4.1 Audio Recording Flow

```
PDM DMIC (16kHz, 2ch, stereo)
    |
    v  (DMA, memory slab buffers)
Audio Thread: dmic_read() -> buffer (1280 bytes)
    |
    v
process_pcm_frame():
    STEREO: pass through unchanged
    MERGE:  (L + R) / 2 -> SpeexDSP preprocess (noise suppress + dereverb)
    |
    v
Opus Encoder (20ms frame, 320 samples)
    |
    v
storage_write_frame():
    [2-byte length][Opus packet] -> write buffer -> SD card
    |
    v
Segment file check:
    If frames_in_file >= segment_duration -> close file, open new segment
```

### 4.2 Command Processing Flow

```
Mobile App
    |
    +--[BLE]--> ble_write_cb() --> at_server_submit_cmd(data, len, TRANSPORT_TYPE_BLE)
    |                                       |
    |                                       v  (k_msgq_put)
    |                              AT Server Thread
    |                              parse_command() -> lookup handler -> execute
    |                                       |
    |                                       v
    |                              Response via transport_send_to()
    |
    +--[UDP]--> wifi_udp handle_packet() --> at_server_submit_cmd(data, len, TRANSPORT_TYPE_UDP)
                                            |
                                            v  (k_msgq_put)
                                           AT Server Thread
                                           parse_command() -> lookup handler -> execute
                                            |
                                            v
                                           transport_udp_send_response()
```

### 4.3 File Transfer Flow (UDP)

```
AT+DOWNLOAD=session_id
    |
    v
transfer_start() --> transfer thread triggered (semaphore)
    |
    v
For each file in session:
    send_file_start() --> [FILE_START frame]
    For each 4KB chunk:
        send_file_data() --> [DATA frames with seq numbers]
        Wait for ACK
        If NACK: retransmit file (up to 10 retries)
    send_file_end() --> [FILE_END frame]
    |
    v
send_transfer_done() --> [TRANSFER_DONE frame]
```

### 4.4 Button Event Flow

```
GPIO interrupt (P1.15, active-low)
    |
    v
Input driver (own thread, priority 5)
    |
    v
button_event_callback():
    Map action to clip_event
    clip_post_event() --> k_msgq_put + k_sem_give
    |
    v
Main thread: clip_event_process()
    Lookup transition_table[current_state][event]
    execute_transition():
        audio_start/stop_recording()
        haptic_play_pattern()
        display_post_event()
```

## 5. Thread Architecture

### 5.1 Thread Overview

*Effective values — `applications/clip/prj.conf` overrides several Kconfig defaults (noted below).*

| Thread | Priority | Stack Size | Purpose |
|--------|----------|------------|---------|
| Main (event loop) | 0 | 6144 (CONFIG_MAIN_STACK_SIZE) | Event processing, state transitions, WiFi on/off |
| Audio recording | 0 | 32768 (CONFIG_CLIP_AUDIO_STACK_SIZE) | DMIC read, DSP, Opus encode, storage write |
| AT Server | 7 | 8192 (CONFIG_CLIP_AT_SERVER_STACK_SIZE, prj.conf; Kconfig default 4096) | AT command parsing and dispatch |
| Transfer | 5 | 4096 (CONFIG_CLIP_TRANSFER_STACK_SIZE, prj.conf; Kconfig default 16384) | File transfer (read + send chunks) |
| UDP Server | 5 | 2048 (CONFIG_CLIP_UDP_THREAD_STACK_SIZE, prj.conf; Kconfig default 4096) | WiFi UDP packet handling |
| Input driver | 5 | 512 (CONFIG_INPUT_GPIO_BUTTON_THREAD_STACK_SIZE) | Button debounce and event detection |
| Display UI | - | - | Zephyr display subsystem thread |
| BLE stack | - | 4096 (CONFIG_BT_RX_STACK_SIZE) | Zephyr BLE internal |
| WPA supplicant | - | 10240 (CONFIG_WIFI_NM_WPA_SUPPLICANT_THREAD_STACK_SIZE) | WiFi auth |

**Priority Rationale:**
- **AT Server (7)**: Highest app priority for responsive command processing
- **Transfer (5)** / **UDP (5)** / **Input (5)**: Mid-priority for I/O operations
- **Audio (0)** / **Main (0)**: Audio needs large stack; main needs stack for WiFi ops

### 5.2 Inter-Thread Communication

**Message Queues (k_msgq):**
- `clip_ev_msgq`: Device events (button -> main thread), 8 items
- `at_ctx.msgq`: AT commands (BLE/UDP -> AT server thread), 10 items

**Semaphores (k_sem):**
- `event_notify_sem`: Main loop wake-up (1 slot, binary)
- `audio_start_sem`: Audio thread start/pause/resume signal
- `stop_done_sem`: Audio thread stop-completion signal
- `transfer_trigger_sem`: Transfer thread start signal
- `file_closed_sem`: Storage -> transfer coordination

**Mutexes (k_mutex):**
- `audio_state_mutex`: Protects recording_active, is_paused, session_id
- `audio_energy_mutex`: Protects energy level and history

**Atomic Variables (atomic_t):**
- `g_state`: Device state (lock-free read via `atomic_get`)
- `g_boost_refcnt`: CPU boost reference count

**Work Queues (k_work):**
- `reboot_work`: Delayed reboot (allows AT response to be sent first)

## 6. State Machine Design

### 6.1 Device State Machine

```
  +----------------+
  | UNINITIALIZED  |
  +-------+--------+
          | boot
          v
  +-------+--------+  START      +------------+
  |      IDLE      |------------>| RECORDING  |
  +---+----+----+--+            +-----+------+
      |    |    |                      |
      |    |    |  STOP                 | STOP
      |    |    +<---------------------+
      |    |
      |    |  WIFI_ON
      |    v
      |  +---------------+  WIFI_OFF
      |  |   WIFI_SYNC    |<----------+
      |  +---------------+
      |
      |  (TRANSMITTING managed by transfer subsystem, not device state)
      |
      |  PAUSE (during RECORDING)
      v
  +---+----+----+--+
  |    PAUSED     |  RESUME -> RECORDING
  +------+--------+  STOP -> IDLE
         |
         | Error
         v
  +------+--------+
  |     ERROR     |  START -> IDLE
  +---------------+
```

**Valid Transitions:**

| From | To | Trigger | Side Effects |
|------|-----|---------|-------------|
| IDLE | RECORDING | START | audio_start, haptic, display rec |
| RECORDING | IDLE | STOP | audio_stop, haptic, display idle |
| RECORDING | PAUSED | PAUSE | audio_pause, haptic, display pause |
| PAUSED | RECORDING | RESUME | audio_resume, haptic, display rec |
| PAUSED | IDLE | STOP | audio_stop, haptic, display idle |
| IDLE | WIFI_SYNC | WIFI_ON | wifi_on() |
| WIFI_SYNC | IDLE | WIFI_OFF | wifi_off() |
| ERROR | IDLE | START | (transition only) |
| Any | (same) | MARK | audio_add_bookmark, display mark |
| Any | (same) | STATUS_SHOW | display status |
| Any | (same) | POWER_OFF_SHOW | display power-off screen |
| Any | (same) | POWER_OFF_EXEC | haptic, PMIC ship mode |

### 6.2 Transfer State Machine

Managed independently by the transfer subsystem. Does not affect device state directly.

```
  +--------+  transfer_start()  +---------------+
  |  IDLE  |------------------->| TRANSMITTING  |
  +---+----+                    +---+-----+-----+
      ^                             |       |
      |                             |       | cancel
      |        transfer_cancel()    |       |
      +-----------------------------+       |
      |                                     |
      |        completion                   v
      +------------------------------+  ERROR  |
                                     +--------+
```

## 7. Error Handling Strategy

### 7.1 Error Categories

| Category | Example | Severity | Recovery |
|----------|---------|----------|----------|
| DMIC Timeout | 5 consecutive timeouts | Low | Auto-retrigger DMIC |
| DMIC Read Error | I2S error | Medium | Stop recording |
| Opus Encode Error | opus_encode() < 0 | High | Drop frame, continue |
| SD Card Write Error | fs_write() failure | High | Close file, continue without storage |
| SD Card Init Error | Mount failure | Low | Continue without storage |
| BLE Disconnect | Connection lost | Medium | Transfer pause (BLE) |
| WiFi Init Error | AP start failure | Low | Continue without WiFi |
| Invalid State Transition | Event not allowed | Low | Log warning, return CLIP_EVENT_INVALID |

### 7.2 Graceful Degradation

**Init failures**: Most subsystems (storage, WiFi, display, button, transfer) log a warning and continue if initialization fails. Only BLE and audio init are treated as hard failures.

**Recording with issues**: DMIC timeouts trigger auto-recovery. SD write errors close the current file but recording continues. Opus encode errors drop individual frames.

**Transfer with issues**: File-level retransmit up to 10 retries. Transfer aborts after exhausting retries for a single file.

## 8. Configuration Reference

### 8.1 Build-Time Configuration (Kconfig)

| Option | Default | Description |
|--------|---------|-------------|
| CLIP_NORMAL_BITRATE | 32000 | Normal mode Opus bitrate (bps) |
| CLIP_NORMAL_COMPLEXITY | 1 | Normal mode Opus complexity (0-10) |
| CLIP_ENHANCED_BITRATE | 32000 | Enhanced mode Opus bitrate (bps) |
| CLIP_ENHANCED_COMPLEXITY | 1 | Enhanced mode Opus complexity (0-10) |
| CLIP_DEFAULT_NOISE | 12 | Default noise suppression (dB) |
| CLIP_DEFAULT_DEREVERB | y | Default dereverberation enabled |
| CLIP_DEFAULT_AUTODEL | -1 | Default auto-delete days (-1=off) |
| CLIP_DEFAULT_BRIGHTNESS | 32 | Default OLED brightness (0-255) |
| CLIP_STORAGE_FULL_PERCENT | 95 | SD usage % at which recording is refused |
| CLIP_LOG_FS_DEFAULT_ON | y (if LOG_BACKEND_UART) | FS log backend on at boot (debug y / production n) |
| CLIP_HAPTIC_MOTOR_ENABLED | n | Enable haptic motor |
| CLIP_AT_SERVER_QUEUE_SIZE | 10 | AT command queue depth |
| CLIP_AT_SERVER_STACK_SIZE | 4096 | AT server thread stack (bytes) |
| CLIP_AT_SERVER_PRIORITY | 7 | AT server thread priority |
| CLIP_AT_MAX_CMD_LEN | 256 | Maximum AT command length |
| CLIP_AT_MAX_RESPONSE_LEN | 1024 | Maximum AT response length |
| CLIP_AUDIO_STACK_SIZE | 32768 | Audio thread stack (bytes) |
| CLIP_AUDIO_THREAD_PRIORITY | 0 | Audio thread priority |
| CLIP_AUDIO_SEGMENT_DURATION_SYNC | 60 | Segment duration during transfer (seconds) |
| CLIP_AUDIO_SEGMENT_DURATION_NO_SYNC | 300 | Segment duration without transfer (seconds) |
| CLIP_TRANSFER_STACK_SIZE | 16384 | Transfer thread stack (bytes) |
| CLIP_TRANSFER_THREAD_PRIORITY | 5 | Transfer thread priority |
| CLIP_TRANSFER_CHUNK_SIZE | 4096 | Transfer chunk size (bytes) |
| CLIP_UDP_THREAD_STACK_SIZE | 4096 | UDP server thread stack (bytes) |
| CLIP_UDP_THREAD_PRIORITY | 5 | UDP server thread priority |
| CLIP_UDP_RECV_BUF_SIZE | 1024 | UDP receive buffer size |
| CLIP_UDP_MAX_DATA_SIZE | 1024 | UDP maximum data per packet |
| CLIP_UDP_HEARTBEAT_INTERVAL_MS | 5000 | UDP heartbeat interval |
| CLIP_UDP_CONNECTION_TIMEOUT_MS | 30000 | UDP connection timeout |
| CLIP_STORAGE_CHUNK_SIZE | 4096 | Storage write buffer size |
| CLIP_WIFI_TIMEOUT_MS | 180000 | WiFi AP auto-off timeout (ms), 0 to disable |

### 8.2 Runtime Configuration (Zephyr Settings on LittleFS)

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| config/mode | uint8_t | 0 | Recording mode (0=normal, 1=enhanced) |
| config/noise_suppress | uint8_t | 12 | Noise suppression level (dB) |
| config/auto_delete_days | int8_t | -1 | Auto-delete days (-1=off, 0-30) |
| config/dereverb_enabled | bool | true | Dereverberation enabled |
| config/oled_brightness | uint8_t | 32 | OLED brightness (0-255) |
| time/unix_timestamp | int64_t | - | Synced time (for session IDs) |

## 9. Memory Architecture

### 9.1 Key Memory Consumers

| Component | Size | Allocation |
|-----------|------|-----------|
| Audio thread stack | 32 KB | Static (K_THREAD_STACK_DEFINE) |
| Transfer thread stack | 4 KB | Static (prj.conf; Kconfig default 16 KB) |
| Audio memory slab | 16 x 1280 B = 20 KB | Static (K_MEM_SLAB_DEFINE_STATIC) |
| AT server thread stack | 8 KB | Static (prj.conf; Kconfig default 4 KB) |
| UDP server thread stack | 2 KB | Static (prj.conf; Kconfig default 4 KB) |
| Main thread stack | 6 KB | Static (CONFIG_MAIN_STACK_SIZE) |
| Heap | 80 KB | Static (CONFIG_HEAP_MEM_POOL_SIZE=81920 in prj.conf) |
| Transfer chunk buffer | 4 KB | Static |
| Opus encoder state | ~20 KB | Heap (opus_encoder_create) |
| SpeexDSP preprocessor | ~10 KB | Heap (speex_preprocess_state_init) |
| Storage write buffer | 4 KB | Static |

### 9.2 Flash Storage

MCUboot runs in **overwrite-only** mode (no A/B swap, no rollback — the incoming
image is copied over the primary slot directly). The network-core image runs from
RAM (`ram_flash`), not internal flash. Layout (see
`boards/seeed/clip/pm_static_clip_nrf5340_cpuapp.yml`):

**Internal flash (1 MB):**

| Partition | Address | Size | Purpose |
|-----------|---------|------|---------|
| MCUboot | 0x000000 | 88 KB | Bootloader (RSA-signed, OLED + USB serial recovery) |
| Application (primary, slot0) | 0x016000 | 936 KB | App-core firmware — single slot, overwrite-only |

**External SPI flash (PY25Q64H, 8 MB / 64 Mbit):**

| Partition | Address | Size | Purpose |
|-----------|---------|------|---------|
| App OTA (mcuboot_secondary) | 0x000000 | 960 KB | App-core OTA staging |
| Netcore OTA (mcuboot_secondary_1) | 0x0f0000 | 256 KB | Network-core OTA staging |
| LittleFS (lfs_storage) | 0x130000 | ~6.8 MB | Settings, BLE bonds, fuel-gauge state |

## 10. Hardware Interfaces

### 10.1 Key GPIO Pins

| Pin | Function | Direction |
|-----|----------|-----------|
| GPIO1.15 | User button | Input, pull-up, active-low |
| GPIO1.14 | Microphone power enable | Output |
| GPIO1.8 | OLED display power enable | Output |
| GPIO1.9 | OLED display reset | Output |
| GPIO0.29 | WiFi RF switch power | Output |
| GPIO1.6 | Haptic motor (PMIC GPIO1) | Output |

### 10.2 I2C Devices

| Bus | Address | Device |
|-----|---------|--------|
| I2C1 | 0x6b | NPM1300 PMIC (battery, regulators, 5 GPIOs) |
| I2C2 | 0x3c | CH1115 OLED display (88x48) |

### 10.3 SPI Devices

| Bus | Device | Chip Select |
|-----|--------|------------|
| SPI3 | PY25Q64H external flash (8MB) | GPIO0.20 |
| SPI4 | SD card (SDHC-SPI) | GPIO0.9 |

### 10.4 PMIC Regulators (NPM1300)

| Regulator | Output | Purpose | Control |
|-----------|--------|---------|---------|
| BUCK1 | MOTOR_3V3 | Vibration motor power | PMIC GPIO2 |
| BUCK2 | VDD_3V3 | Main system power | Always-on |
| LDO1 | VDDMIC_1V8 | Microphone power | Always-on |
| LDO2 | VDD_SD | SD card power | Runtime-gated (idle power-off) |

GPIO-controlled power rails: `mic_vdd` (GPIO1.14), `oled_vdd` (GPIO1.8),
`rfsw_vdd` (GPIO0.29), `flash_vdd` (GPIO0.27).

### 10.5 Power Management

The nRF5340 main and radio regulators are configured for **DCDC** mode
(`vregmain`/`vregradio`), which saves ~500–600µA over LDO. Combined with SD card
idle power-gating (LDO2 + SPI4 off after 45s inactivity, §3.6), removal of the SPI
`bias-pull-up`, and the production snippet disabling the UART console (which
otherwise leaks ~570µA), the production image reaches **~170µA** steady-state idle
(3V3 rail) while remaining BLE-connectable. The debug image idles higher because
the console stays on. `CONFIG_PM_DEVICE_RUNTIME=y` lets UART/I²C/SPI suspend
between accesses; `CONFIG_NRF70_QSPI_LOW_POWER=y` parks QSPI when WiFi is off.
