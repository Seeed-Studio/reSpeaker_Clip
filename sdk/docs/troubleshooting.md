# Troubleshooting

## Command timed out, now every command fails

The Clip protocol has no request ID, so the SDK allows one command in
flight and treats a timeout as a **desynchronized transport**: a late
response must never be attributed to the next command. After a
`CommandTimeoutError`, disconnect and reconnect (the context manager
makes this a `async with` re-entry). This is by design, not a bug.

## Cannot connect over BLE

- The device advertises as `Clip XXXX`. `BleTransport(name="Clip")`
  scans; pass `address=` when several devices are around.
- Pairing is **Just Works** (no PIN). Bonding uses a **single slot**:
  pairing a second phone silently evicts the first (keys-overwrite-
  oldest). If a previously paired phone cannot reconnect,
  `reset_pairing(confirm=True)` and pair again.
- If the app previously enabled USB-only mode (`AT+USB=on` keeps the
  USB stack up), BLE still works — USB and BLE are independent.

## UDP: no responses

- The AP must be running and the host joined to `ClipAP_XXXX`
  (default password `12345678`, unless it was re-randomized at
  pairing — read it over BLE with `AT+WIFI?`).
- The AP **auto-turns off** after idle time with no station; bring it
  back with `AT+WIFI=on` (BLE) before using `UdpTransport`.
- Device IP is `192.168.4.1:8089` — if the host picked a different
  subnet, pass `UdpTransport(host=...)` explicitly.

## `storage()` shows stale numbers

The firmware idle power-gates the SD card. While unmounted,
`AT+STORAGE?` returns the **last known cached** values (fresh enough
for status displays). Mount happens lazily on the next storage
operation; values refresh then.

## Downloads stop part-way

- Per-file inactivity exceeded `timeout` (default 300 s) →
  `TransferTimeoutError`. Resume with
  `download_session(..., start_file="NNNN.opus")`; completed files are
  kept.
- On UDP, a lost file is NACKed and retransmitted automatically; only
  exhausting the firmware retry budget ends the transfer.
- Wi-Fi interference: prefer 5 GHz channels when close, 2.4 GHz at
  range; change with `set_wifi_config()` and restart the AP.

## Device seems bricked

The firmware runs under MCUboot with USB serial recovery: hold the
button while plugging USB (or `AT+DFU`, or open the USB CDC port at
1200 baud) and upload a release `*-signed.bin` / `*-ota.zip` — see the
repository's [docs/usb_dfu.md](../../docs/usb_dfu.md). BLE OTA via
`nrfutil`/nRF Connect works without opening the case.

## Found a firmware-side question

Protocol details live in the repository docs:
[docs/protocol.md](../../docs/protocol.md) (AT + BLE frames),
[docs/udp_protocol.md](../../docs/udp_protocol.md) (UDP frames),
[docs/troubleshooting.md](../../docs/troubleshooting.md) (device side).
