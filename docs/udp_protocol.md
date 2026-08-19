# CLIP UDP Transfer Protocol

## Overview

Fire-and-forget UDP file transfer protocol for the CLIP embedded device. Designed for
simplicity and minimal RAM footprint (~600 bytes static state, dominated by the
512-byte selective-repeat NACK bitmap; no frame buffering).

**Strategy**: DATA frames are sent without per-frame acknowledgment. Each DATA frame
includes a per-frame CRC32 for corruption detection. Full-file integrity is verified
at FILE_END via an accumulated CRC32, with a FILE_ACK response from the client.

**Network**: Device acts as WiFi AP (IP: 192.168.4.1), client connects to UDP
port 8089. All communication is bidirectional on a single socket.

## Frame Types

| Type | Value | Direction | Description |
|------|-------|-----------|-------------|
| DATA | 0x01 | S→C | File data with seq + per-frame CRC32 |
| FILE_ACK | 0x03 | C→S | File verification result (OK/NACK) |
| FILE_START | 0x10 | S→C | Begin file transfer |
| FILE_END | 0x11 | S→C | End file transfer (full-file CRC32) |
| TRANSFER_DONE | 0x12 | S→C | All files complete |
| AT_RESP | 0x20 | S→C | AT command response (JSON) |
| HEARTBEAT | 0x30 | C→S | Keepalive (client→device only; the device never sends it) |

All multi-byte fields are **little-endian**.

---

## Frame Definitions

### DATA (0x01) — Server→Client

Carries a chunk of file data with per-frame CRC32 for corruption detection.

```
Byte:  [0]   [1]  [2]  [3]  [4]  [5] [6] [7] [8]  [9 ... 9+N-1]
Field: type  seq_lo seq_hi len_lo len_hi crc32 (4 bytes)     data (N)
```

| Field | Size | Description |
|-------|------|-------------|
| type | 1 | 0x01 |
| seq | 2 | Per-file sequence number (uint16 LE, starts at 0). **Wraps at 4096** (12-bit effective seq space, `UDP_SEQ_MODULO`), so files larger than ~4 MB (4096 × 1024-byte frames) cannot be selectively repaired and must not exceed the bitmap coverage |
| len | 2 | Data length, max 1024 bytes (uint16 LE) |
| crc32 | 4 | IEEE CRC32 of data field only (uint32 LE) |
| data | N | Raw file data |

**Header size**: 9 bytes. **Max payload**: 1024 bytes. **Max frame**: 1033 bytes.

### FILE_ACK (0x03) — Client→Server

Sent by client after verifying full-file CRC32 at FILE_END.

```
OK:               [0]   [1]
                  type  result(0x00)

NACK whole-file:  [0]   [1]
                  type  result(0x01)

NACK + bitmap:    [0]   [1]      [2] [3]        [4 ... 4+B-1]
                  type  result   total_seqs(2)  bitmap(B)
                        (0x01)    LE
```

| Field | Size | Description |
|-------|------|-------------|
| type | 1 | 0x03 |
| result | 1 | 0x00 = CRC OK, 0x01 = CRC mismatch |
| total_seqs | 2 | Total DATA frames in the file (only with bitmap). uint16 LE. |
| bitmap | ceil(total_seqs/8) | Bit i set = seq i is MISSING (only with bitmap). |

**Frame size**: 2 bytes for OK / legacy NACK; 4 + ceil(total_seqs/8) bytes for a
selective NACK (bitmap). Distinguished by length.

**Selective repeat (backward compatible)**: On a CRC mismatch, a client that tracks
received seqs sends `result=0x01` + `total_seqs` + a bitmap of the missing frames. The
server re-reads and retransmits only those seqs (at their original seq), then re-sends
FILE_END — converging even when each round loses different frames. A legacy server reads
only `result` (byte 1) and ignores the trailing fields → whole-file retransmit. A legacy
client sends the 2-byte NACK → server retransmits the whole file — **the shipped
reference Python client sends only the 2-byte legacy NACK**, so in practice repair
against the reference client is always whole-file; the bitmap path exists in the
firmware for future/alternate clients. Retransmitted frames
are paced (inter-frame delay halving each repair round, configurable via
`CONFIG_CLIP_UDP_REPAIR_PACE_US`).

### FILE_START (0x10) — Server→Client

```
Byte:  [0]   [1]    [2 ... 2+N-1]  [2+N ... 2+N+3]
Field: type  fn_len  filename       file_size (4)
```

| Field | Size | Description |
|-------|------|-------------|
| type | 1 | 0x10 |
| fn_len | 1 | Filename length (0-63) |
| filename | fn_len | UTF-8 encoded filename |
| file_size | 4 | File size in bytes (uint32 LE) |

### FILE_END (0x11) — Server→Client

```
Byte:  [0]   [1] [2] [3] [4]
Field: type  crc32 (4)
```

| Field | Size | Description |
|-------|------|-------------|
| type | 1 | 0x11 |
| crc32 | 4 | IEEE CRC32 of complete file data (uint32 LE) |

Client independently computes CRC over all received DATA payloads and compares.

### TRANSFER_DONE (0x12) — Server→Client

```
Byte:  [0]   [1]    [2 ... 2+N-1]  [2+N ... 2+N+3]
Field: type  sid_len  session_id   file_count (4)
```

| Field | Size | Description |
|-------|------|-------------|
| type | 1 | 0x12 |
| sid_len | 1 | Session ID length |
| session_id | sid_len | UTF-8 session ID |
| file_count | 4 | Total files transferred (uint32 LE) |

### AT_RESP (0x20) — Server→Client

```
Byte:  [0]   [1] [2]  [3 ... 3+N-1]
Field: type  len (2)   json_data
```

| Field | Size | Description |
|-------|------|-------------|
| type | 1 | 0x20 |
| len | 2 | Response length (uint16 LE) |
| json_data | len | UTF-8 encoded JSON |

### HEARTBEAT (0x30) — Client→Server

The device **never sends** HEARTBEAT frames — it only receives them (to reset the
connection-inactivity timer). Sending them is a client-side choice; the reference
Python client sends one every 5 seconds.

```
Byte:  [0]   [1] [2] [3] [4]
Field: type  timestamp (4)
```

| Field | Size | Description |
|-------|------|-------------|
| type | 1 | 0x30 |
| timestamp | 4 | Opaque sender timestamp (reference client: Unix epoch milliseconds, uint32 LE). The device does not interpret it. |

---

## Protocol Flow

```
Client                              Server
  |                                   |
  |--- "AT+DOWNLOAD=session\n" -------|  (plain text)
  |                                   |
  |<-- AT_RESP (JSON) ----------------|
  |                                   |
  |<-- FILE_START (fn, size) ---------|
  |                                   |
  |<-- DATA(seq=0, crc, payload) -----|
  |<-- DATA(seq=1, crc, payload) -----|   fire-and-forget (no per-frame ACK)
  |<-- DATA(seq=2, crc, payload) -----|
  |                                   |
  |  ... (until file done) ...       |
  |                                   |
  |<-- FILE_END(crc32) ---------------|
  |--- FILE_ACK(OK/NACK) ------------|
  |                                   |  (on NACK: selective repair or
  |                                   |   whole-file retransmit, then FILE_END)
  |  ... (next file, if any) ...     |
  |                                   |
  |<-- TRANSFER_DONE(sid, count) -----|
  |                                   |
```

---

## Transfer Strategy

### Server Side

- **Fire-and-forget**: DATA frames are sent without waiting for per-frame ACK
- **Per-frame CRC32**: Each DATA frame includes CRC of its payload for corruption detection
- **Full-file CRC32**: Server accumulates CRC32 across all DATA frames for a file
- **CRC over the full file**: The file CRC covers every frame regardless of `sendto()` success, so FILE_END's CRC matches the complete file the client reassembles. A frame whose send fails is repaired by selective repeat.
- **FILE_END + wait**: After sending all DATA, server sends FILE_END with accumulated CRC32 and waits for FILE_ACK
- **Selective repeat**: On a NACK carrying a bitmap, server retransmits only the missing seqs (at their original seq), then re-sends FILE_END. Falls back to whole-file retransmit when no bitmap is present (legacy client). Up to 10 retries per file.
- **Thread-safe cancel**: AT+CANCEL sets a volatile flag checked by the transfer thread; cancel handling (close file, send TRANSFER_DONE, cleanup) runs entirely in the transfer thread to avoid races with the AT command thread

### Client Side

- **Discard corrupted frames**: Frames with per-frame CRC mismatch are silently dropped
- **Accumulate data**: Valid DATA payloads are appended in arrival order — the reference
  Python client does **not** buffer out-of-order frames by seq. Loss or misordering is
  detected only via the full-file CRC at FILE_END (which then triggers repair)
- **Full-file verification**: On FILE_END, client compares its accumulated CRC32 with server's CRC32
- **FILE_ACK response**: 0x00 = CRC OK (file saved); 0x01 = NACK — with a missing-seq bitmap if the client tracks seqs (selective repair), or a bare 2-byte NACK (whole-file retransmit). **The shipped reference client sends only the bare 2-byte NACK.**

### Retransmission

- Server retries FILE_END up to 3 times, only on FILE_ACK **timeout** (2-second timeout each); a NACK does not consume a FILE_END retry
- On NACK, the server immediately escalates to repair: selective retransmit of the bitmap's missing seqs (if a bitmap was sent), falling back to whole-file retransmit from FILE_START — then re-sends FILE_END
- Max 10 repair rounds per file before abort (`TRANSFER_MAX_FILE_RETRIES`, a compile-time constant in `transfer.h` — not a Kconfig)
- No per-frame ACK; per-frame repair happens only via the selective-repeat path after a FILE_END NACK (whole-file when the client sends a legacy NACK)

### Transfer Modes / Flow Control

- **Cancel mid-transfer**: `AT+CANCEL` sets a volatile flag checked by the transfer
  thread; the transfer aborts after the current file and the cleanup (close file,
  send TRANSFER_DONE, state reset) runs in the transfer thread.
- **Pause/resume**: `AT+PAUSE` / `AT+RESUME` control **recording only** — they do not
  pause or resume an in-flight transfer. There is no transfer-level pause.
- **Record while syncing**: the device supports recording and WiFi sync concurrently
  (see `applications/clip/tests/tools/record.py`, "Record and sync in real-time").

---

## CRC32

### Algorithm

IEEE Ethernet CRC32 (polynomial 0xEDB88320, reflected).

### Usage

1. **Per-frame CRC**: Each DATA frame includes CRC of its payload. Client verifies
   immediately and discards corrupted frames.
2. **Full-file CRC**: FILE_END includes CRC of complete file data. Client
   independently computes and compares for end-to-end verification.

### Important

Both server (Zephyr) and client (Python) must use the **same algorithm**:
- Server: `crc32_ieee_update(0, data, len)` — Zephyr handles `~crc` internally
- Client: `binascii.crc32(data)` — standard Python CRC32
- For accumulation across chunks, both support passing the running CRC:
  - Server: `crc = crc32_ieee_update(crc, chunk, chunk_len)` (starting from 0)
  - Client: `crc = binascii.crc32(chunk, crc)` (starting from 0)

---

## Timing Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| Heartbeat interval | client-side (reference client: 5 s) | Keepalive frequency — the client's choice; the device never sends heartbeats. (`CONFIG_CLIP_UDP_HEARTBEAT_INTERVAL_MS` exists in Kconfig but is unused by the firmware.) |
| Connection timeout | 30000 ms | No activity = disconnected (`CONFIG_CLIP_UDP_CONNECTION_TIMEOUT_MS`) |
| FILE_ACK timeout | 2000 ms | Max wait for FILE_ACK after FILE_END |
| FILE_END retries | 3 | Max FILE_END retransmissions before abort |

---

## Error Handling

| Scenario | Detection | Recovery |
|----------|-----------|----------|
| Corrupted DATA frame | Per-frame CRC mismatch | Client discards frame (no ACK needed) |
| Lost DATA frame | Full-file CRC mismatch at FILE_END | Client sends NACK, server retransmits entire file |
| Lost FILE_END | Client timeout waiting for FILE_END | Server retries FILE_END |
| Lost FILE_ACK | Server timeout waiting for FILE_ACK | Server retries FILE_END |
| Connection lost | Heartbeat timeout (30s) | Server resets transport state |
