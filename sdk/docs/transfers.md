# File transfers

## Local layout

`download_session(session_id, destination)` writes:

```text
recordings/
└── 20260716022113/
    ├── session.json        # metadata first (files, size, synced, mode, ...)
    ├── 0001.opus
    ├── 0002.opus
    └── ...
```

## Integrity model

Each file streams to `NNNN.opus.part`. The `.opus` name is published by
atomic rename **only** when the declared file length and the `FILE_END`
CRC32 both match — a partial or corrupted download never leaves a file
that looks complete.

- **BLE**: link-layer reliability plus the final per-file CRC32. A file
  that still fails CRC is a terminal transfer error for the session.
- **UDP**: every datagram is CRC-checked on arrival; the SDK sends
  `FILE_ACK` only after the complete file passes sequence, size, and
  final-CRC validation. A failed file is discarded and NACKed; the
  firmware retransmits just the missing data (or the whole file for the
  legacy 2-byte NACK), and the SDK retries up to the firmware's
  file-level retry budget.

## Resume

Two ways to continue where you left off:

```python
# 1. Explicit resume point (files before it are skipped)
await clip.download_session(sid, "recordings", start_file="0016.opus")

# 2. Ask the device: the session's synced count is the natural resume
details = await clip.session_details(sid)
next_file = f"{details.synced_files + 1:04d}.opus"
```

Already-published local files are not re-downloaded when resuming.

## Progress & cancellation

```python
def on_progress(done: int, total: int) -> None:
    print(f"{done}/{total} files")

result = await clip.download_session(sid, "recordings", progress=on_progress,
                                     timeout=300.0)

# from another task:
await clip.cancel_download()      # AT+CANCEL; current file's .part is discarded
```

`timeout` is per-file inactivity, not total runtime. A transfer that
exhausts the firmware's retry budget raises `TransferTimeoutError`;
individual firmware command failures raise `CommandError`.

## Record-while-transferring

Recording and transfer can run concurrently — the device slices
recording segments shorter while a transfer is active so fresh audio
becomes downloadable quickly. The SDK needs nothing special for this;
start a download while recording and new files keep arriving in the
session listing.
