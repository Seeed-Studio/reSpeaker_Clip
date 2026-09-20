# reSpeaker Clip Python SDK

Python SDK for controlling reSpeaker Clip device via BLE and WiFi.

## Installation

```bash
cd applications/clip/tests
pip install -r requirements.txt
```

## Quick Start

```bash
# CLI (BLE)
python tools/clip-cli.py status

# CLI (WiFi - connect to device AP first)
python tools/clip-cli.py --transport wifi status

# Web UI
python tools/clip-web.py --transport wifi
```

## File Structure

```
applications/clip/tests/
├── clip/                  # SDK library
│   ├── __init__.py        # Public exports
│   ├── client.py          # BLE client (ClipDevice)
│   ├── commands.py        # AT command API (ClipCommands)
│   ├── transfer.py        # File transfer (SessionSync, FileTransfer)
│   ├── codec.py           # OGG Opus encoding/decoding
│   ├── wifi.py            # WiFi UDP transport (WiFiDevice, WiFiSync)
│   ├── progress.py        # Unified progress display (SyncProgress)
│   ├── utils.py           # Shared utilities
│   └── exceptions.py      # Exception classes
├── tools/                 # CLI tools
│   ├── clip-cli.py        # Unified CLI (BLE + WiFi)
│   ├── clip-web.py        # Web interface backend
│   ├── static/index.html  # Web interface frontend
│   ├── record.py          # Record and real-time sync
│   ├── sync.py            # BLE session sync
│   ├── udp_sync.py        # WiFi session sync
│   ├── ble_terminal.py    # Interactive BLE terminal
│   └── decode_opus.py     # Opus to WAV converter
├── requirements.txt
├── README.md
└── EXAMPLES.md
```

## Library Usage

```python
import asyncio
from clip import ClipDevice, ClipCommands, SessionSync

async def main():
    async with ClipDevice() as device:
        cmds = ClipCommands(device)

        state = await cmds.get_state()
        print(f"Battery: {state.battery}%")

        session = await cmds.start_recording("normal")
        await asyncio.sleep(10)
        await cmds.stop_recording()

asyncio.run(main())
```

## Environment Variables

| Variable | Description |
|----------|-------------|
| `CLIP_DEVICE_ADDRESS` | BLE MAC address (skips auto-discovery) |

## See Also

- [EXAMPLES.md](EXAMPLES.md) - Detailed usage examples
- [docs/testing.md](docs/testing.md) - Testing guide (pytest, markers, fixtures)
- [docs/protocol.md](../../../docs/protocol.md) - AT command protocol
