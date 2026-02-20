# reSpeaker Clip - BLE Recording Application

This is the main application for the reSpeaker Clip BLE recording device.

## Directory Structure

```
applications/clip/
├── CMakeLists.txt              # Build configuration
├── prj.conf                     # Zephyr configuration
├── boards/                      # Device tree overlays
│   └── clip_nrf5340_cpuapp.overlay
├── include/                     # Header files
│   ├── clip.h                   # Main application definitions
│   ├── ble_svc.h                # BLE service definitions
│   ├── at_cmd.h                 # AT command parser
│   ├── state_machine.h          # State machine
│   ├── config.h                 # Configuration management
│   └── json_helper.h            # JSON helper functions
└── src/                         # Source files
    ├── main.c                   # Main application
    ├── ble_svc.c                # BLE GATT service implementation
    ├── at_cmd.c                 # AT command handlers
    ├── state_machine.c          # State machine implementation
    ├── config.c                 # Configuration management
    └── json_helper.c            # JSON helper implementation
```

## Building

```bash
# Set environment (once per terminal session)
source ~/path/to/ncs/v3.2.1/zephyr/zephyr-env.sh
export ZEPHYR_EXTRA_MODULES=$(pwd)

# Build
west build --build-dir build-clip --pristine --board clip/nrf5340/cpuapp applications/clip

# Flash
west flash --build-dir build-clip && nrfutil device reset
```

## Features Implemented

### BLE AT Command Protocol

The application implements a BLE GATT service with three characteristics for AT command communication:

1. **Command Receive** (Write): `6E400002-B5A3-F393-E0A9-E50E24DCCA9E`
   - Receives AT commands from mobile app

2. **Response Send** (Notify): `6E400003-B5A3-F393-E0A9-E50E24DCCA9E`
   - Sends JSON responses

3. **File Data** (Notify): `6E400004-B5A3-F393-E0A9-E50E24DCCA9E`
   - Streams file data (for future use)

### Supported Commands

| Command | Type | Description |
|---------|------|-------------|
| `AT+GSTAT` | EXEC | Get device status |
| `AT+VERSION` | EXEC | Get version info |
| `AT+TIME?` | GET | Get system time |
| `AT+BITRATE=<bps>` | SET | Set Opus bitrate |
| `AT+BITRATE?` | GET | Get current bitrate |
| `AT+COMPLEXITY=<0-10>` | SET | Set encoding complexity |
| `AT+COMPLEXITY?` | GET | Get current complexity |
| `AT+MODE=<normal\|enhanced>` | SET | Set recording mode |
| `AT+MODE?` | GET | Get current mode |
| `AT+START[=mode]` | EXEC/SET | Start recording |
| `AT+STOP` | EXEC | Stop recording |
| `AT+MARK[=note]` | EXEC/SET | Add bookmark |

### State Machine

The device implements a state machine with the following states:

- `UNINITIALIZED`: Boot state
- `IDLE`: Ready to record or transfer
- `RECORDING`: Actively recording
- `TRANSMITTING`: Transferring files (future)
- `PAUSED`: Transfer paused (future)
- `ERROR`: Error state

### Configuration Management

Configuration is stored in NVS (Non-Volatile Storage):

- Bitrate
- Complexity
- Mode
- Noise suppression
- Chunk size

## TODO

Future features to implement:

- [ ] Audio recording (PDM microphone)
- [ ] Opus encoding
- [ ] SpeexDSP processing
- [ ] SD card storage
- [ ] File transfer
- [ ] Button input handling
- [ ] Display (UART → OLED)
- [ ] Haptic feedback
- [ ] Battery monitoring

## Testing

Use the Python test script in `tests/ble_test.py`:

```bash
python tests/ble_test.py --interactive
```

## Logging

The application uses Zephyr logging. View serial output:

```bash
minicom -D /dev/ttyACM0 -b 115200
# or
screen /dev/ttyACM0 115200
```

## References

- [Protocol Documentation](../../docs/protocol.md)
- [Architecture Documentation](../../docs/architecture.md)
- [Requirements Documentation](../../docs/requirements.md)
