# reSpeaker Clip Test Scripts

This directory contains test scripts for the reSpeaker Clip device.

## BLE Protocol Test Script

The `ble_test.py` script provides comprehensive testing of the BLE AT command protocol implemented in the reSpeaker Clip firmware.

### Installation

Install the required Python dependencies:

```bash
pip install -r requirements.txt
```

Or manually install:

```bash
pip install bleak>=0.21.0
```

### Usage

**Auto-discover and test all:**
```bash
python ble_test.py
```

**Connect to specific device:**
```bash
python ble_test.py --device AA:BB:CC:DD:EE:FF
```

**Run specific test:**
```bash
python ble_test.py --test gstat
python ble_test.py --test recording_control
python ble_test.py --test file_transfer
```

**Interactive mode:**
```bash
python ble_test.py --interactive
```

### Test Categories

The test suite includes the following tests:

1. **Connection Tests**
   - Basic BLE connectivity

2. **Status Commands**
   - `AT+GSTAT` - Device status
   - `AT+VERSION` - Version information
   - `AT+TIME` - System time
   - `AT+PAIR` - Pairing status

3. **Configuration Commands**
   - `AT+BITRATE` - Opus bitrate
   - `AT+COMPLEXITY` - Encoding complexity
   - `AT+MODE` - Recording mode
   - `AT+CHUNKSIZE` - Transfer chunk size

4. **Recording Tests**
   - Recording control (start/stop)
   - Bookmark functionality

5. **File Transfer Tests**
   - Session listing
   - File listing
   - File download
   - Non-blocking commands during transfer

6. **Error Handling**
   - Invalid commands
   - Invalid parameters
   - Non-existent files

### Interactive Mode

Interactive mode allows manual testing of the device:

```
> help                    # Show help
> gstat                   # Get device status
> start normal            # Start recording
> mark Important point    # Add bookmark
> stop                    # Stop recording
> list                    # List sessions
> download 20240203_100000/001.opus  # Download file
> bitrate 32000           # Set bitrate
> quit                    # Exit
```

### Test Output

The test script provides detailed output showing:

```
============================================================
reSpeaker Clip BLE Protocol Test Suite
============================================================
  ✓ Connection Test
  ✓ AT+GSTAT
    State: IDLE
    Battery: 85%
    Charging: False
    Mode: normal
    Bitrate: 24000
  ✓ AT+VERSION
    Firmware: 1.0.0
    Hardware: 1.0
    SDK: 3.2.1
    Build: 2024-02-03
...

============================================================
Test Summary: 15/15 passed
============================================================
```

### Troubleshooting

**Device not found:**
- Make sure the device is powered on
- Check that the device is advertising
- Verify the device name filter in the script (default: "reSpeaker")

**Connection failed:**
- Make sure the device is not connected to another device
- Try resetting the device
- Check BLE is enabled on your computer

**Tests timing out:**
- Increase the timeout values in the script
- Check the device is responsive

**File transfer issues:**
- Make sure there are recorded sessions on the SD card
- Check the session and file paths are correct

### Platform Support

The `bleak` library supports:
- **Windows**: Windows 10+ with Bluetooth
- **Linux**: BlueZ-compatible Bluetooth stack
- **macOS**: macOS 10.11+ with Bluetooth

### Development

To add new tests:

1. Add a test method to the `BLEProtocolTests` class:
```python
async def test_my_new_test(self):
    name = "My New Test"
    try:
        # Your test code here
        response = await self.client.send_command("AT+MYCOMMAND")
        if response.get("ok"):
            self.results.add_pass(name)
        else:
            self.results.add_fail(name, response.get("error"))
    except Exception as e:
        self.results.add_fail(name, str(e))
```

2. Run the test:
```bash
python ble_test.py --test my_new_test
```

### Requirements

- Python 3.7+
- bleak 0.21.0+
- BLE 4.0+ capable adapter
- reSpeaker Clip device with working firmware
