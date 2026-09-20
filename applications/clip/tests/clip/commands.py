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
    """Battery status information (AT+BATT)."""
    percent: int
    charging: bool
    voltage: Optional[float] = None
    voltage_mv: Optional[int] = None
    temp_c: Optional[int] = None

    @classmethod
    def from_response(cls, response: dict) -> 'BatteryStatus':
        data = response.get('data', response)
        voltage_mv = data.get('voltage')
        temp_c = data.get('temp')
        return cls(
            percent=data.get('battery', data.get('percent', 0)),
            charging=data.get('charging', False),
            voltage=(voltage_mv / 1000.0) if isinstance(voltage_mv, (int, float)) else None,
            voltage_mv=voltage_mv,
            temp_c=temp_c,
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
        retries: int = 2,
    ) -> dict:
        """Send command and check for OK response.

        Retries on timeout: BLE response notifications can be dropped under
        the real-time-sync FILE_DATA load. Most AT commands are idempotent
        (RECORD->BUSY, STOP->INVALID, queries->re-read), so retry is safe.
        """
        last_err: Optional[Exception] = None
        for attempt in range(retries + 1):
            try:
                response = await self.device.send_command(command, timeout)
                if not response.get('ok'):
                    raise CommandError(
                        response.get('error', 'Command failed'),
                        command=command,
                    )
                return response
            except TimeoutError as e:
                last_err = e
                if attempt < retries:
                    await asyncio.sleep(0.3)
        raise last_err

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
        """Stop the current recording.

        _send_and_check retries on timeout (BLE notify can be dropped under
        sync load). If the device already stopped, returns {"stopped": True}.

        Returns:
            Dict with session info, or {"stopped": True}.
        """
        try:
            response = await self._send_and_check("AT+STOP", timeout=5.0)
            return response.get('data', {})
        except CommandError:
            # Device reports not-recording -> a prior STOP already succeeded
            return {"stopped": True}

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

    async def list_all_sessions(self, per_page: int = 15) -> List[SessionInfo]:
        """
        List all recording sessions with automatic pagination.

        Args:
            per_page: Items per page (max 15)

        Returns:
            List of all SessionInfo objects
        """
        all_sessions = []
        page = 1

        while True:
            if page == 1 and per_page == 10:
                response = await self._send_and_check("AT+LIST")
            else:
                response = await self._send_and_check(f"AT+LIST?{page}&{per_page}")

            data = response.get('data', {})

            if isinstance(data, list):
                # Old format: no pagination, return as-is
                return [SessionInfo.from_dict(s) for s in data]

            sessions = data.get('sessions', [])
            all_sessions.extend([SessionInfo.from_dict(s) for s in sessions])

            total = data.get('total', len(all_sessions))
            if len(all_sessions) >= total or len(sessions) == 0:
                break

            page += 1
            if (page - 1) * per_page >= total:
                break

        return all_sessions

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
        response = await self._send_and_check("AT+BATT?")
        return BatteryStatus.from_response(response)

    # ==================== Transfer Control ====================

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
            'mode': await self.get_mode(),
            'auto_delete': await self.get_auto_delete(),
            'brightness': await self.get_brightness(),
        }

    async def set_config_dict(self, config: Dict[str, Any], ignore_errors: bool = True) -> None:
        """
        Set multiple configuration values.

        Args:
            config: Dict with configuration keys and values
            ignore_errors: If True, continue on individual errors (useful for restore)

        Note:
            - auto_delete: Use boolean (True/False) to enable/disable, or integer for days
            - Unknown keys (from older SDK saves) are ignored
        """
        order = ['mode', 'auto_delete', 'brightness', 'name']

        for key in order:
            if key not in config:
                continue

            value = config[key]
            try:
                if key == 'mode':
                    await self.set_mode(value)
                elif key == 'auto_delete':
                    # value can be boolean (True=7 days, False=off) or integer (days)
                    if isinstance(value, bool):
                        days = 7 if value else -1
                        await self.set_auto_delete(days)
                    else:
                        await self.set_auto_delete(int(value))
                elif key == 'brightness':
                    await self.set_brightness(value)
                elif key == 'name':
                    await self.set_device_name(value)
            except (CommandError, ValueError) as e:
                if not ignore_errors:
                    raise
                # Silently skip invalid values during restore
                # (e.g., bitrate out of range for current mode)
                pass

    # ==================== Device Info ====================

    async def get_device_name(self) -> str:
        """
        Get BLE device name.

        Returns:
            Device name string
        """
        response = await self._send_and_check("AT+DEVICE?")
        return response.get('device', response.get('name', ''))

    async def set_device_name(self, name: str) -> bool:
        """
        Set BLE device name.

        Args:
            name: New device name (max 15 chars)

        Returns:
            True if successful
        """
        await self._send_and_check(f"AT+NAME={name}")
        return True

    # ==================== Display Commands ====================

    async def get_brightness(self) -> int:
        """
        Get OLED brightness level.

        Returns:
            Brightness value (0-255)
        """
        response = await self._send_and_check("AT+BRIGHTNESS?")
        data = response.get('data', {})
        return data.get('value', response.get('value', 128))

    async def set_brightness(self, brightness: int) -> bool:
        """
        Set OLED brightness.

        Args:
            brightness: Brightness value (0-255)

        Returns:
            True if successful
        """
        if not 0 <= brightness <= 255:
            raise ValueError("Brightness must be 0-255")
        await self._send_and_check(f"AT+BRIGHTNESS={brightness}")
        return True

    # ==================== WiFi Commands ====================

    async def wifi_on(self) -> bool:
        """
        Enable WiFi AP mode.

        Returns:
            True if successful
        """
        await self._send_and_check("AT+WIFI=on")
        return True

    async def wifi_off(self) -> bool:
        """
        Disable WiFi AP mode.

        Returns:
            True if successful
        """
        await self._send_and_check("AT+WIFI=off")
        return True

    async def get_wifi_status(self) -> Dict[str, Any]:
        """
        Get WiFi status.

        Returns:
            Dict with WiFi status information
        """
        response = await self._send_and_check("AT+WIFI?")
        data = response.get('data', {})
        return {
            'running': data.get('running', data.get('status') == 'on'),
            'ssid': data.get('ssid', ''),
            'clients': data.get('clients', 0),
        }

    async def get_wifi_config(self) -> Dict[str, Any]:
        """
        Get the stored WiFi AP channel and regulatory domain (AT+WIFICFG?).

        Returns:
            Dict with 'channel' (int) and 'reg_domain' (2-letter country code)
        """
        response = await self._send_and_check("AT+WIFICFG?")
        data = response.get('data', {})
        return {
            'channel': data.get('channel', 0),
            'reg_domain': data.get('reg_domain', ''),
        }

    async def set_wifi_config(self, channel: int, reg_domain: str) -> bool:
        """
        Set the WiFi AP channel and regulatory domain (AT+WIFICFG=<ch>:<CC>).

        Persisted immediately; applied on the next WiFi start (turn the AP
        off/on to take effect).

        Args:
            channel: 1-13 (2.4 GHz) or 36-165 (5 GHz)
            reg_domain: 2-letter country code, e.g. "US", "CN"

        Returns:
            True on success
        """
        if not ((1 <= channel <= 13) or (36 <= channel <= 165)):
            raise ValueError(f"invalid channel {channel}: 1-13 (2.4G) or 36-165 (5G)")
        reg_domain = reg_domain.upper()
        if len(reg_domain) != 2 or not reg_domain.isalpha():
            raise ValueError(f"invalid reg_domain {reg_domain!r}: 2-letter country code")
        await self._send_and_check(f"AT+WIFICFG={channel}:{reg_domain}")
        return True

    # ==================== System / Power / Maintenance ====================

    async def power_off(self) -> None:
        """Power the device off (AT+POWEROFF). The BLE link drops."""
        await self._send_and_check("AT+POWEROFF")

    async def enter_dfu(self) -> None:
        """Reboot into MCUboot serial-recovery / DFU mode (AT+DFU).

        The BLE link drops; the device re-enumerates on USB with PID 0x8069.
        """
        await self._send_and_check("AT+DFU")

    async def factory_reset(self) -> bool:
        """Factory reset (AT+FACTORY=confirm).

        Clears app config, formats the SD card (all recordings), clears BLE
        bonds, then reboots. A failed SD format is reported by the firmware
        in the response message.
        """
        response = await self._send_and_check("AT+FACTORY=confirm")
        return bool(response.get('ok', False))

    async def pair_reset(self) -> bool:
        """Clear BLE bonds and the SD card (AT+PAIR=reset), then reboot."""
        response = await self._send_and_check("AT+PAIR=reset")
        return bool(response.get('ok', False))

    async def get_storage_info(self) -> Dict[str, Any]:
        """SD storage statistics (AT+STORAGE?).

        Returns dict with mounted, total_mb, free_mb, used_mb, used_pct,
        recorded_mb. Values are live when mounted, last-known (cached) while
        the idle power-gate has the card unmounted.
        """
        response = await self._send_and_check("AT+STORAGE?")
        return response.get('data', {})

    async def get_log_level(self) -> str:
        """SD log backend level (AT+LOG?) -> 'off' | 'info' | 'debug'."""
        response = await self._send_and_check("AT+LOG?")
        return response.get('data', {}).get('log', 'off')

    async def set_log_level(self, mode: str) -> bool:
        """Set SD log backend level (AT+LOG=off|info|debug)."""
        mode = mode.lower()
        if mode not in ('off', 'info', 'debug'):
            raise ValueError(f"invalid log mode {mode!r}: off, info or debug")
        await self._send_and_check(f"AT+LOG={mode}")
        return True

    async def get_user_name(self) -> str:
        """User-defined device name (AT+NAME?), '' if unset."""
        response = await self._send_and_check("AT+NAME?")
        return response.get('data', {}).get('name', '')

    # ==================== USB Commands ====================

    async def usb_on(self) -> bool:
        """
        Enable USB CDC (serial) + MSC (SD card reader).

        Returns:
            True if successful
        """
        await self._send_and_check("AT+USB=on")
        return True

    async def usb_off(self) -> bool:
        """
        Disable USB CDC + MSC.

        Returns:
            True if successful
        """
        await self._send_and_check("AT+USB=off")
        return True

    async def get_usb_status(self) -> bool:
        """
        Get USB status.

        Returns:
            True if USB is enabled
        """
        response = await self._send_and_check("AT+USB?")
        data = response.get('data', {})
        status = data.get('status', response.get('value', 'off'))
        return status == 'on'
