# BLE Direct Test Mode (DTM) for Clip

Bluetooth Direct Test Mode firmware for RF testing and certification on the reSpeaker Clip board.

## Overview

DTM is a Bluetooth SIG standard test mode for RF conformance testing. It uses a 2-wire UART interface at 19200 baud to control radio TX/RX operations.

The Clip board uses nRF5340 dual-core architecture:
- **Network core (cpunet)**: Runs DTM firmware controlling the radio
- **Application core (cpuapp)**: Runs remote_shell to bridge IPC to physical UART (P1.04/P1.05)

## Build

```sh
source ~/ncs/v3.3.0/zephyr/zephyr-env.sh
export ZEPHYR_EXTRA_MODULES=$(pwd)
west build --build-dir build-dtm --pristine --board clip/nrf5340/cpunet tests/dtm
```

## Flash

```sh
west flash --build-dir build-dtm && nrfutil device reset
```

This flashes both the cpunet (DTM) and cpuapp (remote_shell) images.

> **No MCUboot**: this is factory/cert firmware. `sysbuild.conf` sets
> `SB_CONFIG_BOOTLOADER_NONE=y` (plus `SB_CONFIG_SECURE_BOOT_NETCORE=n` and
> `SB_CONFIG_PARTITION_MANAGER=n`, so the image links at 0x0), which means the
> image is flashed **directly via J-Link** — no bootloader, no OTA slots, no
> signing.

## Hardware Connection

Connect a DTM test tool to the Clip board's UART:
- **TX**: P1.04 (Clip RX, Test Tool -> Clip)
- **RX**: P1.05 (Clip TX, Clip -> Test Tool)
- **GND**: Common ground
- **Baud rate**: 19200
- **Format**: 8N1

## Python Test Script

```python
import serial, time, threading

def send_recv(port, cmd_bytes, timeout=2):
    s = serial.Serial(port, 19200, timeout=0.2)
    s.reset_input_buffer()
    result = b''
    def reader():
        nonlocal result
        start = time.time()
        while time.time() - start < timeout:
            d = s.read(64)
            if d:
                result += d
                start = time.time()
    t = threading.Thread(target=reader)
    t.start()
    time.sleep(0.05)
    s.write(cmd_bytes)
    t.join()
    s.close()
    return result

# Example: DTM Reset
resp = send_recv('/dev/ttyUSB0', b'\x00\x00')
print(f'Reset response: {resp.hex()}')  # Expected: 0000

# TX test on channel 0, length 37, PRBS9
resp = send_recv('/dev/ttyUSB0', b'\x80\x94')
print(f'TX test response: {resp.hex()}')  # Expected: 0000

# End test
resp = send_recv('/dev/ttyUSB0', b'\xC0\x00')
print(f'End response: {resp.hex()}')  # Expected: 80XX (packet count)
```

Note: Use a parallel reader thread. The DTM response arrives within milliseconds; synchronous read after write may miss it.

## DTM Commands

DTM uses a 2-wire UART protocol with 2-byte command/response format:

```
Bit:  15-14  13-8     7-2      1-0
      Cmd    Channel  Length   PktType
```

| Command     | Bits 15-14 | Hex      | Description            |
|-------------|-----------|----------|------------------------|
| Reset       | 00        | `00 00`  | Reset DTM state        |
| RX Test     | 01        | `01 XX`  | Start RX on channel XX |
| TX Test     | 10        | `80 XX`  | Start TX (see below)   |
| Test End    | 11        | `C0 00`  | Stop test, get count   |

### Setup Commands (cmd=00)

| Sub-cmd | Parameter     | Hex      | Description             |
|---------|---------------|----------|-------------------------|
| Reset   | 0x00-0x03     | `00 00`  | Reset state             |
| Set PHY | PHY value     | `02 XX`  | 0x08=2M, 0x04=1M, etc  |
| Read Feat| 0x00-0x03    | `01 08`  | Read supported features |
| Set Power| dBm value    | `09 XX`  | Set TX power            |

### TX Test Encoding

```
Byte 1: (2 << 6) | (channel & 0x3F)
Byte 2: (length & 0x3F) << 2 | (pkt_type & 0x03)
```

Packet types: 0=PRBS9, 1=0x0F, 2=0x55, 3=0xFF/Vendor

### Response Format

```
Bit 15:    0=Status Event, 1=Packet Report
Bits 14-0: Status (0=success) or packet count
```

## Troubleshooting

- **No response on UART**: Verify baud rate is 19200, check TX/RX wiring (P1.04=RX, P1.05=TX)
- **Build errors**: Ensure `ZEPHYR_EXTRA_MODULES` points to the Clip project root
- **Flash fails**: Try `nrfutil device recover` to unlock the device
- **Missing response in Python**: Use a parallel reader thread, not synchronous read after write

## References

- Nordic DTM Sample: nrf/samples/bluetooth/direct_test_mode
- Nordic Remote Shell Sample: nrf/samples/nrf5340/remote_shell
