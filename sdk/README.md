# reSpeaker Clip SDK

The new Python SDK for the current reSpeaker Clip firmware.  It is intentionally
independent from `applications/clip/tests`: that directory remains the legacy
test/tool collection and is neither imported nor modified by this package.

The SDK provides:

- an asynchronous, typed AT-command API;
- BLE transport (`pip install -e '.[ble]'`) and dependency-free Wi-Fi/UDP transport;
- sequential command dispatch, so concurrent callers cannot consume one another's
  command responses;
- streaming file download to `*.part` files, with length and CRC32 checks before an
  atomic rename;
- live RTC audio streaming (`AT+START=rtc`), with sequence-gap accounting; and
- an intentionally small CLI for common inspection and download tasks.

## Install for development

```sh
cd /path/to/reSpeaker_Clip/sdk
python -m pip install -e '.[dev,ble]'
pytest
```

BLE is optional.  Wi-Fi/UDP needs only the Python standard library.

Installation registers these commands on `PATH`:

```sh
clip.terminal --transport ble --address AA:BB:CC:DD:EE:FF
clip.sync --transport udp --all --output recordings
clip.record --transport ble --mode enhanced --duration 60
clip.stream --transport ble --address AA:BB:CC:DD:EE:FF
clip.wifi --address AA:BB:CC:DD:EE:FF
clip.web --transport udp
```

`clip-sdk` remains the compact JSON-oriented CLI; the `clip.*` commands are the
interactive and workflow-oriented tools. `clip.web` is always registered but
requires the `web` extra when run: `pip install -e '.[web]'` (or `.[web,ble]`
when it controls a BLE device).

## RTC live streaming

`AT+START=rtc` runs the microphone pipeline without touching the SD card;
`AT+DOWNLOAD=<session>` then streams live Opus frames over BLE (BLE only —
the tools reject other transports). The device produces; your code consumes.

**`clip.stream`** streams and captures — nothing else:

```sh
clip.stream --transport ble --address AA:BB:CC:DD:EE:FF
```

Frames are written as a received-packet log — 2-byte little-endian length +
raw Opus packet (`rtc-<session>.bin.part` while streaming, atomically renamed
to `rtc-<session>.bin` on a normal stream end). It is not a standard media
container: parse the length-prefixed records and feed each packet to a
packet-level Opus decoder.
Without `--duration`, streaming continues until `Ctrl-C`; specify, for
example, `--duration 30` for a bounded run. `Ctrl-C` sends `AT+STOP`.

The Python API mirrors the CLI; see
[docs/api.md](docs/api.md#consuming-stream-data) for the three ways to
consume stream data (frame callback, chunk/stack push, complete `.bin`):

```python
from clip.stream import StreamReceiver

def handle_opus_frame(opus_packet: bytes) -> None:
    # One real-time Opus packet per call (nominally 20 ms of audio).
    # This payload excludes the STREAM_DATA type, sequence and length fields.
    process(opus_packet)

receiver = StreamReceiver(on_frame=handle_opus_frame)  # sync, non-blocking
session = await clip.start_rtc()
token = await clip.stream_rtc(session, receiver)
try:
    await receiver.wait_start(timeout=10)
    ...
    await clip.stop_recording()                    # ends the RTC stream
    await receiver.wait_end(timeout=5)
finally:
    # always release the handler slot, even on error paths
    clip.transport.detach_file_frame_handler(token)
```

`receiver.add_sink(capture.feed)` registers another consumer of the same Opus
payload; `capture.feed` writes each packet to the `.bin` log but is not the
source of the real-time frames. Do not replace the transport's single
file-frame handler—use `on_frame` or `add_sink()` to consume live packets.

## Quick start

```python
import asyncio
from pathlib import Path

from clip import ClipClient, BleTransport


async def main() -> None:
    async with ClipClient(BleTransport(name="Clip")) as clip:
        print(await clip.status())
        sessions = await clip.list_all_sessions()
        if sessions:
            result = await clip.download_session(sessions[0].id, Path("recordings"))
            print(result.files)


asyncio.run(main())
```

For Wi-Fi after enabling the Clip AP:

```python
from clip import ClipClient, UdpTransport

async with ClipClient(UdpTransport()) as clip:
    print(await clip.storage())
```

More detail is in [docs/architecture.md](docs/architecture.md) and
[docs/api.md](docs/api.md).  Direct-run utilities are in
[tools/README.md](tools/README.md).
