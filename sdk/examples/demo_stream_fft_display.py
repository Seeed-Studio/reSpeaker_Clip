#!/usr/bin/env python3
"""Minimal real-device demo: real-time FFT spectrum of RTC audio.

Streams live RTC audio from a Clip over BLE, decodes Opus → PCM, and
displays a real-time FFT spectrum in the terminal using Unicode block
characters. No audio is played. Full performance statistics are preserved:
JitterBuffer stats, queue depth distribution, and latency breakdown
(queue / decode / FFT / total).

Usage:
    python examples/demo_stream_fft_display.py --address C4:F1:79:A4:09:A0 [--duration 10]
    python examples/demo_stream_fft_display.py              # scan for a device named "Clip"
"""

from __future__ import annotations

import argparse
import asyncio
import os
import shutil
import sys
import threading
import time
from collections import deque

from _bootstrap import SDK_ROOT  # noqa: F401

from clip import BleTransport, ClipClient
from clip.jitter import FRAME_MS, JitterBuffer
from clip.stream import StreamReceiver

try:
    import numpy as np
    import opuslib
except ImportError as exc:
    raise SystemExit(
        f"Missing dependency: {exc.name}\n"
        "Install with: pip install 'respeaker-clip-sdk[examples]'"
    ) from exc

_SAMPLE_RATE = 16000
_FRAME_SAMPLES = 320  # 20 ms at 16 kHz mono
_FRAME_PERIOD = _FRAME_SAMPLES / _SAMPLE_RATE  # 0.02 s
_FFT_BARS = 64        # spectrum display bars
# Unicode block characters for 8 sub-levels per cell (eighths).
_BLOCKS = " ▁▂▃▄▅▆▇█"


class LiveSpectrum:
    """Jitter buffer + Opus decoder + real-time CLI FFT, fed from on_frame.

    Uses the SDK's :class:`clip.jitter.JitterBuffer` for the queue policy
    (initial fill, underrun, catch-up drop). A parallel timestamp deque
    tracks per-frame arrival time for latency measurement; it is kept in
    sync with the jitter buffer's catch-up drops.

    The processing thread is paced at 20 ms/frame (the natural frame
    period) to simulate the sound card's consumption rate — without this
    pacing, the thread would drain the JitterBuffer too fast and skew
    the underrun/drop statistics.
    """

    def __init__(self, depth_frames: int = 5) -> None:
        self._jbuf = JitterBuffer(depth_frames)
        self._timestamps: deque[float] = deque()
        self._timeline_lock = threading.Lock()
        self._decoder = opuslib.Decoder(_SAMPLE_RATE, 1)
        self._closed = False
        self.decode_errors = 0

        # Latency tracking: feed() stamps arrival; _run() measures segments.
        self._latencies: list[float] = []         # total feed→fft end (ms)
        self._queue_times: list[float] = []       # queue wait (ms)
        self._decode_times: list[float] = []      # Opus decode (ms)

        # Queue depth tracking: snapshot JitterBuffer depth at each feed()
        # (producer) and _run() get() (consumer) to see the fill/drain pattern.
        self._depth_at_feed: list[int] = []       # depth after put()
        self._depth_at_get: list[int] = []         # depth before get()

        # Precompute Hann window for FFT
        self._hann = np.hanning(_FRAME_SAMPLES)

        # Adaptive noise floor (per band) for a hard spectral gate.
        # Fast attack / slow release: the floor drops quickly to lock onto
        # the mic's noise baseline, and rises slowly so speech peaks don't
        # pull it up. A hard gate then blanks anything below floor + margin
        # to a fixed -80 dB — the noise region is a constant blank, never
        # fluctuating frame to frame. Only signal above the gate passes.
        self._noise_floor = np.full(_FFT_BARS, -90.0)
        self._alpha_down = 0.30    # fast attack (~60 ms)
        self._alpha_up = 0.02      # slow release (~1 s)
        self._margin_db = 20.0     # signal must exceed floor by this to show

        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._run, name="clip-spectrum", daemon=True)
        # Thread starts lazily on first feed() to avoid spinning silence
        # before BLE frames arrive (connection param negotiation can take
        # seconds — without this, start_wait_frames would be huge).
        self._thread_started = False
        self._lock = threading.Lock()

    def feed(self, opus_packet: bytes) -> None:
        """Called from on_frame (asyncio thread). Non-blocking."""
        if self._closed:
            return
        # Keep the payload queue and its parallel timestamp queue atomic with
        # respect to the consumer thread. JitterBuffer protects its own queue,
        # but the timestamp bookkeeping needs the same higher-level boundary.
        with self._timeline_lock:
            dropped_before = self._jbuf.stats.dropped_catchup
            self._jbuf.put(opus_packet)
            self._depth_at_feed.append(self._jbuf.buffered)
            # Keep timestamps in sync with JitterBuffer catch-up drops.
            while (
                self._timestamps
                and self._jbuf.stats.dropped_catchup > dropped_before
            ):
                self._timestamps.popleft()
                dropped_before += 1
            self._timestamps.append(time.perf_counter())
        # Lazy thread start: only once the first frame arrives.
        with self._lock:
            if not self._thread_started:
                self._thread_started = True
                self._thread.start()

    def _run(self) -> None:
        # Pace at 20 ms/frame to simulate the sound card's consumption rate.
        # Without sd.write() providing natural pacing, we must sleep to
        # maintain the same JitterBuffer dynamics as the playback version.
        next_tick = time.perf_counter()
        while not self._stop.is_set():
            now = time.perf_counter()
            sleep_time = next_tick - now
            if sleep_time > 0:
                time.sleep(sleep_time)
            elif sleep_time < -_FRAME_PERIOD * 2:
                # Fell behind by more than 2 frames — reset clock to avoid
                # spiral-of-death (compounding catch-up).
                next_tick = time.perf_counter()
            next_tick += _FRAME_PERIOD

            with self._timeline_lock:
                self._depth_at_get.append(self._jbuf.buffered)
                frame = self._jbuf.get()
                ts_arrival = (
                    self._timestamps.popleft()
                    if frame is not None and self._timestamps
                    else None
                )

            if frame is None:
                continue  # underrun or initial fill — no FFT for silence

            t_decode_start = time.perf_counter()
            try:
                pcm = self._decoder.decode(frame, _FRAME_SAMPLES)
                samples = np.frombuffer(pcm, dtype=np.int16)
            except Exception:
                self.decode_errors += 1
                continue
            t_decode_end = time.perf_counter()

            # --- FFT ---
            audio = samples.astype(np.float32) / 32768.0
            windowed = audio * self._hann
            fft_result = np.fft.rfft(windowed)
            magnitude = np.abs(fft_result)
            # Evenly bin into _FFT_BARS display bars (take max of each group)
            edges = np.linspace(0, len(magnitude), _FFT_BARS + 1, dtype=int)
            binned = np.array([
                magnitude[edges[i]:edges[i + 1]].max()
                for i in range(_FFT_BARS)
            ])
            binned_db = 20 * np.log10(binned + 1e-10)

            # --- Adaptive noise floor (suppress mic noise baseline) ---
            # Per-band envelope follower: fast attack / slow release.
            below = binned_db < self._noise_floor
            self._noise_floor[below] = (
                binned_db[below] * self._alpha_down
                + self._noise_floor[below] * (1 - self._alpha_down))
            self._noise_floor[~below] = (
                binned_db[~below] * self._alpha_up
                + self._noise_floor[~below] * (1 - self._alpha_up))

            # Hard spectral gate: anything below floor + margin is blanked
            # to a fixed -80 dB (no soft roll-off, no smoothing) — the noise
            # region is a constant blank and never fluctuates frame to frame.
            # Only signal genuinely above the noise baseline passes through,
            # displayed relative to the floor.
            gate = self._noise_floor + self._margin_db
            display_db = np.where(binned_db > gate, binned_db - self._noise_floor, -80.0)

            t_fft_end = time.perf_counter()

            # --- CLI spectrum display ---
            self._render_spectrum(display_db)

            if ts_arrival is not None:
                self._queue_times.append(
                    (t_decode_start - ts_arrival) * 1000.0)
                self._decode_times.append(
                    (t_decode_end - t_decode_start) * 1000.0)
                self._latencies.append(
                    (t_fft_end - ts_arrival) * 1000.0)

    @staticmethod
    def _render_spectrum(display_db: np.ndarray) -> None:
        """Render spectrum as a single-line Unicode bar chart to stdout."""
        # Map dB range [-10, 30] to [0, 8] sub-levels per bar. display_db is
        # relative to the noise floor (floor + margin subtracted upstream),
        # so 0 dB ≈ signal-at-floor and residual noise maps below visible.
        db_min, db_max = -10.0, 30.0
        norm = np.clip((display_db - db_min) / (db_max - db_min), 0.0, 1.0)
        # Each terminal cell holds one block char; 8 sub-levels per cell.
        # Scale to terminal width: use up to _FFT_BARS cells.
        cols = min(_FFT_BARS, shutil.get_terminal_size((80, 24)).columns - 12)
        if cols < 8:
            cols = 8
        # Resample to fit terminal width
        idx = np.linspace(0, len(norm) - 1, cols, dtype=int)
        norm = norm[idx]
        bars = []
        for v in norm:
            level = int(v * 8)
            level = min(level, 8)
            bars.append(_BLOCKS[level])
        # Frequency labels
        line = "".join(bars)
        # Clear line and print: \r for in-place update
        sys.stdout.write(f"\r{line} ")
        sys.stdout.flush()

    def close(self) -> None:
        if self._closed:
            return
        self._closed = True
        self._stop.set()
        with self._lock:
            thread_started = self._thread_started
        if thread_started:
            self._thread.join(timeout=2.0)

    def print_stats(self) -> None:
        s = self._jbuf.stats
        print()
        print("Live spectrum (SDK JitterBuffer + Opus decode + FFT):")
        print(f"  depth target    : {self._jbuf.depth} frames ({self._jbuf.depth * FRAME_MS:.0f} ms)")
        print(f"  frames in       : {s.frames_in}")
        print(f"  frames processed: {s.frames_out}")
        print(f"  start wait      : {s.start_wait_frames} silent ticks")
        print(f"  underruns       : {s.underruns} ({s.underrun_frames} silent ticks)")
        print(f"  catch-up drops  : {s.dropped_catchup}")
        print(f"  decode errors   : {self.decode_errors}")
        self._print_depth_stats()
        self._print_latency_stats()

    def _print_depth_stats(self) -> None:
        if not self._depth_at_feed and not self._depth_at_get:
            return
        df = sorted(self._depth_at_feed) if self._depth_at_feed else []
        dg = sorted(self._depth_at_get) if self._depth_at_get else []
        print()
        print("Queue depth distribution (JitterBuffer.buffered):")
        if df:
            n = len(df)
            print(f"  at feed  (n={n}): "
                  f"p50={self._pct_int(df,50)}  p95={self._pct_int(df,95)}  "
                  f"min={df[0]}  max={df[-1]}  mean={sum(df)/n:.1f}  (frames)")
        if dg:
            n = len(dg)
            print(f"  at get   (n={n}): "
                  f"p50={self._pct_int(dg,50)}  p95={self._pct_int(dg,95)}  "
                  f"min={dg[0]}  max={dg[-1]}  mean={sum(dg)/n:.1f}  (frames)")
            zero_pct = dg.count(0) * 100.0 / n if n else 0.0
            print(f"  depth=0 at get : {dg.count(0)} ({zero_pct:.1f}%) = underruns")

    @staticmethod
    def _pct_int(sorted_vals: list[int], pct: float) -> int:
        if not sorted_vals:
            return 0
        idx = min(int(len(sorted_vals) * pct / 100.0), len(sorted_vals) - 1)
        return sorted_vals[idx]

    @staticmethod
    def _pct(sorted_vals: list[float], pct: float) -> float:
        if not sorted_vals:
            return 0.0
        idx = min(int(len(sorted_vals) * pct / 100.0), len(sorted_vals) - 1)
        return sorted_vals[idx]

    def _print_latency_stats(self) -> None:
        if not self._latencies:
            print("  (no latency samples)")
            return
        lat = sorted(self._latencies)
        qt = sorted(self._queue_times) if self._queue_times else []
        dt = sorted(self._decode_times) if self._decode_times else []
        n = len(lat)
        print()
        print(f"Latency (on_frame arrival → FFT end, {n} samples):")
        print(f"  total    : p50={self._pct(lat,50):.1f}  p95={self._pct(lat,95):.1f}  "
              f"min={lat[0]:.1f}  max={lat[-1]:.1f}  mean={sum(lat)/n:.1f}  (ms)")
        if qt:
            print(f"  queue    : p50={self._pct(qt,50):.1f}  p95={self._pct(qt,95):.1f}  "
                  f"min={qt[0]:.1f}  max={qt[-1]:.1f}  (ms)")
        if dt:
            print(f"  decode   : p50={self._pct(dt,50):.2f}  p95={self._pct(dt,95):.2f}  "
                  f"min={dt[0]:.2f}  max={dt[-1]:.2f}  (ms)")


async def run(address: str | None, duration: float | None,
              depth_frames: int) -> int:
    transport = BleTransport(address=address) if address else BleTransport(name="Clip")
    async with ClipClient(transport) as clip:
        analyzer = LiveSpectrum(depth_frames)

        def on_frame(opus_packet: bytes) -> None:
            """Synchronous, inline on the receive path — keep non-blocking."""
            analyzer.feed(opus_packet)

        receiver = StreamReceiver(on_frame=on_frame)
        session: str | None = None
        token: int | None = None
        cursor_hidden = False
        try:
            session = await clip.start_rtc()
            token = await clip.stream_rtc(session, receiver)
            print(f"RTC session: {session}")
            # Hide cursor while streaming the live spectrum (DECTCEM off).
            # Set the guard before writing so even a terminal I/O failure
            # reaches the matching restore path.
            cursor_hidden = True
            sys.stdout.write("\033[?25l")
            sys.stdout.flush()
            await receiver.wait_start(timeout=10.0)
            if duration is None:
                print("Streaming until Ctrl-C ...")
                await receiver.wait_end()
            else:
                print(f"Streaming for {duration:g}s ...")
                try:
                    await asyncio.wait_for(receiver.wait_end(), timeout=duration)
                except asyncio.TimeoutError:
                    pass
        finally:
            # Bounded stop + lease release + analyzer close, each guarded.
            try:
                if (
                    session is not None
                    and clip.is_connected
                    and not receiver.ended.is_set()
                ):
                    await clip.stop_recording()
                    await receiver.wait_end(timeout=5.0)
            except Exception as exc:
                print(f"stop: {exc}")
            try:
                if token is not None:
                    transport.detach_file_frame_handler(token)
            finally:
                try:
                    analyzer.close()
                finally:
                    if cursor_hidden:
                        # Restore cursor (DECTCEM on) before printing stats.
                        sys.stdout.write("\033[?25h")
                        sys.stdout.flush()

        print()
        print(f"frames received : {receiver.frames_received}")
        print(f"bytes received  : {receiver.bytes_received}")
        print(f"seq discontin.  : {receiver.sequence_gaps}")
        gaps = receiver.inter_frame_gaps_ms
        if gaps:
            print(f"avg inter-frame : {receiver.avg_inter_frame_ms:.1f} ms "
                  f"(max {receiver.max_inter_frame_ms:.0f} ms)")
        analyzer.print_stats()
        if receiver.error is not None:
            print(f"error           : {receiver.error}")
            return 1
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--address", help="BLE address; omit to scan by name")
    parser.add_argument(
        "--duration",
        type=float,
        help="seconds to stream; default waits for Ctrl-C",
    )
    parser.add_argument(
        "--depth-frames", type=int, default=5,
        help="jitter buffer depth in frames (default 5; 0 = pass-through)",
    )
    args = parser.parse_args()
    if args.duration is not None and args.duration <= 0:
        parser.error("--duration must be positive")
    if args.depth_frames < 0:
        parser.error("--depth-frames must be >= 0")
    try:
        return asyncio.run(run(args.address, args.duration,
                               args.depth_frames))
    except KeyboardInterrupt:
        print("\nStopped.")
        return 130
    except Exception as exc:
        print(f"demo: {exc}")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
