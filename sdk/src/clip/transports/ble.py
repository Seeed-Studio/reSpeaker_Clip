"""BLE GATT transport for the reSpeaker Clip Nordic UART-style service."""

from __future__ import annotations

import asyncio
import sys
from typing import Any

from ..exceptions import CommandTimeoutError, ConnectionError, ProtocolError
from ..protocol import (
    AUDIO_VIS_UUID,
    COMMAND_UUID,
    FILE_DATA_UUID,
    RESPONSE_UUID,
    JsonNotificationDecoder,
)
from .base import BaseTransport


async def _windows_paired_connected_device(address: str, name: str) -> Any | None:
    """Return a bleak device for a paired, connected Windows BLE device.

    A ``BLEDevice`` avoids bleak's discovery cache when Windows already owns
    the connection.  Missing backend imports or failure to obtain the native
    device are treated as a cache miss so the caller can fall back to discovery.
    """
    if sys.platform != "win32":
        return None

    try:
        from bleak.backends.device import BLEDevice
        from winrt.windows.devices.bluetooth import (
            BluetoothConnectionStatus,
            BluetoothLEDevice,
        )
    except ImportError:
        return None

    try:
        native_device = await BluetoothLEDevice.from_bluetooth_address_async(
            int(address.replace(":", "").replace("-", ""), 16)
        )
    except Exception:
        return None
    if native_device is None:
        return None

    try:
        is_connected = native_device.connection_status == BluetoothConnectionStatus.CONNECTED
        is_paired = bool(native_device.device_information.pairing.is_paired)
        if not (is_paired and is_connected):
            return None
    finally:
        native_device.close()

    return BLEDevice(address, name, None)


async def _linux_paired_connected_device(address: str, name: str) -> Any | None:
    """Return a bleak device for a paired, connected BlueZ device.

    A bare address still relies on bleak's discovery cache, even when BlueZ
    knows the paired and connected device.  Supplying BlueZ's object path
    bypasses that cache.  Missing backend imports or D-Bus query failures are
    treated as a cache miss so the caller can fall back to discovery.
    """
    if sys.platform != "linux":
        return None

    try:
        from bleak.backends.device import BLEDevice
        from dbus_fast import BusType
        from dbus_fast.aio import MessageBus
    except ImportError:
        return None

    bus: Any | None = None
    try:
        bus = await MessageBus(bus_type=BusType.SYSTEM).connect()
        introspection = await bus.introspect("org.bluez", "/")
        bluez_proxy = bus.get_proxy_object("org.bluez", "/", introspection)
        object_manager = bluez_proxy.get_interface("org.freedesktop.DBus.ObjectManager")
        managed_objects = await object_manager.call_get_managed_objects()
    except Exception:
        return None
    finally:
        if bus is not None:
            bus.disconnect()

    normalized_address = address.upper()
    bluez_device_id = f"dev_{normalized_address.replace(':', '_')}"
    for object_path, interfaces in managed_objects.items():
        if bluez_device_id not in object_path or "org.bluez.Device1" not in interfaces:
            continue

        device_properties = interfaces["org.bluez.Device1"]
        address_property = device_properties.get("Address")
        paired_property = device_properties.get("Paired")
        connected_property = device_properties.get("Connected")
        address_matches = (
            address_property is not None
            and str(address_property.value).upper() == normalized_address
        )
        is_paired = paired_property is not None and bool(paired_property.value)
        is_connected = connected_property is not None and bool(connected_property.value)
        if address_matches and is_paired and is_connected:
            return BLEDevice(address, name, {"path": object_path})

    return None


class BleTransport(BaseTransport):
    """BLE transport using the optional `bleak` dependency.

    Commands are serialized here as well as by :class:`clip.ClipClient`.  The
    Clip protocol has no request identifier, therefore a timed-out command
    invalidates the transport until the caller reconnects; otherwise a late
    response could be incorrectly assigned to a later command.
    """

    def __init__(
        self,
        address: str | None = None,
        *,
        name: str = "Clip",
        connect_timeout: float = 15.0,
    ) -> None:
        super().__init__()
        self.address = address
        self.name = name
        self.connect_timeout = connect_timeout
        self._client: Any | None = None
        self._responses: asyncio.Queue[dict[str, Any]] = asyncio.Queue()
        self._command_lock = asyncio.Lock()
        self._decoder = JsonNotificationDecoder()
        self._connected = False
        self._desynchronized = False

    @property
    def is_connected(self) -> bool:
        return bool(self._connected and self._client is not None and self._client.is_connected)

    async def connect(self) -> None:
        if self.is_connected:
            return
        try:
            from bleak import BleakClient, BleakScanner
        except ImportError as exc:
            raise ConnectionError("BLE support requires: pip install 'respeaker-clip-sdk[ble]'") from exc

        address = self.address
        if address is None:
            device = await BleakScanner.find_device_by_filter(
                lambda candidate, _advertisement: bool(candidate.name and self.name in candidate.name),
                timeout=self.connect_timeout,
            )
            if device is None:
                raise ConnectionError(f"no BLE device with name containing {self.name!r} found")
            address = device.address
            self.address = address

        direct_device: Any | None = None
        if sys.platform == "win32":
            direct_device = await _windows_paired_connected_device(address, self.name)
        elif sys.platform == "linux":
            direct_device = await _linux_paired_connected_device(address, self.name)

        attempts: list[str] = []
        client: Any | None = None

        # A direct OS handle bypasses bleak's discovery cache when the device
        # is already paired and connected through the platform Bluetooth stack.
        if direct_device is not None:
            try:
                client = await self._open_client(BleakClient, direct_device)
            except Exception as exc:
                attempts.append(
                    f"direct OS connection failed: {self._describe_connection_error(exc)}"
                )

        # Discovery is still required when the device is advertising but is no
        # longer known to the OS, or when the direct connection attempt fails.
        if client is None:
            try:
                device = await BleakScanner.find_device_by_address(
                    address, timeout=self.connect_timeout
                )
                if device is None:
                    attempts.append(f"discovery found no device {address}")
                else:
                    client = await self._open_client(BleakClient, device)
            except Exception as exc:
                attempts.append(
                    f"BLE discovery connect failed: {self._describe_connection_error(exc)}"
                )

        if client is None:
            raise ConnectionError("; ".join(attempts) or f"BLE connection to {address} failed")

        self._client = client
        self._connected = True
        self._desynchronized = False
        self._decoder = JsonNotificationDecoder()
        self._drain_responses()

    async def _open_client(self, client_factory: Any, target: Any) -> Any:
        """Connect a bleak client and register the required notifications."""
        client = client_factory(target, timeout=self.connect_timeout)
        try:
            await client.connect()
            await client.start_notify(RESPONSE_UUID, self._on_response_notification)
            await client.start_notify(FILE_DATA_UUID, self._on_file_notification)
            # Audio visualization is intentionally not required for
            # command/file operation.  Users that need it can add a callback
            # in a later API.
        except BaseException:
            # Cancellation must clean up a partially initialized connection as
            # well as ordinary backend failures.
            try:
                if client.is_connected:
                    await client.disconnect()
            except Exception:
                pass
            raise
        return client

    @staticmethod
    def _describe_connection_error(exc: Exception) -> str:
        """Format one connection attempt for the aggregate failure message."""
        description = f"{type(exc).__name__}: {exc}" if str(exc) else type(exc).__name__
        if isinstance(exc, TimeoutError):
            description += " (device not connectable right now — is it advertising?)"
        return description

    async def disconnect(self) -> None:
        client = self._client
        self._connected = False
        self._client = None
        self._desynchronized = False
        self._drain_responses()
        if client is None:
            return
        try:
            if client.is_connected:
                for uuid in (RESPONSE_UUID, FILE_DATA_UUID):
                    try:
                        await client.stop_notify(uuid)
                    except Exception:
                        pass
                await client.disconnect()
        except Exception as exc:
            raise ConnectionError(f"BLE disconnect failed: {exc}") from exc

    async def send_command(self, command: str, *, timeout: float) -> dict[str, Any]:
        async with self._command_lock:
            if not self.is_connected:
                raise ConnectionError("BLE transport is not connected")
            if self._desynchronized:
                raise ConnectionError("a previous BLE command timed out; disconnect and reconnect before retrying")
            self._drain_responses()
            assert self._client is not None
            try:
                await self._client.write_gatt_char(COMMAND_UUID, command.encode("utf-8"), response=False)
                return await asyncio.wait_for(self._responses.get(), timeout=timeout)
            except asyncio.TimeoutError as exc:
                self._desynchronized = True
                raise CommandTimeoutError(f"no response to {command}") from exc
            except CommandTimeoutError:
                self._desynchronized = True
                raise
            except Exception as exc:
                raise ConnectionError(f"BLE command write failed: {exc}") from exc

    def _on_response_notification(self, _sender: Any, data: bytearray) -> None:
        try:
            for response in self._decoder.feed(bytes(data)):
                if "event" in response:
                    self._emit_event(response)
                else:
                    self._responses.put_nowait(response)
        except ProtocolError:
            # No request can safely continue after an undecodable response.
            self._desynchronized = True

    def _on_file_notification(self, _sender: Any, data: bytearray) -> None:
        self._emit_file_frame(bytes(data))

    def _drain_responses(self) -> None:
        while True:
            try:
                self._responses.get_nowait()
            except asyncio.QueueEmpty:
                return
