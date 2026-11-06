from __future__ import annotations

import asyncio
import struct

import pytest

from clip import ClipClient
from clip.exceptions import TransferError, TransferTimeoutError
from clip.stream import (
    STREAM_END_STOPPED,
    StreamCapture,
    StreamConsumer,
    StreamReceiver,
    stream_session,
)

from conftest import FakeTransport

SESSION = "20260807120000"


def start_frame(session: str = SESSION) -> bytes:
    encoded = session.encode("ascii")
    return b"\x13" + bytes((len(encoded),)) + encoded


def data_frame(sequence: int, payload: bytes = b"opus") -> bytes:
    return b"\x14" + struct.pack("<HH", sequence, len(payload)) + payload


def end_frame(reason: int = STREAM_END_STOPPED) -> bytes:
    return b"\x15" + bytes((reason,))


def test_full_stream_sequence() -> None:
    frames: list[bytes] = []
    receiver = StreamReceiver(on_frame=frames.append)
    receiver.feed(start_frame())
    assert receiver.started.is_set()
    receiver.feed(data_frame(0, b"a"))
    receiver.feed(data_frame(1, b"bb"))
    receiver.feed(end_frame())
    assert receiver.ended.is_set()
    assert frames == [b"a", b"bb"]
    assert receiver.session_id == SESSION
    assert receiver.frames_received == 2
    assert receiver.bytes_received == 3
    assert receiver.sequence_gaps == 0
    assert receiver.end_reason == STREAM_END_STOPPED


def test_counts_sequence_discontinuity_events() -> None:
    """sequence_gaps counts discontinuity EVENTS: 0 then 3 is one event."""
    receiver = StreamReceiver()
    receiver.feed(start_frame())
    receiver.feed(data_frame(0))
    receiver.feed(data_frame(3))  # discontinuity (protocol drift defense)
    receiver.feed(data_frame(4))
    assert receiver.sequence_gaps == 1
    assert receiver.frames_received == 3


def test_sequence_wraps_at_16_bits() -> None:
    receiver = StreamReceiver()
    receiver.feed(start_frame())
    receiver.feed(data_frame(0xFFFE))  # one discontinuity vs expected 0
    receiver.feed(data_frame(0xFFFF))
    receiver.feed(data_frame(0x0000))
    assert receiver.sequence_gaps == 1
    receiver.feed(data_frame(0x0001))
    assert receiver.sequence_gaps == 1


def test_first_frame_discontinuity_is_protocol_drift_defense() -> None:
    """Firmware starts at 0 and only advances seq on successful send, so a
    first frame with seq > 0 cannot happen today; expecting 0 flags any
    future firmware/protocol drift as one discontinuity event."""
    receiver = StreamReceiver()
    receiver.feed(start_frame())
    receiver.feed(data_frame(7))
    assert receiver.sequence_gaps == 1
    receiver.feed(data_frame(8))
    assert receiver.sequence_gaps == 1

    clean = StreamReceiver()
    clean.feed(start_frame())
    clean.feed(data_frame(0))
    assert clean.sequence_gaps == 0


def test_rejects_data_before_start() -> None:
    receiver = StreamReceiver()
    receiver.feed(data_frame(0))
    assert isinstance(receiver.error, TransferError)
    assert receiver.ended.is_set()


def test_rejects_foreign_frame_types() -> None:
    receiver = StreamReceiver()
    receiver.feed(start_frame())
    receiver.feed(b"\x11\x00\x00\x00\x00")  # FILE_END has no place in a stream
    assert isinstance(receiver.error, TransferError)


def test_rejects_duplicate_start() -> None:
    receiver = StreamReceiver()
    receiver.feed(start_frame())
    receiver.feed(start_frame())
    assert isinstance(receiver.error, TransferError)


def test_ignores_frames_after_end() -> None:
    receiver = StreamReceiver()
    receiver.feed(start_frame())
    receiver.feed(end_frame())
    receiver.feed(data_frame(0))
    assert receiver.frames_received == 0


def test_sinks_dispatch_before_on_frame() -> None:
    order: list[str] = []
    receiver = StreamReceiver(on_frame=lambda payload: order.append("on_frame"))
    receiver.add_sink(lambda payload: order.append("sink_a"))
    receiver.add_sink(lambda payload: order.append("sink_b"))
    receiver.feed(start_frame())
    receiver.feed(data_frame(0, b"x"))
    receiver.feed(end_frame())
    assert order == ["sink_a", "sink_b", "on_frame"]


def test_raising_callback_does_not_deprive_later_callbacks() -> None:
    seen: list[bytes] = []

    def bad_sink(_payload: bytes) -> None:
        raise RuntimeError("sink exploded")

    receiver = StreamReceiver(on_frame=seen.append)
    receiver.add_sink(bad_sink)
    receiver.add_sink(seen.append)
    receiver.feed(start_frame())
    receiver.feed(data_frame(0, b"x"))
    # Every callback after the failing one still received the frame...
    assert seen == [b"x", b"x"]
    # ...and the receiver failed with the FIRST error, chained as cause.
    assert isinstance(receiver.error, TransferError)
    assert isinstance(receiver.error.__cause__, RuntimeError)
    assert receiver.ended.is_set()


def test_first_of_multiple_failures_is_recorded() -> None:
    def bad_a(_payload: bytes) -> None:
        raise ValueError("first")

    def bad_b(_payload: bytes) -> None:
        raise KeyError("second")

    receiver = StreamReceiver()
    receiver.add_sink(bad_a)
    receiver.add_sink(bad_b)
    receiver.feed(start_frame())
    receiver.feed(data_frame(0))
    assert isinstance(receiver.error, TransferError)
    assert isinstance(receiver.error.__cause__, ValueError)


async def test_wait_end_times_out() -> None:
    receiver = StreamReceiver()
    receiver.feed(start_frame())
    with pytest.raises(TransferTimeoutError):
        await receiver.wait_end(timeout=0.01)


async def test_wait_start_surfaces_feed_error() -> None:
    receiver = StreamReceiver()
    receiver.feed(data_frame(0))  # fails: no STREAM_START yet
    with pytest.raises(TransferError):
        await receiver.wait_start(timeout=1.0)


async def test_stream_session_sends_download_and_returns_token() -> None:
    transport = FakeTransport([{"ok": True, "data": {"state": "streaming"}}])
    client = ClipClient(transport)
    await client.connect()
    receiver = StreamReceiver()
    token = await stream_session(client, SESSION, receiver)
    assert transport.commands == [f"AT+DOWNLOAD={SESSION}"]
    assert transport._file_frame_handler == receiver.feed
    transport._emit_file_frame(start_frame())
    transport._emit_file_frame(data_frame(0))
    transport._emit_file_frame(end_frame())
    await receiver.wait_end(timeout=1.0)
    assert receiver.frames_received == 1
    # Token lease: detach clears the slot exactly once, idempotently.
    assert transport.detach_file_frame_handler(token) is True
    assert transport._file_frame_handler is None
    assert transport.detach_file_frame_handler(token) is False


async def test_stream_session_detaches_on_failure() -> None:
    transport = FakeTransport([{"ok": False, "msg": "RTC session has no files"}])
    client = ClipClient(transport)
    await client.connect()
    with pytest.raises(Exception):
        await stream_session(client, SESSION, StreamReceiver())
    assert transport._file_frame_handler is None


async def test_stream_session_rejects_invalid_session_id() -> None:
    transport = FakeTransport([])
    client = ClipClient(transport)
    await client.connect()
    with pytest.raises(ValueError):
        await stream_session(client, "not-a-session", StreamReceiver())
    assert transport._file_frame_handler is None


def test_token_lease_does_not_clobber_successor() -> None:
    transport = FakeTransport([])
    first = transport.set_file_frame_handler(lambda frame: None)
    assert first == 1
    second = transport.set_file_frame_handler(lambda frame: None)
    assert second == 2
    # Stale cleanup of the first registration must not clear the second.
    assert transport.detach_file_frame_handler(first) is False
    assert transport._file_frame_handler is not None
    assert transport.detach_file_frame_handler(second) is True
    assert transport._file_frame_handler is None


def test_legacy_set_none_clears_unconditionally() -> None:
    transport = FakeTransport([])
    token = transport.set_file_frame_handler(lambda frame: None)
    assert token is not None
    transport.set_file_frame_handler(None)
    assert transport._file_frame_handler is None
    assert transport.detach_file_frame_handler(token) is False


def test_set_none_returns_no_token() -> None:
    transport = FakeTransport([])
    assert transport.set_file_frame_handler(None) is None


async def test_client_start_rtc_returns_session() -> None:
    transport = FakeTransport([{"ok": True, "data": {"session": SESSION, "mode": "rtc"}}])
    client = ClipClient(transport)
    await client.connect()
    assert await client.start_rtc() == SESSION
    assert transport.commands == ["AT+START=rtc"]


def test_dispatch_is_synchronous_no_added_latency() -> None:
    """The receiver must hand frames to the callback inside feed() — no queueing."""
    import time

    delivered: list[float] = []
    receiver = StreamReceiver(on_frame=lambda payload: delivered.append(time.monotonic()))
    receiver.feed(start_frame())
    send_at = time.monotonic()
    receiver.feed(data_frame(0))
    assert len(delivered) == 1
    assert delivered[0] - send_at < 0.001


async def test_latency_stats() -> None:
    receiver = StreamReceiver()
    receiver.feed(start_frame())
    assert receiver.first_frame_delay_s is None
    await asyncio.sleep(0.05)
    receiver.feed(data_frame(0))
    await asyncio.sleep(0.02)
    receiver.feed(data_frame(1))
    delay = receiver.first_frame_delay_s
    assert delay is not None and 0.04 <= delay <= 0.5
    assert receiver.max_inter_frame_ms >= 15.0
    avg = receiver.avg_inter_frame_ms
    assert avg is not None and 15.0 <= avg <= 100.0
    gaps = receiver.inter_frame_gaps_ms
    assert len(gaps) == 1 and gaps[0] >= 15.0
    assert receiver.first_frame_at is not None
    assert receiver.last_frame_at is not None


def test_latency_histogram_output(capsys) -> None:
    from clip.tools.stream import _print_latency_histogram

    _print_latency_histogram((10.0, 20.0, 60.0, 357.0))
    out = capsys.readouterr().out
    assert "Inter-frame latency distribution:" in out
    assert "0-50 ms" in out
    assert "50-100 ms" in out
    assert "350-400 ms" in out
    assert "50.0%" in out
    assert "25.0%" in out

    _print_latency_histogram(())
    assert capsys.readouterr().out == ""


# --- StreamCapture ---------------------------------------------------------


def read_capture(path) -> list[bytes]:
    records = []
    raw = path.read_bytes()
    offset = 0
    while offset < len(raw):
        (size,) = struct.unpack_from("<H", raw, offset)
        offset += 2
        records.append(raw[offset : offset + size])
        offset += size
    return records


def test_capture_writes_length_prefixed_records(tmp_path) -> None:
    capture = StreamCapture(tmp_path / "rtc.bin")
    assert capture.part_path == tmp_path / "rtc.bin.part"
    capture.feed(b"aa")
    capture.feed(b"bbb")
    capture.finish(normal_end=True)
    assert capture.complete
    assert not capture.part_path.exists()
    assert read_capture(tmp_path / "rtc.bin") == [b"aa", b"bbb"]


def test_capture_abnormal_end_keeps_part_file(tmp_path) -> None:
    capture = StreamCapture(tmp_path / "rtc.bin")
    capture.feed(b"aa")
    capture.finish(normal_end=False)
    assert not capture.complete
    assert not (tmp_path / "rtc.bin").exists()
    assert read_capture(tmp_path / "rtc.bin.part") == [b"aa"]


def test_capture_finish_is_idempotent(tmp_path) -> None:
    capture = StreamCapture(tmp_path / "rtc.bin")
    capture.feed(b"x")
    capture.finish(normal_end=True)
    capture.finish(normal_end=False)  # second close must not undo the rename
    assert capture.complete
    assert (tmp_path / "rtc.bin").exists()


# --- StreamConsumer --------------------------------------------------------


async def test_consumer_rejects_sync_callbacks() -> None:
    with pytest.raises(TypeError):
        StreamConsumer(on_chunk=lambda chunk: None)

    def sync_stack(_stack):
        return None

    with pytest.raises(TypeError):
        StreamConsumer(on_chunk=_async_noop, on_stack=sync_stack)

    # Async subscriptions are accepted.
    consumer = StreamConsumer(on_chunk=_async_noop)
    await consumer.wait_closed(normal_end=True)


async def _async_noop(_value) -> None:
    return None


async def test_consumer_carves_chunks_and_stacks() -> None:
    chunks: list[bytes] = []
    stacks: list[list[bytes]] = []

    async def on_chunk(chunk: bytes) -> None:
        chunks.append(chunk)

    async def on_stack(stack: list[bytes]) -> None:
        stacks.append(stack)

    consumer = StreamConsumer(on_chunk=on_chunk, on_stack=on_stack, chunk_bytes=4, stack_bytes=8)
    # 10 bytes -> chunks of 4/4, remainder 2 held until normal end.
    consumer.feed(b"abcdefghij")
    await consumer.wait_closed(normal_end=True)
    assert chunks == [b"abcd", b"efgh", b"ij"]
    # Stack 1 reaches 8 bytes from full chunks; tail chunk forms final stack.
    assert stacks == [[b"abcd", b"efgh"], [b"ij"]]
    assert consumer.stats.chunks_out == 3
    assert consumer.stats.stacks_out == 2
    assert consumer.stats.bytes_out == 10
    assert consumer.stats.dropped_chunks == 0


async def test_consumer_normal_tail_flushes_chunk_then_stack() -> None:
    chunks: list[bytes] = []
    stacks: list[list[bytes]] = []

    async def on_chunk(chunk: bytes) -> None:
        chunks.append(chunk)

    async def on_stack(stack: list[bytes]) -> None:
        stacks.append(stack)

    consumer = StreamConsumer(on_chunk=on_chunk, on_stack=on_stack, chunk_bytes=4, stack_bytes=16)
    consumer.feed(b"abcdef")  # one full chunk + 2-byte tail
    await consumer.wait_closed(normal_end=True)
    assert chunks == [b"abcd", b"ef"]
    assert stacks == [[b"abcd", b"ef"]]  # partial stack flushed at the end
    assert consumer.stats.discarded_tail_bytes == 0


async def test_consumer_abnormal_tail_discarded_chunk_only_subscription() -> None:
    chunks: list[bytes] = []

    async def on_chunk(chunk: bytes) -> None:
        chunks.append(chunk)

    consumer = StreamConsumer(on_chunk=on_chunk, chunk_bytes=4)
    consumer.feed(b"abcdef")  # one chunk queued (4 B) + uncarved tail (2 B)
    await consumer.wait_closed(normal_end=False)
    # Nothing was delivered before close; both buffers count as discarded.
    assert chunks == []
    assert consumer.stats.discarded_tail_bytes == 6


async def test_consumer_abnormal_tail_counts_partial_stack_for_stack_view() -> None:
    stacks: list[list[bytes]] = []

    async def on_stack(stack: list[bytes]) -> None:
        stacks.append(stack)

    consumer = StreamConsumer(on_stack=on_stack, chunk_bytes=2, stack_bytes=1 << 20)
    consumer.feed(b"abcdefgh")  # four 2-byte chunks queued (8 B); pump idle
    await consumer.wait_closed(normal_end=False)
    # Stack subscription still active: pending + queue + partial stack.
    assert stacks == []
    assert consumer.stats.discarded_tail_bytes == 8


async def test_consumer_abnormal_tail_dual_subscription() -> None:
    chunks: list[bytes] = []
    stacks: list[list[bytes]] = []

    async def on_chunk(chunk: bytes) -> None:
        chunks.append(chunk)

    async def on_stack(stack: list[bytes]) -> None:
        stacks.append(stack)

    consumer = StreamConsumer(on_chunk=on_chunk, on_stack=on_stack, chunk_bytes=2, stack_bytes=1 << 20)
    consumer.feed(b"abcdefgh")  # exactly four 2-byte chunks, no tail
    # Let the pump deliver the queued chunks first (chunk view consumes them).
    await asyncio.sleep(0.05)
    assert chunks == [b"ab", b"cd", b"ef", b"gh"]
    await consumer.wait_closed(normal_end=False)
    # Bytes were delivered through the chunk view, but the stack view (still
    # active) never got them: the aggregated partial stack counts as tail.
    assert stacks == []
    assert consumer.stats.discarded_tail_bytes == 8
    assert consumer.stats.bytes_out == 8


async def test_consumer_abnormal_tail_no_active_views_counts_zero() -> None:
    async def bad_chunk(_chunk: bytes) -> None:
        raise RuntimeError("dies on first chunk")

    consumer = StreamConsumer(on_chunk=bad_chunk, chunk_bytes=2)
    consumer.feed(b"abcd")  # two chunks queued
    await asyncio.sleep(0.05)  # pump delivers first -> subscription dies
    assert consumer.stats.callback_errors == 1
    await consumer.wait_closed(normal_end=False)
    # The only subscription is dead: no active view -> nothing is "pending
    # delivery" to anyone.
    assert consumer.stats.discarded_tail_bytes == 0


async def test_consumer_byte_budget_overflow_drops_oldest_chunks() -> None:
    delivered: list[bytes] = []

    async def on_chunk(chunk: bytes) -> None:
        delivered.append(chunk)

    consumer = StreamConsumer(
        on_chunk=on_chunk, chunk_bytes=2, stack_bytes=1 << 20, max_queue_bytes=4
    )
    # Feed 5 chunks synchronously; the pump task cannot run until we await,
    # so the byte budget (2 chunks) must drop the oldest chunks.
    for i in range(5):
        consumer.feed(bytes((i,)) * 2)
    await consumer.wait_closed(normal_end=True)
    assert delivered == [bytes((3,)) * 2, bytes((4,)) * 2]
    assert consumer.stats.dropped_chunks == 3
    assert consumer.stats.dropped_bytes == 6
    assert consumer.stats.queue_high_water_bytes == 4


async def test_consumer_callback_error_isolates_subscription() -> None:
    stacks: list[list[bytes]] = []

    async def bad_chunk(_chunk: bytes) -> None:
        raise RuntimeError("consumer bug")

    async def on_stack(stack: list[bytes]) -> None:
        stacks.append(stack)

    consumer = StreamConsumer(
        on_chunk=bad_chunk, on_stack=on_stack, chunk_bytes=2, stack_bytes=4
    )
    consumer.feed(b"aabbccdd")
    await consumer.wait_closed(normal_end=True)
    # The chunk subscription died after its first error, but stack delivery
    # continued and the drain kept running.
    assert consumer.stats.callback_errors == 1
    assert stacks == [[b"aa", b"bb"], [b"cc", b"dd"]]
    assert consumer.stats.chunks_out == 4


async def test_consumer_callback_timeout_terminates_subscription_only() -> None:
    delivered: list[bytes] = []

    async def slow_chunk(chunk: bytes) -> None:
        delivered.append(chunk)
        await asyncio.sleep(0.5)  # far beyond the callback timeout

    consumer = StreamConsumer(on_chunk=slow_chunk, chunk_bytes=2, callback_timeout=0.01)
    consumer.feed(b"aabbccdd")
    await consumer.wait_closed(normal_end=True)
    # First invocation timed out: subscription terminated, handle retained,
    # drain continued through the remaining chunks.
    assert delivered == [b"aa"]  # only the first call started
    assert consumer.stats.callback_timeouts == 1
    assert len(consumer.stalled_tasks) == 1
    assert consumer.stats.chunks_out == 4  # all chunks drained
    # The retained handle eventually settles (cancelled sleep).
    await asyncio.wait(consumer.stalled_tasks, timeout=2.0)
    assert consumer.stalled_tasks[0].cancelled()


async def test_consumer_requires_a_subscription() -> None:
    with pytest.raises(ValueError):
        StreamConsumer()


async def test_consumer_validates_configuration() -> None:
    with pytest.raises(ValueError):
        StreamConsumer(on_chunk=_async_noop, chunk_bytes=0)
    with pytest.raises(ValueError):
        StreamConsumer(on_chunk=_async_noop, stack_bytes=0)
    with pytest.raises(ValueError):
        StreamConsumer(on_chunk=_async_noop, max_queue_bytes=0)
    with pytest.raises(ValueError):
        StreamConsumer(on_chunk=_async_noop, chunk_bytes=8, max_queue_bytes=4)
    with pytest.raises(ValueError):
        StreamConsumer(on_chunk=_async_noop, callback_timeout=0)


async def test_consumer_context_manager_flushes_on_clean_exit() -> None:
    chunks: list[bytes] = []

    async def on_chunk(chunk: bytes) -> None:
        chunks.append(chunk)

    async with StreamConsumer(on_chunk=on_chunk, chunk_bytes=4) as consumer:
        consumer.feed(b"abcde")
    assert chunks == [b"abcd", b"e"]


async def test_consumer_only_allocates_subscribed_outputs() -> None:
    stacks: list[list[bytes]] = []

    async def on_stack(stack: list[bytes]) -> None:
        stacks.append(stack)

    consumer = StreamConsumer(on_stack=on_stack, chunk_bytes=2, stack_bytes=4)
    consumer.feed(b"aabbcc")
    await consumer.wait_closed(normal_end=True)
    assert stacks == [[b"aa", b"bb"], [b"cc"]]
    assert consumer.stats.chunks_out == 3  # carved internally, never delivered
