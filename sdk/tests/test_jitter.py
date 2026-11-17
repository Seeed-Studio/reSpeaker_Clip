from __future__ import annotations

import pytest

from clip.jitter import FRAME_MS, JitterBuffer, simulate_playback


def test_passthrough_depth_zero() -> None:
    buf = JitterBuffer(0)
    for i in range(5):
        buf.put(bytes((i,)))
    out = [buf.get() for _ in range(5)]
    assert out == [bytes((i,)) for i in range(5)]
    assert buf.get() is None  # drained -> underrun
    assert buf.stats.underruns == 1
    assert buf.stats.frames_out == 5


def test_initial_fill_gates_output() -> None:
    buf = JitterBuffer(3)
    buf.put(b"a")
    buf.put(b"b")
    assert buf.get() is None  # still filling
    assert buf.get() is None
    assert buf.stats.start_wait_frames == 2
    buf.put(b"c")  # fill reached
    assert buf.get() == b"a"
    assert buf.get() == b"b"
    assert buf.get() == b"c"


def test_underrun_counts() -> None:
    buf = JitterBuffer(1)
    buf.put(b"a")
    assert buf.get() == b"a"
    assert buf.get() is None
    assert buf.get() is None
    buf.put(b"b")
    assert buf.get() == b"b"
    assert buf.stats.underruns == 2
    assert buf.stats.underrun_frames == 2


def test_catchup_drops_oldest_to_depth() -> None:
    buf = JitterBuffer(depth_frames=2, max_depth_frames=4)
    for i in range(8):  # burst of 8 while depth is 2
        buf.put(bytes((i,)))
    # 8 > max_depth 4 -> drop down to depth 2, keeping the newest
    assert buf.buffered == 2
    assert buf.stats.dropped_catchup == 6
    assert buf.get() == bytes((6,))
    assert buf.get() == bytes((7,))


def test_invalid_args() -> None:
    with pytest.raises(ValueError):
        JitterBuffer(-1)
    with pytest.raises(ValueError):
        JitterBuffer(5, max_depth_frames=2)
    with pytest.raises(ValueError):
        simulate_playback([], -1.0)


def test_simulate_steady_stream_no_underrun() -> None:
    gaps = [FRAME_MS] * 499  # 500 frames, perfectly paced
    for depth_ms in (0.0, 60.0, 100.0):
        stats = simulate_playback(gaps, depth_ms)
        assert stats.underruns == 0
        assert stats.frames_out == 500


def test_simulate_stall_causes_underrun_then_catchup() -> None:
    # 50 steady frames, a 200 ms send stall, then a burst catching up.
    gaps = [FRAME_MS] * 49 + [200.0] + [2.0] * 9
    stats = simulate_playback(gaps, 60.0)  # depth 3 frames
    assert stats.underruns > 0
    assert stats.underrun_frames >= 7  # ~200 ms stall minus buffered 60 ms
    assert stats.dropped_catchup > 0  # burst after stall exceeds the cap


def test_simulate_never_fills() -> None:
    stats = simulate_playback([FRAME_MS], 1000.0)  # depth 50, only 2 frames
    assert stats.frames_out == 0
    assert stats.underruns == 0
