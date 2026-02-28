"""
Pytest fixtures for reSpeaker Clip tests.

This module provides shared fixtures for all test modules.
"""

import asyncio
import os
import pytest
import tempfile
from pathlib import Path
from typing import AsyncGenerator, Generator
from unittest.mock import AsyncMock, MagicMock, Mock

import sys
sys.path.insert(0, str(Path(__file__).parent.parent))

from clip import ClipDevice, ClipCommands, FileTransfer
from clip.exceptions import ConnectionError


# Device address from environment or None for auto-discovery
_DEVICE_ADDRESS = os.getenv("CLIP_DEVICE_ADDRESS")

# Check if we should skip device tests
_SKIP_DEVICE_TESTS = os.getenv("CLIP_SKIP_DEVICE_TESTS", "").lower() in ("1", "true", "yes")


def _can_connect_to_device():
    """Check if we can connect to a device."""
    if _SKIP_DEVICE_TESTS:
        return False
    return True


@pytest.fixture
def skip_if_no_device():
    """Skip test if no device is available."""
    if not _can_connect_to_device():
        pytest.skip("No device available (set CLIP_DEVICE_ADDRESS or enable device)")


# Session-scoped device - connects once at start, disconnects at end
@pytest.fixture(scope="session")
async def device_session() -> AsyncGenerator[ClipDevice, None]:
    """
    Provide a connected device for all tests (session-scoped).

    This fixture connects once at the start of the test session and
    disconnects at the end, avoiding repeated connect/disconnect cycles.
    """
    if not _can_connect_to_device():
        pytest.skip("No device available (set CLIP_DEVICE_ADDRESS to run device tests)")

    dev = ClipDevice(address=_DEVICE_ADDRESS)
    try:
        await dev.connect()
        print(f"\n[TEST] Connected to device: {dev.address}")
        yield dev
    except ConnectionError as e:
        pytest.skip(f"Cannot connect to device: {e}")
    finally:
        try:
            await dev.disconnect()
            print(f"\n[TEST] Disconnected from device")
        except Exception:
            pass


# Function-scoped device for backward compatibility
@pytest.fixture
async def device(device_session: ClipDevice) -> AsyncGenerator[ClipDevice, None]:
    """
    Function-scoped device that reuses the session connection.

    Tests can use this fixture without triggering reconnects.
    """
    yield device_session


@pytest.fixture
def mock_device():
    """Provide a mock device for unit tests."""
    mock = MagicMock(spec=ClipDevice)
    mock.is_connected = True
    mock.address = "00:11:22:33:44:55"
    mock.send_command = AsyncMock(return_value={"ok": True, "data": {}})
    mock._clear_file_state = Mock()
    return mock


@pytest.fixture
def mock_commands(mock_device):
    """Provide mock commands for unit tests."""
    mock = MagicMock(spec=ClipCommands)
    mock.device = mock_device
    mock.get_version = AsyncMock()
    mock.get_state = AsyncMock()
    mock.get_time = AsyncMock(return_value=1700000000)
    mock.set_time = AsyncMock(return_value=True)
    mock.get_bitrate = AsyncMock(return_value=32000)
    mock.set_bitrate = AsyncMock(return_value=True)
    mock.get_mode = AsyncMock(return_value="normal")
    mock.set_mode = AsyncMock(return_value=True)
    mock.get_complexity = AsyncMock(return_value=5)
    mock.set_complexity = AsyncMock(return_value=True)
    mock.get_chunk_size = AsyncMock(return_value=500)
    mock.set_chunk_size = AsyncMock(return_value=True)
    mock.ensure_idle = AsyncMock()
    mock.wait_for_recording_to_start = AsyncMock(return_value=True)
    mock.wait_for_recording_to_stop = AsyncMock(return_value=True)
    mock.wait_for_state = AsyncMock(return_value=True)
    # Session ID format: YYYYMMDDHHMMSS (14 digits, no underscore)
    mock.start_recording = AsyncMock(return_value="20240101120000")
    mock.stop_recording = AsyncMock(return_value={"duration": 5.0})
    mock.add_bookmark = AsyncMock()
    return mock


@pytest.fixture
async def commands(device: ClipDevice) -> ClipCommands:
    """
    Provide a ClipCommands instance for tests.

    Automatically ensures device is in IDLE state after each test.
    """
    cmds = ClipCommands(device)
    yield cmds

    # Cleanup: ensure device is back to IDLE state
    try:
        await cmds.ensure_idle()
    except Exception:
        # Ignore cleanup errors, device may already be disconnected
        pass


@pytest.fixture
def temp_dir() -> Generator[Path, None, None]:
    """Provide a temporary directory for file operations."""
    with tempfile.TemporaryDirectory() as tmpdir:
        yield Path(tmpdir)


@pytest.fixture
def temp_file(temp_dir: Path) -> Path:
    """Provide a path for a temporary file."""
    return temp_dir / "test_output.opus"


@pytest.fixture
def output_dir(temp_dir: Path) -> Path:
    """Provide an output directory for downloads."""
    out = temp_dir / "output"
    out.mkdir(parents=True, exist_ok=True)
    return out


class SavedState:
    """Helper to save and restore device state."""
    def __init__(self, commands: ClipCommands):
        self._commands = commands
        self._original_config = None

    async def __aenter__(self):
        # Save original configuration
        self._original_config = await self._commands.get_config_dict()
        return self

    async def __aexit__(self, *args):
        # Restore original configuration
        if self._original_config:
            await self._commands.set_config_dict(self._original_config)


@pytest.fixture
async def saved_state(commands: ClipCommands) -> SavedState:
    """
    Fixture that saves and restores device config around a test.

    Usage:
        @pytest.mark.asyncio
        async def test_something(commands, saved_state):
            async with saved_state:
                # Modify config here
                await commands.set_bitrate(64000)
            # Config is automatically restored
    """
    return SavedState(commands)


# Marks configuration
def pytest_configure(config):
    """Configure custom pytest markers."""
    config.addinivalue_line(
        "markers", "stress: mark test as stress test (long-running)"
    )
    config.addinivalue_line(
        "markers", "slow: mark test as slow (requires device interaction)"
    )
    config.addinivalue_line(
        "markers", "unit: mark test as unit test (no device required)"
    )
    config.addinivalue_line(
        "markers", "device: mark test as requiring a physical device"
    )


def pytest_collection_modifyitems(items):
    """
    Modify test collection to add skip markers for device tests.

    This allows tests to be collected even when no device is available.
    """
    for item in items:
        # Check if test uses device or commands fixture
        if "device" in item.fixturenames or "commands" in item.fixturenames:
            # Add device marker if not already marked
            if not any(mark.name == "unit" for mark in item.iter_markers()):
                if not any(mark.name == "device" for mark in item.iter_markers()):
                    item.add_marker(pytest.mark.device)
