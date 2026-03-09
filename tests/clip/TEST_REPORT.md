# ReSpeaker Clip Test Report

**Device Serial**: ___________________
**Test Date**: ___________________
**Tester**: ___________________
**Firmware Version**: _____________
**Result**: [ ] PASS [ ] FAIL

## Test Environment

- [ ] USB cable connected
- [ ] Serial port: /dev/ttyACM0 @ 921600 baud
- [ ] SD card inserted (4-32GB, FAT32)
- [ ] WiFi available (2.4GHz)
- [ ] Battery charged (>3.7V)

## Test Results

### 1. System Startup
| Test | Expected | Actual | Result |
|------|----------|--------|--------|
| Boot message | "Starting..." | ______ | [ ] [ ] |
| Serial output | No errors | ______ | [ ] [ ] |
| Memory stats | <80% Flash, <85% RAM | ______ | [ ] [ ] |

### 2. OLED Display (CH1115)
| Test | Command | Expected | Actual | Result |
|------|---------|----------|--------|--------|
| Power on | `oled test` | Display shows patterns | ______ | [ ] [ ] |
| Brightness | `oled brightness 255` | Max brightness | ______ | [ ] [ ] |
| Brightness | `oled brightness 50` | Dim display | ______ | [ ] [ ] |
| Clear | `oled clear` | Blank screen | ______ | [ ] [ ] |
| Pixels | `oled pixels` | Test pattern visible | ______ | [ ] [ ] |

**Notes**: _________________________________________________
_________________________________________________________

### 3. PMIC / Battery (NPM1300)
| Test | Command | Expected | Actual | Result |
|------|---------|----------|--------|--------|
| Battery status | `pmic status` | Voltage 3.3-4.2V | ______ | [ ] [ ] |
| Charging | `pmic status` (USB in) | Shows "charging" | ______ | [ ] [ ] |
| Regulator | `pmic regulator mic on` | No error | ______ | [ ] [ ] |
| Regulator | `pmic regulator mic off` | No error | ______ | [ ] [ ] |
| Ship mode | `pmic ship` | Powers off | ______ | [ ] [ ] |

**Battery Voltage**: ______ V
**Charging Status**: ______
**Notes**: _________________________________________________

### 4. IMU Sensor (LSM6DS3TR)
| Test | Command | Expected | Actual | Result |
|------|---------|----------|--------|--------|
| Initialize | `imu init` | "LSM6DS3 detected" | ______ | [ ] [ ] |
| WHO_AM_I | Check log | 0x6C or 0x6A | ______ | [ ] [ ] |
| Read at rest | `imu read` | Gyro ~0 | ______ | [ ] [ ] |
| Tilt X | `imu read` | Accel X changes | ______ | [ ] [ ] |
| Tilt Y | `imu read` | Accel Y changes | ______ | [ ] [ ] |
| Rotate | `imu read` | Gyro values change | ______ | [ ] [ ] |
| Monitor | `imu monitor 5` | 5 readings | ______ | [ ] [ ] |

**Device Address**: ______
**WHO_AM_I**: ______
**Notes**: _________________________________________________

### 5. Vibration Motor
| Test | Command | Expected | Actual | Result |
|------|---------|----------|--------|--------|
| Turn on | `motor on` | Motor runs | ______ | [ ] [ ] |
| Turn off | `motor off` | Motor stops | ______ | [ ] [ ] |
| Pulse | `motor pulse 500` | 500ms pulse | ______ | [ ] [ ] |
| Pattern | `motor pattern sos` | SOS pattern | ______ | [ ] [ ] |
| Pattern | `motor pattern alert` | Alert pattern | ______ | [ ] [ ] |

**Notes**: _________________________________________________

### 6. WiFi (nRF7002)
| Test | Command | Expected | Actual | Result |
|------|---------|----------|--------|--------|
| Enable | `wifi on` | "WiFi ready" | ______ | [ ] [ ] |
| Scan | `wifi scan` | Networks listed | ______ | [ ] [ ] |
| Connect | `wifi connect <SSID>` | Connected | ______ | [ ] [ ] |
| IP/Status | `wifi status` | IP address shown | ______ | [ ] [ ] |
| Throughput | `zperf download <PC_IP>` | 5-15 Mbps | ______ | [ ] [ ] |

**Networks Found**: ______
**Connected to**: ______
**IP Address**: ______
**TCP Throughput**: ______ Mbps
**UDP Throughput**: ______ Mbps
**iperf3 installed on PC**: [ ] Yes [ ] No [ ] N/A
**Notes**: _________________________________________________
_________________________________________________________

### 7. Bluetooth
| Test | Command | Expected | Actual | Result |
|------|---------|----------|--------|--------|
| Status | `ble` | Advertising | ______ | [ ] [ ] |
| Scan | `ble scan` | Devices found | ______ | [ ] [ ] |

**Device Name**: Clip_Test
**Notes**: _________________________________________________

### 8. SD Card
| Test | Command | Expected | Actual | Result |
|------|---------|----------|--------|--------|
| Mount | `sd mount` | Mounted successfully | ______ | [ ] [ ] |
| List | `fs ls /SD:` | Files listed | ______ | [ ] [ ] |
| Eject | `sd eject` | Ejected successfully | ______ | [ ] [ ] |

**Card Size**: ______
**Files Present**: ______
**Notes**: _________________________________________________

### 9. Microphone
| Test | Command | Expected | Actual | Result |
|------|---------|----------|--------|--------|
| Capture | `mic capture 3` | File created | ______ | [ ] [ ] |
| File check | `fs ls /SD:` | New file present | ______ | [ ] [ ] |

**File Created**: ______
**Notes**: _________________________________________________

### 10. Button
| Test | Action | Expected | Actual | Result |
|------|--------|----------|--------|--------|
| Press | Press button | Event logged | ______ | [ ] [ ] |
| Long press | Hold 2s | Event logged | ______ | [ ] [ ] |

**Notes**: _________________________________________________

## Issues Found

| ID | Module | Description | Severity |
|----|--------|-------------|----------|
| 1 | | | [ ] Low [ ] Med [ ] High |
| 2 | | | [ ] Low [ ] Med [ ] High |
| 3 | | | [ ] Low [ ] Med [ ] High |

## Overall Assessment

- [ ] All tests passed
- [ ] Minor issues (see above)
- [ ] Major issues (see above)
- [ ] Cannot complete testing

## Recommendations

_________________________________________________________
_________________________________________________________
_________________________________________________________

## Sign-off

**Tester Signature**: ___________________
**Date**: ___________________
