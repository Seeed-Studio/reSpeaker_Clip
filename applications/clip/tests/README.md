# reSpeaker Clip Test Framework

Quick reference for the test framework.

## Running Tests

### Without a Device (Unit Tests Only)

```bash
# Run only unit tests - these don't require a device
pytest tests/test_unit.py -v

# Or use the marker
pytest tests/ -m unit -v
```

### With a Device

```bash
# Option 1: Auto-discover device
pytest tests/ -v

# Option 2: Specify device address
export CLIP_DEVICE_ADDRESS=AA:BB:CC:DD:EE:FF
pytest tests/ -v

# Option 3: Use the tool scripts
python tools/ble_test.py
```

### Test Markers

| Marker | Description | Requires Device |
|--------|-------------|-----------------|
| `unit` | Unit tests (no device) | No |
| `device` | Device integration tests | Yes |
| `slow` | Slow tests | Yes |
| `stress` | Long-running stress tests | Yes |

### Examples

```bash
# Run only unit tests
pytest tests/ -m unit -v

# Skip device tests
pytest tests/ -m "not device" -v

# Skip stress tests
pytest tests/ -m "not stress" -v

# Run with coverage
pytest tests/ --cov=clip --cov-report=html
```

## Tool Scripts

```bash
# Interactive terminal
python tools/ble_terminal.py

# Sync files from device
python tools/sync.py

# Sync all sessions
python tools/sync.py --all-sessions

# Decode Opus to WAV
python tools/decode_opus.py recording.opus recording.wav

# Quick test
python tools/ble_test.py
```

## Environment Variables

| Variable | Description |
|----------|-------------|
| `CLIP_DEVICE_ADDRESS` | MAC address of device (skips discovery) |
| `CLIP_SKIP_DEVICE_TESTS` | Set to 1 to skip all device tests |

## Library Usage

```python
import asyncio
from clip import ClipDevice, ClipCommands

async def main():
    async with ClipDevice() as device:
        cmds = ClipCommands(device)

        # Get device state
        state = await cmds.get_state()
        print(f"Battery: {state.battery}%")

        # Start recording
        session = await cmds.start_recording("normal")
        await asyncio.sleep(5)
        await cmds.stop_recording()

asyncio.run(main())
```

## File Structure

```
applications/clip/tests/
├── clip/              # Python library
│   ├── client.py      # BLE client
│   ├── commands.py    # AT commands
│   ├── transfer.py    # File transfer
│   └── utils.py       # Utilities
├── tests/             # Test files
│   ├── test_unit.py   # Unit tests (no device)
│   ├── test_basic.py  # Basic AT commands
│   ├── test_config.py # Configuration
│   └── ...
├── tools/             # Utility scripts
└── docs/              # Documentation
```
