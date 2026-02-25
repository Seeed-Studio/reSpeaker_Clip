# reSpeaker Clip Sync Tool

## Overview

The `sync.py` tool is a Python utility for synchronizing audio recordings from the reSpeaker Clip device to your computer. It supports automatic resume, progress tracking, and file merging.

## Features

- **Automatic Sync**: Detects which files are already downloaded and only transfers missing ones
- **Resume Support**: Can resume from any point after disconnection
- **Progress Tracking**: Shows per-file and overall progress with tqdm
- **Auto-Merge**: Combines all audio segments into a single `.opus` file
- **State Detection**: Automatically detects if device is recording or idle
- **Cross-Platform**: Works on Linux, macOS, and Windows

## Requirements

```bash
pip install -r requirements.txt
```

Required packages:
- `bleak` - BLE communication
- `tqdm` - Progress bars (optional, for better UX)
- `asyncio` - Included in Python 3.7+

## Installation

The sync tool is located in the firmware repository:
```bash
cd /path/to/ReSpeaker_Clip/applications/clip/tests
python sync.py --help
```

Or install it system-wide:
```bash
# Create symlink or copy to your PATH
sudo ln -s $(pwd)/sync.py /usr/local/bin/respeaker-sync
respeaker-sync --help
```

## Usage

### Basic Usage

```bash
# Sync the latest session (auto-detected)
python sync.py

# Sync a specific session
python sync.py --session 20250225_143000

# Show device status only
python sync.py --status

# Use specific device (MAC address)
python sync.py --device AA:BB:CC:DD:EE:FF
```

### Command-Line Options

| Option | Short | Description |
|--------|-------|-------------|
| `--device` | `-d` | Device MAC address (auto-scan if not specified) |
| `--session` | `-s` | Specific session ID to sync |
| `--status` | - | Show device status and exit |
| `--oneshot` | - | Exit when no new files (default: continuous for active recordings) |

## Output Examples

### Status Query
```
Querying device status...

Device Status:
  State: IDLE
  Battery: 100%
  Mode: enhanced
```

### Sync from Completed Session
```
Found 22 existing local files
  Local: 001.opus, 002.opus, 003.opus, 004.opus, 005.opus...
  Device reports: 22 files in session
  All 22 files already synced locally
============================================================
✓ Sync Complete!
  Session: 20250225_143000
  Total files: 22
  Newly synced: 0
  Status: All files up to date
============================================================
```

### Sync from Active Recording
```
Device is recording, getting latest session...
Latest session: 20250225_143000
  Using continuous mode (will keep syncing new files)

Found 0 existing local files
  Device reports: 0 files in session (still recording)
  Starting sync from: beginning

  Overall (143000):   0%|          | 0/15 [00:00<?, ?it/s]

  [FILE READY] 001.opus (52598 bytes)
  001.opus: 100%|██████████| 52.6K/52.6K [00:01<00:00, 48.5KB/s]

  [SAVED] 001.opus (52598 bytes)

... (transfer continues)

  Still recording... (5 files so far, press Ctrl+C to stop)

============================================================
✓ Sync Complete!
  Session: 20250225_143000
  Total files: 5
  Newly synced: 5
  Location: /path/to/downloads/20250225_143000
============================================================
```

### Resume After Disconnect
```
Found 10 existing local files
  Local: 001.opus, 002.opus, ..., 010.opus
  Device reports: 22 files in session
  Remaining to sync: ~12 files
  Resuming from: 011.opus

  [FILE READY] 011.opus (51300 bytes)
  011.opus: 100%|██████████| 51.3K/51.3K [00:01<00:00, 45.2KB/s]

  [SAVED] 011.opus (51300 bytes)

... (continues from 011.opus onwards)
```

## Session States

The sync tool automatically detects the device state and adjusts behavior:

### IDLE State (Recording Stopped)
- Uses `--oneshot` mode by default
- Exits when no new files for 10 seconds
- Shows "All files synced" message when complete

### RECORDING State (Active Recording)
- Uses continuous mode by default
- Keeps checking for new files every 30 seconds
- Shows "Still recording..." message with current count
- Press Ctrl+C to stop

## File Handling

### File Naming Convention

Files are named sequentially: `001.opus`, `002.opus`, `003.opus`, etc.

### Skip Existing Files

The tool automatically skips files that already exist locally with the same size:
```
[SKIP] 015.opus already exists (51300 bytes)
```

### File Merging

After all files are synced, they are merged into a single `.opus` file:
```
Merging 22 files -> 20250225_143000.opus...
  + 001.opus (52598 bytes)
  + 002.opus (48124 bytes)
  ...
  + 022.opus (44828 bytes)
✓ Merged: 20250225_143000.opus (974538 bytes)
✓ Files saved to: /path/to/downloads/20250225_143000
```

## Directory Structure

```
downloads/
├── 20250225_143000/          <- Session directory
│   ├── 001.opus              <- Individual segments
│   ├── 002.opus
│   ├── ...
│   └── 022.opus
└── 20250225_143000.opus      <- Merged complete recording
```

## Troubleshooting

### Device Not Found
```
Device 'reSpeaker' not found
```
- Make sure device is powered on
- Bring device close to computer (BLE range ~10 meters)
- Try specifying MAC address: `--device AA:BB:CC:DD:EE:FF`

### Connection Lost
```
[!] Connection lost!
```
- The tool will automatically attempt to reconnect
- If recording is in progress, device continues recording
- Re-run the tool to resume sync

### Files Not Being Saved
- Check that the session directory is writable
- Ensure disk has enough space
- Look for `[SAVED]` messages in output

### Progress Bar Not Showing
- Install tqdm for better UX: `pip install tqdm`
- Progress bars require a terminal that supports ANSI escape codes

## Advanced Usage

### Sync Multiple Sessions

```bash
# Sync all sessions from a device
for session in $(python sync.py --list-sessions); do
    python sync.py --session "$session"
done
```

### Background Sync

```bash
# Run in background (nohup for persistence)
nohup python sync.py --session 20250225_143000 > sync.log 2>&1 &

# Check progress
tail -f sync.log
```

### Monitor Active Recording

```bash
# Continuously sync while recording
python sync.py

# Press Ctrl+C when done
# The tool will finish transferring the current file before exiting
```

## Error Messages

| Error | Cause | Solution |
|-------|-------|----------|
| `Device 'reSpeaker' not found` | Device not in range | Bring closer or specify MAC address |
| `Connection failed` | BLE error | Check device is powered on |
| `Transfer already in progress` | Device busy | Send `AT+CANCEL` or wait |
| `Session not found` | Invalid session ID | Check with `AT+LIST` |
| `No sessions to sync` | No recordings exist | Record something first |

## Integration with Other Tools

### Decode Opus to WAV

```bash
# After sync, decode to WAV for playback
python decode_opus.py downloads/20250225_143000.opus
```

### Analyze Recording

```bash
# Get session info
python sync.py --status

# List files in session directory
ls -lh downloads/20250225_143000/
```

## Version History

- **v1.0** (2025-02-25) - Initial release
  - Basic sync functionality
  - Resume support
  - Progress bars
  - Auto-merge
  - Disconnect/reconnect handling

## Support

For issues or questions:
1. Check device logs via serial console
2. Run with `--status` to verify device state
3. Check GitHub issues for known problems
