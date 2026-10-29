"""Tests for the clip.stream tool run() lifecycle (offline, FakeTransport)."""

from __future__ import annotations

import argparse
import sys

import pytest

from clip.exceptions import CommandError
from clip.tools.stream import build_parser, run

import clip
import clip.tools.stream as stream_tool

from conftest import FakeTransport

SESSION = "20260807120000"


def start_frame() -> bytes:
    encoded = SESSION.encode("ascii")
    return b"\x13" + bytes((len(encoded),)) + encoded


def end_frame(reason: int = 0) -> bytes:
    return b"\x15" + bytes((reason,))


class StreamTransport(FakeTransport):
    """Emits the STREAM_* frames a device would around each AT command."""

    fail_start = False
    fail_pause = False

    async def send_command(self, command: str, *, timeout: float) -> dict:
        assert self.connected
        self.commands.append(command)
        if command.startswith("AT+START"):
            if self.fail_start:
                return {"ok": False, "msg": "Already recording or invalid state"}
            return {"ok": True, "data": {"session": SESSION, "mode": "rtc"}}
        if command.startswith("AT+DOWNLOAD"):
            self._emit_file_frame(start_frame())
            return {"ok": True, "data": {"state": "streaming", "session": SESSION}}
        if command == "AT+STOP":
            self._emit_file_frame(end_frame())
            return {"ok": True, "data": {"stopped": True}}
        if command == "AT+PAUSE":
            if self.fail_pause:
                return {"ok": False, "msg": "Pause failed"}
            return {"ok": True, "data": {"paused": True, "stream": True}}
        raise AssertionError(f"unexpected command {command}")


def _args(**overrides) -> argparse.Namespace:
    defaults = dict(
        transport="ble",
        address=None,
        name="Clip",
        host="192.168.4.1",
        port=8089,
        out=None,
        duration=0.05,
        pause_at=None,
        resume_at=None,
    )
    defaults.update(overrides)
    return argparse.Namespace(**defaults)


def _use(monkeypatch, transport) -> None:
    monkeypatch.setattr(
        stream_tool, "make_client", lambda args: clip.ClipClient(transport)
    )


async def test_run_rejects_udp_before_any_side_effect(monkeypatch, tmp_path):
    called = []

    def boom(_args):
        called.append(True)

    monkeypatch.setattr(stream_tool, "make_client", boom)
    monkeypatch.chdir(tmp_path)
    with pytest.raises(ValueError, match="BLE-only"):
        await run(_args(transport="udp"))
    assert called == []
    assert list(tmp_path.iterdir()) == []  # no files, no connections


async def test_run_happy_path_completes_capture(monkeypatch, tmp_path):
    transport = StreamTransport()
    _use(monkeypatch, transport)
    monkeypatch.chdir(tmp_path)
    exit_code = await run(_args(duration=0.05))
    assert exit_code == 0
    # Normal end: .part renamed to the final capture, handler slot released.
    assert (tmp_path / f"rtc-{SESSION}.bin").exists()
    assert not (tmp_path / f"rtc-{SESSION}.bin.part").exists()
    assert transport._file_frame_handler is None
    assert transport.commands[-1] == "AT+STOP"


async def test_run_start_failure_cleans_up_without_nameerror(monkeypatch, tmp_path):
    """Regression: early failure must not raise NameError nor leak cleanup."""
    transport = StreamTransport()
    transport.fail_start = True
    _use(monkeypatch, transport)
    monkeypatch.chdir(tmp_path)
    with pytest.raises(CommandError):
        await run(_args(duration=0.05))
    # No capture file or part file was ever created (start failed first).
    assert list(tmp_path.iterdir()) == []
    assert transport._file_frame_handler is None


async def test_run_download_failure_keeps_part_and_detaches(monkeypatch, tmp_path):
    """Failure after capture opened: .part retained, lease released, no hang."""

    class FailDownload(StreamTransport):
        async def send_command(self, command: str, *, timeout: float) -> dict:
            if command.startswith("AT+DOWNLOAD"):
                self.commands.append(command)
                return {"ok": False, "msg": "RTC session has no files"}
            return await super().send_command(command, timeout=timeout)

    transport = FailDownload()
    _use(monkeypatch, transport)
    monkeypatch.chdir(tmp_path)
    with pytest.raises(CommandError):
        await run(_args(duration=0.05))
    # Abnormal end: partial capture kept as .part and reported, never renamed.
    assert not (tmp_path / f"rtc-{SESSION}.bin").exists()
    assert (tmp_path / f"rtc-{SESSION}.bin.part").exists()
    assert transport._file_frame_handler is None


async def test_disconnect_failure_without_primary_fails_the_run(monkeypatch, tmp_path):
    """No primary error: the FIRST cleanup failure IS the failure."""

    class FailDisconnect(StreamTransport):
        async def disconnect(self) -> None:
            raise RuntimeError("disconnect blew up")

    transport = FailDisconnect()
    _use(monkeypatch, transport)
    monkeypatch.chdir(tmp_path)
    with pytest.raises(RuntimeError, match="disconnect blew up"):
        await run(_args(duration=0.05))
    # The stream itself completed normally before cleanup failed.
    assert (tmp_path / f"rtc-{SESSION}.bin").exists()


async def test_disconnect_failure_does_not_mask_primary(monkeypatch, tmp_path, capsys):
    class FailDisconnect(StreamTransport):
        fail_start = True

        async def disconnect(self) -> None:
            raise RuntimeError("disconnect blew up")

    transport = FailDisconnect()
    _use(monkeypatch, transport)
    monkeypatch.chdir(tmp_path)
    with pytest.raises(CommandError):  # primary preserved
        await run(_args(duration=0.05))
    err = capsys.readouterr().err
    assert "disconnect blew up" in err  # reported, not raised


async def test_failed_pause_side_task_fails_the_run(monkeypatch, tmp_path):
    """A scheduled AT+PAUSE completing with error terminates the run."""
    transport = StreamTransport()
    transport.fail_pause = True
    _use(monkeypatch, transport)
    monkeypatch.chdir(tmp_path)
    with pytest.raises(CommandError):
        await run(_args(duration=1.0, pause_at=0.01))
    # Cleanup still ran: session stopped, lease released, capture finalized.
    assert transport.commands[-1] in ("AT+STOP",)
    assert transport._file_frame_handler is None


def test_build_parser_has_no_playback_options() -> None:
    parser = build_parser()
    args = parser.parse_args([])
    assert args.transport == "ble"
    assert not hasattr(args, "play")
    assert not hasattr(args, "wav")
    assert not hasattr(args, "device")
    assert not hasattr(args, "simulate_playback")
