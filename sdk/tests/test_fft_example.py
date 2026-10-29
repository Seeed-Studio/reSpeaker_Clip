"""Offline lifecycle checks for the optional RTC FFT example."""

from __future__ import annotations

import importlib.util
import sys
from pathlib import Path

import pytest

pytest.importorskip("numpy")
pytest.importorskip("opuslib")

EXAMPLES_DIR = Path(__file__).resolve().parents[1] / "examples"
MODULE_PATH = EXAMPLES_DIR / "demo_stream_fft_display.py"


def _load_example_module():
    spec = importlib.util.spec_from_file_location("clip_fft_example", MODULE_PATH)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.path.insert(0, str(EXAMPLES_DIR))
    try:
        spec.loader.exec_module(module)
    finally:
        sys.path.pop(0)
    return module


def test_analyzer_close_before_first_frame_is_idempotent() -> None:
    """A stream ending without DATA must not join an unstarted thread."""
    module = _load_example_module()
    analyzer = module.LiveSpectrum(depth_frames=5)

    analyzer.close()
    analyzer.close()

    assert analyzer._closed is True
    assert analyzer._thread_started is False
