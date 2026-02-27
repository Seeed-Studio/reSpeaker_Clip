"""
AT Command wrappers for reSpeaker Clip device.

Provides high-level methods for all AT commands.
"""

import asyncio
import time
from typing import Optional, Literal, Dict, Any, List
from dataclasses import dataclass

from .client import ClipDevice
from .exceptions import CommandError, StateError, TimeoutError


@dataclass
class VersionInfo:
    """Device version information."""
    firmware: str
    hardware: str
    sdk: str
    build: str

    @classmethod
    def from_response(cls, response: dict) -> 'VersionInfo':
        return cls(
            firmware=response.get('firmware', ''),
            hardware=response.get('hardware', ''),
            sdk=response.get('sdk', ''),
            build=response.get('build', ''),
        )


@dataclass
class DeviceState:
    """Device state information."""
    state: str  # IDLE, RECORDING, TRANSMITTING, PAUSED, ERROR
    battery: int
    charging: bool
    mode: str
    bitrate: int
    session_id: Optional[str] = None
    session_files: int = 0
    duration: Optional[float] = None

    @classmethod
    def from_response(cls, response: dict) -> 'DeviceState':
        data = response.get('data', {})
        return cls(
            state=data.get('state', 'UNKNOWN'),
            battery=data.get('battery', 0),
            charging=data.get('charging', False),
            mode=data.get('mode', 'normal'),
            bitrate=data.get('bitrate', 32000),
            session_id=data.get('session'),
            session_files=data.get('session_files', 0),
            duration=data.get('duration'),
        )


@dataclass
class SessionInfo:
    """Recording session information."""
    id: str
    files: int
    size: int

    @classmethod
    def from_dict(cls, data: dict) -> 'SessionInfo':
        return cls(
            id=data.get('id', ''),
            files=data.get('files', 0),
            size=data.get('size', 0),
        )


@dataclass
class BookmarkInfo:
    """Bookmark information."""
    offset: float
    file: str
    note: str

    @classmethod
    def from_response(cls, response: dict) -> 'BookmarkInfo':
        data = response.get('data', {})
        return cls(
            offset=data.get('offset', 0.0),
            file=data.get('file', ''),
            note=data.get('note', ''),
        )


@dataclass
class BatteryStatus:
    """Battery status information."""
    percent: int
    charging: bool
    voltage: Optional[float] = None

    @classmethod
    def from_response(cls, response: dict) -> 'BatteryStatus':
        data = response.get('data', response)
        return cls(
            percent=data.get('percent', data.get('battery', 0)),
            charging=data.get('charging', False),
            voltage=data.get('voltage'),
        )


class ClipCommands:
    """
    High-level AT command interface for reSpeaker Clip.

    All methods raise CommandError on failure unless otherwise noted.

    Example:
        >>> async with ClipDevice() as device:
        ...     cmds = ClipCommands(device)
        ...     version = await cmds.get_version()
        ...     print(version.firmware)
    """

    # Valid audio modes
    MODE_NORMAL = "normal"
    MODE_ENHANCED = "enhanced"
    MODE_STEREO = "stereo"
    MODE_MERGE = "merge"

    # Valid modes for recording start
    RECORDING_MODES = [MODE_NORMAL, MODE_ENHANCED, MODE_STEREO, MODE_MERGE]

    def __init__(self, device: ClipDevice):
        """
        Initialize command interface.

        Args:
            device: Connected ClipDevice instance
        """
        self.device = device

    async def _send_and_check(
        self,
        command: str,
        timeout: float = 5.0,
    ) -> dict:
        """Send command and check for OK response."""
        response = await self.device.send_command(command, timeout)
        if not response.get('ok'):
            raise CommandError(
                response.get('error', 'Command failed'),
                command=command,
            )
        return response

    # ==================== Basic Commands ====================

    async def get_version(self) -> VersionInfo:
        """
        Get device version information.

        Returns:
            VersionInfo with firmware, hardware, SDK, and build versions
        """
        response = await self._send_and_check("AT+VERSION")
        return VersionInfo.from_response(response)

    async def get_state(self) -> DeviceState:
        """
        Get current device state.

        Returns:
            DeviceState with current status information
        """
        response = await self._send_and_check("AT+GSTAT")
        return DeviceState.from_response(response)

    async def get_time(self) -> int:
        """
        Get device Unix timestamp.

        Returns:
            Unix timestamp
        """
        response = await self._send_and_check("AT+TIME?")
        # Device may return 'time', 'value', or 'timestamp' field
        return response.get('time', response.get('value', response.get('timestamp', 0)))

    async def set_time(self, unix_timestamp: int) -> bool:
        """
        Set device time.

        Args:
            unix_timestamp: Unix timestamp to set

        Returns:
            True if successful
        """
        await self._send_and_check(f"AT+TIME={unix_timestamp}")
        return True

    async def get_pairing_status(self) -> Dict[str, Any]:
        """
        Get BLE pairing status.

        Returns:
            Dict with pairing status and peer address
        """
        response = await self._send_and_check("AT+PAIR?")
        return {
            'status': response.get('value'),
            'address': response.get('addr'),
        }

    async def reboot(self) -> None:
        """Reboot the device."""
        await self._send_and_check("AT+REBOOT")

    # ==================== Configuration Commands ====================

    async def get_bitrate(self) -> int:
        """
        Get current Opus bitrate.

        Returns:
            Bitrate in bps
        """
        response = await self._send_and_check("AT+BITRATE?")
        return response.get('value', 32000)

    async def set_bitrate(self, bitrate: int) -> bool:
        """
        Set Opus bitrate.

        Args:
            bitrate: Bitrate in bps (typically 16000-64000)

        Returns:
            True if successful
        """
        await self._send_and_check(f"AT+BITRATE={bitrate}")
        return True

    async def get_mode(self) -> str:
        """
        Get current audio mode.

        Returns:
            Mode string (normal, enhanced, stereo, merge)
        """
        response = await self._send_and_check("AT+MODE?")
        return response.get('value', 'normal')

    async def set_mode(self, mode: str) -> bool:
        """
        Set audio mode.

        Args:
            mode: Mode (normal, enhanced, stereo, merge)

        Returns:
            True if successful
        """
        if mode not in self.RECORDING_MODES:
            raise ValueError(f"Invalid mode: {mode}. Must be one of {self.RECORDING_MODES}")
        await self._send_and_check(f"AT+MODE={mode}")
        return True

    async def get_complexity(self) -> int:
        """
        Get Opus complexity setting.

        Returns:
            Complexity value (0-10)
        """
        response = await self._send_and_check("AT+COMPLEXITY?")
        return response.get('value', 5)

    async def set_complexity(self, complexity: int) -> bool:
        """
        Set Opus complexity.

        Args:
            complexity: Complexity value (0-10)

        Returns:
            True if successful
        """
        if not 0 <= complexity <= 10:
            raise ValueError("Complexity must be 0-10")
        await self._send_and_check(f"AT+COMPLEXITY={complexity}")
        return True

    async def get_chunk_size(self) -> int:
        """
        Get BLE transfer chunk size.

        Returns:
            Chunk size in bytes
        """
        response = await self._send_and_check("AT+CHUNKSIZE?")
        return response.get('value', 500)

    async def set_chunk_size(self, size: int) -> bool:
        """
        Set BLE transfer chunk size.

        Args:
            size: Chunk size in bytes (typically 200-1000)

        Returns:
            True if successful
        """
        await self._send_and_check(f"AT+CHUNKSIZE={size}")
        return True

    # Noise suppression (if supported)
    async def get_noise_suppression(self) -> int:
        """Get noise suppression level."""
        response = await self._send_and_check("AT+NOISE?")
        return response.get('value', 0)

    async def set_noise_suppression(self, level: int) -> bool:
        """Set noise suppression level (0-3)."""
        await self._send_and_check(f"AT+NOISE={level}")
        return True

    # AGC (if supported)
    async def get_agc(self) -> int:
        """Get AGC level."""
        response = await self._send_and_check("AT+AGC?")
        return response.get('value', 0)

    async def set_agc(self, level: int) -> bool:
        """Set AGC level (0-3)."""
        await self._send_and_check(f"AT+AGC={level}")
        return True

    # Dereverb (if supported)
    async def get_dereverb(self) -> bool:
        """Get dereverb state."""
        response = await self._send_and_check("AT+DEREVERB?")
        return response.get('value', False)

    async def set_dereverb(self, enabled: bool) -> bool:
        """Enable/disable dereverb."""
        value = 1 if enabled else 0
        await self._send_and_check(f"AT+DEREVERB={value}")
        return True

    # Auto-delete (if supported)
    async def get_auto_delete(self) -> bool:
        """Get auto-delete state."""
        response = await self._send_and_check("AT+AUTODEL?")
        return response.get('value', False)

    async def set_auto_delete(self, enabled: bool) -> bool:
        """Enable/disable auto-delete after sync."""
        value = 1 if enabled else 0
        await self._send_and_check(f"AT+AUTODEL={value}")
        return True

    # ==================== Recording Commands ====================

    async def start_recording(self, mode: str = MODE_NORMAL) -> str:
        """
        Start a new recording session.

        Args:
            mode: Recording mode (normal, enhanced, stereo, merge)

        Returns:
            Session ID of the new recording

        Raises:
            StateError: If device is already recording
        """
        state = await self.get_state()
        if state.state == "RECORDING":
            raise StateError("Already recording")

        response = await self._send_and_check(f"AT+START={mode}")
        data = response.get('data', {})
        return data.get('session', '')

    async def stop_recording(self) -> Dict[str, Any]:
        """
        Stop the current recording.

        Returns:
            Dict with session info including duration
        """
        response = await self._send_and_check("AT+STOP")
        return response.get('data', {})

    async def pause_recording(self) -> bool:
        """
        Pause the current recording.

        Returns:
            True if successful
        """
        await self._send_and_check("AT+PAUSE")
        return True

    async def resume_recording(self) -> bool:
        """
        Resume a paused recording.

        Returns:
            True if successful
        """
        await self._send_and_check("AT+RESUME")
        return True

    async def add_bookmark(self, note: str = "") -> BookmarkInfo:
        """
        Add a bookmark during recording.

        Args:
            note: Optional bookmark note/description

        Returns:
            BookmarkInfo with offset, file, and note

        Raises:
            StateError: If not recording
        """
        if note:
            response = await self._send_and_check(f"AT+MARK={note}")
        else:
            response = await self._send_and_check("AT+MARK")
        return BookmarkInfo.from_response(response)

    # ==================== Session Management ====================

    async def list_sessions(self) -> List[SessionInfo]:
        """
        List all recording sessions.

        Returns:
            List of SessionInfo objects
        """
        response = await self._send_and_check("AT+LIST")
        data = response.get('data', [])
        return [SessionInfo.from_dict(s) for s in data]

    async def list_session_files(self, session_id: str) -> List[str]:
        """
        List files in a session.

        Args:
            session_id: Session ID

        Returns:
            List of filenames
        """
        response = await self._send_and_check(f"AT+LIST={session_id}")
        return response.get('data', [])

    async def delete_session(self, session_id: str) -> bool:
        """
        Delete a recording session.

        Args:
            session_id: Session ID to delete

        Returns:
            True if successful
        """
        await self._send_and_check(f"AT+DELETE={session_id}")
        return True

    async def purge_all_sessions(self) -> bool:
        """
        Delete all recording sessions.

        Returns:
            True if successful
        """
        await self._send_and_check("AT+PURGE")
        return True

    async def format_sd_card(self) -> bool:
        """
        Format the SD card.

        Warning: This deletes all data!

        Returns:
            True if successful
        """
        await self._send_and_check("AT+FORMAT")
        return True

    # ==================== Battery Commands ====================

    async def get_battery_status(self) -> BatteryStatus:
        """
        Get battery status.

        Returns:
            BatteryStatus with percent, charging, and voltage
        """
        response = await self._send_and_check("AT+BATTERY?")
        return BatteryStatus.from_response(response)

    # ==================== Transfer Control ====================

    async def get_progress(self) -> Dict[str, Any]:
        """
        Get file transfer progress.

        Returns:
            Dict with progress information
        """
        response = await self._send_and_check("AT+PROGRESS")
        return response.get('data', {})

    async def pause_transfer(self) -> bool:
        """
        Pause current file transfer.

        Returns:
            True if successful
        """
        await self._send_and_check("AT+PAUSE")
        return True

    async def resume_transfer(self) -> bool:
        """
        Resume paused file transfer.

        Returns:
            True if successful
        """
        await self._send_and_check("AT+RESUME")
        return True

    async def cancel_transfer(self) -> bool:
        """
        Cancel current file transfer.

        Returns:
            True if successful
        """
        await self._send_and_check("AT+CANCEL")
        return True

    # ==================== Helper Methods ====================

    async def ensure_idle(self) -> None:
        """
        Ensure device is in IDLE state.

        Raises:
            StateError: If device cannot be made idle
        """
        state = await self.get_state()

        if state.state == "IDLE":
            return

        if state.state == "RECORDING":
            await self.stop_recording()
            await asyncio.sleep(0.5)

        # Check again
        state = await self.get_state()
        if state.state != "IDLE":
            raise StateError(f"Device is in {state.state} state, expected IDLE")

    async def wait_for_state(
        self,
        target_state: str,
        timeout: float = 10.0,
    ) -> bool:
        """
        Wait for device to enter a specific state.

        Args:
            target_state: State to wait for (e.g., "IDLE", "RECORDING")
            timeout: Maximum wait time in seconds

        Returns:
            True if target state reached, False if timeout
        """
        start = time.time()
        while time.time() - start < timeout:
            state = await self.get_state()
            if state.state == target_state:
                return True
            await asyncio.sleep(0.2)
        return False

    async def get_config_dict(self) -> Dict[str, Any]:
        """
        Get all device configuration as a dict.

        Returns:
            Dict with all configuration values
        """
        return {
            'bitrate': await self.get_bitrate(),
            'mode': await self.get_mode(),
            'complexity': await self.get_complexity(),
            'chunk_size': await self.get_chunk_size(),
            'noise_suppression': await self.get_noise_suppression(),
            'agc': await self.get_agc(),
            'dereverb': await self.get_dereverb(),
            'auto_delete': await self.get_auto_delete(),
        }

    async def set_config_dict(self, config: Dict[str, Any]) -> None:
        """
        Set multiple configuration values.

        Args:
            config: Dict with configuration keys and values
        """
        for key, value in config.items():
            setter_map = {
                'bitrate': self.set_bitrate,
                'mode': self.set_mode,
                'complexity': self.set_complexity,
                'chunk_size': self.set_chunk_size,
                'noise_suppression': self.set_noise_suppression,
                'agc': self.set_agc,
                'dereverb': lambda v: self.set_dereverb(bool(v)),
                'auto_delete': lambda v: self.set_auto_delete(bool(v)),
            }
            if key in setter_map:
                await setter_map[key](value)
