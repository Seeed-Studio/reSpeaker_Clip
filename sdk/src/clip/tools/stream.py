"""Stream live RTC audio from the Clip and save Opus frames to a file.

Streaming is this tool's only job: it starts an RTC session, captures the
arrival log and prints stream diagnostics. Playback and media rendering are
left to applications consuming the captured Opus packets.

The capture is a received-packet log: each frame is written as a 2-byte
little-endian length followed by the raw Opus packet — a private log format,
not a media container: parse the records and feed each packet to a
packet-level Opus decoder. It is complete only after a normal stream end
(``.part`` is renamed to the final name then).
"""

from __future__ import annotations

import argparse
import asyncio
import math
import sys
from pathlib import Path

from ..stream import (
    STREAM_END_DISCONNECT,
    STREAM_END_STOPPED,
    STREAM_END_TIMEOUT,
    StreamCapture,
    StreamReceiver,
)
from .common import add_connection_options, make_client

_END_REASONS = {
    STREAM_END_STOPPED: "stopped",
    STREAM_END_TIMEOUT: "start-timeout",
    STREAM_END_DISCONNECT: "ble-disconnect",
}

_HISTOGRAM_BUCKET_MS = 50.0
_HISTOGRAM_BAR_WIDTH = 20


def _print_summary(receiver) -> None:
    reason = _END_REASONS.get(receiver.end_reason, str(receiver.end_reason))
    print(f"Ended: reason={reason}")
    rows = [
        ("frames", str(receiver.frames_received)),
        ("bytes", str(receiver.bytes_received)),
        ("seq_gaps", str(receiver.sequence_gaps)),
    ]
    first_delay = receiver.first_frame_delay_s
    if first_delay is not None:
        rows.append(("first_frame", f"{first_delay * 1000:.0f} ms"))
        avg = receiver.avg_inter_frame_ms
        if avg is not None:
            rows.append(("avg_inter_frame", f"{avg:.1f} ms"))
            rows.append(("max_inter_frame", f"{receiver.max_inter_frame_ms:.0f} ms"))
    for name, value in rows:
        print(f"  {name:<15} : {value}")
    if first_delay is not None and receiver.avg_inter_frame_ms is not None:
        _print_latency_histogram(receiver.inter_frame_gaps_ms)


def _print_latency_histogram(gaps: tuple[float, ...]) -> None:
    if not gaps:
        return
    bucket_count = max(1, math.ceil(max(gaps) / _HISTOGRAM_BUCKET_MS))
    buckets = [0] * bucket_count
    for gap in gaps:
        buckets[min(int(gap // _HISTOGRAM_BUCKET_MS), bucket_count - 1)] += 1
    labels = [
        f"{i * _HISTOGRAM_BUCKET_MS:.0f}-{(i + 1) * _HISTOGRAM_BUCKET_MS:.0f} ms"
        for i in range(bucket_count)
    ]
    width = max(len(label) for label in labels)
    print()
    print("Inter-frame latency distribution:")
    for label, count in zip(labels, buckets):
        pct = count * 100.0 / len(gaps)
        bars = round(pct * _HISTOGRAM_BAR_WIDTH / 100.0)
        if count and not bars:
            bars = 1
        print(f"  {label:>{width}} : {pct:5.1f}%  {'■' * bars}")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    add_connection_options(parser)
    parser.add_argument("--out", help="output file (default rtc-<session>.bin)")
    parser.add_argument("--duration", type=float, help="stream this many seconds; default waits for Ctrl-C")
    parser.add_argument("--pause-at", type=float, help="send AT+PAUSE this many seconds into the stream")
    parser.add_argument("--resume-at", type=float, help="send AT+RESUME this many seconds into the stream")
    return parser


async def _at_after(client, delay: float, method) -> None:
    await asyncio.sleep(delay)
    await method()


async def run(args: argparse.Namespace) -> int:
    # RTC streaming is BLE-only; reject before any resource is acquired,
    # dependency imported, or connection opened.
    if args.transport != "ble":
        raise ValueError(
            "clip.stream requires --transport ble: RTC live streaming is BLE-only"
        )
    if args.duration is not None and args.duration <= 0:
        raise ValueError("--duration must be positive")
    for name, value in (("--pause-at", args.pause_at), ("--resume-at", args.resume_at)):
        if value is not None and (value <= 0 or (args.duration is not None and value >= args.duration)):
            raise ValueError(f"{name} must be positive and smaller than --duration")

    receiver = StreamReceiver()
    capture: StreamCapture | None = None
    side_tasks: list[asyncio.Task] = []
    token: int | None = None
    cleanup_errors: list[Exception] = []
    primary: BaseException | None = None
    interrupted = False
    client = make_client(args)

    try:
        await client.connect()
        try:
            session = await client.start_rtc()
            out_path = Path(args.out) if args.out else Path(f"rtc-{session}.bin")
            capture = StreamCapture(out_path)
            receiver.add_sink(capture.feed)
            token = await client.stream_rtc(session, receiver)
            print(f"RTC session: {session}")
            await receiver.wait_start(timeout=10.0)
            print(f"Streaming to {out_path} (Ctrl-C to stop).")
            if args.pause_at is not None:
                side_tasks.append(asyncio.create_task(_at_after(client, args.pause_at, client.pause_recording)))
            if args.resume_at is not None:
                side_tasks.append(asyncio.create_task(_at_after(client, args.resume_at, client.resume_recording)))

            # Wait for the stream end (optionally bounded) while observing
            # the scheduled side tasks: a PAUSE/RESUME that completes with
            # an error fails this run immediately.
            end_wait = (
                receiver.wait_end()
                if args.duration is None
                else asyncio.wait_for(receiver.wait_end(), timeout=args.duration)
            )
            end_task = asyncio.ensure_future(end_wait)
            remaining = {end_task, *side_tasks}
            while remaining:
                done, remaining = await asyncio.wait(remaining, return_when=asyncio.FIRST_COMPLETED)
                for task in done:
                    if task is not end_task and not task.cancelled():
                        exc = task.exception()
                        if exc is not None:
                            raise exc
                if end_task in done:
                    remaining = set()  # stream over: stop watching
                    if not end_task.cancelled():
                        exc = end_task.exception()
                        if exc is not None and not isinstance(exc, asyncio.TimeoutError):
                            raise exc
        except KeyboardInterrupt:
            interrupted = True
            print("Stopping...")
        except BaseException as exc:  # noqa: BLE001 - captured, cleanup runs first
            primary = exc
        finally:
            # Observe and await every side task; an error that completed
            # before cancellation surfaces (unless a primary already exists).
            for task in side_tasks:
                task.cancel()
            for task in side_tasks:
                try:
                    await task
                except asyncio.CancelledError:
                    pass
                except Exception as exc:  # noqa: BLE001 - cleanup path
                    if primary is None and not interrupted:
                        primary = exc
                    else:
                        cleanup_errors.append(exc)
            # Stop the firmware session only when there is something to stop,
            # and bound the wait so cleanup cannot hang.
            try:
                if client.is_connected and not receiver.ended.is_set():
                    await client.stop_recording()
                    await receiver.wait_end(timeout=5.0)
            except Exception as exc:  # noqa: BLE001 - cleanup path
                cleanup_errors.append(exc)
            try:
                if token is not None:
                    client.transport.detach_file_frame_handler(token)
            except Exception as exc:  # noqa: BLE001 - cleanup path
                cleanup_errors.append(exc)
            normal = receiver.error is None and receiver.end_reason == STREAM_END_STOPPED
            if capture is not None:
                try:
                    capture.finish(normal)
                except Exception as exc:  # noqa: BLE001 - cleanup path
                    cleanup_errors.append(exc)
            try:
                await client.disconnect()
            except Exception as exc:  # noqa: BLE001 - cleanup path
                cleanup_errors.append(exc)
    except KeyboardInterrupt:
        interrupted = True
        print("Stopping...")
    except BaseException as exc:  # noqa: BLE001 - connect failed or cleanup re-raised
        if primary is None and not interrupted:
            primary = exc
        else:
            if isinstance(exc, Exception):
                cleanup_errors.append(exc)

    if primary is not None:
        for extra in cleanup_errors:
            print(f"stream: cleanup failure: {extra}", file=sys.stderr)
        raise primary
    if cleanup_errors:
        # No primary error: the first cleanup failure IS the failure.
        for extra in cleanup_errors[1:]:
            print(f"stream: additional cleanup failure: {extra}", file=sys.stderr)
        raise cleanup_errors[0]

    if not interrupted or receiver.started.is_set():
        _print_summary(receiver)
    if capture is not None:
        if capture.complete:
            print(f"Capture: {capture.path} ({capture.frames} frames)")
        else:
            print(f"Capture PARTIAL (stream did not end normally): {capture.part_path}")
    return 0


def main() -> int:
    try:
        return asyncio.run(run(build_parser().parse_args()))
    except Exception as exc:
        print(f"stream: {exc}")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
