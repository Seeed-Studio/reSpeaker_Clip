# SDK architecture

`sdk/` is a new, installable package.  It does not import, move, or modify
`applications/clip/tests`, which remains available as the legacy test and tool
collection.

```text
ClipClient
  ├─ typed current-firmware AT commands
  ├─ command lock (one outstanding request)
  ├─ streaming download coordinator
  │    └─ FileReceiver
  │         ├─ .opus.part writer
  │         ├─ byte count + CRC32 validation
  │         └─ atomic rename to .opus
  └─ RTC live streaming (AT+START=rtc + AT+DOWNLOAD)
       └─ StreamReceiver (producer -> consumer fan-out)
            ├─ on_frame / add_sink raw taps (fail-fast)
            ├─ sequence-gap + arrival-timing accounting
            ├─ StreamCapture: received-packet .bin log (.part -> rename)
            ├─ StreamConsumer: bounded async chunk/stack push (live edge)
            └─ clip.jitter.JitterBuffer available to application consumers

BaseTransport
  ├─ BleTransport   optional bleak dependency; GATT notifications
  └─ UdpTransport   standard-library asyncio datagrams
```

The command lock is a protocol requirement, not a convenience: device responses
do not contain a request ID.  If a command times out, the transport becomes
desynchronized and requires disconnect/reconnect before another command can be
sent.  This deliberately prevents a late response from being attributed to a
different command.

Binary transfer frames are handled independently from AT responses.  BLE uses
link-layer reliability and verifies the final per-file CRC32.  UDP additionally
validates each datagram's CRC32 and sends the firmware `FILE_ACK` only after the
complete file has passed sequence, size, and final CRC32 validation.  A failed
UDP file is discarded and NACKed for retransmission; a failed BLE file is a
terminal transfer error.

RTC live streaming reuses the same file-frame notification path with
STREAM_START/STREAM_DATA/STREAM_END frames: `StreamReceiver` hands each Opus
payload to a callback as it arrives, tracking sequence discontinuities and
inter-arrival timing instead of persisting anything.  Consumers attach
explicitly — `StreamCapture` logs raw arrivals to a length-prefixed `.bin`
(renamed from `.part` only on a normal end), and `StreamConsumer` pushes the
newest data through a byte-budget async queue as 4 KB chunks / ~1 MB stacks,
dropping the oldest undelivered chunks under backpressure (async-only
callbacks, per-callback timeout, `wait_closed` lifecycle).  The handler slot
is released through a lease token (atomic conditional detach).
`clip.jitter.JitterBuffer` remains available to applications that need to
decouple bursty arrivals from a steady 20 ms consume rate (initial fill,
underrun handling and catch-up drops that bound latency to the live edge),
and `simulate_playback()` replays recorded arrival gaps through the same
model offline to size the buffer.

For hosts that start on BLE, `clip.wifi.handoff_to_wifi()` provides an explicit
control-plane/data-plane handoff: it sends `AT+WIFI=on` over BLE, joins the host
to the returned AP using `nmcli` (Linux), `networksetup` (macOS), or `netsh`
(Windows), then verifies the new UDP route with `AT+GSTAT`. `clip.web` exposes
the same sequence behind its local **Switch transfer to Wi-Fi** button.

The public API is intentionally based on the current firmware command set
(`GSTAT`, `BATT`, `LIST`, `DOWNLOAD`, `WIFI`, etc.).  Removed legacy runtime
controls such as `BITRATE`, `COMPLEXITY`, `NOISE`, `AGC`, and `DEREVERB` are not
emulated or exposed.
