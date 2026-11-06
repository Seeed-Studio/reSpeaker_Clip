"""High-level asynchronous API for the current reSpeaker Clip AT protocol."""

from __future__ import annotations

import asyncio
import re
from collections.abc import Callable
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from .exceptions import CommandError, ProtocolError
from .models import (
    Battery,
    Bookmark,
    DownloadResult,
    PairingStatus,
    Session,
    SessionDetails,
    Status,
    Storage,
    WifiAccessPoint,
)
from .stream import StreamReceiver, stream_session as _stream_session
from .transfer import ProgressCallback, download_session as _download_session
from .transports.base import BaseTransport
from .validation import chunk_name, page, session_id

_PAIR_ADDRESS_RE = re.compile(r'"addr":"([^"]+)"')


class ClipClient:
    """A typed client for a BLE or Wi-Fi connected Clip device.

    The current firmware has no command transaction id.  This client therefore
    serializes all AT commands.  Do not use ``transport.send_command`` directly
    once it is owned by a ``ClipClient``.
    """

    def __init__(self, transport: BaseTransport, *, command_timeout: float = 10.0) -> None:
        if command_timeout <= 0:
            raise ValueError("command_timeout must be positive")
        self.transport = transport
        self.command_timeout = command_timeout
        self._command_lock = asyncio.Lock()

    async def connect(self) -> None:
        await self.transport.connect()

    async def disconnect(self) -> None:
        await self.transport.disconnect()

    async def __aenter__(self) -> "ClipClient":
        await self.connect()
        return self

    async def __aexit__(self, exc_type: object, _exc: object, _traceback: object) -> None:
        try:
            await self.disconnect()
        except Exception:
            # A disconnect failure must never replace the primary error that
            # is already propagating out of the body.  With no primary error
            # the disconnect failure is the failure, so it propagates.
            if exc_type is None:
                raise

    @property
    def is_connected(self) -> bool:
        return self.transport.is_connected

    def on_event(self, callback: Callable[[dict[str, Any]], None] | None) -> None:
        """Set a callback for unsolicited JSON events emitted by firmware."""
        self.transport.set_event_handler(callback)

    async def request(self, command: str, *, timeout: float | None = None) -> dict[str, Any]:
        """Issue a current-firmware AT command and return its raw response.

        The SDK does not silently translate removed legacy commands.  This keeps
        unsupported firmware functionality visible to callers rather than
        creating false compatibility.
        """
        if not isinstance(command, str) or not command.startswith("AT+"):
            raise ValueError("command must start with 'AT+'")
        if "\r" in command or "\n" in command or len(command) > 512:
            raise ValueError("command must be a single line no longer than 512 bytes")
        wait = self.command_timeout if timeout is None else timeout
        if wait <= 0:
            raise ValueError("timeout must be positive")
        async with self._command_lock:
            response = await self.transport.send_command(command, timeout=wait)
        if not isinstance(response, dict):
            raise ProtocolError("transport returned a non-object command response")
        if response.get("ok") is not True:
            message = response.get("msg", "device rejected command")
            raise CommandError(str(message), command=command, response=response)
        return response

    # Device status ---------------------------------------------------------

    async def status(self) -> Status:
        return Status.from_response(await self.request("AT+GSTAT"))

    async def battery(self) -> Battery:
        return Battery.from_response(await self.request("AT+BATT?"))

    async def storage(self) -> Storage:
        return Storage.from_response(await self.request("AT+STORAGE?"))

    async def device_name(self) -> str:
        response = await self.request("AT+DEVICE?")
        name = response.get("device")
        if not isinstance(name, str):
            raise ProtocolError("AT+DEVICE response did not contain device")
        return name

    async def firmware_version(self) -> str:
        response = await self.request("AT+VERSION")
        version = response.get("firmware")
        if not isinstance(version, str):
            raise ProtocolError("AT+VERSION response did not contain firmware")
        return version

    async def get_time(self) -> datetime:
        response = await self.request("AT+TIME?")
        value = _data(response).get("time")
        if not isinstance(value, str):
            raise ProtocolError("AT+TIME? response did not contain an ISO-8601 time")
        try:
            return datetime.fromisoformat(value.replace("Z", "+00:00"))
        except ValueError as exc:
            raise ProtocolError(f"invalid device time {value!r}") from exc

    async def set_time(self, value: int | datetime) -> int:
        if isinstance(value, datetime):
            timestamp = int((value.replace(tzinfo=timezone.utc) if value.tzinfo is None else value).timestamp())
        else:
            timestamp = value
        if isinstance(timestamp, bool) or not isinstance(timestamp, int) or timestamp < 0:
            raise ValueError("time must be a non-negative Unix timestamp or datetime")
        response = await self.request(f"AT+TIME={timestamp}")
        echoed = _data(response).get("time")
        if not isinstance(echoed, int):
            raise ProtocolError("AT+TIME response did not contain its timestamp")
        return echoed

    # Persistent configuration ---------------------------------------------

    async def mode(self) -> str:
        return _required_str(_data(await self.request("AT+MODE?")), "mode")

    async def set_mode(self, value: str) -> str:
        if value not in ("normal", "enhanced"):
            raise ValueError("mode must be 'normal' or 'enhanced'")
        return _required_str(_data(await self.request(f"AT+MODE={value}")), "mode")

    async def auto_delete_days(self) -> int | None:
        value = _data(await self.request("AT+AUTODEL?")).get("autodel")
        if value == "off":
            return None
        if isinstance(value, int):
            return value
        raise ProtocolError("AT+AUTODEL? returned an invalid autodel value")

    async def set_auto_delete_days(self, days: int | None) -> int | None:
        if days is None:
            await self.request("AT+AUTODEL=off")
            return None
        if isinstance(days, bool) or not isinstance(days, int) or not 0 <= days <= 30:
            raise ValueError("days must be None or an integer from 0 through 30")
        value = _data(await self.request(f"AT+AUTODEL={days}")).get("autodel")
        return value if isinstance(value, int) else None

    async def brightness(self) -> int:
        return _required_int(_data(await self.request("AT+BRIGHTNESS?")), "brightness")

    async def set_brightness(self, value: int) -> int:
        if isinstance(value, bool) or not isinstance(value, int) or not 0 <= value <= 255:
            raise ValueError("brightness must be an integer from 0 through 255")
        return _required_int(_data(await self.request(f"AT+BRIGHTNESS={value}")), "brightness")

    async def configured_name(self) -> str:
        return _required_str(_data(await self.request("AT+NAME?")), "name")

    async def set_name(self, name: str) -> str:
        if not isinstance(name, str) or not name or len(name.encode("utf-8")) > 256:
            raise ValueError("name must contain 1..256 UTF-8 bytes")
        if any(ord(char) < 0x20 for char in name) or '"' in name:
            raise ValueError("name cannot contain controls or double quotes")
        response = await self.request(f'AT+NAME="{name}"')
        return _required_str(_data(response), "name")

    async def clear_name(self) -> None:
        await self.request("AT+NAME=CLEAR")

    async def log_mode(self) -> str:
        return _required_str(_data(await self.request("AT+LOG?")), "log")

    async def set_log_mode(self, value: str) -> str:
        if value not in ("off", "info", "debug"):
            raise ValueError("log mode must be 'off', 'info', or 'debug'")
        return _required_str(_data(await self.request(f"AT+LOG={value}")), "log")

    async def pairing_status(self) -> PairingStatus:
        message = (await self.request("AT+PAIR?")).get("msg")
        if not isinstance(message, str):
            raise ProtocolError("AT+PAIR? response did not contain msg")
        if '"unpaired"' in message:
            return PairingStatus(paired=False, peer_address=None)
        if '"paired"' in message:
            match = _PAIR_ADDRESS_RE.search(message)
            return PairingStatus(paired=True, peer_address=match.group(1) if match else None)
        raise ProtocolError("AT+PAIR? returned an unknown status")

    async def reset_pairing(self, *, confirm: bool = False) -> None:
        if not confirm:
            raise ValueError("reset_pairing erases all recordings; pass confirm=True")
        await self.request("AT+PAIR=reset")

    # Recording -------------------------------------------------------------

    async def start_recording(self, mode: str | None = None) -> str | None:
        if mode is None:
            response = await self.request("AT+START")
        else:
            if mode not in ("normal", "enhanced", "stereo", "merge"):
                raise ValueError("recording mode must be normal, enhanced, stereo, or merge")
            response = await self.request(f"AT+START={mode}")
        value = _data(response).get("session")
        return value if isinstance(value, str) else None

    async def start_rtc(self) -> str:
        """Start a live RTC session: Opus over BLE, nothing written to SD."""
        response = await self.request("AT+START=rtc")
        return _required_str(_data(response), "session")

    async def stop_recording(self) -> dict[str, Any]:
        return _data(await self.request("AT+STOP"))

    async def pause_recording(self) -> None:
        await self.request("AT+PAUSE")

    async def resume_recording(self) -> None:
        await self.request("AT+RESUME")

    async def bookmark(self) -> Bookmark:
        return Bookmark.from_data(_data(await self.request("AT+MARK")))

    # Sessions --------------------------------------------------------------

    async def list_sessions(self, *, page_number: int = 1, per_page: int = 10) -> tuple[Session, ...]:
        page(page_number, name="page_number")
        page(per_page, name="per_page", maximum=50)
        command = "AT+LIST" if page_number == 1 and per_page == 10 else f"AT+LIST?{page_number}&{per_page}"
        data = _data(await self.request(command))
        values = data.get("sessions", [])
        if not isinstance(values, list):
            raise ProtocolError("AT+LIST response did not contain sessions")
        return tuple(Session.from_data(item) for item in values if isinstance(item, dict))

    async def list_all_sessions(self, *, per_page: int = 50) -> tuple[Session, ...]:
        page(per_page, name="per_page", maximum=50)
        result: list[Session] = []
        number = 1
        while True:
            command = "AT+LIST" if number == 1 and per_page == 10 else f"AT+LIST?{number}&{per_page}"
            data = _data(await self.request(command))
            values = data.get("sessions", [])
            if not isinstance(values, list):
                raise ProtocolError("AT+LIST response did not contain sessions")
            result.extend(Session.from_data(item) for item in values if isinstance(item, dict))
            total = _required_int(data, "total")
            if len(result) >= total or not values:
                return tuple(result)
            number += 1

    async def session_details(self, value: str) -> SessionDetails:
        sid = session_id(value)
        return SessionDetails.from_response(sid, await self.request(f"AT+LIST={sid}"))

    async def list_files(self, value: str, *, page_number: int = 1, per_page: int = 20) -> tuple[str, ...]:
        sid = session_id(value)
        page(page_number, name="page_number")
        page(per_page, name="per_page", maximum=20)
        data = _data(await self.request(f"AT+LIST={sid}?{page_number}&{per_page}"))
        values = data.get("files", [])
        if not isinstance(values, list) or not all(isinstance(item, str) for item in values):
            raise ProtocolError("AT+LIST file response did not contain filenames")
        return tuple(values)

    async def list_bookmarks(self, value: str, *, per_page: int = 100) -> tuple[Bookmark, ...]:
        sid = session_id(value)
        page(per_page, name="per_page", maximum=100)
        result: list[Bookmark] = []
        number = 1
        while True:
            data = _data(await self.request(f"AT+MARKS={sid}?{number}&{per_page}"))
            values = data.get("bookmarks", [])
            if not isinstance(values, list):
                raise ProtocolError("AT+MARKS response did not contain bookmarks")
            result.extend(Bookmark.from_data(item) for item in values if isinstance(item, dict))
            total = _required_int(data, "total")
            if len(result) >= total or not values:
                return tuple(result)
            number += 1

    async def delete_session(self, value: str, *, confirm: bool = False) -> None:
        if not confirm:
            raise ValueError("delete_session is destructive; pass confirm=True")
        await self.request(f"AT+DELETE={session_id(value)}")

    async def format_storage(self, *, confirm: bool = False) -> None:
        if not confirm:
            raise ValueError("format_storage is destructive; pass confirm=True")
        await self.request("AT+FORMAT", timeout=60.0)

    # File transfer ---------------------------------------------------------

    async def start_download(self, value: str, *, start_file: str | None = None) -> dict[str, Any]:
        sid = session_id(value)
        command = f"AT+DOWNLOAD={sid}"
        if start_file is not None:
            command += f":{chunk_name(start_file)}"
        return _data(await self.request(command))

    async def cancel_download(self) -> None:
        await self.request("AT+CANCEL")

    async def stream_rtc(self, value: str, receiver: StreamReceiver) -> int | None:
        """Start an RTC stream: frames flow into receiver until STREAM_END.

        Returns the file-frame handler lease token. AT+STOP
        (stop_recording) ends the stream; the caller then detaches with
        ``transport.detach_file_frame_handler(token)``, which clears the
        handler slot only if this stream still owns it.
        """
        return await _stream_session(self, value, receiver)

    async def download_session(
        self,
        value: str,
        destination: str | Path,
        *,
        start_file: str | None = None,
        timeout: float = 300.0,
        progress: ProgressCallback | None = None,
    ) -> DownloadResult:
        if timeout <= 0:
            raise ValueError("timeout must be positive")
        details = await self.session_details(value)
        if start_file is not None:
            chunk_name(start_file)
        return await _download_session(
            self,
            details,
            Path(destination),
            start_file=start_file,
            timeout=timeout,
            progress=progress,
        )

    # Wi-Fi / USB / reset ---------------------------------------------------

    async def wifi(self) -> WifiAccessPoint:
        return WifiAccessPoint.from_response(await self.request("AT+WIFI?"))

    async def start_wifi(self) -> WifiAccessPoint:
        return WifiAccessPoint.from_response(await self.request("AT+WIFI=on", timeout=30.0))

    async def stop_wifi(self) -> None:
        await self.request("AT+WIFI=off")

    async def wifi_config(self) -> tuple[int, str]:
        data = _data(await self.request("AT+WIFICFG?"))
        return _required_int(data, "channel"), _required_str(data, "reg_domain")

    async def set_wifi_config(self, channel: int, country: str) -> tuple[int, str]:
        if isinstance(channel, bool) or not isinstance(channel, int) or not (1 <= channel <= 13 or 36 <= channel <= 165):
            raise ValueError("channel must be 1..13 or 36..165")
        if not isinstance(country, str) or len(country) != 2 or not country.isalpha():
            raise ValueError("country must be a two-letter code")
        data = _data(await self.request(f"AT+WIFICFG={channel}:{country.upper()}"))
        return _required_int(data, "channel"), _required_str(data, "reg_domain")

    async def usb_enabled(self) -> bool:
        return _required_str(_data(await self.request("AT+USB?")), "status") == "on"

    async def set_usb_enabled(self, enabled: bool) -> bool:
        data = _data(await self.request(f"AT+USB={'on' if enabled else 'off'}"))
        return _required_str(data, "status") == "on"

    async def reboot(self) -> None:
        await self.request("AT+REBOOT")

    async def enter_dfu(self) -> None:
        await self.request("AT+DFU")

    async def power_off(self, *, confirm: bool = False) -> None:
        if not confirm:
            raise ValueError("power_off requires confirm=True")
        await self.request("AT+POWEROFF")

    async def factory_reset(self, *, confirm: bool = False) -> None:
        if not confirm:
            raise ValueError("factory_reset erases settings, pairing, and recordings; pass confirm=True")
        await self.request("AT+FACTORY=confirm", timeout=60.0)


def _data(response: dict[str, Any]) -> dict[str, Any]:
    value = response.get("data", {})
    return value if isinstance(value, dict) else {}


def _required_str(data: dict[str, Any], name: str) -> str:
    value = data.get(name)
    if not isinstance(value, str):
        raise ProtocolError(f"response did not contain string {name!r}")
    return value


def _required_int(data: dict[str, Any], name: str) -> int:
    value = data.get(name)
    if isinstance(value, bool) or not isinstance(value, int):
        raise ProtocolError(f"response did not contain integer {name!r}")
    return value
