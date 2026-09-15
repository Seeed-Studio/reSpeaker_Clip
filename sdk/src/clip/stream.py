"""Live RTC audio streaming from the Clip over BLE.

An RTC session (`AT+START=rtc`) runs the microphone pipeline without writing
to SD; `AT+DOWNLOAD=<session>` then discards whatever was queued before it
(RTC delivers "now" — pre-DOWNLOAD audio is never sent) and streams live
Opus frames as STREAM_START/STREAM_DATA/STREAM_END notifications on the
file-data characteristic.

Consuming the stream is producer/consumer by design — the device produces,
and every consumer taps the receiver explicitly:

* ``on_frame`` / ``add_sink``: raw frames, lowest latency, fail-fast.
* ``StreamCapture``: raw arrivals logged to a length-prefixed ``.bin`` file.
* ``StreamConsumer``: async, bounded push of the newest data as chunks and
  stacks, decoupled from the receive path.

Sequence numbers: the firmware assigns ``seq`` starting at 0 and increments
it only after a frame was successfully handed to the BLE link, so queue,
pause and transmit drops on the device do NOT consume sequence numbers.
``sequence_gaps`` therefore counts observed sequence-DISCONTINUITY events —
a protocol-drift defense, not a device-loss metric: with current firmware
and the reliable BLE link, frame loss shows up as missing frames, and loss
visibility on the device side would need a firmware change.
"""

from __future__ import annotations

import asyncio
import os
import struct
import time
from collections import deque
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path
from typing import TYPE_CHECKING, Awaitable

from .exceptions import ProtocolError, TransferError, TransferTimeoutError
from .protocol import (
    StreamDataFrame,
    StreamEndFrame,
    StreamStartFrame,
    decode_file_frame,
)
from .validation import session_id as _session_id

if TYPE_CHECKING:
    from .client import ClipClient

STREAM_END_STOPPED = 0
STREAM_END_TIMEOUT = 1
STREAM_END_DISCONNECT = 2

#: Default consumer push sizes: 4 KB per chunk, 1 MiB per stack.
DEFAULT_CHUNK_BYTES = 4096
DEFAULT_STACK_BYTES = 1024 * 1024
#: Default delivery-queue byte budget: at least one second at the firmware
#: maximum payload rate (50 frames/s x 384 B/frame = 19.2 KB/s).
DEFAULT_MAX_QUEUE_BYTES = 20 * 1024
#: Default per-callback timeout in seconds.
DEFAULT_CALLBACK_TIMEOUT_S = 5.0

FrameCallback = Callable[[bytes], None]


def _swallow_task_result(task: asyncio.Task) -> None:
    """Silence a retained task's result so it cannot spam 'never retrieved'."""
    if not task.cancelled():
        task.exception()


class StreamReceiver:
    """Consumes STREAM_* frames from the file-data notification path.

    Unlike FileReceiver there is no persistence here: every STREAM_DATA
    payload is handed to each sink and the frame callback as soon as it
    arrives. The receiver only tracks ordering so callers can report
    discontinuities.

    Fan-out ownership: raw validated frames dispatch to every sink
    registered via ``add_sink`` (e.g. a ``StreamCapture`` and a
    ``StreamConsumer``) FIRST, then to ``on_frame``. If any callback
    raises, the frame is still delivered to all remaining callbacks first;
    the receiver then fails with the FIRST exception (wrapped in a
    ``TransferError`` carrying the original as ``__cause__``). Raw taps are
    fail-fast by contract: nothing is swallowed silently.

    ``sequence_gaps`` counts observed discontinuity events (0 then 3 is one
    event). It is a protocol-drift defense, not a device-loss metric — the
    firmware consumes sequence numbers only on successfully transmitted
    frames.
    """

    def __init__(self, on_frame: FrameCallback | None = None) -> None:
        self.on_frame = on_frame
        self.started = asyncio.Event()
        self.ended = asyncio.Event()
        self.error: Exception | None = None
        self.session_id: str | None = None
        self.end_reason: int | None = None
        self.frames_received = 0
        self.bytes_received = 0
        self.sequence_gaps = 0
        self.started_at: float | None = None
        self.first_frame_at: float | None = None
        self.last_frame_at: float | None = None
        self._sinks: list[FrameCallback] = []
        self._inter_frame_gaps_ms: list[float] = []
        self._expected_sequence = 0

    def add_sink(self, sink: FrameCallback) -> None:
        """Register an additional raw-frame consumer (fan-out)."""
        self._sinks.append(sink)

    @property
    def avg_inter_frame_ms(self) -> float | None:
        """Mean inter-frame arrival gap in milliseconds (nominal 20 ms)."""
        if not self._inter_frame_gaps_ms:
            return None
        return sum(self._inter_frame_gaps_ms) / len(self._inter_frame_gaps_ms)

    @property
    def max_inter_frame_ms(self) -> float:
        """Largest inter-frame arrival gap in milliseconds."""
        return max(self._inter_frame_gaps_ms, default=0.0)

    @property
    def inter_frame_gaps_ms(self) -> tuple[float, ...]:
        """All inter-frame arrival gaps in milliseconds, oldest first."""
        return tuple(self._inter_frame_gaps_ms)

    @property
    def first_frame_delay_s(self) -> float | None:
        """Seconds between STREAM_START and the first STREAM_DATA frame."""
        if self.started_at is None or self.first_frame_at is None:
            return None
        return self.first_frame_at - self.started_at

    def feed(self, raw_frame: bytes) -> None:
        if self.error is not None or self.ended.is_set():
            return
        try:
            frame = decode_file_frame(raw_frame)
            if isinstance(frame, StreamStartFrame):
                self._on_start(frame)
            elif isinstance(frame, StreamDataFrame):
                self._on_data(frame)
            elif isinstance(frame, StreamEndFrame):
                self._on_end(frame)
            else:
                raise TransferError(
                    f"unexpected {type(frame).__name__} during RTC stream"
                )
        except ProtocolError as exc:
            error = TransferError(str(exc))
            error.__cause__ = exc
            self._fail(error)
        except Exception as exc:
            if isinstance(exc, TransferError):
                self._fail(exc)
            else:
                error = TransferError(str(exc))
                error.__cause__ = exc
                self._fail(error)

    async def wait_start(self, timeout: float) -> None:
        try:
            await asyncio.wait_for(self.started.wait(), timeout=timeout)
        except asyncio.TimeoutError as exc:
            raise TransferTimeoutError("RTC stream did not start in time") from exc
        if self.error is not None:
            raise self.error

    async def wait_end(self, timeout: float | None = None) -> None:
        try:
            if timeout is None:
                await self.ended.wait()
            else:
                await asyncio.wait_for(self.ended.wait(), timeout=timeout)
        except asyncio.TimeoutError as exc:
            raise TransferTimeoutError("RTC stream did not end in time") from exc
        if self.error is not None:
            raise self.error

    def _on_start(self, frame: StreamStartFrame) -> None:
        if self.started.is_set():
            raise TransferError("received STREAM_START twice")
        self.session_id = frame.session_id
        self.started_at = time.monotonic()
        # Firmware assigns seq from 0 and only advances it after a
        # successful send, so the expected first sequence is always 0.
        # Expecting 0 anyway doubles as a protocol-drift defense: any other
        # first value flags a future firmware or protocol change.
        self._expected_sequence = 0
        self.started.set()

    def _on_data(self, frame: StreamDataFrame) -> None:
        if not self.started.is_set():
            raise TransferError("received STREAM_DATA before STREAM_START")
        if frame.sequence != self._expected_sequence:
            self.sequence_gaps += 1
        self._expected_sequence = (frame.sequence + 1) & 0xFFFF
        now = time.monotonic()
        if self.first_frame_at is None:
            self.first_frame_at = now
        elif self.last_frame_at is not None:
            self._inter_frame_gaps_ms.append((now - self.last_frame_at) * 1000.0)
        self.last_frame_at = now
        self.frames_received += 1
        self.bytes_received += len(frame.payload)
        # Deterministic fan-out: every sink receives the frame before
        # on_frame, and a raising callback never deprives the callbacks
        # after it. The first failure is recorded after complete dispatch.
        first_error: Exception | None = None
        for sink in self._sinks:
            try:
                sink(frame.payload)
            except Exception as exc:  # noqa: PERF203 - fail-fast fan-out
                if first_error is None:
                    first_error = exc
        if self.on_frame is not None:
            try:
                self.on_frame(frame.payload)
            except Exception as exc:
                if first_error is None:
                    first_error = exc
        if first_error is not None:
            raise TransferError(
                f"stream frame callback failed: {first_error}"
            ) from first_error

    def _on_end(self, frame: StreamEndFrame) -> None:
        if not self.started.is_set():
            raise TransferError("received STREAM_END before STREAM_START")
        self.end_reason = frame.reason
        self.ended.set()

    def _fail(self, error: Exception) -> None:
        if self.error is None:
            self.error = error
        self.ended.set()


class StreamCapture:
    """Logs raw stream arrivals to a length-prefixed ``.bin`` file.

    Each record is a 2-byte little-endian length followed by the raw Opus
    packet. This is a private log format, not a media container: parse the
    records and pass each packet to a packet-level Opus decoder. The capture
    taps raw
    validated arrivals before any consumer-side dropping, so it is the
    received-packet log of the run: it does not store sequence numbers and
    cannot reconstruct loss positions (``sequence_gaps`` is only a
    discontinuity-event counter, and current firmware sequence numbers
    cannot reveal device-side drops).

    Partial-file policy: data writes to ``<name>.part`` and is atomically
    renamed to the final path only after a normal ``STREAM_END``. Any other
    outcome leaves the ``.part`` behind so an incomplete capture is never
    mistaken for a complete one.
    """

    def __init__(self, path) -> None:
        self.path = Path(path)
        self.part_path = self.path.with_name(self.path.name + ".part")
        self._handle = self.part_path.open("wb")
        self.frames = 0
        self.bytes = 0
        self.complete = False
        self._closed = False

    def feed(self, payload: bytes) -> None:
        if self._closed:
            return
        self._handle.write(struct.pack("<H", len(payload)) + payload)
        self.frames += 1
        self.bytes += len(payload)

    def finish(self, normal_end: bool) -> None:
        """Close the file; rename ``.part`` -> final only on a normal end."""
        if self._closed:
            return
        self._closed = True
        self._handle.close()
        if normal_end:
            os.replace(self.part_path, self.path)
            self.complete = True

    def abort(self) -> None:
        self.finish(normal_end=False)


@dataclass
class ConsumerStats:
    """Counters describing what a StreamConsumer delivered or dropped."""

    chunks_out: int = 0
    stacks_out: int = 0
    bytes_out: int = 0
    dropped_chunks: int = 0          # oldest undelivered chunks dropped on overflow
    dropped_bytes: int = 0
    discarded_tail_bytes: int = 0    # see StreamConsumer.wait_closed
    callback_errors: int = 0
    callback_timeouts: int = 0
    queue_high_water_bytes: int = 0


class StreamConsumer:
    """Pushes the newest stream data to async callbacks as chunks and stacks.

    The device and the BLE link deliver in order, so no reorder window is
    needed — this consumer decouples the receive path from consumer
    callbacks instead, and drops toward the live edge under backpressure.

    Contract:

    * **Async-only callbacks.** ``on_chunk(chunk: bytes)`` and
      ``on_stack(chunks: list[bytes])`` must be coroutine functions;
      synchronous callables are rejected at subscription with ``TypeError``.
      A blocking callback would stall the event loop and cannot be timed
      out, so it has no place here.
    * **Byte-budget delivery queue.** Fed payloads are carved into
      ``chunk_bytes`` chunks (default 4 KB) held in a queue bounded by
      ``max_queue_bytes`` (default 20 KiB — at least one second at the
      firmware maximum payload rate of 50 x 384 B/s). Overflow drops the
      OLDEST undelivered chunks (chunk granularity preserves stack
      alignment), counted in ``dropped_chunks``/``dropped_bytes``.
      Configuration rules: ``max_queue_bytes`` must be >= ``chunk_bytes``;
      non-multiples are tolerated. Owned aggregation memory is bounded by
      ``max_queue_bytes`` + one partial chunk (< ``chunk_bytes``) + one
      partial stack (< ``stack_bytes``); callback-task arguments and
      retained stalled tasks are outside that bound.
    * **Stacks.** Every ``stack_bytes`` (default 1 MiB) of delivered chunks
      are pushed together as ``on_stack(chunks)`` — the current stack as a
      list. Subscribing to both callbacks delivers two groupings of the
      same bytes; only subscribed outputs are produced. Chunks and stacks
      are ordered byte views and may split Opus packet boundaries.
    * **Callback execution.** A single pump drains the queue and invokes
      each callback in its own task, guarded by ``callback_timeout``
      (default 5 s) via a non-blocking timeout: on expiry the pump cancels
      the task once WITHOUT awaiting the cancellation, terminates only that
      callback's subscription (``callback_timeouts``), retains the handle
      in ``stalled_tasks`` for the caller to inspect/await/clear, and
      continues draining. A raising callback likewise terminates only its
      subscription (``callback_errors``). Cancellation-resistant coroutines
      are not guaranteed to terminate; the SDK never touches retained
      handles again.
    * **Lifecycle.** ``wait_closed(normal_end)``: normal = stop admission,
      drain the queue, flush the tail chunk, then the tail stack; abnormal
      = discard the pending aggregation and count it. Receiver protocol
      completion is independent of consumer drain — callers needing
      complete tails await both.

    ``discarded_tail_bytes`` (abnormal close only): the unique admitted
    bytes that were not fully delivered through every still-active
    subscribed view — i.e. the uncarved tail plus the undelivered queue
    bytes, plus the partial stack when a stack subscription is still
    active. Subscriptions already terminated by timeout/error do not
    participate.
    """

    def __init__(
        self,
        on_chunk: Callable[[bytes], Awaitable[None]] | None = None,
        on_stack: Callable[[list[bytes]], Awaitable[None]] | None = None,
        *,
        chunk_bytes: int = DEFAULT_CHUNK_BYTES,
        stack_bytes: int = DEFAULT_STACK_BYTES,
        max_queue_bytes: int = DEFAULT_MAX_QUEUE_BYTES,
        callback_timeout: float = DEFAULT_CALLBACK_TIMEOUT_S,
    ) -> None:
        if on_chunk is None and on_stack is None:
            raise ValueError("subscribe at least one of on_chunk / on_stack")
        for name, callback in (("on_chunk", on_chunk), ("on_stack", on_stack)):
            if callback is not None and not asyncio.iscoroutinefunction(callback):
                raise TypeError(
                    f"{name} must be an async function — StreamConsumer is "
                    "async-only (synchronous callbacks cannot be timed out)"
                )
        if chunk_bytes <= 0 or stack_bytes <= 0 or max_queue_bytes <= 0:
            raise ValueError("chunk_bytes, stack_bytes and max_queue_bytes must be > 0")
        if max_queue_bytes < chunk_bytes:
            raise ValueError("max_queue_bytes must be >= chunk_bytes")
        if callback_timeout <= 0:
            raise ValueError("callback_timeout must be > 0")
        self._on_chunk = on_chunk
        self._on_stack = on_stack
        self.chunk_bytes = chunk_bytes
        self.stack_bytes = stack_bytes
        self.max_queue_bytes = max_queue_bytes
        self.callback_timeout = callback_timeout
        self.stats = ConsumerStats()
        self.stalled_tasks: list[asyncio.Task] = []
        self._pending = bytearray()
        self._queue: deque[bytes] = deque()
        self._queue_bytes = 0
        self._stack: list[bytes] = []
        self._stack_bytes = 0
        self._wakeup = asyncio.Event()
        self._task: asyncio.Task[None] | None = None
        self._closing = False
        self._closed = False
        self._chunk_sub_dead = False
        self._stack_sub_dead = False

    def feed(self, payload: bytes) -> None:
        """Receiver sink: carve payload bytes into chunks and queue them.

        Synchronous and cheap; callback execution happens in the pump task.
        """
        if self._closed:
            return
        if self._task is None:
            self._task = asyncio.get_running_loop().create_task(
                self._pump(), name="clip-stream-consumer"
            )
        self._pending.extend(payload)
        while len(self._pending) >= self.chunk_bytes:
            self._enqueue(bytes(self._pending[: self.chunk_bytes]))
            del self._pending[: self.chunk_bytes]

    def _enqueue(self, chunk: bytes) -> None:
        self._queue_bytes += len(chunk)
        while self._queue_bytes > self.max_queue_bytes:
            dropped = self._queue.popleft()
            self._queue_bytes -= len(dropped)
            self.stats.dropped_chunks += 1
            self.stats.dropped_bytes += len(dropped)
        self._queue.append(chunk)
        if self._queue_bytes > self.stats.queue_high_water_bytes:
            self.stats.queue_high_water_bytes = self._queue_bytes
        self._wakeup.set()

    async def _pump(self) -> None:
        while True:
            await self._wakeup.wait()
            self._wakeup.clear()
            while self._queue:
                chunk = self._queue.popleft()
                self._queue_bytes -= len(chunk)
                await self._deliver_chunk(chunk)
            if self._closing:
                return

    async def _deliver_chunk(self, chunk: bytes) -> None:
        self.stats.chunks_out += 1
        self.stats.bytes_out += len(chunk)
        if self._on_chunk is not None and not self._chunk_sub_dead:
            await self._invoke(self._on_chunk, chunk, chunk_subscription=True)
        # Stack aggregation only runs for a live stack subscription.
        if self._on_stack is not None and not self._stack_sub_dead:
            self._stack.append(chunk)
            self._stack_bytes += len(chunk)
            if self._stack_bytes >= self.stack_bytes:
                await self._push_stack()

    async def _push_stack(self) -> None:
        stack, self._stack, self._stack_bytes = self._stack, [], 0
        if not stack:
            return
        if self._on_stack is None or self._stack_sub_dead:
            return  # no live stack view: drop silently (already accounted)
        self.stats.stacks_out += 1
        await self._invoke(self._on_stack, list(stack), chunk_subscription=False)

    async def _invoke(self, callback: Callable, argument, *, chunk_subscription: bool) -> None:
        """Run one callback in its own task with a non-blocking timeout.

        On timeout the task is cancelled exactly once and NOT awaited (the
        cancellation may itself stall); the subscription ends, the handle is
        retained in ``stalled_tasks``, and the drain continues.
        """
        task = asyncio.get_running_loop().create_task(callback(argument))
        done, pending = await asyncio.wait({task}, timeout=self.callback_timeout)
        if pending:
            task.cancel()
            task.add_done_callback(_swallow_task_result)
            self.stalled_tasks.append(task)
            self.stats.callback_timeouts += 1
            if chunk_subscription:
                self._chunk_sub_dead = True
            else:
                self._stack_sub_dead = True
            return
        try:
            task.result()
        except asyncio.CancelledError:
            raise
        except Exception:
            self.stats.callback_errors += 1
            if chunk_subscription:
                self._chunk_sub_dead = True
            else:
                self._stack_sub_dead = True

    def _undelivered_tail_bytes(self) -> int:
        """Admitted bytes not fully delivered through every still-active view."""
        chunk_active = self._on_chunk is not None and not self._chunk_sub_dead
        stack_active = self._on_stack is not None and not self._stack_sub_dead
        if not chunk_active and not stack_active:
            return 0
        total = len(self._pending) + self._queue_bytes
        if stack_active:
            total += self._stack_bytes
        return total

    async def wait_closed(self, normal_end: bool) -> None:
        """Stop the consumer (see class docstring for the close semantics)."""
        if self._closed:
            return
        self._closed = True
        if normal_end:
            if self._pending:
                self._enqueue(bytes(self._pending))
                self._pending.clear()
        else:
            self.stats.discarded_tail_bytes = self._undelivered_tail_bytes()
            self._pending.clear()
            self._queue.clear()
            self._queue_bytes = 0
            self._stack.clear()
            self._stack_bytes = 0
        self._closing = True
        self._wakeup.set()
        if self._task is not None:
            await self._task
        if normal_end:
            await self._push_stack()

    async def __aenter__(self) -> "StreamConsumer":
        return self

    async def __aexit__(self, exc_type: object, *_rest: object) -> None:
        await self.wait_closed(normal_end=exc_type is None)


async def stream_session(
    client: "ClipClient", session: str, receiver: StreamReceiver
) -> int | None:
    """Attach the receiver and start the RTC stream with AT+DOWNLOAD.

    Returns once the device acknowledges the command; frames keep arriving
    until STREAM_END. Returns the file-frame handler lease token: the caller
    owns stopping the stream (AT+STOP) and then detaches with
    ``transport.detach_file_frame_handler(token)`` — which clears the slot
    only if this session still owns it.
    """
    sid = _session_id(session)
    token = client.transport.set_file_frame_handler(receiver.feed)
    try:
        await client.start_download(sid)
    except Exception:
        if token is not None:
            client.transport.detach_file_frame_handler(token)
        else:
            client.transport.set_file_frame_handler(None)
        raise
    return token
