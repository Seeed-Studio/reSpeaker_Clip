from __future__ import annotations

import asyncio

import pytest

from clip import ClipClient, CommandError, SessionDetails

from conftest import FakeTransport


@pytest.mark.asyncio
async def test_current_firmware_status_and_storage_commands() -> None:
    transport = FakeTransport(
        [
            {"ok": True, "data": {"state": "IDLE", "recording": False, "session": None, "duration": 0,
                                  "battery": 78, "charging": False, "temp": 25, "voltage": 3890,
                                  "mode": "enhanced", "bitrate": 32000, "free_space": 1000, "device": "Clip 8673"}},
            {"ok": True, "data": {"mounted": True, "total_mb": 1000, "free_mb": 750,
                                  "used_mb": 250, "used_pct": 25, "recorded_mb": 200}},
        ]
    )
    async with ClipClient(transport) as client:
        status = await client.status()
        storage = await client.storage()
    assert status.battery_percent == 78
    assert storage.used_percent == 25
    assert transport.commands == ["AT+GSTAT", "AT+STORAGE?"]


@pytest.mark.asyncio
async def test_device_error_uses_msg_not_legacy_error() -> None:
    transport = FakeTransport([{"ok": False, "msg": "Invalid session ID"}])
    async with ClipClient(transport) as client:
        with pytest.raises(CommandError, match="Invalid session ID") as caught:
            await client.request("AT+LIST=bad")
    assert caught.value.command == "AT+LIST=bad"


@pytest.mark.asyncio
async def test_pagination_uses_current_list_syntax() -> None:
    sid = "20260716022113"
    transport = FakeTransport(
        [
            {"ok": True, "data": {"total": 2, "page": 1, "per_page": 2,
                                  "sessions": [{"id": sid, "files": 1, "size": 1, "bookmarks": 0},
                                               {"id": "20260716022000", "files": 2, "size": 2, "bookmarks": 1}]}},
            {"ok": True, "data": {"files": 1, "size": 10, "synced": 0, "bookmarks": 0,
                                  "channels": 1, "sample_rate": 16000, "mode": "enhanced"}},
        ]
    )
    async with ClipClient(transport) as client:
        sessions = await client.list_all_sessions(per_page=2)
        details = await client.session_details(sid)
    assert [item.id for item in sessions] == [sid, "20260716022000"]
    assert details.sample_rate_hz == 16000
    assert transport.commands == ["AT+LIST?1&2", f"AT+LIST={sid}"]


@pytest.mark.asyncio
async def test_destructive_operations_require_local_confirmation() -> None:
    transport = FakeTransport()
    async with ClipClient(transport) as client:
        with pytest.raises(ValueError, match="confirm=True"):
            await client.delete_session("20260716022113")
        with pytest.raises(ValueError, match="confirm=True"):
            await client.format_storage()
    assert transport.commands == []


@pytest.mark.asyncio
async def test_client_serializes_concurrent_at_commands() -> None:
    class SlowTransport(FakeTransport):
        def __init__(self) -> None:
            super().__init__([{"ok": True}, {"ok": True}])
            self.in_flight = 0
            self.maximum_in_flight = 0

        async def send_command(self, command: str, *, timeout: float) -> dict:
            self.in_flight += 1
            self.maximum_in_flight = max(self.maximum_in_flight, self.in_flight)
            await asyncio.sleep(0)
            self.in_flight -= 1
            return await super().send_command(command, timeout=timeout)

    transport = SlowTransport()
    async with ClipClient(transport) as client:
        await asyncio.gather(client.request("AT+GSTAT"), client.request("AT+VERSION"))
    assert transport.maximum_in_flight == 1


@pytest.mark.asyncio
async def test_disconnect_failure_cannot_mask_primary_error() -> None:
    class FailDisconnect(FakeTransport):
        async def disconnect(self) -> None:
            raise RuntimeError("disconnect blew up")

    # With a primary error propagating from the body, a failing disconnect
    # must be suppressed so the primary error survives unchanged.
    transport = FailDisconnect([{"ok": True, "data": {}}])
    with pytest.raises(ValueError, match="body error"):
        async with ClipClient(transport) as client:
            await client.request("AT+GSTAT")
            raise ValueError("body error")

    # With no primary error, the disconnect failure IS the failure.
    transport2 = FailDisconnect([{"ok": True, "data": {}}])
    with pytest.raises(RuntimeError, match="disconnect blew up"):
        async with ClipClient(transport2) as client:
            await client.request("AT+GSTAT")
