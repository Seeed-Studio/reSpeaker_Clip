# Quick start

## Install

```sh
cd sdk
python -m pip install -e '.[dev,ble]'   # development + BLE transport
pytest                                   # 21 tests, no hardware needed
```

The Wi-Fi/UDP transport needs only the Python standard library. `bleak`
(BLE) is optional: install `'.[ble]'` to use `BleTransport`. The
browser panel needs `'.[web]'`.

## First contact over BLE

The device advertises as `Clip XXXX` (4 hex of the chip id):

```python
import asyncio
from clip import BleTransport, ClipClient

async def main() -> None:
    async with ClipClient(BleTransport(name="Clip")) as clip:
        print(await clip.status())
        print(await clip.battery())
        print(await clip.firmware_version())

asyncio.run(main())
```

`BleTransport(address=None, *, name="Clip", connect_timeout=15.0)` scans
by name prefix when no address is given; pass a MAC/address to skip
scanning. Pairing is Just Works — no PIN.

## Record, list, download

```python
async with ClipClient(BleTransport(name="Clip")) as clip:
    await clip.set_time(0)                  # sync clock to host time
    session_id = await clip.start_recording(mode="enhanced")
    await asyncio.sleep(30)
    await clip.stop_recording()

    sessions = await clip.list_all_sessions()   # newest first
    result = await clip.download_session(sessions[0].id, "recordings")
    print(result.files)                        # downloaded file paths
```

Large sessions download much faster over Wi-Fi — see
[wifi.md](wifi.md) for the BLE → Wi-Fi handoff, and
[transfers.md](transfers.md) for resume / CRC / cancel semantics.

## Wi-Fi / UDP only

If the AP is already running (`ClipAP_XXXX`, default password
`12345678`, device at `192.168.4.1:8089`):

```python
from clip import ClipClient, UdpTransport

async with ClipClient(UdpTransport()) as clip:   # 192.168.4.1:8089
    print(await clip.storage())
```

## Command line

```sh
clip-sdk --transport ble status            # JSON one-shots
clip-sdk --transport ble --address AA:BB:CC:DD:EE:FF battery
clip-sdk --transport udp download 20260716022113 recordings

clip.terminal --transport ble              # interactive AT terminal
clip.sync --transport udp --all --output recordings
clip.record --transport ble --mode enhanced --duration 60
clip.web --transport udp                   # local browser panel
```

See [api.md](api.md) for the full method reference and
[troubleshooting.md](troubleshooting.md) when things go quiet.
