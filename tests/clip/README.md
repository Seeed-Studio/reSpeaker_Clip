# ReSpeaker Clip Hardware Test Suite

## Overview

This test suite provides comprehensive testing for all hardware components on the ReSpeaker Clip board based on nRF5340.

## Building

```bash
# Set environment
source ~/ncs/v3.2.1/zephyr/zephyr-env.sh
export ZEPHYR_EXTRA_MODULES=$(pwd)

# Build
west build --build-dir build-test --pristine --board clip/nrf5340/cpuapp tests/clip

# Flash and reset
west flash --build-dir build-test && nrfutil device reset
```

## Serial Configuration

- **Baud Rate**: 921600
- **Port**: /dev/ttyACM0 (or appropriate USB-serial port)
- **Connect**: `minicom -D /dev/ttyACM0 -b 921600`

## Test Modules

### 1. BLE Test

**Purpose**: Test Bluetooth Low Energy functionality

**Commands**:
```bash
ble                   # Show BLE status
ble scan             # Scan for BLE devices
```

**Expected Results**:
- Device advertises as "Clip_Test"
- BLE scan shows nearby devices

### 2. WiFi Test

**Purpose**: Test nRF7002 WiFi module connectivity and throughput

**Device Configuration**:
- MAC Address: 14:5A:FC:5E:37:9C (fixed in prj.conf)
- Supports: 2.4GHz + 5GHz dual-band (802.11 b/g/n/ac)

**Basic Commands**:
```bash
wifi on              # Enable WiFi module
wifi scan            # Scan for networks (shows SSID, RSSI, Channel, BAND)
wifi scan 0          # Scan all bands (default)
wifi scan 1          # Scan 2.4GHz only
wifi scan 2          # Scan 5GHz only
wifi connect <SSID> [password]  # Connect to network
wifi status          # Show status and IP address
wifi disconnect      # Disconnect from network
```

**Expected Results**:
- WiFi powers on successfully (no error messages)
- Scan finds available networks with RSSI values
- Connection establishes with valid credentials
- DHCP assigns IP address (usually 192.168.x.x)

---

#### WiFi Throughput Testing (with iperf2)

**Overview**: Device uses `iperf` command which is **iperf2 compatible** for UDP throughput testing.

**Test Type**: UDP upload from device to PC (device sends, PC receives)

**Default Parameters**:
- Server IP: 192.168.1.100
- Port: 5001
- Duration: 10 seconds
- Rate: 100 Mbps (100000 kbps)

**Test Procedure**:

**Step 1: Find device IP address**
```bash
# On device
wifi status
# Example output: IP: 192.168.1.100
```

**Step 2: Start iperf2 server on PC**
```bash
# On PC - Start iperf2 server (UDP mode)
iperf -s -u -p 5001

# Or with verbose output
iperf -s -u -p 5001 -i 1

# Note: Most systems have 'iperf' which is iperf2
# Windows: Download iperf.exe from https://iperf.fr
```

**Step 3: Run iperf test on device**
```bash
# On device - Run UDP throughput test
iperf                       # Use defaults (192.168.1.100, 10s, 100Mbps)
iperf 192.168.1.100         # Specify PC IP
iperf 192.168.1.100 30      # 30 second test
iperf 192.168.1.100 10 50000 # 10 second test at 50 Mbps
```

**Expected Device Output**:
```
Test completed!
  Packets sent: 7300
  Packets lost: 25
  Packets received: 7275
  Bytes sent: 10220000
  Time: 10000 ms
  Throughput: 8100 kbps (8.100 Mbps)
```

**Expected PC Output**:
```
------------------------------------------------------------
Server listening on UDP port 5001
Receiving 1470 byte datagrams
UDP buffer size: 208 KByte (default)
------------------------------------------------------------
[  5] local 192.168.1.100 port 5001 connected with 192.168.1.100 port 49153
[ ID] Interval       Transfer     Bitrate
[  5]   0.00-10.00  sec  10.2 MBytes  8.10 Mbits/sec
[  5]  -  -  -  -  -  -  -  -  -  -  -  -
[  5]   0.00-10.00  sec  1 datagram  0.00 bits/sec
------------------------------------------------------------
```

**Expected Throughput**:
- UDP Upload: 5-15 Mbps (typical for 2.4GHz WiFi)
- Packet loss: <1% in good conditions

**Command Parameters**:
| Parameter | Description | Range | Default |
|-----------|-------------|-------|---------|
| server_ip | PC IP address | Any valid IP | 192.168.1.100 |
| duration_sec | Test duration | 1-3600 seconds | 10 |
| rate_kbps | Send rate | 100-1000000 kbps | 100000 |

**Troubleshooting WiFi Issues**:

| Problem | Solution |
|---------|----------|
| No networks found | Check antenna connection, verify router is powered on |
| Only 2.4G networks, no 5G | Verify router has 5GHz enabled, check signal strength, try `wifi scan 2` |
| Connection fails | Verify SSID/password, check router security type |
| No IP address | Check DHCP on router, try static IP |
| Low throughput | Check interference, distance from router, reduce rate |
| "WiFi not connected" | Run `wifi connect` first |
| High packet loss | Reduce rate (try 50000 or lower), check WiFi signal |

**Note on 5GHz Support**:
The nRF7002 supports both 2.4GHz and 5GHz bands. If you only see 2.4G networks in scan results:
1. Verify your router has 5GHz enabled (many "dual-band" routers have separate 2.4G and 5G SSIDs)
2. Try `wifi scan 2` to scan 5GHz networks only
3. Check distance - 5GHz has shorter range than 2.4GHz
4. Some 5GHz channels may not be available in your region


---

### 3. SD Card Test

**Purpose**: Test SD card file system operations

**Commands**:
```bash
sd mount             # Mount SD card
fs ls /SD:           # List files
sd eject             # Eject SD card
```

**Expected Results**:
- SD card mounts when present
- File listing works correctly
- Eject safely unmounts

### 4. Microphone Test

**Purpose**: Test PDM microphone audio capture

**Commands**:
```bash
mic capture [time_sec]  # Capture audio (default 5 seconds)
```

**Expected Results**:
- Audio capture starts and stops
- Data is written to SD card

### 5. Button Test

**Purpose**: Test user button functionality

**Expected Results**:
- Button presses are detected
- Multi-press and long-press work correctly

### 6. OLED Display Test

**Purpose**: Test CH1115 OLED display (88x48)

**Commands**:
```bash
oled test            # Run automated test
oled clear           # Clear display
oled fill            # Fill display
oled pattern         # Show test pattern
oled circle          # Draw circle
oled pixels          # Draw test pixels
oled brightness <0-255>  # Set brightness
oled help            # Show all commands
```

**Expected Results**:
- Display shows test patterns correctly
- Brightness adjustment works
- No visible artifacts

### 7. PMIC Test

**Purpose**: Test NPM1300 PMIC battery and power management

**Commands**:
```bash
pmic status          # Show battery/charger status
pmic monitor         # Continuously monitor status
pmic regulator <mic|oled|rfsw> <on|off>  # Control regulators
pmic ship            # Enter ship mode (power off)
```

**Expected Results**:
- Battery voltage and percentage display correctly
- Charging status accurate
- Regulator control works
- Ship mode powers off device

### 8. Motor Test

**Purpose**: Test vibration motor

**Commands**:
```bash
motor on             # Turn motor on
motor off            # Turn motor off
motor pulse <ms>     # Pulse for duration
motor pattern <short|double|long|sos|alert>  # Play pattern
motor test           # Run motor test
```

**Expected Results**:
- Motor turns on/off correctly
- Pulse duration is accurate
- Patterns play as expected

### 9. IMU Test

**Purpose**: Test LSM6DS3TR 6-axis IMU sensor

**Commands**:
```bash
imu init             # Initialize IMU and configure
imu read             # Read sensor data
imu monitor [n]      # Monitor n iterations (default 10)
imu scan             # Scan I2C bus
imu selftest         # Run self-test
```

**Expected Results**:
- IMU initializes and detects at address 0x6A
- WHO_AM_I returns 0x6C or 0x6A
- Accelerometer and gyroscope data update
- Values change when device is moved

**Interpreting Sensor Data**:
- **Accelerometer**: +/- 4g range, ~1000 LSB/g at rest
- **Gyroscope**: +/- 500dps range, ~0 LSB/s at rest

## Troubleshooting

### IMU Not Detected

**Symptoms**: WHO_AM_I returns 0x00 or no device found

**Solutions**:
1. Check IMU is powered: GPIO0.2 should be high
2. Verify I2C connections: GPIO1.0 (SDA), GPIO1.1 (SCL)
3. Check SDO/SA0 pin is grounded (I2C address 0x6A)
4. Ensure I2C pull-ups are connected to GPIO0.2
5. Run `imu scan` to check for any I2C devices

### PMIC Ship Mode

**Important**: After entering ship mode (`pmic ship`), the device will power off. To wake:
- Connect USB cable
- Press button
- Apply voltage to VBUS

### SD Card Issues

**Symptoms**: Card not mounting or errors

**Solutions**:
1. Check card is properly inserted
2. Try reformatting card as FAT32
3. Use `sd eject` before removing card
4. Check for transient sync errors (these are normal)

### WiFi Connection Failures

**Symptoms**: Cannot connect to WiFi

**Solutions**:
1. Check SSID and password are correct
2. Ensure WiFi router is 2.4GHz (nRF7002 is 2.4GHz only)
3. Check antenna is connected
4. Try `wifi on` then scan before connecting

## Hardware Specifications

### Pin Assignments

| Function | GPIO | Description |
|----------|------|-------------|
| Button | GPIO1.15 | User button (active low) |
| IMU SDA | GPIO1.0 | I2C data (software) |
| IMU SCL | GPIO1.1 | I2C clock (software) |
| IMU INT1 | GPIO0.3 | IMU interrupt |
| IMU VDD_EN | GPIO0.2 | IMU power enable (NFC1) |
| Motor Ctrl | GPIO1.6 | Vibration motor control |
| Mic VDD_EN | GPIO1.14 | Microphone power enable |
| OLED VDD_EN | GPIO1.8 | OLED power enable |
| RFSW VDD_EN | GPIO0.29 | WiFi RF switch enable |

### I2C Devices

| Device | Address | Bus | Description |
|--------|---------|-----|-------------|
| NPM1300 PMIC | 0x6B | I2C1 | Power management IC |
| CH1115 OLED | 0x3C | I2C2 | Display controller |
| LSM6DS3TR IMU | 0x6A | Software I2C | 6-axis IMU sensor |

### Power Supply

- **USB**: 5V VBUS for charging and main power
- **Battery**: Li-Po battery managed by NPM1300
- **Regulators**:
  - BUCK1: MOTOR_3V3 (vibration motor)
  - BUCK2: VDD_3V3 (main system)
  - LDO1: VDDMIC_1V8 (microphone)
  - LDO2: VDD_SD (SD card)

## Memory Usage

```
FLASH:      802 KB (76.5% of 1 MB)
RAM:        364 KB (79.4% of 448 KB)
```

## Test Coverage Matrix

| Module | Power | Comm | Config | Read | Write |
|--------|-------|------|--------|------|-------|
| BLE | ✓ | ✓ | ✓ | - | - |
| WiFi | ✓ | ✓ | ✓ | - | - |
| SD Card | ✓ | - | - | ✓ | ✓ |
| Mic | ✓ | - | ✓ | - | - |
| Button | ✓ | - | - | ✓ | - |
| OLED | ✓ | ✓ | ✓ | - | - |
| PMIC | - | ✓ | ✓ | ✓ | ✓ |
| Motor | ✓ | - | - | - | - |
| IMU | ✓ | ✓ | ✓ | ✓ | ✓ |

## Development Notes

### Adding New Tests

1. Create source file in `tests/clip/src/`
2. Create header file in `tests/clip/src/`
3. Add to CMakeLists.txt
4. Initialize in main.c
5. Add shell commands

### Code Style

- Follow Zephyr coding style
- Use LOG_MODULE_REGISTER for logging
- Return negative errno on errors
- Check device_is_ready() before using devices

### Shell Commands

Use SHELL_CMD_* macros for shell command registration:
- SHELL_CMD: Simple command
- SHELL_CMD_ARG: Command with arguments
- SHELL_STATIC_SUBCMD_SET_CREATE: Subcommand hierarchy

## Version History

- 2025-03-09: Added IMU test module with software I2C
- 2025-03-09: Added vibration motor test commands
- 2025-03-09: Added PMIC (NPM1300) test commands
- 2025-03-09: Added OLED display test commands
- 2023: Initial test suite framework

## License

Copyright (c) 2023 Nordic Semiconductor ASA

SPDX-License-Identifier: LicenseRef-Nordic-5-Clause
