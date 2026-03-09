# ReSpeaker Clip - Quick Test Reference

## Quick Start

```bash
# 1. Build and flash
source ~/ncs/v3.2.1/zephyr/zephyr-env.sh
export ZEPHYR_EXTRA_MODULES=$(pwd)
west build --build-dir build-test --pristine --board clip/nrf5340/cpuapp tests/clip
west flash --build-dir build-test && nrfutil device reset

# 2. Connect serial (921600 baud)
minicom -D /dev/ttyACM0 -b 921600
```

## Quick Test Commands

### Power Up Test
```
pmic status          # Check battery and power
```

### Display Test
```
oled test           # Full display test
oled brightness 200 # Set brightness
```

### Sensor Test
```
imu init            # Initialize IMU
imu read            # Read sensor data
imu monitor 5       # Monitor 5 readings
```

### Motor Test
```
motor pattern sos   # SOS pattern test
motor pulse 200     # 200ms pulse
```

### Connectivity Test
```
ble scan            # Scan for BLE devices
wifi on             # Enable WiFi
wifi scan           # Scan for WiFi networks (2.4G + 5G)
wifi scan 1         # Scan 2.4GHz only
wifi scan 2         # Scan 5GHz only
wifi connect <SSID> [password]  # Connect to WiFi
wifi status         # Show status and IP address
wifi disconnect      # Disconnect from WiFi
```

### WiFi Throughput Test (requires iperf on PC)
```
# Step 1: Install iperf (iperf2) on PC
# Linux: sudo apt-get install iperf
# macOS: brew install iperf
# Windows: Download iperf.exe from https://iperf.fr

# Step 2: Start iperf server on PC (UDP mode)
iperf -s -u -p 5001

# Step 3: Run test from device
wifi status          # Get device IP first (shows IP address)
iperf <PC_IP>        # UDP test (10s, 100Mbps default)
iperf <PC_IP> 30      # 30 second test
iperf <PC_IP> 10 50000 # 10 second test at 50 Mbps

# Expected: 5-15 Mbps UDP upload, <1% packet loss
```

### Storage Test
```
sd mount            # Mount SD card
fs ls /SD:          # List files
mic capture 5       # 5-second audio capture
```

## Test Checklist

| Test | Command | Pass Criteria |
|------|---------|---------------|
| Display | `oled test` | All patterns visible |
| Battery | `pmic status` | Voltage 3.3-4.2V |
| IMU | `imu init` → `imu read` | Accel ~1000 at rest |
| Motor | `motor pulse 200` | 200ms vibration |
| WiFi | `wifi on` → `wifi scan` | Networks found |
| BLE | `ble` | Shows "advertising" |
| SD Card | `sd mount` → `fs ls /SD:` | No errors |
| Mic | `mic capture 3` | Creates file |

## Expected Sensor Values (at rest)

```
IMU (LSM6DS3TR):
  Accel X,Y,Z: ~0 to +2000 (device orientation dependent)
  Gyro X,Y,Z: ~0 to ±100 (some drift is normal)

Battery (charging):
  Voltage: 3.7V-4.2V (charging), 3.3V-3.7V (discharging)
  Charging: "yes" when USB connected
```

## Troubleshooting Quick Guide

| Problem | Solution |
|---------|----------|
| IMU fails init | Check board - IMU may not be populated |
| WiFi won't connect | 2.4GHz only, check password |
| SD card errors | Reformat as FAT32, size 4-32GB |
| Display blank | Check `oled brightness` |
| Device won't wake | `pmic ship` was used - connect USB |

## Hardware Pin Quick Ref

```
GPIO0.2 (NFC1)  → IMU Power Enable
GPIO0.3 (NFC2)  → IMU Interrupt
GPIO1.0         → IMU SDA
GPIO1.1         → IMU SCL
GPIO1.6         → Motor Control
GPIO1.8         → OLED Power Enable
GPIO1.14        → Mic Power Enable
GPIO1.15        → User Button
```

## Default I2C Addresses

```
0x3C - CH1115 OLED Display
0x6A - LSM6DS3TR IMU (SA0=0)
0x6B - NPM1300 PMIC
```

## Memory & Performance

```
Flash:  802 KB / 1 MB (76%)
RAM:    364 KB / 448 KB (79%)
Baud:   921600
```

## Exit Test Mode

```bash
# To exit test mode and run normal application:
west build --build-dir build-clip --pristine --board clip/nrf5340/cpuapp applications/clip
west flash --build-dir build-clip && nrfutil device reset
```
