"""Jitter buffer for Clip RTC playback.

BLE delivery is bursty: connection-event granularity, retransmissions, host
scheduling and occasional device-side TX stalls mean frames produced at
exactly 20 ms intervals do not arrive at exactly 20 ms intervals. Playback
must not inherit that jitter.

JitterBuffer decouples arrival from playback:

* Producer: ``put()`` on every STREAM_DATA arrival (any thread).
* Consumer: ``get()`` once per nominal frame period (20 ms for Clip RTC),
  paced by the real playback clock (audio device) or a simulated clock.

Policy:

* Initial fill — nothing is output until ``depth`` frames are buffered;
  the buffer depth is the price of smoothness (depth = added latency).
* Underrun — ``get()`` returns ``None``; the caller plays silence/PLC.
* Catch-up — when the buffer grows past ``max_depth`` (a burst arriving
  after a stall), the oldest frames are dropped to snap back to ``depth``
  so end-to-end latency stays bounded ("live edge" semantics).
* ``depth == 0`` is pass-through (minimum latency, no smoothing).
"""

from __future__ import annotations

import threading
from collections import deque
from collections.abc import Sequence
from dataclasses import dataclass

FRAME_MS = 20.0  # Clip RTC Opus frame duration


@dataclass
class JitterStats:
    """Counters describing what a consumer experienced."""

    frames_in: int = 0
    frames_out: int = 0
    start_wait_frames: int = 0  # silent ticks before initial fill completed
    underruns: int = 0          # consumer ticks that ran dry after start
    underrun_frames: int = 0    # silent ticks emitted after start
    dropped_catchup: int = 0    # oldest frames dropped to snap to live edge


class JitterBuffer:
    """Thread-safe frame queue with initial-fill, underrun and catch-up rules."""

    def __init__(self, depth_frames: int, max_depth_frames: int | None = None) -> None:
        if depth_frames < 0:
            raise ValueError("depth_frames must be >= 0")
        self.depth = depth_frames
        if max_depth_frames is None:
            max_depth_frames = max(depth_frames * 2, depth_frames + 5)
        if max_depth_frames < depth_frames:
            raise ValueError("max_depth_frames must be >= depth_frames")
        self.max_depth = max_depth_frames
        self._queue: deque[bytes] = deque()
        self._lock = threading.Lock()
        self._started = depth_frames == 0
        self.stats = JitterStats()

    @property
    def buffered(self) -> int:
        with self._lock:
            return len(self._queue)

    def put(self, payload: bytes) -> None:
        """Enqueue one arrived frame and enforce the latency cap."""
        with self._lock:
            self.stats.frames_in += 1
            self._queue.append(payload)
            if not self._started and len(self._queue) >= self.depth:
                self._started = True
            if len(self._queue) > self.max_depth:
                excess = len(self._queue) - self.depth
                for _ in range(excess):
                    self._queue.popleft()
                self.stats.dropped_catchup += excess

    def get(self) -> bytes | None:
        """Pull the frame for the current playback tick.

        Returns ``None`` when nothing can be played yet (initial fill
        pending or underrun); the caller emits silence/PLC for the tick.
        """
        with self._lock:
            if not self._started:
                self.stats.start_wait_frames += 1
                return None
            if not self._queue:
                self.stats.underruns += 1
                self.stats.underrun_frames += 1
                return None
            self.stats.frames_out += 1
            return self._queue.popleft()


def simulate_playback(
    inter_frame_gaps_ms: Sequence[float],
    depth_ms: float,
    frame_ms: float = FRAME_MS,
    max_depth_ms: float | None = None,
) -> JitterStats:
    """Replay recorded arrival gaps through the buffer model.

    ``inter_frame_gaps_ms`` is e.g. ``StreamReceiver.inter_frame_gaps_ms``:
    gaps between consecutive arrivals, first frame at t=0. Returns the stats
    a player with the given buffer depth would have experienced. Useful for
    sizing the buffer from a real capture without replaying audio.
    """
    if depth_ms < 0:
        raise ValueError("depth_ms must be >= 0")
    depth_frames = round(depth_ms / frame_ms)
    max_depth_frames = None if max_depth_ms is None else round(max_depth_ms / frame_ms)
    buf = JitterBuffer(depth_frames, max_depth_frames)

    arrivals = [0.0]
    for gap in inter_frame_gaps_ms:
        arrivals.append(arrivals[-1] + gap)
    total = len(arrivals)
    if total == 0:
        return buf.stats

    ai = 1
    buf.put(b"")
    if depth_frames > 0:
        while ai < total and buf.buffered < depth_frames:
            buf.put(b"")
            ai += 1
        if buf.buffered < depth_frames:
            return buf.stats  # never reached initial fill

    t = arrivals[ai - 1] if depth_frames > 0 else 0.0
    while True:
        while ai < total and arrivals[ai] <= t:
            buf.put(b"")
            ai += 1
        if buf.buffered == 0:
            if ai >= total:
                break  # stream over and buffer drained
            buf.get()  # silent tick, more frames still coming
        else:
            buf.get()
        t += frame_ms

    return buf.stats
