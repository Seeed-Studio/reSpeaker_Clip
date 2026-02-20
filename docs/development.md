# reSpeaker Clip BLE Recorder - Development Log

## Project Overview

实现基于 BLE 的录音设备固件，支持通过 AT 命令控制录音、配置和文件传输。

**Hardware**: Seeed ReSpeaker Clip (Nordic nRF5340)
**RTOS**: Zephyr RTOS v3.2.1 (via Nordic nRF Connect SDK)
**Application Location**: `applications/clip`

---

## 2025-02-20 - Initial Implementation

### Completed Tasks

#### 1. Documentation (Phase 1)
- ✅ Created `docs/requirements.md` - Product Requirements Document
- ✅ Created `docs/protocol.md` - BLE AT Protocol Specification
- ✅ Created `docs/architecture.md` - System Architecture Design
- ✅ Created `tests/ble_test.py` - Python BLE test script

#### 2. Application Structure
Created `applications/clip` with modular architecture:
```
applications/clip/
├── CMakeLists.txt
├── prj.conf
├── include/
│   ├── clip.h              # Main data structures
│   ├── ble_svc.h           # BLE service interface
│   ├── at_cmd.h            # AT command parser
│   ├── state_machine.h     # State machine
│   ├── config.h            # Configuration management
│   └── json_helper.h       # JSON response builder
└── src/
    ├── main.c              # Application entry point
    ├── ble_svc.c           # BLE GATT service
    ├── at_cmd.c            # AT command implementation
    ├── state_machine.c     # State transitions
    ├── config.c            # NVS-based config storage
    └── json_helper.c       # JSON utilities
```

#### 3. BLE Communication Implementation
- ✅ Custom GATT service (UUID: 6E400001-B5A3-F393-E0A9-E50E24DCCA9E)
  - Command Receive characteristic (Write)
  - Response Send characteristic (Notify)
  - File Data characteristic (Notify)
- ✅ MTU exchange for better throughput
- ✅ Auto-reconnect advertising

#### 4. AT Command Parser
Implemented commands:
- ✅ `GSTAT` - Get device status
- ✅ `VERSION` - Get firmware version
- ✅ `TIME` - Get/set RTC time
- ✅ `BITRATE` - Configure Opus bitrate (SET/GET)
- ✅ `COMPLEXITY` - Configure Opus complexity (SET/GET)
- ✅ `MODE` - Set recording mode (normal/enhanced)
- ✅ `START` - Start recording (EXEC/SET)
- ✅ `STOP` - Stop recording
- ✅ `MARK` - Add bookmark

Syntax support:
- `AT+CMD?` - GET query
- `AT+CMD=value` - SET command
- `AT+CMD` - EXECUTE command

#### 5. State Machine
States:
- `UNINITIALIZED` → `IDLE` → `RECORDING` → `IDLE`
- `IDLE` → `TRANSMITTING` → `IDLE`
- `RECORDING` → `PAUSED` → `RECORDING`
- Any state → `ERROR`

Features:
- State transition validation
- Callback system for state changes
- Thread-safe operations

#### 6. Configuration Management (NVS)
- ✅ Settings subsystem integration
- ✅ External SPI flash storage (ext-nvs partition, 64KB)
- ✅ Persistent configuration:
  - Bitrate (default: 24000)
  - Complexity (default: 5)
  - Mode (default: normal)
  - Noise suppression
  - Chunk size
- ✅ Factory reset support
- ✅ Auto-save on configuration change

#### 7. Memory Management
- ✅ All allocations use Zephyr kernel APIs (`k_malloc`, `k_free`, `k_strdup`)
- ✅ Heap size: 32KB (CONFIG_HEAP_MEM_POOL_SIZE=32768)
- ✅ Stack size: 16KB (CONFIG_MAIN_STACK_SIZE=16384)

### Build Configuration

**Kconfig Options** (prj.conf):
```conf
# Bluetooth
CONFIG_BT=y
CONFIG_BT_PERIPHERAL=y
CONFIG_BT_DEVICE_NAME="reSpeaker Clip"
CONFIG_BT_MAX_CONN=1
CONFIG_BT_GATT_CLIENT=y
CONFIG_BT_BUF_ACL_RX_SIZE=502
CONFIG_BT_BUF_ACL_TX_SIZE=502
CONFIG_BT_L2CAP_TX_MTU=247
CONFIG_BT_RX_STACK_SIZE=2048

# Storage
CONFIG_FLASH=y
CONFIG_FLASH_MAP=y
CONFIG_SETTINGS=y
CONFIG_SETTINGS_NVS=y
CONFIG_NVS=y

# Memory
CONFIG_HEAP_MEM_POOL_SIZE=32768
CONFIG_MAIN_STACK_SIZE=16384

# Hardware
CONFIG_GPIO=y
CONFIG_I2C=y
CONFIG_LOG=y
```

### Build Status

✅ **Successfully Compiles**
- Firmware size: 133 KB FLASH / 81 KB RAM
- Memory usage: 13.17% FLASH / 18.11% RAM
- Build command:
  ```bash
  ncs-env && export ZEPHYR_EXTRA_MODULES=$(pwd)
  west build --build-dir build-clip --board clip/nrf5340/cpuapp applications/clip
  ```

### Known Issues & Limitations

1. **Audio Recording** - Not yet implemented
   - PDM microphone driver integration needed
   - Opus encoding integration needed
   - SpeexDSP processing integration needed

2. **Storage** - Not yet implemented
   - SD card filesystem integration needed
   - File management needed

3. **User Interface** - Not yet implemented
   - Button handler (INPUT_CLIP driver) needed
   - Display driver integration needed
   - Haptic feedback needed (log-based initially)

4. **WiFi** - Not implemented
   - nRF7002 driver integration needed (future)

### Fixed Issues

1. **Enum naming conflict** - Renamed `device_state` → `clip_state` to avoid Zephyr conflicts
2. **UUID macro format** - Fixed BT_UUID_128_ENCODE parameter count (16 → 5 params)
3. **Multiple definition** - Removed duplicate global variable definitions in at_cmd.c
4. **Memory allocation** - Replaced `strdup`/`free` with `k_malloc`/`k_free`
5. **Settings API** - Corrected include path to `<zephyr/settings/settings.h>`
6. **BLE MTU exchange** - Added `CONFIG_BT_GATT_CLIENT=y` to enable API

### Next Steps

#### Phase 2: Audio Recording (High Priority)
1. Integrate PDM microphone driver
2. Implement Opus encoding
3. Add SpeexDSP noise suppression
4. Implement audio buffer management

#### Phase 3: Storage
1. SD card filesystem integration
2. File naming and management
3. Storage space monitoring

#### Phase 4: User Interface
1. Button handler with multi-press support
2. OLED display driver (CH1115)
3. Haptic feedback (log-based initially)

#### Phase 5: Testing
1. Flash firmware to device
2. Test BLE connection with Python script
3. Test AT commands
4. Test state transitions
5. Test configuration persistence

### Testing Tools

- **Python BLE Test Script**: `tests/ble_test.py`
  - Requires: `pip install -r tests/requirements.txt`
  - Usage: `python tests/ble_test.py`
  - Features: Automated tests + interactive mode

### Reference Implementations

- `samples/opus_encode` - Audio recording reference
- `tests/clip` - Multi-image test suite
- Custom drivers: `drivers/input/` - Button driver

### Git Repository

**Branch**: `clip`
**Main Branch**: `main`

### Configuration Notes

**Memory Layout**:
- Total SRAM: 512KB
- BLE Core: 64KB
- Application: 448KB
- Current usage: 81KB (18%)

**External Flash** (PY25Q64H, 64MB):
- ext-nvs: 64KB (NVS storage)
- ext-storage: 15MB (user data)

### Development Workflow

```bash
# 1. Set environment
ncs-env
export ZEPHYR_EXTRA_MODULES=$(pwd)

# 2. Build
west build --build-dir build-clip --board clip/nrf5340/cpuapp applications/clip

# 3. Flash
west flash --build-dir build-clip && nrfutil device reset

# 4. View serial output
minicom -D /dev/ttyACM0 -b 115200
```
