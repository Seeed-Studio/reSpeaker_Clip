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
    free_space: int = 0  # Free storage space in KB
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
            free_space=data.get('free_space', 0),
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
    synced_files: int = 0  # Number of files synced/transferred
    bookmarks: int = 0     # Number of bookmarks in session
    channels: int = 1      # Audio channels (1=mono, 2=stereo)
    sample_rate: int = 16000  # Sample rate in Hz
    mode: str = "normal"   # Recording mode: "normal" or "enhanced"

    @classmethod
    def from_dict(cls, data: dict) -> 'SessionInfo':
        return cls(
            id=data.get('id', ''),
            files=data.get('files', 0),
            size=data.get('size', 0),
            synced_files=data.get('synced', 0),
            bookmarks=data.get('bookmarks', 0),
            channels=data.get('channels', 1),
            sample_rate=data.get('sample_rate', 16000),
            mode=data.get('mode', 'normal'),
        )


@dataclass
class BookmarkInfo:
    """Bookmark information - simplified (only offset in seconds)."""
    offset: int         # Seconds from session start

    @classmethod
    def from_response(cls, response: dict) -> 'BookmarkInfo':
        data = response.get('data', {})
        return cls(
            offset=data.get('offset', 0),
        )

    @classmethod
    def from_dict(cls, data: dict) -> 'BookmarkInfo':
        return cls(
            offset=data.get('offset', 0),
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

    # Valid audio modes for AT+MODE (only these are accepted by AT+MODE)
    MODE_NORMAL = "normal"
    MODE_ENHANCED = "enhanced"

    # Additional mode aliases for AT+START (map to above)
    MODE_STEREO = "stereo"  # Alias for normal
    MODE_MERGE = "merge"    # Alias for enhanced

    # Valid modes for AT+START command
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
        Set audio mode (AT+MODE).

        Note: AT+MODE only accepts "normal" and "enhanced".
              For AT+START, you can also use "stereo" and "merge" as aliases.

        Args:
            mode: Mode (normal or enhanced)

        Returns:
            True if successful
        """
        if mode not in [self.MODE_NORMAL, self.MODE_ENHANCED]:
            raise ValueError(f"Invalid mode: {mode}. AT+MODE only accepts 'normal' or 'enhanced'")
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
        """
        Get noise suppression level.

        Returns:
            Noise suppression level in dB (0-60)
        """
        response = await self._send_and_check("AT+NOISE?")
        # Firmware returns {"ok":true,"data":{"value":N}}
        data = response.get('data', {})
        return data.get('value', response.get('value', 0))

    async def set_noise_suppression(self, level: int) -> bool:
        """
        Set noise suppression level.

        Args:
            level: Noise suppression level in dB (0-60)

        Returns:
            True if successful
        """
        await self._send_and_check(f"AT+NOISE={level}")
        return True

    # AGC (if supported)
    async def get_agc(self) -> bool:
        """
        Get AGC enabled state.

        Returns:
            True if AGC is enabled
        """
        response = await self._send_and_check("AT+AGC?")
        # Firmware returns {"ok":true,"data":{"enabled":true/false,"target":N}}
        data = response.get('data', {})
        enabled = data.get('enabled', response.get('value', False))
        # Handle string boolean from JSON
        if isinstance(enabled, str):
            return enabled.lower() == 'true'
        return bool(enabled)

    async def set_agc(self, enabled: bool, target: int = 0) -> bool:
        """
        Enable/disable AGC.

        Args:
            enabled: True to enable AGC
            target: Target level in dB (0-30, default 0)

        Returns:
            True if successful
        """
        value = "on" if enabled else "off"
        await self._send_and_check(f"AT+AGC={value},{target}")
        return True

    # Dereverb (if supported)
    async def get_dereverb(self) -> bool:
        """
        Get dereverb enabled state.

        Returns:
            True if dereverb is enabled
        """
        response = await self._send_and_check("AT+DEREVERB?")
        # Firmware returns {"ok":true,"data":{"enabled":true/false,"level":N,"decay":M}}
        data = response.get('data', {})
        enabled = data.get('enabled', response.get('value', False))
        # Handle string boolean from JSON
        if isinstance(enabled, str):
            return enabled.lower() == 'true'
        return bool(enabled)

    async def set_dereverb(self, enabled: bool, level: int = 5, decay: int = 0) -> bool:
        """
        Enable/disable dereverb.

        Args:
            enabled: True to enable dereverb
            level: Dereverb level (0-10, default 5)
            decay: Decay value (0-5, default 0)

        Returns:
            True if successful
        """
        value = "on" if enabled else "off"
        await self._send_and_check(f"AT+DEREVERB={value},{level},{decay}")
        return True

    # Auto-delete (if supported)
    async def get_auto_delete(self) -> bool:
        """
        Get auto-delete enabled state.

        Returns:
            True if auto-delete is enabled (non-negative days)
        """
        response = await self._send_and_check("AT+AUTODEL?")
        # Firmware returns {"ok":true,"data":{"value":"off"} or {"value":N}}
        data = response.get('data', {})
        value = data.get('value', response.get('value', "off"))
        # "off" means disabled, any number means enabled
        return value != "off" and int(value) >= 0

    async def set_auto_delete(self, days: int) -> bool:
        """
        Set auto-delete policy.

        Args:
            days: Number of days (0-30), or -1 to disable

        Returns:
            True if successful
        """
        if days < 0:
            await self._send_and_check("AT+AUTODEL=off")
        else:
            await self._send_and_check(f"AT+AUTODEL={days}")
        return True

    # ==================== Recording Commands ====================

    async def start_recording(self, mode: str = MODE_NORMAL) -> str:
        """
        Start a new recording session.

        Args:
            mode: Recording mode (normal, enhanced, stereo, merge)
                   Note: "stereo" is alias for "normal", "merge" is alias for "enhanced"

        Returns:
            Session ID of the new recording

        Raises:
            StateError: If device is already recording
        """
        state = await self.get_state()
        if state.state == "RECORDING":
            raise StateError("Already recording")

        # Map mode aliases to what firmware expects for AT+START
        # Firmware accepts: normal/stereo (stereo) or enhanced/mono (mono+DSP)
        mode_mapping = {
            self.MODE_STEREO: self.MODE_NORMAL,    # stereo -> normal
            self.MODE_MERGE: self.MODE_ENHANCED,   # merge -> enhanced
        }
        firmware_mode = mode_mapping.get(mode, mode)

        response = await self._send_and_check(f"AT+START={firmware_mode}")
        # Session ID might be at top level or under 'data'
        session_id = response.get('session', response.get('data', {}).get('session', ''))
        return session_id

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

    async def add_bookmark(self) -> BookmarkInfo:
        """
        Add a bookmark during recording.

        Returns:
            BookmarkInfo with offset in seconds

        Raises:
            StateError: If not recording
        """
        response = await self._send_and_check("AT+MARK")
        return BookmarkInfo.from_response(response)

    async def get_bookmarks(self, session_id: str, fetch_all: bool = True) -> List[BookmarkInfo]:
        """
        Get all bookmarks for a session.

        Args:
            session_id: Session ID (e.g., "20250227_120000")
            fetch_all: If True, fetch all bookmarks (with pagination if needed).
                      If False, only return what's in the first response.

        Returns:
            List of BookmarkInfo objects

        Raises:
            CommandError: If session not found or request fails
        """
        all_bookmarks = []
        page = 1
        per_page = 10  # Default items per page

        while True:
            # First request gets summary without query string
            if page == 1 and not fetch_all:
                response = await self._send_and_check(f"AT+MARKS={session_id}")
                data = response.get('data', {})
                # If no bookmarks array, this is just a count summary
                if 'bookmarks' not in data:
                    return []
                # If bookmarks exist but empty, return empty list
                bookmarks = data.get('bookmarks', [])
                return [BookmarkInfo.from_dict(b) for b in bookmarks]

            # Paginated request: AT+MARKS=<session_id>?<page>&<per_page>
            response = await self._send_and_check(f"AT+MARKS={session_id}?{page}&{per_page}")
            data = response.get('data', {})

            # Check if response has bookmarks array
            if 'bookmarks' in data:
                bookmarks = data.get('bookmarks', [])
                all_bookmarks.extend([BookmarkInfo.from_dict(b) for b in bookmarks])

                total = data.get('total', len(all_bookmarks))

                # Check if we got all bookmarks
                if len(all_bookmarks) >= total or len(bookmarks) == 0:
                    break

                # Next page
                page += 1

                # Safety check to prevent infinite loop
                if (page - 1) * per_page >= total:
                    break
            else:
                # No bookmarks array, return what we have
                break

        return all_bookmarks

    async def get_bookmarks_count(self, session_id: str) -> int:
        """
        Get the number of bookmarks for a session (without fetching details).

        Args:
            session_id: Session ID (e.g., "20250227_120000")

        Returns:
            Number of bookmarks

        Raises:
            CommandError: If session not found or request fails
        """
        response = await self._send_and_check(f"AT+MARKS={session_id}")
        data = response.get('data', {})
        # New API returns 'total' field instead of 'count'
        return data.get('total', 0)

    # ==================== Session Management ====================

    async def list_sessions(self, page: int = 1, per_page: int = 10) -> List[SessionInfo]:
        """
        List recording sessions with pagination.

        Args:
            page: Page number (default 1)
            per_page: Items per page (default 10, max 15)

        Returns:
            List of SessionInfo objects
        """
        if page == 1 and per_page == 10:
            # Default first page - no parameters needed
            response = await self._send_and_check("AT+LIST")
        else:
            # Paginated request
            response = await self._send_and_check(f"AT+LIST?{page}&{per_page}")

        data = response.get('data', {})

        # Handle both old format (data is list) and new format (data is dict with 'sessions')
        if isinstance(data, list):
            # Old format: {"ok":true,"data":[{...},{...}]}
            sessions = data
        else:
            # New format: {"ok":true,"data":{"sessions":[{...},{...}]}}
            sessions = data.get('sessions', [])

        return [SessionInfo.from_dict(s) for s in sessions]

    async def get_session_info(self, session_id: str) -> 'SessionInfo':
        """
        Get detailed session information including synced files count and audio format.

        Args:
            session_id: Session ID

        Returns:
            SessionInfo with files, size, synced_files, channels, sample_rate, and mode
        """
        response = await self._send_and_check(f"AT+LIST={session_id}")
        data = response.get('data', {})
        # Create SessionInfo with synced_files and audio format
        return SessionInfo(
            id=session_id,
            files=data.get('files', 0),
            size=data.get('size', 0),
            synced_files=data.get('synced', 0),
            channels=data.get('channels', 1),
            sample_rate=data.get('sample_rate', 16000),
            mode=data.get('mode', 'normal'),
        )

    async def list_session_files(self, session_id: str) -> List[str]:
        """
        List files in a session (with pagination).

        Args:
            session_id: Session ID

        Returns:
            List of filenames (all files in session)
        """
        all_files = []
        page = 1
        per_page = 10  # Default items per page (consistent with AT+MARKS)

        while True:
            # Paginated request: AT+LIST=<session_id>?<page>&<per_page>
            response = await self._send_and_check(f"AT+LIST={session_id}?{page}&{per_page}")
            data = response.get('data', {})

            # Check if response has files array
            if 'files' in data:
                files = data.get('files', [])
                all_files.extend(files)

                total = data.get('total', len(all_files))

                # Check if we got all files
                if len(all_files) >= total or len(files) == 0:
                    break

                # Next page
                page += 1

                # Safety check to prevent infinite loop
                if (page - 1) * per_page >= total:
                    break
            else:
                # No files array, return what we have
                break

        return all_files

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

        Will attempt to stop recording if in RECORDING state.
        Handles error states by waiting and retrying.

        Note: After stopping recording, waits for audio thread to finish
        stopping before returning. This is important because the audio
        thread processes asynchronously from the main thread.

        Raises:
            StateError: If device cannot be made idle after retries
        """
        max_retries = 5
        retry_count = 0
        check_interval = 0.3  # Check every 300ms

        while retry_count < max_retries:
            try:
                state = await self.get_state()

                if state.state == "IDLE":
                    return

                if state.state == "RECORDING":
                    # Try to stop recording
                    try:
                        await self.stop_recording()
                    except CommandError:
                        # May already be stopping or in error state, continue
                        pass

                    # After stop, wait for audio thread to finish (can take 1-2 seconds)
                    await asyncio.sleep(1.0)
                    # Then poll for IDLE state
                    for _ in range(10):  # Wait up to 3 more seconds
                        await asyncio.sleep(check_interval)
                        state = await self.get_state()
                        if state.state == "IDLE":
                            return

                elif state.state == "UNKNOWN" or state.state not in ["IDLE", "RECORDING", "TRANSMITTING", "PAUSED"]:
                    # Device in unusual state, wait and retry
                    await asyncio.sleep(1.0)

                retry_count += 1

            except CommandError as e:
                # Device may be in error state, wait and retry
                retry_count += 1
                if retry_count >= max_retries:
                    raise StateError(f"Device error: {e}")
                await asyncio.sleep(1.0)

        # Final check
        try:
            state = await self.get_state()
            if state.state != "IDLE":
                raise StateError(f"Device is in {state.state} state, expected IDLE")
        except CommandError as e:
            raise StateError(f"Failed to get state: {e}")

    async def wait_for_state(
        self,
        target_state: str,
        timeout: float = 10.0,
        check_interval: float = 0.2,
    ) -> bool:
        """
        Wait for device to enter a specific state.

        Args:
            target_state: State to wait for (e.g., "IDLE", "RECORDING")
            timeout: Maximum wait time in seconds
            check_interval: How often to check state (default 0.2s)

        Returns:
            True if target state reached, False if timeout
        """
        start = time.time()
        while time.time() - start < timeout:
            try:
                state = await self.get_state()
                if state.state == target_state:
                    return True
            except CommandError:
                # Ignore errors during polling, just retry
                pass
            await asyncio.sleep(check_interval)
        return False

    async def wait_for_recording_to_start(self, timeout: float = 5.0) -> bool:
        """
        Wait for recording to actually start.

        After sending AT+START, the audio thread takes time to initialize.
        This method waits until the device reports RECORDING state.

        Args:
            timeout: Maximum wait time in seconds

        Returns:
            True if recording started, False if timeout
        """
        return await self.wait_for_state("RECORDING", timeout=timeout)

    async def wait_for_recording_to_stop(self, timeout: float = 5.0) -> bool:
        """
        Wait for recording to actually stop.

        After sending AT+STOP, the audio thread takes time to cleanup.
        This method waits until the device reports IDLE state.

        Args:
            timeout: Maximum wait time in seconds

        Returns:
            True if recording stopped, False if timeout
        """
        return await self.wait_for_state("IDLE", timeout=timeout)

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

    async def set_config_dict(self, config: Dict[str, Any], ignore_errors: bool = True) -> None:
        """
        Set multiple configuration values.

        Args:
            config: Dict with configuration keys and values
            ignore_errors: If True, continue on individual errors (useful for restore)

        Note:
            - agc: Use boolean (True/False) to enable/disable
            - dereverb: Use boolean (True/False) to enable/disable
            - auto_delete: Use boolean (True/False) to enable/disable, or integer for days
            - Mode is set FIRST before bitrate (bitrate range depends on mode)
        """
        # Order matters: set mode before bitrate (bitrate range depends on mode)
        order = ['mode', 'bitrate', 'complexity', 'chunk_size',
                 'noise_suppression', 'agc', 'dereverb', 'auto_delete']

        for key in order:
            if key not in config:
                continue

            value = config[key]
            try:
                if key == 'mode':
                    await self.set_mode(value)
                elif key == 'bitrate':
                    await self.set_bitrate(value)
                elif key == 'complexity':
                    await self.set_complexity(value)
                elif key == 'chunk_size':
                    await self.set_chunk_size(value)
                elif key == 'noise_suppression':
                    await self.set_noise_suppression(value)
                elif key == 'agc':
                    # value can be boolean or integer (for target level)
                    if isinstance(value, bool):
                        await self.set_agc(value)
                    elif isinstance(value, int):
                        await self.set_agc(True, target=value)
                    else:
                        await self.set_agc(value[0], target=value[1])
                elif key == 'dereverb':
                    # value is boolean to enable/disable
                    await self.set_dereverb(bool(value))
                elif key == 'auto_delete':
                    # value can be boolean (True=7 days, False=off) or integer (days)
                    if isinstance(value, bool):
                        days = 7 if value else -1
                        await self.set_auto_delete(days)
                    else:
                        await self.set_auto_delete(int(value))
            except (CommandError, ValueError) as e:
                if not ignore_errors:
                    raise
                # Silently skip invalid values during restore
                # (e.g., bitrate out of range for current mode)
                pass
