# WiFi + BLE Coexistence Sample

Verifies that the 5 GHz WiFi AP (nRF7002) and BLE can run simultaneously on
the Clip board with the PTA coexistence configuration (`NRF70_SR_COEX`).
Based on `wifi_ap_iperf` plus a minimal BLE GATT throughput service.

## Build

```sh
west build --build-dir build-wifi-ble-coex --board clip/nrf5340/cpuapp samples/wifi_ble_coex
west flash --build-dir build-wifi-ble-coex && nrfutil device reset
```

## Usage

Shell commands (UART console, `minicom -D /dev/ttyACM0 -b 921600`):

```
wifi_ap start|stop|status   # 5 GHz AP (ch36), SSID ClipAP_XXXX pass 12345678
ble start|stop|status       # BLE advertising + GATT throughput service
iperf <pc_ip> [sec] [kbps]  # zperf UDP upload to a PC on the AP
```

- **BLE throughput**: connect to the `ClipCoex` BLE device, enable
  notifications on the throughput characteristic — the device streams data
  and prints kbps every second.
- **WiFi iperf**: connect a PC to the AP, run `iperf -s -i 1 -u` on the PC,
  then `iperf <PC_IP>` on the device.
