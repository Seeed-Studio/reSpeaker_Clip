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
    # Session info includes synced_files count
    synced = getattr(session, 'synced_files', 0)
    print(f"  Synced: {synced}/{session.files}")
```

### Get Session Details

```python
# Get detailed session info including synced_files count
session_info = await cmds.get_session_info("20250227_120000")
print(f"Files: {session_info.files}")
print(f"Synced: {session_info.synced_files}")
print(f"Size: {session_info.size} bytes")
```

### Sync Latest Session

```python
from clip import SessionSync

sync = SessionSync(device)

# Sync latest session (auto-detects and resumes from last synced file)
result = await sync.sync("20250227_120000", Path("downloads"))

if result.get('status') == 'already_synced':
    print("Session already synced")
else:
    print(f"Synced {result['file_count']} files")
```

### Sync with Resume Support

```python
# sync() automatically detects synced_files and resumes
# No need to manually calculate start file

# If 15 files were synced, it will automatically start from 0016.opus
result = await sync.sync(
    session_id="20250227_120000",
    output_dir=Path("downloads"),
    delete_after=True  # Delete from device after successful sync
)

# Result includes:
# - file_count: Number of files synced this session
# - total_size: Total bytes transferred
# - merged_file: Path to merged opus file (if created)
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

### record.py - Record and Sync in Real-Time

```bash
# Record and sync (stop with Ctrl+C)
python tools/record.py

# Record in enhanced mode (mono + DSP)
python tools/record.py --mode enhanced

# Record for 30 seconds then stop
python tools/record.py --duration 30

# Record to custom directory
python tools/record.py --output ./my_recordings

# Specify device by MAC address
python tools/record.py --device AA:BB:CC:DD:EE:FF
```

**Features:**
- Real-time sync while recording
- Progress display with file count and speed
- Auto-merge files after transfer
- Deletes files from device after sync

### sync.py - Sync Sessions with Resume Support

```bash
# Sync latest session (auto-detect)
python tools/sync.py

# Sync specific session
python tools/sync.py --session 20250227_120000

# Sync all sessions
python tools/sync.py --all-sessions

# Keep sessions on device after sync
python tools/sync.py --keep

# Show status only (don't sync)
python tools/sync.py --status

# Specify output directory
python tools/sync.py --output ./downloads
```

**Features:**
- Auto-resume from last synced file
- Progress display with transfer speed
- Handles recording state (continuous mode)
- Ctrl+C support with graceful cancellation
- Auto-merge files into single opus file

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
        sync = SessionSync(device)
        result = await sync.sync(session_id, Path("recordings"))

        if result.get('status') == 'already_synced':
            print("Already synced")
        elif result['file_count'] > 0:
            print(f"Synced {result['file_count']} files")

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
        sync = SessionSync(device)
        sync_result = await sync.sync(session_id, OUTPUT_DIR)

        if sync_result.get('status') == 'already_synced':
            print("Already synced")
        elif sync_result['file_count'] > 0:
            print(f"Sync successful: {sync_result['file_count']} files")

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

### Using the record.py Tool

The `record.py` tool combines recording and real-time sync in one command:

```bash
# Simple record and sync (Ctrl+C to stop)
python tools/record.py

# Record with specific mode and duration
python tools/record.py --mode enhanced --duration 60
```

**Output:**
```
============================================================
ReSpeaker Clip - Record & Sync
============================================================

Connecting to device...
Battery: 85%
Storage: 1.8 GB free

Starting recording in enhanced mode...
Session ID: 20250228_143000

Starting real-time sync to: recordings/20250228_143000
Recording... (Press Ctrl+C to stop)

[Recording] 00:00:10   | Files: 2 | Total: 143.2 KB | Speed: 14.2 KB/s
[Recording] 00:00:20   | Files: 4 | Total: 286.4 KB | Speed: 14.3 KB/s

Stopping recording...
Syncing files...

============================================================
Recording Summary
============================================================
  Session: 20250228_143000
  Duration: 00:00:30
  Merged file: 20250228_143000.opus (429.6 KB)
  Total synced: 429.6 KB
  Avg speed: 14.3 KB/s
  Location: recordings/20250228_143000
============================================================
```

### Using the sync.py Tool

The `sync.py` tool handles session synchronization with resume support:

```bash
# Sync latest session (auto-detects)
python tools/sync.py

# Sync with progress display
python tools/sync.py --session 20250228_143000
```

**Output (with resume):**
```
============================================================
Sync Session: 20250228_143000
============================================================
Resuming from: 0016.opus (synced: 15/30)
  Progress: 0016.opus (1 files, 71.3 KB, 5s, 14.1 KB/s)
  Progress: 0018.opus (3 files, 175.8 KB, 11s, 15.8 KB/s)
  ...
  Progress: 0030.opus (15 files, 1070.6 KB, 75s, 14.2 KB/s)

Sync Complete!
============================================================
  Session: 20250228_143000
  Files: 15
  Total: 1.04 MB
  Avg speed: 14.2 KB/s
  Merged: downloads/20250228_143000/20250228_143000.opus
  Location: downloads/20250228_143000
============================================================
```

See `examples/` directory for more complete examples:

- `examples/basic_usage.py` - Basic usage
- `examples/auto_record.py` - Auto recording script
- `examples/batch_sync.py` - Batch sync
- `examples/monitor.py` - Device monitoring

## Related Documentation

- [README.md](README.md) - Test framework overview
- [docs/protocol.md](docs/protocol.md) - AT command protocol
- [clip/](clip/) - API documentation source code
