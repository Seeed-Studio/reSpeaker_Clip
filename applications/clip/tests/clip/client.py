"""
BLE Client for reSpeaker Clip device.

Provides low-level BLE connection management and AT command communication.

Architecture:
- Notification handler (background thread) → Queue → send_command (async)
- Properly decouples receiving and sending
"""

import asyncio
import json
import threading
from typing import Optional
from collections import deque

try:
    from bleak import BleakClient, BleakScanner
    from bleak.exc import BleakError
except ImportError:
    raise ImportError(
        "bleak is required. Install with: pip install bleak"
    )

from .exceptions import (
    ConnectionError,
    TimeoutError,
    ResponseError,
)


# BLE UUIDs
SERVICE_UUID = "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"
CMD_RECV_UUID = "6E400002-B5A3-F393-E0A9-E50E24DCCA9E"
RESP_SEND_UUID = "6E400003-B5A3-F393-E0A9-E50E24DCCA9E"
FILE_DATA_UUID = "6E400004-B5A3-F393-E0A9-E50E24DCCA9E"

# Device discovery filter
DEVICE_NAME_FILTER = "reSpeaker"

# Timeouts (seconds)
CONNECT_TIMEOUT = 10.0
COMMAND_TIMEOUT = 10.0


class ClipDevice:
    """
    BLE client for reSpeaker Clip device.

    Uses a Queue-based architecture to properly handle cross-thread
    communication between WinRT background notifications and asyncio.
    """

    def __init__(self, address: Optional[str] = None, name_filter: str = DEVICE_NAME_FILTER):
        self.address = address
        self.name_filter = name_filter
        self.client: Optional[BleakClient] = None
        self._connected = False

        # Message queue for receiving notifications
        self._response_queue: Optional[asyncio.Queue] = None

        # Buffer for assembling multi-packet responses
        self._response_buffer = bytearray()
        self._buffer_lock = threading.Lock()

        # Event loop reference for thread-safe queue puts
        self._loop = None

    async def connect(self, timeout: float = CONNECT_TIMEOUT) -> None:
        """Connect to the device."""
        if self._connected:
            return

        # Get event loop and create queue
        self._loop = asyncio.get_running_loop()
        self._response_queue = asyncio.Queue()

        if self.address is None:
            device = await BleakScanner.find_device_by_filter(
                lambda d, _: d.name and self.name_filter in d.name
            )
            if device is None:
                raise ConnectionError(f"Device '{self.name_filter}' not found")
            self.address = device.address

        self.client = BleakClient(self.address, timeout=timeout)

        try:
            await self.client.connect()
            await self.client.start_notify(RESP_SEND_UUID, self._notification_handler)
            await self.client.start_notify(FILE_DATA_UUID, self._file_data_handler)
            await asyncio.sleep(0.5)
            self._connected = True
        except BleakError as e:
            raise ConnectionError(f"Connection failed: {e}")

    async def disconnect(self) -> None:
        """Disconnect from the device."""
        if not self._connected:
            return

        if self.client and self.client.is_connected:
            await self.client.stop_notify(RESP_SEND_UUID)
            await self.client.stop_notify(FILE_DATA_UUID)
            await self.client.disconnect()

        self._connected = False
        self._loop = None
        self._response_queue = None

    async def __aenter__(self):
        await self.connect()
        return self

    async def __aexit__(self, *args):
        await self.disconnect()

    @property
    def is_connected(self) -> bool:
        return self._connected and self.client is not None and self.client.is_connected

    async def send_command(self, command: str, timeout: float = COMMAND_TIMEOUT) -> dict:
        """
        Send an AT command and wait for response.

        Uses asyncio.Queue to receive responses from the background
        notification handler, properly decoupling send and receive.
        """
        if not self.is_connected:
            raise ConnectionError("Not connected")

        if self._response_queue is None:
            raise ConnectionError("Queue not initialized - not connected?")

        # Clear buffer before sending new command
        with self._buffer_lock:
            self._response_buffer.clear()

        # Send command
        await self.client.write_gatt_char(CMD_RECV_UUID, command.encode('utf-8'))

        # Wait for response from queue (with timeout)
        try:
            response_data = await asyncio.wait_for(
                self._response_queue.get(),
                timeout=timeout
            )
        except asyncio.TimeoutError:
            raise TimeoutError(f"No response to: {command}")

        # Parse JSON
        try:
            return json.loads(response_data)
        except json.JSONDecodeError as e:
            raise ResponseError(f"Invalid JSON: {response_data}")

    def _notification_handler(self, sender, data: bytearray):
        """
        Handle notifications from response characteristic.

        Called from WinRT background thread. Puts complete responses
        into the asyncio.Queue for the main event loop to process.

        This decouples the background thread receiving notifications
        from the async tasks sending commands.
        """
        print(f"[Notification] Received {len(data)} bytes")

        with self._buffer_lock:
            self._response_buffer.extend(data)

            try:
                response_str = self._response_buffer.decode('utf-8').strip()
                print(f"[Notification] Data: {response_str}")

                # Check if we have a complete JSON response
                if response_str.endswith('}') or response_str.endswith(']'):
                    self._response_buffer.clear()
                    print(f"[Notification] Complete response, queuing to event loop")

                    # Put response in queue (thread-safe via call_soon_threadsafe)
                    if self._loop and not self._loop.is_closed() and self._response_queue:
                        self._loop.call_soon_threadsafe(
                            self._response_queue.put_nowait,
                            response_str
                        )
            except UnicodeDecodeError:
                print(f"[Notification] Unicode error, clearing buffer")
                self._response_buffer.clear()

    def _file_data_handler(self, sender, data: bytearray):
        """Handle file data during transfer."""
        # TODO: Implement file data streaming
        pass

    # Placeholder methods
    async def start_notifications(self, callback):
        pass

    def _clear_file_state(self):
        pass

    async def get_file_data(self) -> bytes:
        return b''
