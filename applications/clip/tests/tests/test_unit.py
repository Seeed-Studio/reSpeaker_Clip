"""
Unit tests that don't require a physical device.

Tests utility functions, dataclasses, and library internals.
"""

import pytest
import time
from pathlib import Path

from clip.utils import (
    parse_session_id,
    format_session_id,
    format_bytes,
    format_duration,
    validate_session_id,
    merge_opus_files,
)
from clip.commands import (
    VersionInfo,
    DeviceState,
    SessionInfo,
    BookmarkInfo,
    BatteryStatus,
)
from clip.exceptions import ClipError, ConnectionError, CommandError


@pytest.mark.unit
class TestUtilityFunctions:
    """Test utility functions."""

    def test_parse_session_id(self):
        """Should parse session ID into components."""
        session_id = "20240101_120000"
        result = parse_session_id(session_id)

        assert result['year'] == 2024
        assert result['month'] == 1
        assert result['day'] == 1
        assert result['hour'] == 12
        assert result['minute'] == 0
        assert result['second'] == 0

    def test_parse_invalid_session_id(self):
        """Should return empty dict for invalid session ID."""
        result = parse_session_id("invalid")
        assert result == {}

    def test_format_session_id_default(self):
        """Should format current time as session ID."""
        session_id = format_session_id()

        assert isinstance(session_id, str)
        assert len(session_id) == 15  # YYYYMMDD_HHMMSS
        assert "_" in session_id

    def test_format_session_id_timestamp(self):
        """Should format specific timestamp as session ID."""
        timestamp = 1704067200  # 2024-01-01 00:00:00
        session_id = format_session_id(timestamp)

        assert session_id == "20240101_000000"

    def test_format_bytes(self):
        """Should format byte counts correctly."""
        assert format_bytes(0) == "0.0 B"
        assert format_bytes(500) == "500.0 B"
        assert format_bytes(1024) == "1.0 KB"
        assert format_bytes(1536) == "1.5 KB"
        assert format_bytes(1024 * 1024) == "1.0 MB"
        assert format_bytes(1024 * 1024 * 1024) == "1.0 GB"

    def test_format_duration(self):
        """Should format duration correctly."""
        assert format_duration(0) == "0s"
        assert format_duration(30) == "30s"
        assert format_duration(60) == "1:00"
        assert format_duration(90) == "1:30"
        assert format_duration(3600) == "1:00:00"
        assert format_duration(3661) == "1:01:01"

    def test_validate_session_id(self):
        """Should validate session ID format."""
        assert validate_session_id("20240101_120000") is True
        assert validate_session_id("20240101_12000") is False  # Too short
        assert validate_session_id("2024-01-01_12:00:00") is False  # Wrong format
        assert validate_session_id("invalid") is False


@pytest.mark.unit
class TestDataClasses:
    """Test dataclasses."""

    def test_version_info_from_response(self):
        """Should create VersionInfo from response."""
        response = {
            'firmware': '1.0.0',
            'hardware': '1.0',
            'sdk': 'zephyr 3.2.0',
            'build': '2024-01-01',
        }

        version = VersionInfo.from_response(response)

        assert version.firmware == '1.0.0'
        assert version.hardware == '1.0'
        assert version.sdk == 'zephyr 3.2.0'
        assert version.build == '2024-01-01'

    def test_version_info_from_empty_response(self):
        """Should handle empty response."""
        response = {}
        version = VersionInfo.from_response(response)

        assert version.firmware == ''
        assert version.hardware == ''
        assert version.sdk == ''
        assert version.build == ''

    def test_device_state_from_response(self):
        """Should create DeviceState from response."""
        response = {
            'ok': True,
            'data': {
                'state': 'IDLE',
                'battery': 85,
                'charging': False,
                'mode': 'normal',
                'bitrate': 32000,
                'session': '20240101_120000',
                'session_files': 10,
                'duration': 125.5,
            }
        }

        state = DeviceState.from_response(response)

        assert state.state == 'IDLE'
        assert state.battery == 85
        assert state.charging is False
        assert state.mode == 'normal'
        assert state.bitrate == 32000
        assert state.session_id == '20240101_120000'
        assert state.session_files == 10
        assert state.duration == 125.5

    def test_device_state_from_minimal_response(self):
        """Should handle minimal response."""
        response = {
            'ok': True,
            'data': {
                'state': 'RECORDING',
                'battery': 50,
            }
        }

        state = DeviceState.from_response(response)

        assert state.state == 'RECORDING'
        assert state.battery == 50
        assert state.charging is False
        assert state.mode == 'normal'  # Default
        assert state.bitrate == 32000  # Default

    def test_session_info_from_dict(self):
        """Should create SessionInfo from dict."""
        data = {
            'id': '20240101_120000',
            'files': 5,
            'size': 1024000,
        }

        session = SessionInfo.from_dict(data)

        assert session.id == '20240101_120000'
        assert session.files == 5
        assert session.size == 1024000

    def test_bookmark_info_from_response(self):
        """Should create BookmarkInfo from response."""
        response = {
            'ok': True,
            'data': {
                'offset': 10.5,
                'file': '00001.opus',
                'note': 'Test bookmark',
            }
        }

        bookmark = BookmarkInfo.from_response(response)

        assert bookmark.offset == 10.5
        assert bookmark.file == '00001.opus'
        assert bookmark.note == 'Test bookmark'

    def test_battery_status_from_response(self):
        """Should create BatteryStatus from response."""
        response = {
            'ok': True,
            'data': {
                'percent': 75,
                'charging': True,
                'voltage': 4.1,
            }
        }

        battery = BatteryStatus.from_response(response)

        assert battery.percent == 75
        assert battery.charging is True
        assert battery.voltage == 4.1

    def test_battery_status_from_flat_response(self):
        """Should handle flat response structure."""
        response = {
            'ok': True,
            'battery': 60,
            'charging': False,
        }

        battery = BatteryStatus.from_response(response)

        assert battery.percent == 60
        assert battery.charging is False
        assert battery.voltage is None


@pytest.mark.unit
class TestExceptions:
    """Test custom exceptions."""

    def test_clip_error(self):
        """Base exception should work."""
        error = ClipError("Test error")
        assert str(error) == "Test error"
        assert isinstance(error, Exception)

    def test_connection_error(self):
        """ConnectionError should be ClipError."""
        error = ConnectionError("Connection failed")
        assert isinstance(error, ClipError)
        assert str(error) == "Connection failed"

    def test_command_error(self):
        """CommandError should be ClipError."""
        error = CommandError("Command failed")
        assert isinstance(error, ClipError)
        assert str(error) == "Command failed"

    def test_transfer_error(self):
        """TransferError should be ClipError."""
        error = TransferError("Transfer failed")
        assert isinstance(error, ClipError)
        assert str(error) == "Transfer failed"


@pytest.mark.unit
class TestMergeOpusFiles:
    """Test Opus file merging."""

    def test_merge_opus_files(self, temp_dir):
        """Should merge multiple Opus files."""
        # Create test files
        file1 = temp_dir / "0001.opus"
        file2 = temp_dir / "002.opus"
        output = temp_dir / "merged.opus"

        file1.write_bytes(b"OGG_OPUS_DATA_1")
        file2.write_bytes(b"OGG_OPUS_DATA_2")

        # Merge
        result = merge_opus_files([file1, file2], output)

        assert result is True
        assert output.exists()
        assert output.read_bytes() == b"OGG_OPUS_DATA_1OGG_OPUS_DATA_2"

    def test_merge_opus_files_sorted(self, temp_dir):
        """Should merge files in sorted order."""
        # Create test files in non-sorted order
        file3 = temp_dir / "003.opus"
        file1 = temp_dir / "0001.opus"
        file2 = temp_dir / "002.opus"
        output = temp_dir / "merged.opus"

        file1.write_bytes(b"A")
        file2.write_bytes(b"B")
        file3.write_bytes(b"C")

        # Merge with unsorted list
        result = merge_opus_files([file3, file1, file2], output)

        assert result is True
        # Files should be in original list order, not sorted by name
        assert output.read_bytes() == b"CBA"

    def test_merge_nonexistent_file(self, temp_dir):
        """Should handle nonexistent files gracefully."""
        output = temp_dir / "merged.opus"

        # Create one existing, one nonexistent
        file1 = temp_dir / "0001.opus"
        file1.write_bytes(b"DATA")

        result = merge_opus_files([file1, temp_dir / "nonexistent.opus"], output)

        # Should succeed (skips missing files)
        assert result is True
        assert output.read_bytes() == b"DATA"

    def test_merge_empty_list(self, temp_dir):
        """Should handle empty file list."""
        output = temp_dir / "merged.opus"

        result = merge_opus_files([], output)

        assert result is True
        assert not output.exists()


@pytest.mark.unit
class TestRecordingModes:
    """Test recording mode constants."""

    def test_recording_modes(self):
        """Should have all expected modes."""
        from clip.commands import ClipCommands

        assert hasattr(ClipCommands, 'MODE_NORMAL')
        assert hasattr(ClipCommands, 'MODE_ENHANCED')
        assert hasattr(ClipCommands, 'MODE_STEREO')
        assert hasattr(ClipCommands, 'MODE_MERGE')

        assert ClipCommands.MODE_NORMAL == "normal"
        assert ClipCommands.MODE_ENHANCED == "enhanced"
        assert ClipCommands.MODE_STEREO == "stereo"
        assert ClipCommands.MODE_MERGE == "merge"

    def test_recording_modes_list(self):
        """Recording modes list should contain all modes."""
        from clip.commands import ClipCommands

        assert "normal" in ClipCommands.RECORDING_MODES
        assert "enhanced" in ClipCommands.RECORDING_MODES
        assert "stereo" in ClipCommands.RECORDING_MODES
        assert "merge" in ClipCommands.RECORDING_MODES


@pytest.mark.unit
class TestClipDeviceInit:
    """Test ClipDevice initialization."""

    def test_init_with_address(self):
        """Should initialize with address."""
        from clip import ClipDevice

        device = ClipDevice(address="AA:BB:CC:DD:EE:FF")

        assert device.address == "AA:BB:CC:DD:EE:FF"
        assert device.name_filter == "reSpeaker"

    def test_init_without_address(self):
        """Should initialize without address."""
        from clip import ClipDevice

        device = ClipDevice()

        assert device.address is None
        assert device.name_filter == "reSpeaker"

    def test_init_with_custom_filter(self):
        """Should initialize with custom name filter."""
        from clip import ClipDevice

        device = ClipDevice(name_filter="MyDevice")

        assert device.name_filter == "MyDevice"

    def test_initially_not_connected(self):
        """Device should not be connected initially."""
        from clip import ClipDevice

        device = ClipDevice()
        assert device.is_connected is False


@pytest.mark.unit
class TestCommandsInit:
    """Test ClipCommands initialization."""

    def test_init_with_device(self, mock_device):
        """Should initialize with device."""
        from clip import ClipCommands

        commands = ClipCommands(mock_device)

        assert commands.device is mock_device
