# Testing Guide for reSpeaker Clip

This guide covers testing the reSpeaker Clip device using the Python test framework.

## Quick Start

```bash
cd applications/clip/tests

# Install dependencies
pip install -r requirements.txt

# Run unit tests only (no device required)
pytest tests/ -m unit -v

# Run all tests (requires device, will skip if unavailable)
pytest tests/ -v

# Run specific test file
pytest tests/test_basic.py -v

# Run without stress tests
pytest tests/ -m "not stress" -v

# Run with coverage report
pytest tests/ --cov=clip --cov-report=html
```

## Running Tests Without a Device

When no reSpeaker Clip device is available:

```bash
# Run only unit tests (no device required)
pytest tests/test_unit.py -v

# Run with marker to skip device tests
pytest tests/ -m unit -v

# Skip device tests explicitly
pytest tests/ -m "not device" -v

# Set environment variable to skip all device tests
export CLIP_SKIP_DEVICE_TESTS=1
pytest tests/ -v
```

To run tests that require a device:

```bash
# Set device address to skip discovery
export CLIP_DEVICE_ADDRESS=AA:BB:CC:DD:EE:FF

# Run all tests (device tests will use the address)
pytest tests/ -v

# Run only device tests
pytest tests/ -m device -v
```

## Test Organization

### Directory Structure

```
applications/clip/tests/
├── clip/                    # Python library (device control)
│   ├── __init__.py
│   ├── client.py            # BLE client class
│   ├── commands.py          # AT command wrappers
│   ├── transfer.py          # File transfer handling
│   ├── exceptions.py        # Custom exceptions
│   └── utils.py             # Utility functions
├── tests/                   # pytest test cases
│   ├── __init__.py
│   ├── conftest.py          # pytest fixtures
│   ├── test_basic.py        # Basic AT commands
│   ├── test_config.py       # Configuration commands
│   ├── test_recording.py    # Recording control
│   ├── test_transfer.py     # File transfer
│   └── test_storage.py      # Storage management
├── tools/                   # Utility scripts
│   ├── ble_terminal.py      # Interactive terminal
│   ├── sync.py              # File sync tool
│   ├── decode_opus.py       # Opus decoder
│   └── ble_test.py          # Quick test script
├── docs/                    # Documentation
├── requirements.txt         # Python dependencies
└── pytest.ini              # pytest configuration
```

### Test Categories

- **Unit tests**: Test individual commands and functions (no device required for some)
- **Integration tests**: Test multi-command workflows (device required)
- **Stress tests**: Long-running tests (marked with `@pytest.mark.stress`)

### Test Markers

```bash
# Run only unit tests
pytest tests/ -m unit

# Run only slow tests
pytest tests/ -m slow

# Skip stress tests
pytest tests/ -m "not stress"

# List all markers
pytest --markers
```

## Using the clip Library

### Basic Usage

```python
import asyncio
from clip import ClipDevice, ClipCommands

async def main():
    # Connect to device
    async with ClipDevice() as device:
        cmds = ClipCommands(device)

        # Get device state
        state = await cmds.get_state()
        print(f"State: {state.state}")
        print(f"Battery: {state.battery}%")

        # Get version
        version = await cmds.get_version()
        print(f"Firmware: {version.firmware}")

asyncio.run(main())
```

### Recording Control

```python
from clip import ClipDevice, ClipCommands

async def record_audio():
    async with ClipDevice() as device:
        cmds = ClipCommands(device)

        # Start recording
        session_id = await cmds.start_recording("normal")
        print(f"Recording: {session_id}")

        # Wait 5 seconds
        await asyncio.sleep(5)

        # Add bookmark
        await cmds.add_bookmark("Interesting part")

        # Stop recording
        result = await cmds.stop_recording()
        print(f"Duration: {result['duration']}s")

asyncio.run(record_audio())
```

### File Transfer

```python
from clip import ClipDevice, FileTransfer
from pathlib import Path

async def download_session():
    async with ClipDevice() as device:
        transfer = FileTransfer(device)

        # Download all files from a session
        result = await transfer.download_session(
            "20240101_120000",
            Path("./downloads"),
        )

        print(f"Downloaded {result['file_count']} files")
        print(f"Merged: {result.get('merged_file')}")

asyncio.run(download_session())
```

### Session Sync

```python
from clip import ClipDevice, SessionSync

async def sync_all():
    async with ClipDevice() as device:
        sync = SessionSync(device)

        # Sync all sessions
        results = await sync.sync_all(Path("./downloads"))

        for result in results:
            print(f"{result['session_id']}: {result['status']}")

asyncio.run(sync_all())
```

## Tool Scripts

### ble_terminal.py - Interactive Terminal

```bash
# Auto-discover and connect
python tools/ble_terminal.py

# Connect to specific device
python tools/ble_terminal.py --device AA:BB:CC:DD:EE:FF
```

Commands in terminal:
- `AT+VERSION` - Get version info
- `AT+GSTAT` - Get device status
- `AT+START=normal` - Start recording
- `AT+STOP` - Stop recording
- `AT+LIST` - List sessions
- `help` - Show all commands
- `quit` - Exit terminal

### sync.py - File Sync Tool

```bash
# Sync latest session
python tools/sync.py

# Sync specific session
python tools/sync.py --session 20240101_120000

# Sync all sessions
python tools/sync.py --all-sessions

# Show status only
python tools/sync.py --status

# Keep sessions on device
python tools/sync.py --keep

# Custom output directory
python tools/sync.py -o /path/to/downloads
```

### decode_opus.py - Opus Decoder

```bash
# Decode Opus to WAV
python tools/decode_opus.py recording.opus recording.wav

# Decode stereo
python tools/decode_opus.py recording.opus recording.wav --channels 2

# Different sample rate
python tools/decode_opus.py recording.opus recording.wav --sample-rate 48000
```

### ble_test.py - Quick Test Script

```bash
# Run all tests
python tools/ble_test.py

# Run specific test
python tools/ble_test.py --test version

# Use specific device
python tools/ble_test.py --device AA:BB:CC:DD:EE:FF
```

## Environment Variables

```bash
# Set device address for auto-discovery
export CLIP_DEVICE_ADDRESS=AA:BB:CC:DD:EE:FF

# Run tests - will use the device address
pytest tests/ -v
```

## Writing New Tests

### Test Template

```python
import pytest
from clip import ClipCommands

@pytest.mark.asyncio
class TestMyFeature:
    """Test my feature."""

    async def test_basic_operation(self, commands: ClipCommands):
        """Should do basic operation."""
        result = await commands.some_command()
        assert result is not None

    async def test_with_fixture(self, commands: ClipCommands, saved_state):
        """Test with state restoration."""
        async with saved_state:
            # Modify config here
            await commands.set_bitrate(48000)
            # Config is automatically restored
```

### Best Practices

1. **Use fixtures**: Leverage `device`, `commands`, and `saved_state` fixtures
2. **Clean up**: Always restore device state after tests
3. **Use markers**: Mark slow tests with `@pytest.mark.slow`
4. **Handle errors**: Use `pytest.raises()` for expected errors
5. **Skip gracefully**: Use `pytest.skip()` when tests can't run

### Example Test

```python
import pytest
from clip import ClipCommands
from clip.exceptions import CommandError

@pytest.mark.asyncio
@pytest.mark.slow
class TestRecording:
    """Test recording functionality."""

    async def test_start_stop_recording(self, commands: ClipCommands):
        """Should start and stop recording."""
        await commands.ensure_idle()

        # Start recording
        session_id = await commands.start_recording("normal")
        assert session_id is not None

        # Verify state
        state = await commands.get_state()
        assert state.state == "RECORDING"

        # Wait and stop
        await asyncio.sleep(2)
        result = await commands.stop_recording()

        assert result["duration"] >= 2
```

## Troubleshooting

### Connection Issues

```bash
# Scan for device
python tools/ble_terminal.py

# If device not found, check Bluetooth is on
# On Linux: sudo systemctl start bluetooth
```

### Test Failures

```bash
# Run with verbose output
pytest tests/ -vv

# Run with pdb on error
pytest tests/ --pdb

# Run specific test
pytest tests/test_basic.py::TestBasicCommands::test_get_version -v
```

### Dependency Issues

```bash
# Reinstall dependencies
pip install -r requirements.txt --force-reinstall

# Check versions
pip list | grep -E "(bleak|pytest)"
```

## Continuous Integration

Example GitHub Actions workflow:

```yaml
name: Tests
on: [push, pull_request]
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      - uses: actions/setup-python@v4
        with:
          python-version: '3.10'
      - run: pip install -r applications/clip/tests/requirements.txt
      - run: pytest applications/clip/tests/tests/ -m "not stress"
```

## Additional Resources

- [Protocol Documentation](../../docs/protocol.md)
- [Architecture Documentation](../../docs/architecture.md)
- [Development Notes](../../docs/development.md)
