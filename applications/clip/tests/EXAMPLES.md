# reSpeaker Clip Python API - Usage Examples

This document provides detailed usage examples for the reSpeaker Clip Python API.

## Table of Contents

- [Installation](#installation)
- [Quick Start](#quick-start)
- [Basic Operations](#basic-operations)
- [Recording Control](#recording-control)
- [File Synchronization](#file-synchronization)
- [Configuration Management](#configuration-management)
- [Command Line Tools](#command-line-tools)
- [Web Interface](#web-interface)

## Installation

### Install Dependencies

```bash
pip install bleak pytest-asyncio
```

### Full Installation (with test tools)

```bash
cd applications/clip/tests
pip install -r requirements.txt
```

## Quick Start

### Basic Connection

```python
import asyncio
from clip import ClipDevice, ClipCommands

async def main():
    # Auto-discover device
    async with ClipDevice() as device:
        cmds = ClipCommands(device)

        # Get device status
        state = await cmds.get_state()
        print(f"Battery: {state.battery}%")
        print(f"State: {state.state}")

asyncio.run(main())
```

### Specify Device Address

```python
# Connect using MAC address
device = ClipDevice(address="AA:BB:CC:DD:EE:FF")
await device.connect()
```

## Basic Operations

### Get Device Information

```python
# Get version information
version = await cmds.get_version()
print(f"Firmware: {version.firmware}")
print(f"Hardware: {version.hardware}")
print(f"SDK: {version.sdk}")

# Get device state
state = await cmds.get_state()
print(f"State: {state.state}")
print(f"Battery: {state.battery}%")
print(f"Mode: {state.mode}")
```

### Time Management

```python
import time

# Get device time
time_info = await cmds.get_time()
print(f"Timestamp: {time_info}")

# Set device time (Unix timestamp)
await cmds.set_time(int(time.time()))
```

## Recording Control

### Start Recording

```python
# Stereo mode (normal mode)
result = await cmds.start_recording("normal")
print(f"Session ID: {result['session']}")

# Mono mode (enhanced mode, with noise suppression)
result = await cmds.start_recording("enhanced")
print(f"Session ID: {result['session']}")
```

### Timed Recording

```python
# Record for 10 seconds then auto-stop
await cmds.start_recording("normal")
await asyncio.sleep(10)
await cmds.stop_recording()
```

### Add Bookmarks

```python
# Add bookmark during recording
await cmds.add_bookmark("Important content")

# Bookmark without note
await cmds.add_bookmark()
```

### Stop Recording

```python
# Stop recording and get result
result = await cmds.stop_recording()
print(f"Recording complete: {result['session']}")
```

## File Synchronization

### List All Sessions

```python
sessions = await cmds.list_sessions()

for session in sessions:
    print(f"{session.id}: {session.files} files, {session.size} bytes")
```

### Sync Latest Session

```python
from clip import SessionSync

sync = SessionSync(device, output_dir=Path("downloads"))

# Sync latest session
result = await sync.sync_latest()
print(f"Synced {result['files']} files")
```

### Sync Specific Session

```python
# Sync specific session
result = await sync.sync_session("20250227_120000")

if result['status'] == 'success':
    print(f"Sync successful: {result['files']} files")
```

### Sync All Sessions

```python
# Sync all sessions and delete from device
results = await sync.sync_all(delete_after=True)

for result in results:
    if result['status'] == 'success':
        print(f"✓ {result['session']}")
    else:
        print(f"✗ {result['session']}: {result.get('error')}")
```

### Resume Transfer

```python
# Resume syncing from specific file
result = await sync.resume_from(
    session_id="20250227_120000",
    start_file="010.opus"
)
```

## Configuration Management

### Get Configuration

```python
# Get single config
mode = await cmds.get_config("mode")
print(f"Mode: {mode}")

# Get all configuration
config = await cmds.get_all_config()
print(f"Bitrate: {config['bitrate']}")
print(f"Complexity: {config['complexity']}")
```

### Set Configuration

```python
# Set recording mode
await cmds.set_config("mode", "normal")    # Stereo
await cmds.set_config("mode", "enhanced")  # Mono + DSP

# Set bitrate (mono)
await cmds.set_config("bitrate", 32000)

# Set Opus encoding complexity (0-10)
await cmds.set_config("complexity", 5)

# Set noise suppression
await cmds.set_config("noise_suppress", -30)  # dB
```

## Command Line Tools

### clip-cli - Command Line Interface

```bash
# Connect and show status
python tools/clip-cli.py connect

# Record for 60 seconds
python tools/clip-cli.py record 60

# Record in stereo mode
python tools/clip-cli.py record --mode normal

# Stop recording
python tools/clip-cli.py record --stop

# Add bookmark
python tools/clip-cli.py bookmark "Important"

# Sync all sessions
python tools/clip-cli.py sync --all

# Sync specific session
python tools/clip-cli.py sync 20250227_120000

# List all sessions
python tools/clip-cli.py list

# Convert Opus to WAV
python tools/decode_opus.py recording.opus recording.wav

# Batch convert directory
python tools/decode_opus.py downloads/ --output wav_files/ --batch
```

## Web Interface

### clip-web - Web UI

```bash
# Start web server
python tools/clip-web.py

# Specify port
python tools/clip-web.py --port 8080

# Specify listen address
python tools/clip-web.py --host 127.0.0.1 --port 5000
```

Then visit http://localhost:5000

Web UI features:
- Device status display
- Recording control (start/stop/bookmark)
- Session list and synchronization
- Configuration management

## Complete Examples

### Recording and Sync Workflow

```python
import asyncio
from pathlib import Path
from clip import ClipDevice, ClipCommands, SessionSync

async def record_and_sync():
    async with ClipDevice() as device:
        cmds = ClipCommands(device)

        # 1. Check device status
        state = await cmds.get_state()
        print(f"Battery: {state.battery}%")
        if state.battery < 20:
            print("Warning: Low battery")
            return

        # 2. Set to stereo mode
        await cmds.set_config("mode", "normal")
        await cmds.set_config("bitrate", 96000)

        # 3. Start recording
        result = await cmds.start_recording("normal")
        session_id = result['session']
        print(f"Starting recording: {session_id}")

        # 4. Record for 30 seconds
        for i in range(30):
            await asyncio.sleep(1)
            if i % 10 == 0:
                print(f"Recording... {i} sec")

        # 5. Add bookmark
        await cmds.add_bookmark("30 second mark")

        # 6. Record for another 10 seconds
        await asyncio.sleep(10)

        # 7. Stop recording
        await cmds.stop_recording()
        print("Recording complete")

        # 8. Sync files
        sync = SessionSync(device, output_dir=Path("recordings"))
        result = await sync.sync_session(session_id)

        if result['status'] == 'success':
            print(f"Synced {result['files']} files")

        # 9. Convert to WAV
        from tools.decode_opus import decode_raw_opus

        for opus_file in Path("recordings").glob("*.opus"):
            wav_file = opus_file.with_suffix('.wav')
            decode_raw_opus(opus_file, wav_file)
            print(f"Converted: {opus_file.name} -> {wav_file.name}")

asyncio.run(record_and_sync())
```

### Auto Recording and Sync Script

```python
#!/usr/bin/env python3
"""
Auto Recording Script - Automatically record and sync when battery is sufficient
"""

import asyncio
from clip import ClipDevice, ClipCommands, SessionSync
from pathlib import Path

MIN_BATTERY = 20
RECORDING_DURATION = 300  # 5 minutes
OUTPUT_DIR = Path("recordings")

async def auto_record():
    device = ClipDevice()

    try:
        await device.connect()
        cmds = ClipCommands(device)

        # Check battery
        state = await cmds.get_state()
        if state.battery < MIN_BATTERY:
            print(f"Low battery: {state.battery}% < {MIN_BATTERY}%")
            return 1

        # Start recording
        print(f"Starting recording ({RECORDING_DURATION} seconds)")
        await cmds.start_recording("normal")

        # Can add bookmark during recording
        await asyncio.sleep(RECORDING_DURATION // 2)
        await cmds.add_bookmark("Midpoint mark")

        await asyncio.sleep(RECORDING_DURATION // 2)

        # Stop recording
        result = await cmds.stop_recording()
        session_id = result['session']
        print(f"Recording complete: {session_id}")

        # Auto sync
        print("Syncing files...")
        sync = SessionSync(device, output_dir=OUTPUT_DIR)
        sync_result = await sync.sync_session(session_id)

        if sync_result['status'] == 'success':
            print(f"Sync successful: {sync_result['files']} files")

        return 0

    except Exception as e:
        print(f"Error: {e}")
        return 1
    finally:
        await device.disconnect()

if __name__ == '__main__':
    import sys
    sys.exit(asyncio.run(auto_record()))
```

## Error Handling

### Basic Error Handling

```python
from clip.exceptions import (
    ClipError,
    ConnectionError,
    TimeoutError,
    CommandError,
)

async def safe_operation():
    try:
        async with ClipDevice() as device:
            cmds = ClipCommands(device)
            await cmds.start_recording("normal")

    except ConnectionError as e:
        print(f"Connection failed: {e}")
    except TimeoutError as e:
        print(f"Operation timeout: {e}")
    except CommandError as e:
        print(f"Command error: {e}")
    except ClipError as e:
        print(f"Device error: {e}")
```

### Retry Mechanism

```python
async def retry_operation(max_retries=3):
    for attempt in range(max_retries):
        try:
            async with ClipDevice() as device:
                cmds = ClipCommands(device)
                return await cmds.start_recording("normal")

        except ConnectionError as e:
            if attempt < max_retries - 1:
                print(f"Connection failed, retry {attempt + 1}/{max_retries}...")
                await asyncio.sleep(2)
            else:
                raise
```

## Advanced Usage

### Async Task Management

```python
import asyncio

async def record_in_background(duration, session_id):
    """Record in background"""
    device = ClipDevice()
    await device.connect()
    cmds = ClipCommands(device)

    await cmds.start_recording("normal")
    await asyncio.sleep(duration)
    await cmds.stop_recording()

    await device.disconnect()

async def main():
    # Start background recording task
    task = asyncio.create_task(record_in_background(60, "bg-session"))

    # Do other things simultaneously
    print("Recording running in background...")
    await asyncio.sleep(30)
    print("30 seconds passed...")

    # Wait for recording to complete
    await task
    print("Background recording complete")
```

### Batch Operations

```python
async def batch_process_operations():
    """Batch process multiple operations"""
    async with ClipDevice() as device:
        cmds = ClipCommands(device)

        # Batch configuration
        configs = {
            "mode": "enhanced",
            "bitrate": 32000,
            "complexity": 5,
            "noise_suppress": -30,
        }

        for key, value in configs.items():
            await cmds.set_config(key, value)
            print(f"Set {key} = {value}")

        # Get all config for verification
        all_config = await cmds.get_all_config()
        print("Current config:", all_config)
```

## More Examples

See `examples/` directory for more complete examples:

- `examples/basic_usage.py` - Basic usage
- `examples/auto_record.py` - Auto recording script
- `examples/batch_sync.py` - Batch sync
- `examples/monitor.py` - Device monitoring

## Related Documentation

- [README.md](README.md) - Test framework overview
- [docs/protocol.md](docs/protocol.md) - AT command protocol
- [clip/](clip/) - API documentation source code
