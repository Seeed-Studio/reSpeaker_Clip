# reSpeaker Clip - System Architecture

## 1. Architecture Overview

### 1.1 System Context

The reSpeaker Clip is an embedded audio recording device built on Zephyr RTOS, running on the Nordic nRF5340 dual-core microcontroller. It provides high-quality audio capture with BLE synchronization to mobile devices.

**External Actors:**
- **End User**: Interacts via button and display
- **Mobile App**: Interacts via BLE GATT
- **SD Card**: Stores audio recordings
- **Charging Source**: Powers device

**System Boundaries:**
- Hardware: nRF5340, PMIC, microphones, SD card
- Firmware: Zephyr RTOS + custom application
- Protocol: BLE AT command protocol

### 1.2 Architectural Drivers

**Primary Drivers:**
1. **Memory Constraints**: Only 192KB non-secure SRAM, 192KB flash
2. **Real-Time Audio**: Must process audio with < 50ms latency
3. **Power Efficiency**: > 8 hours recording on 500mAh battery
4. **BLE Throughput**: > 20 KB/s file transfer
5. **UI Simplicity**: Single button, minimal display

**Quality Attributes:**
- Performance: Low latency audio processing
- Reliability: Graceful error handling
- Maintainability: Modular design
- Testability: Clear interfaces between modules

### 1.3 Quality Attributes

| Attribute | Priority | Tactics |
|-----------|----------|---------|
| Performance | High | Double buffering, DMA, priority threads |
| Reliability | High | Error detection, graceful degradation |
| Power Efficiency | High | Low power states, PMIC control |
| Maintainability | Medium | Modular design, clear interfaces |
| Testability | Medium | Unit tests, integration tests |

### 1.4 Design Principles

1. **Separation of Concerns**: Each module has single responsibility
2. **Layered Architecture**: Clear abstraction between layers
3. **Data Hiding**: Modules expose only necessary interfaces
4. **Resource Management**: Explicit ownership of buffers/memory
5. **Error Isolation**: Errors contained, don't cascade
6. **Real-Time Safe**: No blocking in high-priority threads

## 2. High-Level Architecture

### 2.1 Layered Architecture

```
┌─────────────────────────────────────────────────────────┐
│                Application Layer                         │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐ │
│  │ Recording    │  │ Command      │  │ State        │ │
│  │ Controller   │  │ Handler      │  │ Machine      │ │
│  └──────────────┘  └──────────────┘  └──────────────┘ │
├─────────────────────────────────────────────────────────┤
│                  Service Layer                           │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐ │
│  │ BLE GATT     │  │ AT Command   │  │ Session      │ │
│  │ Server       │  │ Parser       │  │ Manager      │ │
│  └──────────────┘  └──────────────┘  └──────────────┘ │
├─────────────────────────────────────────────────────────┤
│                Processing Layer                         │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐ │
│  │ Audio        │  │ SpeexDSP     │  │ Opus         │ │
│  │ Capture      │  │ Processor    │  │ Encoder      │ │
│  └──────────────┘  └──────────────┘  └──────────────┘ │
├─────────────────────────────────────────────────────────┤
│            Hardware Abstraction Layer (HAL)             │
│  ┌────────┐ ┌────────┐ ┌────────┐ ┌────────┐ ┌───────┐│
│  │ PDM    │ │ SD     │ │ BLE    │ │ GPIO   │ │ PMIC  ││
│  │ Driver │ │ Card   │ │ Stack  │ │ Driver │ │ Driver││
│  └────────┘ └────────┘ └────────┘ └────────┘ └───────┘│
├─────────────────────────────────────────────────────────┤
│               Zephyr RTOS Kernel                         │
│  Threads │ Semaphores │ Timers │ Memory Pool │ WorkQ   │
└─────────────────────────────────────────────────────────┘
```

### 2.2 Component Diagram

```
┌──────────────────────────────────────────────────────────┐
│                      Mobile App                          │
└───────────────────┬──────────────────────────────────────┘
                    │ BLE (GATT)
┌───────────────────▼──────────────────────────────────────┐
│              reSpeaker Clip Device                       │
│                                                          │
│  ┌─────────────────────────────────────────────────┐   │
│  │              User Interface                     │   │
│  │  ┌──────────┐  ┌──────────┐  ┌──────────────┐  │   │
│  │  │ Button   │  │ Display  │  │ Haptic       │  │   │
│  │  │ Handler  │  │ Manager  │  │ Motor        │  │   │
│  │  └────┬─────┘  └────┬─────┘  └──────────────┘  │   │
│  └───────┼─────────────┼───────────────────────────┘   │
│          │             │                                │
│  ┌───────▼─────────────▼───────┐                        │
│  │      Application Core       │                        │
│  │  ┌──────────────────────┐   │                        │
│  │  │ Recording Controller │   │                        │
│  │  └──────┬───────────────┘   │                        │
│  │         │                    │                        │
│  │  ┌──────▼───────────────┐   │                        │
│  │  │ State Machine        │   │                        │
│  │  └──────┬───────────────┘   │                        │
│  │         │                    │                        │
│  │  ┌──────▼───────────────┐   │                        │
│  │  │ Command Handler      │   │                        │
│  │  └──────┬───────────────┘   │                        │
│  └─────────┼────────────────────┘                        │
│            │                                            │
│  ┌─────────▼─────────────────────────────────────────┐ │
│  │                  Services                          │ │
│  │  ┌──────────┐  ┌──────────┐  ┌──────────────┐   │ │
│  │  │ BLE      │  │ Session  │  │ Config       │   │ │
│  │  │ Service  │  │ Manager  │  │ Manager      │   │ │
│  │  └────┬─────┘  └────┬─────┘  └──────────────┘   │ │
│  └───────┼─────────────┼────────────────────────────┘ │
│          │             │                                │
│  ┌───────▼─────────────▼───────┐                        │
│  │      Audio Pipeline          │                        │
│  │  ┌──────┐  ┌──────┐  ┌────┐ │                        │
│  │  │ PDM  │→│ DSP  │→│    │ │                        │
│  │  │ MIC  │  │      │  │    │ │                        │
│  │  └──────┘  └──────┘  │    │ │                        │
│  │                      │Opus│ │                        │
│  │  ┌──────────┐        │    │ │                        │
│  │  │ Storage  │←───────┤    │ │                        │
│  │  │ Manager  │        └────┘ │                        │
│  │  └──────────┘                │                        │
│  └──────────────────────────────┘                        │
│                                                          │
│  ┌─────────────────────────────────────────────────┐   │
│  │               Hardware HAL                       │   │
│  └─────────────────────────────────────────────────┘   │
└──────────────────────────────────────────────────────────┘
                    │
                    ▼
           ┌────────────────┐
           │   SD Card      │
           └────────────────┘
```

### 2.3 Technology Stack

| Layer | Technology | Version |
|-------|-----------|---------|
| RTOS | Zephyr | 3.2.1 (via NCS) |
| MCU | Nordic nRF5340 | - |
| Audio Codec | Opus | 1.6.1 |
| Audio DSP | SpeexDSP | 1.2.1 (custom) |
| Build System | CMake / West | - |
| Language | C | C11 |

## 3. Module Decomposition

### 3.1 Hardware Abstraction Layer

#### 3.1.1 PDM Microphone Driver

**Purpose**: Capture audio from PDM microphones

**Responsibilities:**
- Configure PDM/I2S interface
- Manage double buffers
- Handle overflow/underrun
- Provide audio data to pipeline

**Interface:**
```c
int pdm_mic_init(const struct pdm_mic_config *config);
int pdm_mic_start(void);
int pdm_mic_stop(void);
int pdm_mic_read(int16_t *buffer, size_t frames);
```

**Configuration:**
- Sample rate: 16 kHz
- Channels: 1 (mono) or 2 (stereo)
- Buffer size: 2048 frames (double-buffered)
- Interface: I2S compatible PDM

**Dependencies:** Zephyr I2S driver

---

#### 3.1.2 SD Card Driver

**Purpose**: File system access on SD card

**Responsibilities:**
- Mount/unmount FAT32 filesystem
- File I/O operations
- Directory management
- Error detection and reporting

**Interface:**
```c
int sd_card_mount(void);
int sd_card_unmount(void);
int sd_card_write(const char *path, const void *data, size_t len);
int sd_card_read(const char *path, void *data, size_t len);
```

**Configuration:**
- File system: FAT32
- Mount point: `/SD:/`
- Block size: 512 bytes
- Write buffer: 4 KB

**Dependencies:** Zephyr FAT filesystem, SDHC-SPI driver

---

#### 3.1.3 BLE Controller

**Purpose**: BLE stack management

**Responsibilities:**
- Initialize BLE stack
- Manage advertising
- Handle connections
- GATT server operations

**Interface:**
```c
int ble_init(void);
int ble_start_advertising(void);
int ble_stop_advertising(void);
int ble_send_notification(uint16_t handle, const uint8_t *data, uint16_t len);
```

**Configuration:**
- Service UUID: 6E400001-B5A3-F393-E0A9-E50E24DCCA9E
- MTU: Negotiated (up to 517)
- Bonding: Required
- Encryption: Required

**Dependencies:** Zephyr BLE stack

---

#### 3.1.4 PMIC Driver (NPM1300)

**Purpose**: Power management IC control

**Responsibilities:**
- Monitor battery voltage
- Detect charging state
- Control power regulators
- Manage GPIOs

**Interface:**
```c
int pmic_init(void);
int pmic_get_battery(uint8_t *percent);
int pmic_is_charging(bool *charging);
int pmic_set_regulator(enum pmic_regulator reg, bool enable);
```

**Configuration:**
- I2C address: 0x6b
- Regulators: BUCK1, BUCK2, LDO1, LDO2
- GPIOs: 5 configurable

**Dependencies:** Zephyr I2C driver

---

#### 3.1.5 GPIO Driver

**Purpose**: GPIO pin control

**Responsibilities:**
- Configure GPIO pins
- Handle interrupts
- Button input
- LED output (if any)

**Interface:**
```c
int gpio_init(void);
int gpio_set_pin(uint32_t pin, int value);
int gpio_get_pin(uint32_t pin);
int gpio_configure_interrupt(uint32_t pin, gpio_callback_t callback);
```

**Key Pins:**
- GPIO1.15: User button (input, pull-up)
- GPIO1.14: Microphone power enable
- GPIO1.8: OLED power enable
- GPIO0.29: WiFi RF switch

**Dependencies:** Zephyr GPIO driver

---

#### 3.1.6 I2C/SPI Drivers

**Purpose**: Communication with peripherals

**Responsibilities:**
- I2C bus management (PMIC, OLED)
- SPI bus management (external flash)
- Transaction management

**Interface:**
```c
int i2c_write(uint8_t addr, const uint8_t *data, uint16_t len);
int i2c_read(uint8_t addr, uint8_t *data, uint16_t len);
int spi_write(const uint8_t *data, uint16_t len);
int spi_read(uint8_t *data, uint16_t len);
```

**Dependencies:** Zephyr I2C/SPI drivers

---

### 3.2 Audio Processing Layer

#### 3.2.1 Audio Capture Module

**Purpose**: Manage audio input pipeline

**Responsibilities:**
- Initialize PDM microphone
- Handle audio interrupts
- Fill circular buffer
- Detect overflows

**Interface:**
```c
int audio_capture_init(const struct audio_config *config);
int audio_capture_start(void);
int audio_capture_stop(void);
int audio_capture_read(int16_t *buffer, size_t frames);
```

**Thread:** Audio thread (priority 5)

**Data Flow:**
```
PDM MIC → I2S Driver → Audio Buffer → Circular Buffer
```

---

#### 3.2.2 SpeexDSP Processing Module

**Purpose**: Audio signal processing

**Responsibilities:**
- Noise suppression
- Dereverberation
- Automatic gain control
- Pre-processing for encoder

**Interface:**
```c
int speexdsp_init(const struct speexdsp_config *config);
int speexdsp_process(int16_t *input, int16_t *output, size_t frames);
int speexdsp_set_ns_level(int level_db);
int speexdsp_set_agc(bool enable, int target, int max_gain);
```

**Configuration:**
- Noise suppression: 0-60 dB
- Dereverberation: on/off, level, decay
- AGC: on/off, target level, max gain

**Memory:** ~10KB for state

**Dependencies:** lib/speexdsp/

---

#### 3.2.3 Opus Encoder Module

**Purpose**: Opus audio encoding

**Responsibilities:**
- Initialize Opus encoder
- Encode audio frames
- Manage encoder state
- Handle errors

**Interface:**
```c
int opus_encoder_init(int sample_rate, int channels, int bitrate);
int opus_encoder_encode(const int16_t *pcm, uint8_t *opus, size_t *len);
int opus_encoder_set_bitrate(int bitrate);
int opus_encoder_set_complexity(int complexity);
void opus_encoder_cleanup(void);
```

**Configuration:**
- Sample rate: 16 kHz
- Channels: 1 (mono) or 2 (stereo)
- Bitrate: 12000-64000 bps
- Frame size: 20 ms (320 samples)
- Complexity: 0-10

**Memory:** ~20KB for state

**Dependencies:** lib/opus/

---

#### 3.2.4 Mode Processing Module

**Purpose**: Handle different recording modes

**Responsibilities:**
- Mono/Stereo/Merge processing
- Normal/Enhanced file splitting
- Bitrate adaptation

**Interface:**
```c
int mode_processor_init(enum recording_mode mode);
int mode_processor_process(const int16_t *input, int16_t *output, size_t frames);
int mode_processor_get_channels(void);
int mode_processor_get_bitrate(void);
```

**Modes:**
- **Mono**: Single microphone, 1 channel
- **Stereo**: Dual microphones, 2 channels
- **Merge**: Stereo input, mixed to mono

**File Splitting:**
- Normal: 10 minutes per file
- Enhanced: 2 minutes per file

---

### 3.3 Storage Management Layer

#### 3.3.1 File System Module

**Purpose**: High-level file operations

**Responsibilities:**
- Create session directories
- Write audio files
- Manage file metadata
- Handle errors

**Interface:**
```c
int fs_init(void);
int fs_create_session(const char *session_id, struct session *session);
int fs_write_audio(const char *session_id, const uint8_t *data, size_t len);
int fs_write_metadata(const char *session_id, const struct session_meta *meta);
int fs_delete_session(const char *session_id);
```

**Directory Structure:**
```
/SD:/REC/
├── YYYYMMDDHHMMSS/
│   ├── session.json
│   ├── files.lst
│   ├── marks.bin
│   ├── 001.opus
│   ├── 002.opus
│   └── ...
```

---

#### 3.3.2 Session Manager

**Purpose**: Manage recording sessions

**Responsibilities:**
- Create new sessions
- Track active session
- Update session metadata
- Finalize sessions

**Interface:**
```c
int session_mgr_create(const char *session_id, struct session **out);
int session_mgr_add_file(struct session *session, const char *filename, size_t size);
int session_mgr_add_mark(struct session *session, const struct mark *mark);
int session_mgr_finalize(struct session *session);
int session_mgr_list(struct session_list **out);
int session_mgr_get(const char *session_id, struct session **out);
int session_mgr_delete(const char *session_id);
```

**Session Lifecycle:**
```
IDLE → CREATING → RECORDING → FINALIZING → COMPLETED
```

---

#### 3.3.3 Bookmark Manager

**Purpose**: Manage recording bookmarks

**Responsibilities:**
- Add bookmarks
- Store bookmarks (marks.bin)
- Retrieve bookmarks
- Serialize/deserialize

**Interface:**
```c
int bookmark_mgr_init(const char *session_id);
int bookmark_mgr_add(const struct mark *mark);
int bookmark_mgr_list(struct mark **marks, int *count);
int bookmark_mgr_save(void);
int bookmark_mgr_cleanup(void);
```

**Binary Format:**
```
[4 bytes magic "MRK1"]
[4 bytes count]
[Entry 1]...
```

---

#### 3.3.4 Purge Policy Manager

**Purpose**: Auto-delete old sessions

**Responsibilities:**
- Check auto-delete policy
- Identify purgeable sessions
- Execute purge

**Interface:**
```c
int purge_init(void);
int purge_check(void);  // Call periodically
int purge_get_purgeable(struct purge_info *info);
int purge_execute(void);
int purge_set_policy(enum purge_policy policy, int days);
```

**Policies:**
- `off`: Manual only
- `0`: Delete after transfer
- `1-30`: Delete N days after transfer

---

### 3.4 Communication Layer

#### 3.4.1 BLE GATT Server

**Purpose**: BLE GATT service implementation

**Responsibilities:**
- Register GATT service
- Handle writes (commands)
- Send notifications (responses, data)
- Manage connection

**Interface:**
```c
int ble_gatt_init(void);
int ble_gatt_send_response(const char *json, size_t len);
int ble_gatt_send_data(const uint8_t *data, size_t len);
int ble_gatt_get_mtu(uint16_t *mtu);
```

**Characteristics:**
- Command Receive: Write only
- Response Send: Notify
- File Data: Notify

---

#### 3.4.2 AT Command Parser

**Purpose**: Parse AT commands

**Responsibilities:**
- Parse command syntax
- Validate parameters
- Dispatch to handler
- Format responses

**Interface:**
```c
int at_parser_init(void);
int at_parser_parse(const char *cmd, struct at_command *out);
int at_parser_execute(const struct at_command *cmd, char **response);
void at_parser_cleanup(void);
```

**Command Structure:**
```c
struct at_command {
    enum at_type type;        // EXEC, SET, GET
    char name[16];            // Command name
    char *value;              // Parameter value
};
```

---

#### 3.4.3 JSON Serializer/Deserializer

**Purpose**: JSON parsing and generation

**Responsibilities:**
- Parse JSON requests
- Generate JSON responses
- Handle errors

**Interface:**
```c
int json_to_dict(const char *json, struct json_obj **out);
int json_get_string(struct json_obj *obj, const char *key, char **out);
int json_get_int(struct json_obj *obj, const char *key, int *out);
char *json_from_response(const struct response *resp);
void json_free(struct json_obj *obj);
```

**Implementation:** Minimal JSON parser (no heavy dependencies)

---

#### 3.4.4 File Transfer Manager

**Purpose**: Manage file transfer over BLE

**Responsibilities:**
- Transfer state machine
- Chunk reading and sending
- Progress tracking
- Pause/resume/cancel

**Interface:**
```c
int xfer_init(void);
int xfer_start(const char *path);
int xfer_pause(void);
int xfer_resume(void);
int xfer_cancel(void);
int xfer_get_progress(struct xfer_progress *progress);
int xfer_set_chunk_size(size_t size);
```

**State Machine:**
```
IDLE → TRANSMITTING → PAUSED → COMPLETED → IDLE
                    ↓                 ↓
                  CANCEL            ERROR
```

**Non-Blocking:** Allows AT command processing during transfer

---

### 3.5 Application Layer

#### 3.5.1 Recording Controller

**Purpose**: Main recording logic

**Responsibilities:**
- Start/stop recording
- Manage audio pipeline
- Handle bookmarks
- Coordinate modules

**Interface:**
```c
int rec_init(void);
int rec_start(enum recording_mode mode);
int rec_stop(void);
int rec_add_mark(const char *note);
bool rec_is_recording(void);
int rec_get_duration(uint32_t *seconds);
```

**State Machine:**
```
IDLE → RECORDING → IDLE
```

**Triggers:**
- AT+START command
- AT+STOP command
- Button long press

---

#### 3.5.2 Command Handler

**Purpose:** Process AT commands

**Responsibilities:**
- Dispatch commands
- Call appropriate handlers
- Generate responses
- Handle errors

**Interface:**
```c
int cmd_handler_init(void);
int cmd_handler_process(const char *cmd, char **response);
void cmd_handler_register(const char *name, cmd_func_t func);
```

**Command Registry:**
```c
struct cmd_entry {
    const char *name;
    cmd_func_t handler;
    enum cmd_type type;  // EXEC, SET, GET
};
```

**Example Command:**
```c
static int cmd_gstat(const struct at_command *cmd, char **response)
{
    struct gstat_data data = {
        .state = state_to_string(current_state),
        .battery = battery_percent,
        .charging = battery_charging,
        ...
    };
    return json_encode_success(&data, response);
}
```

---

#### 3.5.3 State Machine Manager

**Purpose**: Global device state

**Responsibilities:**
- Manage device states
- Handle transitions
- Notify state changes
- Validate state-dependent operations

**Interface:**
```c
int state_init(void);
int state_transition(enum device_state new_state);
enum device_state state_get_current(void);
const char *state_to_string(enum device_state state);
int state_register_callback(state_change_callback_t cb);
```

**States:**
```c
enum device_state {
    STATE_UNINITIALIZED,
    STATE_IDLE,
    STATE_RECORDING,
    STATE_TRANSMITTING,
    STATE_PAUSED,
    STATE_ERROR
};
```

**Transition Validation:**
```c
static bool is_valid_transition(enum device_state from, enum device_state to)
{
    switch (from) {
    case STATE_IDLE:
        return to == STATE_RECORDING || to == STATE_TRANSMITTING;
    case STATE_RECORDING:
        return to == STATE_IDLE;
    case STATE_TRANSMITTING:
        return to == STATE_PAUSED || to == STATE_IDLE;
    ...
    }
}
```

---

#### 3.5.4 Configuration Manager

**Purpose**: Persistent configuration storage

**Responsibilities:**
- Load/save configuration
- Provide config access
- Handle defaults
- Factory reset

**Interface:**
```c
int config_init(void);
int config_load(void);
int config_save(void);
int config_get(const char *key, void *value, size_t len);
int config_set(const char *key, const void *value, size_t len);
int config_reset(void);
```

**Storage:** Zephyr NVS (Non-Volatile Storage)

**Keys:**
- `bitrate`: uint16
- `complexity`: uint8
- `mode`: string
- `noise`: uint8
- `dereverb`: string
- `agc`: string
- `chunksize`: uint16
- `autodel`: string

---

### 3.6 User Interface Layer

#### 3.6.1 Button Input Handler

**Purpose**: Handle user button input

**Responsibilities:**
- Detect button presses
- Differentiate short/long press
- Trigger actions
- Provide feedback

**Interface:**
```c
int button_init(void);
int button_set_callback(button_event_t event, button_callback_t cb);
void button_irq_handler(void);  // Interrupt handler
```

**Events:**
```c
enum button_event {
    BUTTON_SHORT_PRESS,  // < 1 second
    BUTTON_LONG_PRESS,   // >= 1 second
};
```

**Device Tree Configuration:**
```dts
usr_btn: button {
    compatible = "input-device-gpio";
    gpios = <&gpio1 15 GPIO_ACTIVE_LOW>;
    label = "User Button";
    long-press-ms = <1000>;
};
```

**Logic:**
```
GPIO Interrupt → Timer Start → Button Release → Check Duration
                                       ↓
                    Duration >= 1s? ──Yes→ LONG_PRESS
                              │No
                              ↓
                         SHORT_PRESS
```

**Actions:**
- **Long Press**: Toggle recording (start/stop)
- **Short Press**: Add bookmark (during recording)

**Integration:**
```c
static void button_callback(enum button_event event)
{
    switch (event) {
    case BUTTON_LONG_PRESS:
        if (rec_is_recording()) {
            rec_stop();
        } else {
            rec_start(current_config.mode);
        }
        break;
    case BUTTON_SHORT_PRESS:
        if (rec_is_recording()) {
            rec_add_mark(NULL);
        }
        break;
    }
}
```

---

#### 3.6.2 Display Manager

**Purpose**: Update display content

**Responsibilities:**
- Render display content
- Update on events
- Format information
- Manage display state

**Interface:**
```c
int display_init(void);
int display_update(enum device_state state,
                   const struct battery_info *batt,
                   uint32_t rec_time);
int display_show_error(const char *error);
int display_clear(void);
```

---

#### 3.6.3 OLED Display Driver (Future)

**Purpose**: CH1115 OLED driver

**Responsibilities:**
- Initialize CH1115 over I2C
- Draw text and graphics
- Manage display buffer
- Update display

**Interface:**
```c
int oled_init(void);
int oled_clear(void);
int oled_write(uint8_t x, uint8_t y, const char *text);
int oled_update(void);
```

**Specifications:**
- Controller: CH1115
- Resolution: 88x48 pixels
- Interface: I2C
- Address: 0x3c
- Reset GPIO: gpio1.9

**Display Layout:**
```
┌──────────────────────┐
│  reSpeaker Clip      │  Row 0 (header)
│                      │  Row 1
│  State: RECORDING    │  Row 2
│  [REC] 01:23:45      │  Row 3
│                      │  Row 4
│  Batt: 85% ⚡        │  Row 5
│  Mode: Enhanced      │  Row 6
└──────────────────────┘
```

**Current Status**: Use UART serial output for development

---

#### 3.6.4 Haptic Motor Driver

**Purpose**: Haptic feedback

**Responsibilities:**
- Control vibration motor
- Generate patterns
- Manage timing

**Interface:**
```c
int haptic_init(void);
int haptic_pulse(uint16_t duration_ms);
int haptic_pattern(const uint16_t *pattern, int count);
```

**Implementation Status:**
- **Current Implementation**: Via LOG_INF() macros (logging feedback)
- **Future Implementation**: Actual motor control via PMIC GPIO2 (BUCK1 enable)

**Patterns:**
- Recording start: 100ms single pulse
- Recording stop: 50ms double pulse
- Bookmark: 30ms triple pulse
- Error: 200ms long pulse

**Current Implementation (Logging):**
```c
int haptic_pulse(uint16_t duration_ms)
{
    LOG_INF("[HAPTIC] Pulse: %u ms", duration_ms);
    return 0;
}

int haptic_pattern(const uint16_t *pattern, int count)
{
    LOG_INF("[HAPTIC] Pattern: %d pulses", count);
    for (int i = 0; i < count; i++) {
        LOG_INF("[HAPTIC]   Pulse %d: %u ms", i, pattern[i]);
    }
    return 0;
}
```

**Future Implementation (Motor Control):**
```c
int haptic_pulse(uint16_t duration_ms)
{
    // Enable motor via PMIC GPIO2
    gpio_set_pin(PMIC_GPIO_MOTOR, 1);
    k_sleep(K_MSEC(duration_ms));
    gpio_set_pin(PMIC_GPIO_MOTOR, 0);
    return 0;
}
```

**Control:** Via PMIC GPIO2 (BUCK1 enable)

---

## 4. Data Flow Architecture

### 4.1 Audio Recording Flow

```
┌─────────────────────────────────────────────────────────────┐
│                      Audio Recording Pipeline                │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  PDM Microphone                                             │
│  (I2S compatible, 16kHz)                                    │
│         │                                                   │
│         ▼                                                   │
│  I2S Driver (DMA)                                           │
│  ┌──────────────┐  ┌──────────────┐                        │
│  │  Buffer A    │  │  Buffer B    │  Double buffering      │
│  │  (2048 fr)   │  │  (2048 fr)   │                        │
│  └──────────────┘  └──────────────┘                        │
│         │                                                   │
│         ▼                                                   │
│  Audio Capture Module                                       │
│  (ISR fills circular buffer)                                │
│         │                                                   │
│         ▼                                                   │
│  Circular Buffer (32KB)                                     │
│  ┌──────────────────────────────────────────┐              │
│  │  [Frame1][Frame2][Frame3]...[FrameN]     │              │
│  └──────────────────────────────────────────┘              │
│         │                                                   │
│         ▼                                                   │
│  Mode Processor                                             │
│  (Mono/Stereo/Merge)                                        │
│         │                                                   │
│         ▼                                                   │
│  SpeexDSP                                                   │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐                 │
│  │ Noise    │→│ Dereverb │→│ AGC      │                 │
│  │ Suppress │  │          │  │          │                 │
│  └──────────┘  └──────────┘  └──────────┘                 │
│         │                                                   │
│         ▼                                                   │
│  Opus Encoder                                               │
│  (20ms frames, 320 samples)                                 │
│         │                                                   │
│         ▼                                                   │
│  ┌─────────────────────────────────────────────┐           │
│  │  [2 bytes len][Opus frame][2 bytes len]...  │           │
│  └─────────────────────────────────────────────┘           │
│         │                                                   │
│         ▼                                                   │
│  Storage Manager                                            │
│  ┌─────────────────────────────────────────────┐           │
│  │  Split into files (2min/10min)              │           │
│  │  Write to SD: /SD:/REC/SESSION/NNN.opus     │           │
│  └─────────────────────────────────────────────┘           │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

**Buffer Sizes:**
- PDM buffer: 2048 frames × 2 channels × 2 bytes = 8 KB × 2 = 16 KB
- Circular buffer: 32 KB
- Opus output: ~500 bytes/frame × 50 frames = 25 KB

---

### 4.2 File Transfer Flow

```
┌─────────────────────────────────────────────────────────────┐
│                    File Transfer Pipeline                   │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  SD Card File                                               │
│  ┌─────────────────────────────────────────────┐           │
│  │  001.opus (720 KB)                          │           │
│  └─────────────────────────────────────────────┘           │
│         │                                                   │
│         ▼                                                   │
│  File Open                                                  │
│  (fp = fopen("/SD:/REC/SESSION/001.opus", "r"))             │
│         │                                                   │
│         ▼                                                   │
│  Transfer Loop                                              │
│  ┌─────────────────────────────────────────────┐           │
│  │  while (!feof(fp)) {                         │           │
│  │      chunk = read(fp, chunk_size);          │           │
│  │      if (chunk < chunk_size) {              │           │
│  │          // Last chunk                      │           │
│  │      }                                      │           │
│  │      send_via_ble(chunk);                   │           │
│  │      update_progress();                     │           │
│  │  }                                          │           │
│  └─────────────────────────────────────────────┘           │
│         │                                                   │
│         ▼                                                   │
│  BLE GATT Notification                                      │
│  (Characteristic: 6E400004-B5A3-F393-E0A9-E50E24DCCA9E)     │
│         │                                                   │
│         ▼                                                   │
│  Mobile App                                                 │
│  (Reconstructs file)                                        │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

**Non-Blocking Command Handling:**
```
Transfer in progress...
    ↓
AT+GSTAT received
    ↓
Pause transfer temporarily
    ↓
Process AT+GSTAT → Send response
    ↓
Resume transfer
```

---

### 4.3 Command Processing Flow

```
┌─────────────────────────────────────────────────────────────┐
│                    Command Processing                       │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  Mobile App                                                 │
│  (Write to Command Characteristic)                          │
│         │                                                   │
│         ▼                                                   │
│  BLE GATT Write Callback                                    │
│  (ble_gatt_write_cb)                                       │
│         │                                                   │
│         ▼                                                   │
│  AT Parser                                                  │
│  ┌─────────────────────────────────────────────┐           │
│  │  Parse: AT+BITRATE=24000                    │           │
│  │  type: SET                                  │           │
│  │  name: BITRATE                              │           │
│  │  value: "24000"                             │           │
│  └─────────────────────────────────────────────┘           │
│         │                                                   │
│         ▼                                                   │
│  Command Handler                                            │
│  ┌─────────────────────────────────────────────┐           │
│  │  Lookup: "BITRATE" → cmd_bitrate_handler    │           │
│  │  Execute: Set bitrate to 24000              │           │
│  │  Save to NVS                                │           │
│  └─────────────────────────────────────────────┘           │
│         │                                                   │
│         ▼                                                   │
│  Response Generator                                         │
│  ┌─────────────────────────────────────────────┐           │
│  │  {"ok": true, "value": 24000}               │           │
│  └─────────────────────────────────────────────┘           │
│         │                                                   │
│         ▼                                                   │
│  BLE GATT Notification                                      │
│  (Send to Response Characteristic)                          │
│         │                                                   │
│         ▼                                                   │
│  Mobile App                                                 │
│  (Receive and parse JSON)                                   │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

---

### 4.4 Button Event Flow

```
┌─────────────────────────────────────────────────────────────┐
│                      Button Event Flow                      │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  User Presses Button                                        │
│  (GPIO1.15 goes LOW)                                       │
│         │                                                   │
│         ▼                                                   │
│  GPIO Interrupt                                             │
│  (gpio1.15 IRQ handler)                                     │
│         │                                                   │
│         ▼                                                   │
│  Button Driver                                              │
│  ┌─────────────────────────────────────────────┐           │
│  │  Start Timer                                │           │
│  │  Wait for GPIO HIGH (release)               │           │
│  │  Check timer value                          │           │
│  │      └─ ≥ 1000ms → LONG_PRESS               │           │
│  │      └─ < 1000ms → SHORT_PRESS              │           │
│  └─────────────────────────────────────────────┘           │
│         │                                                   │
│         ▼                                                   │
│  Recording Controller                                       │
│  ┌─────────────────────────────────────────────┐           │
│  │  if (LONG_PRESS) {                          │           │
│  │      if (recording) {                       │           │
│  │          rec_stop();                        │           │
│  │      } else {                               │           │
│  │          rec_start(current_mode);           │           │
│  │      }                                      │
│  │  } else if (SHORT_PRESS) {                  │           │
│  │      if (recording) {                       │
│  │          rec_add_mark(NULL);                │           │
│  │      }                                      │
│  │  }                                          │           │
│  └─────────────────────────────────────────────┘           │
│         │                                                   │
│         ▼                                                   │
│  Haptic Feedback                                            │
│  (Pulse motor for confirmation)                             │
│         │                                                   │
│         ▼                                                   │
│  Display Update                                             │
│  (Show new state)                                           │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

## 5. Thread Architecture

### 5.1 Thread Responsibilities

```c
// Zephyr thread priorities: -15 (cooperative) to 7 (preemptive)

┌─────────────────────────────────────────────────────────────┐
│                      Thread Architecture                    │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  Priority -15: Cooperative (never preempts)                 │
│  ┌──────────────────────┐                                  │
│  │ (None - use preemptive for responsiveness)              │
│  └──────────────────────┘                                  │
│                                                             │
│  Priority 0: Main Thread                                   │
│  ┌──────────────────────┐                                  │
│  │ - Initialization     │                                  │
│  │ - Status monitoring  │                                  │
│  │ - Low priority tasks │                                  │
│  └──────────────────────┘                                  │
│                                                             │
│  Priority 3: SD Card Thread                                │
│  ┌──────────────────────┐                                  │
│  │ - Async file I/O     │                                  │
│  │ - Write operations   │                                  │
│  └──────────────────────┘                                  │
│                                                             │
│  Priority 5: Audio Thread                                  │
│  ┌──────────────────────┐                                  │
│  │ - Audio capture      │                                  │
│  │ - DSP processing     │                                  │
│  │ - Opus encoding      │                                  │
│  └──────────────────────┘                                  │
│                                                             │
│  Priority 6: Button Handler Thread                         │
│  ┌──────────────────────┐                                  │
│  │ - Button debouncing  │                                  │
│  │ - Event detection    │                                  │
│  └──────────────────────┘                                  │
│                                                             │
│  Priority 7: BLE Thread (Zephyr internal)                  │
│  ┌──────────────────────┐                                  │
│  │ - BLE stack          │                                  │
│  │ - GATT operations    │                                  │
│  └──────────────────────┘                                  │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

### 5.2 Thread Priorities

| Thread | Priority | Stack Size | Preemptible |
|--------|----------|------------|-------------|
| Main | 0 | 8 KB | Yes |
| SD Card | 3 | 4 KB | Yes |
| Audio | 5 | 32 KB | Yes |
| Button | 6 | 2 KB | Yes |
| BLE | 7 | 8 KB | Yes (internal) |

**Priority Rationale:**
- **BLE (7)**: Highest priority for reliable communication
- **Button (6)**: Responsive UI
- **Audio (5)**: Real-time processing, but tolerates brief delays
- **SD Card (3)**: Important but not time-critical
- **Main (0)**: Background tasks, monitoring

### 5.3 Inter-Thread Communication

**Semaphores (k_sem):**
- Audio buffer ready signal
- SD write completion
- BLE send completion

**Work Queues (k_work):**
- Defer work from ISR
- Display updates
- Progress notifications

**Message Queues (k_msgq):**
- Audio data to encoder
- Commands to handler

**Example: Audio Thread Communication**
```c
// Producer (ISR)
void i2s_callback(const struct device *dev, void *user_data)
{
    k_sem_give(&audio_data_ready);
}

// Consumer (Audio Thread)
void audio_thread(void)
{
    while (1) {
        k_sem_take(&audio_data_ready, K_FOREVER);
        process_audio();
    }
}
```

### 5.4 Synchronization Primitives

**Memory Slabs (k_mem_slab):**
- Fixed-size audio blocks
- Efficient allocation

**Mutexes (k_mutex):**
- Session manager access
- Configuration access
- Display access

**Atomic Variables:**
- State flags
- Progress counters
- Battery level

**Example: Safe State Access**
```c
static enum device_state current_state;
static k_mutex state_lock;

enum device_state state_get_current(void)
{
    enum device_state state;
    k_mutex_lock(&state_lock, K_FOREVER);
    state = current_state;
    k_mutex_unlock(&state_lock);
    return state;
}
```

## 6. Memory Architecture

### 6.1 Memory Layout

**nRF5340 Total SRAM: 512KB**
- 64KB allocated to BLE core (dedicated)
- **448KB available for application**

```
┌─────────────────────────────────────────────────────────────┐
│                 Application SRAM (448 KB)                   │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  ┌───────────────────────────────────────────────────┐     │
│  │  Thread Stacks (96 KB)                            │     │
│  │  ├─ Main: 16 KB                                  │     │
│  │  ├─ SD Card: 8 KB                                │     │
│  │  ├─ Audio: 64 KB                                 │     │
│  │  ├─ Button: 4 KB                                 │     │
│  │  └─ BLE: 4 KB (application callbacks)            │     │
│  └───────────────────────────────────────────────────┘     │
│                                                             │
│  ┌───────────────────────────────────────────────────┐     │
│  │  Audio Buffer (64 KB)                             │     │
│  │  └─ 32 blocks × 2 KB each                        │     │
│  └───────────────────────────────────────────────────┘     │
│                                                             │
│  ┌───────────────────────────────────────────────────┐     │
│  │  Codec State (30 KB)                              │     │
│  │  ├─ Opus Encoder: 20 KB                           │     │
│  │  └─ SpeexDSP: 10 KB                              │     │
│  └───────────────────────────────────────────────────┘     │
│                                                             │
│  ┌───────────────────────────────────────────────────┐     │
│  │  Buffers (24 KB)                                  │     │
│  │  ├─ SD Card write: 8 KB                           │     │
│  │  ├─ Protocol buffer: 8 KB                         │     │
│  │  └─ Transfer chunk: 8 KB (configurable)           │     │
│  └───────────────────────────────────────────────────┘     │
│                                                             │
│  ┌───────────────────────────────────────────────────┐     │
│  │  Heap / Dynamic (64 KB)                           │     │
│  │  └─ Malloc pool                                   │     │
│  └───────────────────────────────────────────────────┘     │
│                                                             │
│  ┌───────────────────────────────────────────────────┐     │
│  │  Global Data (~30 KB)                             │     │
│  │  ├─ Session data: 10 KB                           │     │
│  │  ├─ Configuration: 5 KB                           │     │
│  │  ├─ State machine: 2 KB                           │     │
│  │  └─ Other: 13 KB                                  │     │
│  └───────────────────────────────────────────────────┘     │
│                                                             │
│  ┌───────────────────────────────────────────────────┐     │
│  │  Reserved (~140 KB)                               │     │
│  └───────────────────────────────────────────────────┘     │
│                                                             │
└─────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│                  BLE Core SRAM (64 KB)                      │
│                        (Dedicated)                          │
└─────────────────────────────────────────────────────────────┘
```

### 6.2 Buffer Management

**Audio Buffer (Circular Buffer):**
```c
#define AUDIO_BLOCK_SIZE  2048  // frames
#define AUDIO_BLOCK_COUNT 8
#define AUDIO_BUFFER_SIZE (AUDIO_BLOCK_SIZE * AUDIO_BLOCK_COUNT)

struct audio_buffer {
    int16_t data[AUDIO_BUFFER_SIZE];
    size_t read_pos;
    size_t write_pos;
    k_sem sem_ready;
};
```

**Memory Pool (Dynamic Blocks):**
```c
#define BLOCK_SIZE 1024
#define BLOCK_COUNT 16

K_MEM_POOL_DEFINE(audio_pool, BLOCK_SIZE, BLOCK_SIZE, BLOCK_COUNT, 4);

void *allocate_block(void)
{
    return k_mem_pool_malloc(&audio_pool, BLOCK_SIZE);
}
```

### 6.3 Memory Pools

**Audio Blocks:**
- Size: 2 KB
- Count: 16
- Total: 32 KB
- Purpose: Audio data pipeline

**SD Card Blocks:**
- Size: 1 KB
- Count: 4
- Total: 4 KB
- Purpose: File write buffering

### 6.4 Stack Sizing

**Thread Stack Analysis:**

| Thread | Utilization | Max | Reserved |
|--------|-------------|-----|----------|
| Main | ~6 KB | 16 KB | 10 KB headroom |
| Audio | ~48 KB | 64 KB | 16 KB headroom |
| SD Card | ~4 KB | 8 KB | 4 KB headroom |
| Button | ~2 KB | 4 KB | 2 KB headroom |
| BLE callbacks | ~2 KB | 4 KB | 2 KB headroom |

**Stack Usage Analysis:**
- Audio thread has largest stack (Opus + SpeexDSP call chains)
- Monitor with `CONFIG_STACK_SENTINEL`
- Adjust based on runtime analysis

## 7. State Machine Design

### 7.1 Global State Machine

```
┌─────────────────────────────────────────────────────────────┐
│                    Device State Machine                     │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│   ┌──────────────┐                                         │
│   │UNINITIALIZED │                                         │
│   └──────┬───────┘                                         │
│          │ boot_complete                                   │
│          ▼                                                 │
│   ┌──────────────┐  long_press/AT+START  ┌──────────┐    │
│   │     IDLE     │─────────────────────────→│RECORDING  │    │
│   └──────┬───────┘                         └─────┬────┘    │
│          │                                       │         │
│          │ AT+DOWNLOAD                          │ long_press/AT+STOP
│          │                                       │         │
│          ▼                                       │         │
│   ┌──────────────┐                         ┌─────┴─────┐    │
│   │TRANSMITTING  │←────────────────────────│    IDLE    │    │
│   └──────┬───────┘    AT+PAUSE             └───────────┘    │
│          │                                                       │
│          │ AT+PAUSE                                    │        │
│          ▼                                                       │
│   ┌──────────────┐                                         │
│   │    PAUSED    │────────────────┐                        │
│   └──────┬───────┘                 │                        │
│          │                         │                        │
│          │ AT+RESUME               │ AT+CANCEL/Error        │
│          │                         ▼                        │
│          └────────────►TRANSMITTING          IDLE            │
│                              │                │               │
│                              │ completion/    │               │
│                              │ Error          │               │
│                              ▼                │               │
│                           ┌─────┴─────────────┘               │
│                           │     IDLE                         │
│                           └─────────────────────────────────┘ │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

**State Transitions:**

| From | To | Trigger | Action |
|------|-----|---------|--------|
| UNINITIALIZED | IDLE | Boot complete | Init complete |
| IDLE | RECORDING | Button long press, AT+START | Create session, start audio |
| RECORDING | IDLE | Button long press, AT+STOP | Finalize session, stop audio |
| IDLE | TRANSMITTING | AT+DOWNLOAD | Open file, start transfer |
| TRANSMITTING | PAUSED | AT+PAUSE, disconnect | Pause transfer |
| PAUSED | TRANSMITTING | AT+RESUME | Resume transfer |
| TRANSMITTING | IDLE | Completion, AT+CANCEL | Close file |
| Any | ERROR | Error condition | Report error |
| ERROR | IDLE | Recovery | Reset state |

### 7.2 Recording State Machine

```
┌─────────────────────────────────────────────────────────────┐
│                    Recording State Machine                  │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│    ┌─────────┐  long_press (≥1s) / AT+START    ┌─────────┐ │
│    │   IDLE  │ ──────────────────────────────> │RECORDING│ │
│    └─────────┘                                   └────┬────┘ │
│         ▲                                             │     │
│         │          long_press (≥1s) / AT+STOP          │     │
│         │ <───────────────────────────────────────────┘     │
│         │                                                   │
│         │                                                   │
│    short_press (<1s)  ── Add bookmark (only during RECORDING)
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

**Recording-Specific Actions:**
- **IDLE → RECORDING**:
  1. Create session directory
  2. Initialize session.json
  3. Start audio pipeline
  4. Enable button bookmarks
  5. Update display

- **RECORDING → IDLE**:
  1. Stop audio pipeline
  2. Close all files
  3. Finalize session.json
  4. Disable button bookmarks
  5. Update display

- **During RECORDING (short press)**:
  1. Get current timestamp
  2. Calculate offset
  3. Add bookmark to marks.bin
  4. Send notification
  5. Haptic feedback

### 7.3 Transfer State Machine

```
┌─────────────────────────────────────────────────────────────┐
│                    Transfer State Machine                   │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│    ┌──────────┐      AT+DOWNLOAD=file      ┌─────────────┐  │
│    │   IDLE   │ ──────────────────────────>│TRANSMITTING │  │
│    └──────────┘                             └──────┬──────┘  │
│         ▲                                         │         │
│         │         AT+PAUSE / Disconnect            │         │
│         │                 │                       │         │
│         │                 ▼                       │         │
│         │          ┌───────────┐                  │         │
│         │          │  PAUSED   │                  │         │
│         │          └─────┬─────┘                  │         │
│         │                │                        │         │
│         │    ┌───────────┴────────────┐           │         │
│         │    │                        │           │         │
│         │    ▼                        ▼           │         │
│         │ AT+RESUME              AT+CANCEL       │         │
│         │    │                        │          │         │
│         │    └────────────────────────┼──────────┘         │
│         │                             │                    │
│         └─────────────────────────────┼────────────────────┘
│                                       │
│         ┌─────────────────────────────┴────────────────┐   │
│         │                  Completion / Error          │   │
│         ▼                                               │   │
│    ┌──────────┐                                         │   │
│    │   IDLE   │<────────────────────────────────────────┘   │
│    └──────────┘                                              │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

**Transfer-Specific Actions:**

- **IDLE → TRANSMITTING**:
  1. Open file
  2. Get file size
  3. Initialize transfer context
  4. Send start response

- **During TRANSMITTING**:
  1. Read chunk (chunk_size bytes)
  2. Send via BLE notify
  3. Update progress
  4. Check for pause command
  5. Repeat until EOF

- **TRANSMITTING → PAUSED**:
  1. Stop sending data
  2. Keep file open
  3. Save current position

- **PAUSED → TRANSMITTING**:
  1. Resume sending from saved position
  2. Continue until EOF

- **TRANSMITTING/PAUSED → IDLE**:
  1. Close file
  2. Create .transferred marker
  3. Send completion response
  4. Clear transfer context

### 7.4 BLE Connection State Machine

```
┌─────────────────────────────────────────────────────────────┐
│                   BLE Connection State Machine              │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│    ┌─────────────┐                                         │
│    │DISCONNECTED │<─────────────────────────┐              │
│    └──────┬──────┘                          │              │
│           │ Connect / Auto-advertise        │              │
│           ▼                                 │              │
│    ┌─────────────┐                         │              │
│    │ CONNECTING  │                         │              │
│    └──────┬──────┘                         │              │
│           │ Connected                      │              │
│           ▼                                 │              │
│    ┌─────────────┐   Bonding required?   ┌──┴──────┐     │
│    │ CONNECTED   │ ────────────────────>│PAIRING  │     │
│    └──────┬──────┘                      └─────┬────┘     │
│           │                                    │          │
│           │ Paired                             │          │
│           ▼                                    │          │
│    ┌─────────────┐                            │          │
│    │   BONDED    │<───────────────────────────┘          │
│    └──────┬──────┘                                        │
│           │                                               │
│           │ Disconnect / AT+PAIR=reset                    │
│           └───────────────────────────────────────────────┘
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

**Connection-Specific Actions:**

- **DISCONNECTED**:
  - Auto-advertise
  - Wait for connection

- **CONNECTED**:
  - Check if bonded
  - Start pairing if needed
  - Notify app of connection

- **PAIRING**:
  - Execute LE Secure Connections
  - Wait for pairing completion
  - Store bond information

- **BONDED**:
  - Full access to commands
  - Allow file transfer
  - Auto-reconnect on disconnect

## 8. Error Handling Strategy

### 8.1 Error Categories

| Category | Examples | Severity | Recovery |
|----------|----------|----------|----------|
| Audio Overflow | PDM buffer overflow | Low | Skip frame |
| Audio Underrun | Encoder starvation | Medium | Stop recording |
| SD Card Error | Write failure | High | Stop recording, preserve data |
| BLE Disconnect | Connection lost | Medium | Pause transfer, reconnect |
| Low Battery | < 10% charge | High | Prevent new recording |
| Storage Full | No space | High | Prevent recording |
| File Not Found | Session missing | Low | Return error |
| Encoder Error | Opus failure | High | Stop recording |

### 8.2 Error Detection

**Audio Errors:**
```c
// Detect overflow in ISR
if (i2s_status & I2S_STATUS_OVERFLOW) {
    error_count.audio_overflow++;
    // Skip current frame
}
```

**SD Card Errors:**
```c
int result = fs_write(&file, data, len);
if (result < 0) {
    error_set(ERROR_SD_WRITE);
    return result;
}
```

**BLE Errors:**
```c
int result = bt_gatt_notify(conn, &tx_params);
if (result == -EIO) {
    error_set(ERROR_BLE_DISCONNECT);
    transfer_pause();
}
```

### 8.3 Error Recovery

**Graceful Degradation:**
- Audio overflow: Skip frame, continue
- Transfer paused: Auto-resume on reconnect
- Low battery: Allow recording to complete, prevent new

**Resource Cleanup:**
- On recording error: Close files, finalize session
- On transfer error: Delete partial file, return to IDLE
- On memory error: Reboot device

**Error Reporting:**
- LOG_ERR() for debugging
- JSON error response to app
- Display error state on screen

### 8.4 Error Reporting

**Logging:**
```c
LOG_ERR("SD card write error: %d", result);
```

**JSON Response:**
```json
{
  "ok": false,
  "error": "SD card write error"
}
```

**Display:**
```
State: ERROR
Error: SD card error
```

### 8.5 Graceful Degradation

**Recording with Issues:**
- Encountered SD card error → Stop recording, preserve what was recorded
- Encountered encoder error → Stop recording, keep valid data
- Low battery → Allow current recording to finish

**Transfer with Issues:**
- BLE disconnect → Pause transfer, wait for reconnect
- Reconnect timeout → Return to IDLE, don't create .transferred
- App cancel → Clean up, don't mark as transferred

## 9. User Interface Implementation

### 9.1 Button Input Handler

**Device Tree Configuration:**
```dts
/ {
    gpio_keys {
        compatible = "gpio-keys";
        user_button: button_0 {
            label = "User Button";
            gpios = <&gpio1 15 GPIO_ACTIVE_LOW>;
            long-press-ms = <1000>;
        };
    };
};
```

**Event Definitions:**
```c
#define BUTTON_SHORT_PRESS  0  // < 1 second
#define BUTTON_LONG_PRESS   1  // >= 1 second
```

**Callback Registration:**
```c
static void button_callback(enum button_event event, void *user_data)
{
    switch (event) {
    case BUTTON_SHORT_PRESS:
        if (state_get_current() == STATE_RECORDING) {
            rec_add_mark(NULL);
        }
        break;
    case BUTTON_LONG_PRESS:
        if (state_get_current() == STATE_RECORDING) {
            rec_stop();
        } else {
            rec_start(current_config.mode);
        }
        break;
    }
}

void init_button(void)
{
    button_set_callback(BUTTON_SHORT_PRESS, button_callback, NULL);
    button_set_callback(BUTTON_LONG_PRESS, button_callback, NULL);
}
```

---

### 9.2 Display System

#### 9.2.1 UART Serial Output (Initial Implementation)

Display content via serial logging for debugging:

```c
void display_update(rec_state_t state, battery_info_t *batt, uint32_t rec_time)
{
    LOG_INF("========================================");
    LOG_INF("      reSpeaker Clip");
    LOG_INF("");
    LOG_INF("  State: %s", state_to_string(state));
    if (state == RECORDING) {
        uint32_t hours = rec_time / 3600;
        uint32_t mins = (rec_time % 3600) / 60;
        uint32_t secs = rec_time % 60;
        LOG_INF("  [REC] %02u:%02u:%02u", hours, mins, secs);
    }
    LOG_INF("");
    LOG_INF("  Batt: %u%% %s", batt->percent,
            batt->charging ? "[CHARGING]" : "");
    LOG_INF("  Mode: %s", mode_to_string(current_mode));
    LOG_INF("  %s %s", bitrate_to_string(current_bitrate),
            channels_to_string(current_channels));
    LOG_INF("========================================");
}
```

**Output Example:**
```
========================================
      reSpeaker Clip

  State: RECORDING
  [REC] 00:05:23

  Batt: 85% [CHARGING]
  Mode: Enhanced
  48kHz Stereo
========================================
```

---

#### 9.2.2 OLED Display Layout (Future Implementation)

**CH1115 Specifications:**
- Controller: CH1115
- Resolution: 88 × 48 pixels
- Interface: I2C
- Address: 0x3c
- Font: 6 × 8 pixels (typical)
- Rows: 48 / 8 = 6 text rows
- Columns: 88 / 6 = ~14 characters

**Display Layout:**
```
Row 0: reSpeaker Clip    (Header)
Row 1: (empty)
Row 2: State: RECORDING  (Current state)
Row 3: [REC] 00:05:23    (Icon + Time)
Row 4: (empty)
Row 5: Batt: 85% ⚡      (Battery + charging)
Row 6: Mode: Enhanced    (Settings)
Row 7: 48kHz Stereo      (Bitrate/channels)
```

**Display Update Function:**
```c
void oled_display_update(rec_state_t state,
                        battery_info_t *batt,
                        uint32_t rec_time)
{
    char line[16];

    // Row 0: Header
    oled_write(0, 0, "reSpeaker Clip");

    // Row 2: State
    snprintf(line, sizeof(line), "State: %s",
             state_to_string_short(state));
    oled_write(0, 2, line);

    // Row 3: Time (if recording)
    if (state == RECORDING) {
        uint32_t hours = rec_time / 3600;
        uint32_t mins = (rec_time % 3600) / 60;
        uint32_t secs = rec_time % 60;
        snprintf(line, sizeof(line), "[REC] %02u:%02u:%02u",
                 hours, mins, secs);
        oled_write(0, 3, line);
    }

    // Row 5: Battery
    snprintf(line, sizeof(line), "Batt: %u%% %s",
             batt->percent,
             batt->charging ? "+" : "");
    oled_write(0, 5, line);

    // Row 6: Mode
    snprintf(line, sizeof(line), "Mode: %s",
             mode_to_string(current_mode));
    oled_write(0, 6, line);

    // Row 7: Bitrate/Channels
    snprintf(line, sizeof(line), "%ukHz %s",
             sample_rate / 1000,
             channels_to_string_short(current_channels));
    oled_write(0, 7, line);
}
```

---

### 9.3 Display Update Triggers

Display updates on:
- State changes (immediate)
- Recording time increment (every second)
- Battery level change (> 5% change)
- Mode/settings changes (immediate)
- Error conditions (immediate)

**Implementation:**
```c
static struct k_work display_work;

static void display_work_handler(struct k_work *work)
{
    display_update(current_state, &battery_info, recording_time);
}

void schedule_display_update(void)
{
    k_work_submit(&display_work);
}

// Timer for periodic updates
void display_timer_callback(struct k_timer *timer)
{
    schedule_display_update();
}

K_TIMER_DEFINE(display_timer, display_timer_callback, NULL);

// Start 1-second periodic updates
void display_start_periodic(void)
{
    k_timer_start(&display_timer, K_SECONDS(1), K_SECONDS(1));
}
```

---

### 9.4 Haptic Feedback Patterns

**Current Implementation (Logging):**
```c
void haptic_feedback(enum haptic_event event)
{
    switch (event) {
    case HAPTIC_RECORDING_START:
        LOG_INF("[HAPTIC] Recording start: 100ms pulse");
        haptic_pulse(100);  // Currently logs, future: motor control
        break;
    case HAPTIC_RECORDING_STOP:
        LOG_INF("[HAPTIC] Recording stop: 50ms double pulse");
        haptic_double_pulse(50, 50);  // Currently logs
        break;
    case HAPTIC_BOOKMARK:
        LOG_INF("[HAPTIC] Bookmark: 30ms triple pulse");
        haptic_triple_pulse(30, 30);  // Currently logs
        break;
    case HAPTIC_ERROR:
        LOG_INF("[HAPTIC] Error: 200ms long pulse");
        haptic_pulse(200);  // Currently logs
        break;
    }
}
```

**Future Implementation (Motor Control):**
```c
// Same API, but haptic_pulse() will actually control motor
void haptic_pulse(uint16_t duration_ms)
{
    // Enable motor via PMIC GPIO2
    gpio_set_pin(PMIC_GPIO_MOTOR, 1);
    k_sleep(K_MSEC(duration_ms));
    gpio_set_pin(PMIC_GPIO_MOTOR, 0);
}
```

## 10. Integration Points

### 10.1 Zephyr RTOS Integration

**Kconfig Integration:**
```kconfig
source "Kconfig.zephyr"

# Audio Configuration
config AUDIO_DMIC_MODE
    int "DMIC Mode"
    default 0

config SAMPLE_RATE
    int "Sample Rate"
    default 16000

# Opus Configuration
config OPUS_BITRATE
    int "Opus Bitrate"
    default 24000

# Recording Configuration
config RECORDING_MODE
    int "Recording Mode"
    default 0  # 0=normal, 1=enhanced
```

**Devicetree Integration:**
```dts
&pdm0 {
    status = "okay";
    label = "PDM_0";
};

&i2c1 {
    status = "okay";
    pmic: npm1300@6b {
        compatible = "nordic,npm1300";
        reg = <0x6b>;
        label = "NPM1300";
    };
};
```

---

### 10.2 Opus Codec Integration

**Header:**
```c
#include <opus/opus.h>
```

**Initialization:**
```c
OpusEncoder *opus_enc;
int opus_error;

opus_enc = opus_encoder_create(SAMPLE_RATE,
                                CHANNELS,
                                OPUS_APPLICATION_VOIP,
                                &opus_error);

opus_encoder_ctl(opus_enc, OPUS_SET_BITRATE(bitrate));
opus_encoder_ctl(opus_enc, OPUS_SET_COMPLEXITY(complexity));
```

**Encoding:**
```c
uint8_t opus_out[MAX_PACKET_SIZE];
opus_int32 pcm[MAX_FRAME_SIZE];

// Read PCM samples...
read_pcm_samples(pcm, FRAME_SIZE);

// Encode
int len = opus_encode(opus_enc,
                      pcm,
                      FRAME_SIZE,
                      opus_out,
                      MAX_PACKET_SIZE);

// Write opus_out (len bytes) to file
```

---

### 10.3 SpeexDSP Integration

**Header:**
```c
#include <speex/speex_preprocess.h>
```

**Initialization:**
```c
SpeexPreprocessState *st;

st = speex_preprocess_init(FRAME_SIZE, SAMPLE_RATE);

// Set parameters
int noise_suppress = 30;  // dB
speex_preprocess_ctl(st, SPEEX_PREPROCESS_SET_NOISE_SUPPRESS,
                      &noise_suppress);

int agc_level = 8000;
speex_preprocess_ctl(st, SPEEX_PREPROCESS_SET_AGC_TARGET,
                      &agc_level);
```

**Processing:**
```c
// For each frame
speex_preprocess_run(st, pcm_frame);
```

---

### 10.4 BLE Stack Integration

**Service Registration:**
```c
static struct bt_uuid_128 ble_service_uuid = {
    .uuid = BT_UUID_INIT_128(
        0x9E, 0xCC, 0x4D, 0x24, 0x0E, 0xE5, 0xA9, 0xE0,
        0x93, 0xF3, 0xA3, 0xB5, 0x01, 0x00, 0x40, 0x6E
    )
};

BT_GATT_SERVICE_DEFINE(clip_svc,
    BT_GATT_CHARACTERISTIC(
        &cmd_recv_uuid.uuid,
        BT_GATT_CHRC_WRITE,
        BT_GATT_PERM_WRITE,
        NULL, cmd_write_cb, NULL
    ),
    BT_GATT_CHARACTERISTIC(
        &resp_send_uuid.uuid,
        BT_GATT_CHRC_NOTIFY,
        BT_GATT_PERM_READ,
        NULL, NULL, NULL
    ),
    BT_GATT_CHARACTERISTIC(
        &file_data_uuid.uuid,
        BT_GATT_CHRC_NOTIFY,
        BT_GATT_PERM_READ,
        NULL, NULL, NULL
    )
);
```

**Write Callback:**
```c
static ssize_t cmd_write_cb(struct bt_conn *conn,
                            const struct bt_gatt_attr *attr,
                            const void *buf, uint16_t len,
                            uint16_t offset, uint8_t flags)
{
    char cmd[512];
    char *response = NULL;

    memcpy(cmd, buf, len);
    cmd[len] = '\0';

    // Process command
    int result = cmd_handler_process(cmd, &response);

    // Send response
    ble_send_response(response);

    free(response);
    return len;
}
```

## 11. Configuration Management

### 11.1 Kconfig System (Build-Time)

**Configuration Options:**
```kconfig
# Audio Configuration
config AUDIO_SAMPLE_RATE
    int "Audio Sample Rate (Hz)"
    default 16000
    range 8000 48000

config_AUDIO_CHANNELS
    int "Audio Channels"
    default 1  # Mono
    range 1 2

# Opus Configuration
config_OPUS_BITRATE
    int "Opus Bitrate (bps)"
    default 24000

config_OPUS_COMPLEXITY
    int "Opus Complexity (0-10)"
    default 5
    range 0 10

# SpeexDSP Configuration
config_SPEEXDSP_NOISE_SUPPRESS
    int "Noise Suppression (dB)"
    default 0
    range 0 60
```

### 11.2 Runtime Configuration (NVS)

**NVS Keys:**
```c
// NVS key definitions
#define NVS_BITRATE     0x01
#define NVS_COMPLEXITY  0x02
#define NVS_MODE        0x03
#define NVS_NOISE       0x04
#define NVS_DEREVERB    0x05
#define NVS_AGC         0x06
#define NVS_CHUNKSIZE   0x07
#define NVS_AUTODEL     0x08
```

**Load Configuration:**
```c
struct config {
    uint16_t bitrate;
    uint8_t complexity;
    char mode[8];
    uint8_t noise_suppress;
    char dereverb[16];
    char agc[16];
    uint16_t chunk_size;
    char autodel[8];
};

int config_load(struct config *cfg)
{
    // Load from NVS or use defaults
    if (nvs_read(NVS_BITRATE, &cfg->bitrate, sizeof(cfg->bitrate)) != 0) {
        cfg->bitrate = CONFIG_OPUS_BITRATE;  // Default
    }
    // ... load other values
    return 0;
}
```

**Save Configuration:**
```c
int config_save(const struct config *cfg)
{
    nvs_write(NVS_BITRATE, &cfg->bitrate, sizeof(cfg->bitrate));
    // ... save other values
    return 0;
}
```

### 11.3 Factory Defaults

```c
static const struct config factory_defaults = {
    .bitrate = 24000,
    .complexity = 5,
    .mode = "normal",
    .noise_suppress = 0,
    .dereverb = "off",
    .agc = "off",
    .chunk_size = 500,
    .autodel = "off",
};
```

### 11.4 Factory Reset Implementation

```c
int config_factory_reset(void)
{
    // Clear all NVS
    nvs_clear();

    // Restore defaults
    config_save(&factory_defaults);

    // Clear BLE bonds
    bt_unpair(BT_ID_DEFAULT, NULL);

    // Delete all recordings
    fs_delete_all_sessions();

    // Reboot
    sys_reboot(SYS_REBOOT_COLD);

    return 0;
}
```

## 12. Testing Architecture

### 12.1 Unit Testing Strategy

**Frameworks:**
- Zephyr Ztest: Built-in unit testing
- Unity: Lightweight C test framework

**Testable Modules:**
- AT command parser
- JSON serializer/deserializer
- Bookmark manager
- Configuration manager

**Example Test:**
```c
void test_at_parser_exec(void)
{
    struct at_command cmd;
    int result = at_parser_parse("AT+GSTAT", &cmd);

    zassert_equal(result, 0, "Parse failed");
    zassert_str_equal(cmd.name, "GSTAT", "Wrong command");
    zassert_equal(cmd.type, AT_EXEC, "Wrong type");
}
```

### 12.2 Integration Testing

**Test Scenarios:**
1. Full recording cycle (start → record → stop)
2. File transfer (download entire session)
3. Command during transfer (non-blocking)
4. Bookmark during recording
5. Auto-delete policy

**Test Environment:**
- Real hardware (reSpeaker Clip)
- SD card
- BLE sniffer (nRF Sniffer or Wireshark)

### 12.3 System Testing (tests/clip/)

**Multi-Image Test Suite:**
- BLE connection test
- Button input test
- SD card test
- Microphone test

**Running Tests:**
```sh
west build --build-dir build-test --board clip/nrf5340/cpuapp --pristine tests/clip
west flash --build-dir build-test && nrfutil device reset
```

### 12.4 Performance Testing

**Metrics:**
- Audio latency (PDM → Opus output)
- Transfer speed (KB/s)
- Memory usage (heap, stack)
- Battery current (mA)

**Tools:**
- Zephyr profiler
- Logic analyzer (for timing)
- Power meter (for current)
- BLE sniffer (for throughput)

## Appendix A: Module Dependencies

```
┌─────────────────────────────────────────────────────────────┐
│                    Dependency Graph                         │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  Recording Controller                                       │
│       ├─→ Audio Pipeline                                   │
│       │      ├─→ PDM Driver (HAL)                         │
│       │      ├─→ SpeexDSP                                 │
│       │      └─→ Opus Encoder                             │
│       ├─→ Session Manager                                 │
│       │      └─→ File System (HAL)                        │
│       ├─→ State Machine                                   │
│       ├─→ Display Manager                                 │
│       │      └─→ UART Driver (HAL)                        │
│       └─→ Button Handler                                  │
│              └─→ GPIO Driver (HAL)                        │
│                                                             │
│  Command Handler                                           │
│       ├─→ AT Parser                                       │
│       ├─→ JSON Handler                                    │
│       ├─→ Config Manager                                  │
│       │      └─→ NVS (Zephyr)                             │
│       ├─→ BLE GATT Service                                │
│       │      └─→ BLE Stack (Zephyr)                       │
│       └─→ File Transfer Manager                           │
│              └─→ File System (HAL)                        │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

## Appendix B: API Specifications

### Recording Controller API

```c
// Initialize recording subsystem
int rec_init(void);

// Start recording
int rec_start(enum recording_mode mode);

// Stop recording
int rec_stop(void);

// Add bookmark
int rec_add_mark(const char *note);

// Check if recording
bool rec_is_recording(void);

// Get recording duration
int rec_get_duration(uint32_t *seconds);
```

### Command Handler API

```c
// Initialize command handler
int cmd_handler_init(void);

// Process AT command
int cmd_handler_process(const char *cmd, char **response);

// Register custom command
int cmd_handler_register(const char *name, cmd_func_t func);
```

### Session Manager API

```c
// Create new session
int session_mgr_create(const char *session_id, struct session **out);

// Add file to session
int session_mgr_add_file(struct session *session, const char *filename, size_t size);

// Add bookmark to session
int session_mgr_add_mark(struct session *session, const struct mark *mark);

// Finalize session
int session_mgr_finalize(struct session *session);

// Delete session
int session_mgr_delete(const char *session_id);
```

## Appendix C: Configuration Reference

### Build-Time Configuration (Kconfig)

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| CONFIG_AUDIO_SAMPLE_RATE | int | 16000 | Audio sample rate (Hz) |
| CONFIG_AUDIO_CHANNELS | int | 1 | Number of channels (1=mono, 2=stereo) |
| CONFIG_OPUS_BITRATE | int | 24000 | Opus bitrate (bps) |
| CONFIG_OPUS_COMPLEXITY | int | 5 | Opus complexity (0-10) |
| CONFIG_SPEEXDSP_NOISE_SUPPRESS | int | 0 | Noise suppression (dB) |
| CONFIG_RECORDING_MODE | int | 0 | Recording mode (0=normal, 1=enhanced) |

### Runtime Configuration (NVS)

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| bitrate | uint16 | 24000 | Opus bitrate (bps) |
| complexity | uint8 | 5 | Opus complexity (0-10) |
| mode | string | "normal" | Recording mode |
| noise | uint8 | 0 | Noise suppression (dB) |
| dereverb | string | "off" | Dereverberation settings |
| agc | string | "off" | AGC settings |
| chunksize | uint16 | 500 | Transfer chunk size (bytes) |
| autodel | string | "off" | Auto-delete policy |
