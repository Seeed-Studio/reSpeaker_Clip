# reSpeaker Clip Python SDK - Usage Examples

This document provides usage examples for the reSpeaker Clip Python SDK.

## Table of Contents

- [Installation](#installation)
- [Quick Start](#quick-start)
- [Basic Operations](#basic-operations)
- [Recording Control](#recording-control)
- [File Synchronization](#file-synchronization)
- [Configuration Management](#configuration-management)
- [WiFi Transport](#wifi-transport)
- [Command Line Tools](#command-line-tools)
- [Web Interface](#web-interface)

## Installation

### Install Dependencies

```bash
cd applications/clip/tests
pip install -r requirements.txt
```

Required packages: `bleak` (BLE), `tqdm` (progress bars), `starlette` + `uvicorn` (web interface).

## Quick Start

### BLE Connection

```python
import asyncio
from clip import ClipDevice, ClipCommands

async def main():
    # Auto-discover device (looks for "Clip XXXX")
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
device = ClipDevice(address="AA:BB:CC:DD:EE:FF")
await device.connect()
```

## Basic Operations

### Get Device Information

```python
# Version info
version = await cmds.get_version()
print(f"Firmware: {version.firmware}")
print(f"Hardware: {version.hardware}")

# Device state
state = await cmds.get_state()
print(f"State: {state.state}")
print(f"Battery: {state.battery}%")
print(f"Mode: {state.mode}")
```

### Time Management

```python
import time

# Get device time
ts = await cmds.get_time()
print(f"Timestamp: {ts}")

# Set device time
await cmds.set_time(int(time.time()))
```

## Recording Control

### Start/Stop Recording

```python
# Start recording
session_id = await cmds.start_recording("normal")
print(f"Session: {session_id}")

# Record for 10 seconds
await asyncio.sleep(10)

# Stop recording
result = await cmds.stop_recording()
print(f"Duration: {result.get('duration')}s")
```

### Pause/Resume

```python
await cmds.pause_recording()
await asyncio.sleep(5)
await cmds.resume_recording()
```

### Add Bookmarks

```python
# add_bookmark() returns BookmarkInfo with .offset field
bm = await cmds.add_bookmark()
print(f"Bookmark at {bm.offset}s")
```

## File Synchronization

### List Sessions

```python
sessions = await cmds.list_sessions()
for s in sessions:
    print(f"{s.id}: {s.files} files, {s.size} bytes")
```

### Sync Session (BLE)

```python
from clip import SessionSync

sync = SessionSync(device)

# Sync specific session
result = await sync.sync("20260326120000", Path("recordings"))

# Sync with options
result = await sync.sync(
    session_id="20260326120000",
    output_dir=Path("recordings"),
    delete_after=False,      # Keep on device
    start_file="0015.opus",  # Resume from specific file
)

print(f"Files: {result.get('file_count')}, Size: {result.get('total_size')}")
```

### Sync Session (WiFi)

```python
from clip import WiFiSync

sync = WiFiSync("192.168.4.1", 8089)
if sync.connect():
    # List sessions
    sessions = sync.list_sessions()

    # Download session
    sync.download_session(
        "20260326120000",
        Path("recordings"),
        convert_ogg=True,
        start_file="0015.opus",
        delete_after=False,
    )
    sync.disconnect()
```

## Configuration Management

```python
# Individual getters/setters
await cmds.set_mode("enhanced")
await cmds.set_mode("enhanced")   # normal | enhanced (governs bitrate/complexity)

mode = await cmds.get_mode()
mode = await cmds.get_mode()

# Batch get/set
config = await cmds.get_config_dict()
print(config)

await cmds.set_config_dict({
    "mode": "enhanced",
    "bitrate": 32000,
    "complexity": 10,
})
```

## WiFi Transport

WiFi uses UDP on port 8089. Connect to the device's WiFi AP (SSID: `ClipAP_XXXX`, password: `12345678`).

### WiFiDevice (async, compatible with ClipDevice)

```python
import asyncio
from clip import WiFiDevice

async def main():
    async with WiFiDevice("192.168.4.1", 8089) as device:
        resp = await device.send_command("AT+GSTAT")
        print(resp)
        resp = await device.send_command("AT+LIST")
        print(resp)

asyncio.run(main())
```

### WiFiSync (blocking)

```python
from clip import WiFiSync

sync = WiFiSync("192.168.4.1", 8089)
if sync.connect():
    sessions = sync.list_sessions()
    for s in sessions:
        print(f"  {s['id']}: {s.get('files', 0)} files, {s.get('size', 0)} bytes")

    sync.download_session(sessions[-1]["id"], Path("recordings"))
    sync.disconnect()
```

## Command Line Tools

### clip-cli — Unified CLI

```bash
# BLE (default)
clip-cli status
clip-cli version
clip-cli list
clip-cli record --mode enhanced --duration 60
clip-cli sync --session 20260326120000
clip-cli sync --session 20260326120000 --file 0015.opus
clip-cli sync --session 20260326120000 --keep
clip-cli sync --all --keep
clip-cli config get
clip-cli config set bitrate=32000
clip-cli delete 20260326120000
clip-cli bookmark
clip-cli terminal
clip-cli --device AA:BB:CC:DD:EE:FF status

# WiFi
clip-cli --transport wifi status
clip-cli --transport wifi list
clip-cli --transport wifi sync --session 20260326120000
clip-cli --transport wifi sync --all --keep
clip-cli --transport wifi --host 192.168.4.1 terminal
```

### record.py — Record and Sync in Real-Time

```bash
python tools/record.py
python tools/record.py --mode enhanced
python tools/record.py --duration 60
python tools/record.py --output ./my_recordings
python tools/record.py --device AA:BB:CC:DD:EE:FF
python tools/record.py --keep  # Don't delete after sync
```

### sync.py — BLE Session Sync

```bash
python tools/sync.py                         # Sync latest session
python tools/sync.py --session 20260326120000
python tools/sync.py --all-sessions
python tools/sync.py --session 20260326120000 --file 0015.opus
python tools/sync.py --keep                  # Don't delete from device
```

### udp_sync.py — WiFi Session Sync

```bash
python tools/udp_sync.py                          # List sessions
python tools/udp_sync.py --session 20260326120000 # Download session
python tools/udp_sync.py --all-sessions           # Download all
python tools/udp_sync.py --session 20260326120000 --file 0015.opus
python tools/udp_sync.py --session 20260326120000 --keep
python tools/udp_sync.py --no-ogg                 # Skip OGG conversion
```

### ble_terminal.py — Interactive Terminal

```bash
python tools/ble_terminal.py
python tools/ble_terminal.py --device AA:BB:CC:DD:EE:FF
```

### decode_opus.py — Opus to WAV

```bash
python tools/decode_opus.py recording.opus recording.wav
```

## Web Interface

### clip-web — Web UI

```bash
# BLE mode (default)
python tools/clip-web.py

# WiFi mode
python tools/clip-web.py --transport wifi

# Custom host/port
python tools/clip-web.py --host 0.0.0.0 --port 8080
```

Then visit http://localhost:5000

Features: device status, recording control, session list, sync progress, configuration panel, audio visualization.

REST API endpoints:
```
GET  /api/status          GET  /api/version         GET  /api/sessions
POST /api/record/start    POST /api/record/stop     POST /api/record/bookmark
POST /api/sync/{id}       DELETE /api/sessions/{id}  GET  /api/config
PUT  /api/config          WS   /ws
```

## Error Handling

```python
from clip import ClipError, ConnectionError, TimeoutError, CommandError

async def safe_operation():
    try:
        async with ClipDevice() as device:
            cmds = ClipCommands(device)
            await cmds.start_recording("normal")
    except ConnectionError as e:
        print(f"Connection failed: {e}")
    except TimeoutError as e:
        print(f"Timeout: {e}")
    except CommandError as e:
        print(f"Command error: {e}")
```

## Complete Example

```python
import asyncio
from pathlib import Path
from clip import ClipDevice, ClipCommands, SessionSync

async def record_and_sync():
    async with ClipDevice() as device:
        cmds = ClipCommands(device)

        # Check battery
        state = await cmds.get_state()
        print(f"Battery: {state.battery}%")
        if state.battery < 20:
            print("Low battery, aborting")
            return

        # Configure
        await cmds.set_mode("normal")
        await cmds.set_mode("enhanced")

        # Record for 30 seconds
        session_id = await cmds.start_recording("normal")
        print(f"Recording: {session_id}")
        await asyncio.sleep(30)

        # Add bookmark
        bm = await cmds.add_bookmark()
        print(f"Bookmark at {bm.offset}s")

        # Record 10 more seconds
        await asyncio.sleep(10)

        # Stop and sync
        await cmds.stop_recording()

        sync = SessionSync(device)
        result = await sync.sync(session_id, Path("recordings"), delete_after=True)
        print(f"Synced: {result.get('file_count')} files")

asyncio.run(record_and_sync())
```
