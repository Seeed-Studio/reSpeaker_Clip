# API reference

```python
from clip import BleTransport, ClipClient, UdpTransport
```

Construct one transport, pass it to `ClipClient`, and use the client as
an async context manager. `connect()` performs no implicit time sync or
other state-changing work.

Exactly one command is in flight at a time (the protocol has no request
ID). If a command times out, the transport is desynchronized until you
disconnect and reconnect — see [troubleshooting.md](troubleshooting.md).

All firmware errors surface as `clip.exceptions.CommandError`; timeouts
as `CommandTimeoutError`; transfer failures as `TransferError` /
`TransferTimeoutError` (base class `ClipError`).

## Transports

| Transport | Constructor | Notes |
|-----------|-------------|-------|
| `BleTransport` | `(address=None, *, name="Clip", connect_timeout=15.0)` | `bleak` via the `ble` extra. Scans by name substring when no address given. GATT notifications; link-layer reliability. |
| `UdpTransport` | `(host="192.168.4.1", port=8089)` | Standard library only. Per-file CRC32 verified before `FILE_ACK`; failed files are NACKed for retransmission. |

## Device status & info

| Method | Returns | Command |
|--------|---------|---------|
| `await clip.status()` | `Status` — state, recording, session, duration, battery, charging, temp, voltage, mode, free_space, device | `AT+GSTAT` |
| `await clip.battery()` | `Battery` — percent, charging, voltage_mv, temperature_c | `AT+BATT` |
| `await clip.storage()` | `Storage` — total_mb, free_mb, used_mb, used_percent, recorded_mb | `AT+STORAGE?` |
| `await clip.device_name()` | `str` (advertised name) | `AT+DEVICE` |
| `await clip.firmware_version()` | `str` | `AT+VERSION` |
| `await clip.get_time()` | `datetime` | `AT+TIME?` |
| `await clip.set_time(value)` | `int` (unix ts) — accepts `int` or `datetime` | `AT+TIME=<ts>` |
| `await clip.request("AT+...")` | raw response `dict` — escape hatch, one current-firmware command | any |

## Configuration

| Method | Returns | Command |
|--------|---------|---------|
| `await clip.mode()` / `set_mode(value)` | `"normal" \| "enhanced"` | `AT+MODE` |
| `await clip.auto_delete_days()` / `set_auto_delete_days(days)` | `int \| None` (`None` = off) | `AT+AUTODEL` |
| `await clip.brightness()` / `set_brightness(value)` | `int` 0-255 | `AT+BRIGHTNESS` |
| `await clip.configured_name()` / `set_name(name)` / `clear_name()` | user-defined name, `""` if unset | `AT+NAME` |
| `await clip.log_mode()` / `set_log_mode(value)` | `"off" \| "info" \| "debug"` | `AT+LOG` |
| `await clip.pairing_status()` | `PairingStatus` | `AT+PAIR?` |

## Recording

| Method | Returns | Command |
|--------|---------|---------|
| `await clip.start_recording(mode=None)` | session id (or `None` if unknown yet) | `AT+START` / `AT+START=<mode>` |
| `await clip.stop_recording()` | `dict` — session, duration, frames, total_size | `AT+STOP` |
| `await clip.pause_recording()` / `resume_recording()` | — | `AT+PAUSE` / `AT+RESUME` |
| `await clip.bookmark()` | `Bookmark` — position_ms, note | `AT+MARK` |

`AT+PAUSE` / `AT+RESUME` control **recording only** — a file transfer
cannot be paused, only cancelled.

## Sessions & files

| Method | Returns | Command |
|--------|---------|---------|
| `await clip.list_sessions(page_number=1, per_page=10)` | `tuple[Session]` (one page) | `AT+LIST?page&per_page` |
| `await clip.list_all_sessions(per_page=50)` | `tuple[Session]` (auto-paginated, newest first) | `AT+LIST` pages |
| `await clip.session_details(session_id)` | `SessionDetails` — files, size, synced, bookmarks, channels, sample_rate | `AT+LIST=<id>` |
| `await clip.list_files(session_id, page_number=1, per_page=20)` | `tuple[str]` — `NNNN.opus` names | `AT+LIST=<id>?page&per_page` |
| `await clip.list_bookmarks(session_id, per_page=100)` | `tuple[Bookmark]` | `AT+MARKS=<id>` |
| `await clip.delete_session(session_id, *, confirm=False)` | — raises without `confirm=True` | `AT+DELETE=<id>` |

## Download

| Method | Returns | Notes |
|--------|---------|-------|
| `await clip.start_download(session_id, *, start_file=None)` | `dict` | begin streaming (`AT+DOWNLOAD[=id[:file]]`) |
| `await clip.cancel_download()` | — | `AT+CANCEL` |
| `await clip.download_session(session_id, destination, *, start_file=None, timeout=300.0, progress=None)` | `DownloadResult` | high-level: details → stream → per-file CRC + atomic publish. `progress` is an optional callback. |

Semantics (`*.part` files, CRC32, resume via `start_file`):
[transfers.md](transfers.md).

## Wi-Fi & USB

| Method | Returns | Command |
|--------|---------|---------|
| `await clip.wifi()` | `WifiAccessPoint` — running, ssid, password, host, port, connected | `AT+WIFI?` |
| `await clip.start_wifi()` / `stop_wifi()` | `WifiAccessPoint` / — | `AT+WIFI=on/off` |
| `await clip.wifi_config()` | `(channel, country)` | `AT+WIFICFG?` |
| `await clip.set_wifi_config(channel, country)` | `(channel, country)` — applied on the **next** WiFi start | `AT+WIFICFG=<ch>:<CC>` |
| `await clip.usb_enabled()` / `set_usb_enabled(enabled)` | `bool` | `AT+USB` |

## Power & maintenance (confirm-gated)

```python
await clip.reboot()                                # AT+REBOOT
await clip.enter_dfu()                             # AT+DFU — MCUboot recovery
await clip.power_off(confirm=True)                 # AT+POWEROFF
await clip.format_storage(confirm=True)            # AT+FORMAT — wipes the SD card
await clip.reset_pairing(confirm=True)             # AT+PAIR=reset — bonds + SD
await clip.factory_reset(confirm=True)             # AT+FACTORY=confirm — settings + SD + bonds
```

Every destructive call raises `ValueError` unless `confirm=True` is
passed explicitly.

## Data models (`clip.models`)

`Status`, `Battery`, `Storage`, `Session`, `SessionDetails`,
`Bookmark`, `WifiAccessPoint`, `PairingStatus`, `DownloadedFile`,
`DownloadResult` — immutable dataclasses; `DownloadResult.files` is the
tuple of published local paths.

## Wi-Fi handoff helper

```python
from clip.wifi import handoff_to_wifi
ap = await handoff_to_wifi(clip)   # AT+WIFI=on over BLE, join host via
                                   # nmcli/networksetup/netsh, verify AT+GSTAT over UDP
```

Raises `HostWifiError` if the host cannot join the AP. Full story in
[wifi.md](wifi.md).
## RTC streaming

```python
from clip.stream import StreamReceiver

receiver = StreamReceiver(on_frame=handle_frame)   # sync, non-blocking
session = await clip.start_rtc()                   # AT+START=rtc; nothing on SD
token = await clip.stream_rtc(session, receiver)   # AT+DOWNLOAD=<session>
try:
    await receiver.wait_start(timeout=10)
    ...
    await clip.stop_recording()                    # ends the RTC stream
    await receiver.wait_end(timeout=5)
finally:
    # always release the handler slot, even on error paths
    clip.transport.detach_file_frame_handler(token)
```

`start_rtc()` returns the RTC session id.  `stream_rtc()` returns the
file-frame handler **lease token** once the device acknowledges;
STREAM_START/STREAM_DATA/STREAM_END frames then flow on the file-data path
until `STREAM_END`.  Detach with
`transport.detach_file_frame_handler(token)`: the slot is cleared only if
this stream still owns it (atomic compare-and-clear, idempotent), so a late
cleanup can never clobber a successor transfer.  The legacy
`set_file_frame_handler(None)` unconditional clear still works.

`StreamReceiver(on_frame)` hands every Opus frame payload to the callback as
it arrives and tracks `frames_received`, `bytes_received`, and
`sequence_gaps` — the count of observed sequence-DISCONTINUITY events (0
then 3 is one event).  This is a protocol-drift defense, not a device-loss
metric: the firmware advances `seq` only after a frame is successfully handed
to the BLE link, so queue/transmit drops do not consume sequence numbers and
cannot be measured this way.  Arrival timing is exposed via
`inter_frame_gaps_ms`, `avg_inter_frame_ms`, `max_inter_frame_ms`, and
`first_frame_delay_s`.  `end_reason` exposes the `STREAM_END` reason byte;
the currently known values are `STREAM_END_STOPPED`, `STREAM_END_TIMEOUT`,
`STREAM_END_DISCONNECT` (all in `clip.stream`), but unknown integer values
may appear if the firmware grows the set — treat it as an int first.

`on_frame` and every sink registered with `add_sink` are invoked
**synchronously, inline, on the receive path**: they must be plain
(non-coroutine) functions that return quickly. A coroutine function passed
here would never execute (calling it only creates a coroutine object), and a
slow/blocking tap delays frame reception — async or heavyweight consumers
belong on `StreamConsumer` instead.

A callback or sink raising an exception fails the receiver explicitly (raw
taps are fail-fast): the frame is first delivered to every sink, then
`receiver.error` is set to a `TransferError` carrying the FIRST exception as
`__cause__`.  Additional raw-frame consumers attach with
`receiver.add_sink(callable)` and are dispatched BEFORE `on_frame`.

### Where each real-time frame arrives

There are two different representations in the receive path:

```text
BLE File Data notification
  -> complete STREAM_DATA packet: [0x14][seq:2][payload_len:2][Opus payload]
  -> StreamReceiver.feed(raw_frame)
  -> decode_file_frame(raw_frame)
  -> StreamDataFrame(sequence, payload)
  -> add_sink callbacks, then on_frame, receive payload only
```

Application code normally consumes the last value: one `bytes` object
containing one real-time Opus packet (nominally 20 ms of audio). It does not
include the `0x14` type, sequence number, payload-length field, or an arrival
timestamp.

```python
def handle_opus_frame(opus_packet: bytes) -> None:
    # Called inline for every real-time Opus packet. Keep this non-blocking.
    send_to_decoder_or_asr(opus_packet)

receiver = StreamReceiver(on_frame=handle_opus_frame)

# Several consumers may receive the same packet. StreamCapture.feed writes it
# to the length-prefixed .bin log; it is not the source of the real-time data.
receiver.add_sink(capture.feed)
```

The complete protocol packet first enters the SDK in
`BleTransport._on_file_notification()` and is passed to
`StreamReceiver.feed()`. The transport file-frame handler is a single leased
slot owned by the active stream or file transfer, so application code should
not replace it to observe frames. Use `on_frame` or `add_sink()` for normal
real-time consumers. Per-packet sequence numbers are decoded internally for
`sequence_gaps`; the current public payload callbacks do not expose them.

### Consuming stream data

The device produces; three consumer paths are available, and they can be
combined by attaching several sinks to one receiver:

1. **Frame callback** — lowest latency, one real-time Opus packet per call:

   ```python
   receiver = StreamReceiver(on_frame=handle_opus_frame)
   ```

2. **Chunk/stack push** (`StreamConsumer`) — bounded async delivery for
   downstream pipes (forwarding, streaming ASR clients).  Payload bytes are
   carved into `chunk_bytes` chunks (default 4 KB) and pushed as
   `on_chunk(chunk: bytes)`; every `stack_bytes` (default 1 MiB) of chunks
   are also pushed together as `on_stack(chunks: list[bytes])` — the current
   stack as a list.  Sizes are configurable (`max_queue_bytes` must be >=
   `chunk_bytes`); subscribing to both delivers two groupings of the same
   bytes.

   **Async-only contract:** `on_chunk`/`on_stack` must be coroutine
   functions; synchronous callables are rejected at subscription
   (`TypeError`), because a blocking callback would stall the event loop and
   cannot be timed out.  A single pump drains a delivery queue bounded by
   `max_queue_bytes` (default 20 KiB — at least one second at the firmware
   maximum payload rate of 50 × 384 B/s): if the consumer cannot keep up,
   the OLDEST undelivered chunks are dropped (chunk-granular, so stack
   alignment is preserved; `dropped_chunks`/`dropped_bytes`) and the
   consumer converges on the live edge.  Owned aggregation memory is bounded
   by the queue budget + one partial chunk + one partial stack (callback
   task arguments and retained stalled tasks excluded).

   Each callback runs in its own task guarded by `callback_timeout`
   (default 5 s): on expiry the pump cancels the task once without awaiting
   the cancellation, terminates only that subscription
   (`callback_timeouts`), and retains the handle in `consumer.stalled_tasks`
   for you to inspect/await/clear. The SDK never awaits or cancels a
   retained task again; it only attaches a completion observer so a
   cancellation-resistant task cannot spam unhandled-exception warnings.
   The pump keeps draining regardless.  A raising callback likewise
   terminates only its subscription (`callback_errors`).

   ```python
   from clip.stream import StreamConsumer

   async def forward(chunk: bytes) -> None: ...
   async def archive(stack: list[bytes]) -> None: ...

   consumer = StreamConsumer(on_chunk=forward, on_stack=archive,
                             chunk_bytes=4096, stack_bytes=1 << 20)
   receiver.add_sink(consumer.feed)
   ...
   await consumer.wait_closed(normal_end=True)   # or async with StreamConsumer(...)
   ```

   `wait_closed(normal_end)`: normal = stop admission, drain, flush the tail
   chunk then the tail stack; abnormal = discard the pending aggregation and
   count it in `discarded_tail_bytes` — the unique admitted bytes not fully
   delivered through every still-active subscribed view (subscriptions
   already terminated by timeout/error do not participate).  Receiver
   completion is independent of consumer drain; await both when complete
   tails matter.

   `consumer.stats` reports `chunks_out`, `stacks_out`, `bytes_out`,
   `dropped_chunks`, `dropped_bytes`, `discarded_tail_bytes`,
   `callback_errors`, `callback_timeouts`, `queue_high_water_bytes`.

3. **Complete file** (`StreamCapture`) — the received-packet log:

   ```python
   from clip.stream import StreamCapture

   capture = StreamCapture("rtc-session.bin")   # writes rtc-session.bin.part
   receiver.add_sink(capture.feed)
   ...
   capture.finish(normal_end=True)   # renames .part -> final on a normal end
   ```

   Each record is a 2-byte little-endian length + raw Opus packet.  This is
   a private log format, not a standard media container (no Ogg/WebM):
   parse the length-prefixed records and pass each packet to a packet-level
   Opus decoder.  The capture taps raw arrivals before any consumer-side
   dropping, but stores
   no sequence numbers — it does not reconstruct loss positions
   (`sequence_gaps` is only a discontinuity-event counter, and current
   firmware sequence numbers cannot reveal device-side drops).  After any
   abnormal end the `.part` file is kept and never mistaken for a complete
   capture.

### Jitter buffer

`clip.jitter` decouples the bursty BLE arrivals from steady 20 ms playback
(`FRAME_MS`):

```python
from clip.jitter import FRAME_MS, JitterBuffer, simulate_playback

buf = JitterBuffer(depth_frames=5)   # ~100 ms of buffering
buf.put(frame)                       # producer: every arrival, any thread
frame = buf.get()                    # consumer: once per 20 ms tick; None = silence

stats = simulate_playback(receiver.inter_frame_gaps_ms, depth_ms=100)
```

`JitterBuffer(depth_frames, max_depth_frames=None)` policy: nothing is emitted
until `depth` frames are buffered (initial fill); `get()` returns `None` on
underrun; when the queue grows past `max_depth` the oldest frames are dropped
to snap back to `depth`, bounding latency to the live edge.  `depth_frames=0`
is pass-through.  `stats` is a `JitterStats` dataclass: `frames_in`,
`frames_out`, `start_wait_frames`, `underruns`, `underrun_frames`,
`dropped_catchup`.  `simulate_playback(inter_frame_gaps_ms, depth_ms,
frame_ms=FRAME_MS, max_depth_ms=None)` replays recorded arrival gaps through
the same model offline, for sizing the buffer from a real capture without
playing audio.

## CLI

```sh
clip-sdk --transport ble --address AA:BB:CC:DD:EE:FF status
clip-sdk --transport udp --host 192.168.4.1 sessions
clip-sdk --transport udp download 20260716022113 recordings
clip.terminal --transport udp
clip.sync --transport udp --all --output recordings
clip.record --transport ble --duration 60
clip.stream --transport ble --duration 30
clip.web --transport udp
```

For `clip.stream`, `--duration` is optional; omitting it waits until `Ctrl-C`
or a device-side stream end.

`clip-sdk command` is available for development and accepts only a single
`AT+...` command string.  The installable `clip.terminal`, `clip.sync`,
`clip.record`, `clip.stream`, and `clip.wifi` tools use the same package API.
`clip.stream` only streams and captures; applications can consume the raw
Opus packets through the public streaming API.
`clip.web` adds a local browser panel when installed with the `web` extra;
use the typed methods for production code.
