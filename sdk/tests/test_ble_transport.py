from __future__ import annotations

import sys
from types import ModuleType, SimpleNamespace

import pytest

from clip.transports import ble as ble_transport


class FakeBLEDevice:
    def __init__(self, address: str, name: str, details: object) -> None:
        self.address = address
        self.name = name
        self.details = details


def _install_ble_device(monkeypatch: pytest.MonkeyPatch) -> None:
    bleak = ModuleType("bleak")
    bleak.__path__ = []  # type: ignore[attr-defined]
    backends = ModuleType("bleak.backends")
    backends.__path__ = []  # type: ignore[attr-defined]
    device = ModuleType("bleak.backends.device")
    device.BLEDevice = FakeBLEDevice  # type: ignore[attr-defined]
    monkeypatch.setitem(sys.modules, "bleak", bleak)
    monkeypatch.setitem(sys.modules, "bleak.backends", backends)
    monkeypatch.setitem(sys.modules, "bleak.backends.device", device)


@pytest.mark.parametrize(
    ("paired", "connected", "expected"),
    [
        (True, True, True),
        (False, True, False),
        (True, False, False),
        (False, False, False),
    ],
)
@pytest.mark.asyncio
async def test_windows_direct_device_requires_paired_and_connected(
    monkeypatch: pytest.MonkeyPatch,
    paired: bool,
    connected: bool,
    expected: bool,
) -> None:
    _install_ble_device(monkeypatch)
    monkeypatch.setattr(ble_transport.sys, "platform", "win32")

    class BluetoothConnectionStatus:
        CONNECTED = object()

    class NativeDevice:
        def __init__(self) -> None:
            self.connection_status = (
                BluetoothConnectionStatus.CONNECTED if connected else object()
            )
            self.device_information = SimpleNamespace(
                pairing=SimpleNamespace(is_paired=paired)
            )
            self.closed = False

        def close(self) -> None:
            self.closed = True

    native_device = NativeDevice()

    class BluetoothLEDevice:
        @staticmethod
        async def from_bluetooth_address_async(address: int) -> NativeDevice:
            assert address == int("AABBCCDDEEFF", 16)
            return native_device

    winrt = ModuleType("winrt")
    winrt.__path__ = []  # type: ignore[attr-defined]
    windows = ModuleType("winrt.windows")
    windows.__path__ = []  # type: ignore[attr-defined]
    devices = ModuleType("winrt.windows.devices")
    devices.__path__ = []  # type: ignore[attr-defined]
    bluetooth = ModuleType("winrt.windows.devices.bluetooth")
    bluetooth.BluetoothConnectionStatus = BluetoothConnectionStatus  # type: ignore[attr-defined]
    bluetooth.BluetoothLEDevice = BluetoothLEDevice  # type: ignore[attr-defined]
    monkeypatch.setitem(sys.modules, "winrt", winrt)
    monkeypatch.setitem(sys.modules, "winrt.windows", windows)
    monkeypatch.setitem(sys.modules, "winrt.windows.devices", devices)
    monkeypatch.setitem(sys.modules, "winrt.windows.devices.bluetooth", bluetooth)

    result = await ble_transport._windows_paired_connected_device(
        "AA:BB:CC:DD:EE:FF", "Clip"
    )

    assert (result is not None) is expected
    assert native_device.closed


@pytest.mark.parametrize(
    ("paired", "connected", "expected"),
    [
        (True, True, True),
        (False, True, False),
        (True, False, False),
        (None, True, False),
        (True, None, False),
    ],
)
@pytest.mark.asyncio
async def test_linux_direct_device_requires_paired_and_connected(
    monkeypatch: pytest.MonkeyPatch,
    paired: bool | None,
    connected: bool | None,
    expected: bool,
) -> None:
    _install_ble_device(monkeypatch)
    monkeypatch.setattr(ble_transport.sys, "platform", "linux")

    properties = {"Address": SimpleNamespace(value="AA:BB:CC:DD:EE:FF")}
    if paired is not None:
        properties["Paired"] = SimpleNamespace(value=paired)
    if connected is not None:
        properties["Connected"] = SimpleNamespace(value=connected)
    object_path = "/org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF"
    managed_objects = {
        object_path: {"org.bluez.Device1": properties},
    }

    class BusType:
        SYSTEM = object()

    class MessageBus:
        instance: "MessageBus | None" = None

        def __init__(self, *, bus_type: object) -> None:
            assert bus_type is BusType.SYSTEM
            self.disconnected = False
            MessageBus.instance = self

        async def connect(self) -> "MessageBus":
            return self

        async def introspect(self, service: str, path: str) -> object:
            assert (service, path) == ("org.bluez", "/")
            return object()

        def get_proxy_object(
            self, service: str, path: str, introspection: object
        ) -> "MessageBus":
            assert (service, path) == ("org.bluez", "/")
            return self

        def get_interface(self, interface: str) -> "MessageBus":
            assert interface == "org.freedesktop.DBus.ObjectManager"
            return self

        async def call_get_managed_objects(self) -> dict[str, object]:
            return managed_objects

        def disconnect(self) -> None:
            self.disconnected = True

    dbus_fast = ModuleType("dbus_fast")
    dbus_fast.__path__ = []  # type: ignore[attr-defined]
    dbus_fast.BusType = BusType  # type: ignore[attr-defined]
    dbus_fast_aio = ModuleType("dbus_fast.aio")
    dbus_fast_aio.MessageBus = MessageBus  # type: ignore[attr-defined]
    monkeypatch.setitem(sys.modules, "dbus_fast", dbus_fast)
    monkeypatch.setitem(sys.modules, "dbus_fast.aio", dbus_fast_aio)

    result = await ble_transport._linux_paired_connected_device(
        "aa:bb:cc:dd:ee:ff", "Clip"
    )

    assert (result is not None) is expected
    if result is not None:
        assert result.details == {"path": object_path}
    assert MessageBus.instance is not None
    assert MessageBus.instance.disconnected
