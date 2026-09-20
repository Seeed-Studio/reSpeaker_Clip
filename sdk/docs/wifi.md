# Wi-Fi AP

## The AP

| Property | Value |
|----------|-------|
| SSID | `ClipAP_XXXX` (4 hex of the chip id) |
| Password | `12345678` by default — **re-randomized on first pairing/bond change**; read the current one from `AT+WIFI?` |
| Device IP | `192.168.4.1` (DHCP server for clients) |
| UDP service | port `8089` — AT commands and the binary transfer frames multiplexed on one socket |

The UDP transport is dependency-free and much faster than BLE for bulk
downloads. The AP auto-turns off after an idle period with no
associated station; `start_wifi()` brings it back at any time.

## Channel & regulatory domain

```python
channel, country = await clip.wifi_config()       # e.g. (36, "US")
await clip.set_wifi_config(6, "CN")               # 2.4 GHz ch 6
await clip.set_wifi_config(149, "CN")             # 5 GHz
```

Channels 1-13 are 2.4 GHz, 36-165 are 5 GHz. The setting is persisted
immediately but **applied on the next WiFi start** — cycle the AP to
take effect:

```python
await clip.stop_wifi()
await clip.start_wifi()
```

## BLE → Wi-Fi handoff

`clip.wifi.handoff_to_wifi()` is the one-call control-plane/data-plane
switch when you start on BLE:

1. sends `AT+WIFI=on` over BLE and reads the AP credentials;
2. joins the **host** to the AP with `nmcli` (Linux), `networksetup`
   (macOS), or `netsh` (Windows);
3. verifies the UDP route with `AT+GSTAT` on a fresh `UdpTransport`.

```python
from clip import BleTransport, ClipClient, UdpTransport
from clip.wifi import handoff_to_wifi

async with ClipClient(BleTransport(name="Clip")) as ble:
    ap = await handoff_to_wifi(ble)

async with ClipClient(UdpTransport()) as clip:   # host is now on the AP
    result = await clip.download_session(sid, "recordings")
```

Failures raising `HostWifiError` mean the host could not join (wrong
network manager, captive environment) — the device side is fine; join
manually and use `UdpTransport` directly. `clip.web` exposes the same
sequence behind its **Switch transfer to Wi-Fi** button.
