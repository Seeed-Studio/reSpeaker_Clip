"""
Recording control tests for reSpeaker Clip.

Tests recording commands: START, STOP, MARK, PAUSE, RESUME

Note: These tests account for the asynchronous nature of the audio thread.
State changes are not immediate - the audio thread runs independently and
takes time to start/stop recording.
"""

import pytest
import asyncio
import re

from clip import ClipCommands
from clip.exceptions import StateError, CommandError


@pytest.mark.asyncio
class TestRecordingControl:
    """Test recording start/stop control."""

    async def test_start_recording_normal(self, commands: ClipCommands):
        """Should start recording in normal mode."""
        # Ensure idle first
        await commands.ensure_idle()

        session_id = await commands.start_recording("normal")

        assert session_id is not None
        assert len(session_id) == 14  # Format: YYYYMMDDHHMMSS (14 digits)

        # Wait for recording to actually start (audio thread is async)
        started = await commands.wait_for_recording_to_start(timeout=5.0)
        assert started, "Recording did not start within timeout"

        # Verify state
        state = await commands.get_state()
        assert state.state == "RECORDING"

        # Cleanup
        await commands.stop_recording()
        await commands.wait_for_recording_to_stop(timeout=5.0)

    async def test_start_recording_enhanced(self, commands: ClipCommands):
        """Should start recording in enhanced mode (mono + DSP)."""
        await commands.ensure_idle()

        session_id = await commands.start_recording("enhanced")

        assert session_id is not None
        assert len(session_id) == 14

        # Wait for recording to start
        started = await commands.wait_for_recording_to_start(timeout=5.0)
        assert started

        state = await commands.get_state()
        assert state.state == "RECORDING"

        await commands.stop_recording()
        await commands.wait_for_recording_to_stop(timeout=5.0)

    async def test_stop_recording(self, commands: ClipCommands):
        """Should stop recording and return duration."""
        await commands.ensure_idle()

        # Start recording
        await commands.start_recording("normal")
        await commands.wait_for_recording_to_start(timeout=5.0)

        # Wait a bit
        await asyncio.sleep(2)

        # Stop
        result = await commands.stop_recording()

        assert "duration" in result
        assert result["duration"] >= 2  # At least 2 seconds

        # Wait for recording to actually stop (audio thread cleanup)
        stopped = await commands.wait_for_recording_to_stop(timeout=5.0)
        assert stopped, "Recording did not stop within timeout"

        # Verify state
        state = await commands.get_state()
        assert state.state == "IDLE"

    async def test_start_while_recording_fails(self, commands: ClipCommands):
        """Should fail to start if already recording."""
        await commands.ensure_idle()

        # First start
        await commands.start_recording("normal")
        await commands.wait_for_recording_to_start(timeout=5.0)

        # Second start should fail
        with pytest.raises(StateError):
            await commands.start_recording("normal")

        # Cleanup
        await commands.stop_recording()
        await commands.wait_for_recording_to_stop(timeout=5.0)


@pytest.mark.asyncio
class TestBookmarks:
    """Test bookmark functionality."""

    async def test_add_bookmark(self, commands: ClipCommands):
        """Should add bookmark during recording."""
        await commands.ensure_idle()

        # Start recording
        await commands.start_recording("normal")
        await commands.wait_for_recording_to_start(timeout=5.0)

        # Wait a bit
        await asyncio.sleep(1)

        # Add bookmark
        bookmark = await commands.add_bookmark()

        assert bookmark.offset > 0

        # Cleanup
        await commands.stop_recording()
        await commands.wait_for_recording_to_stop(timeout=5.0)

    async def test_add_multiple_bookmarks(self, commands: ClipCommands):
        """Should add multiple bookmarks."""
        await commands.ensure_idle()

        await commands.start_recording("normal")
        await commands.wait_for_recording_to_start(timeout=5.0)

        bookmarks = []
        for i in range(3):
            await asyncio.sleep(0.5)
            bm = await commands.add_bookmark()
            bookmarks.append(bm)

        assert len(bookmarks) == 3
        # Offsets should be increasing
        assert bookmarks[0].offset < bookmarks[1].offset < bookmarks[2].offset

        await commands.stop_recording()
        await commands.wait_for_recording_to_stop(timeout=5.0)

    async def test_bookmark_when_not_recording(self, commands: ClipCommands):
        """Should fail to add bookmark when not recording."""
        await commands.ensure_idle()

        with pytest.raises((StateError, CommandError)):
            await commands.add_bookmark()


@pytest.mark.asyncio
class TestStateTransitions:
    """Test state machine transitions."""

    async def test_idle_to_recording(self, commands: ClipCommands):
        """Should transition from IDLE to RECORDING."""
        await commands.ensure_idle()

        state = await commands.get_state()
        assert state.state == "IDLE"

        await commands.start_recording("normal")
        await commands.wait_for_recording_to_start(timeout=5.0)

        state = await commands.get_state()
        assert state.state == "RECORDING"

        await commands.stop_recording()
        await commands.wait_for_recording_to_stop(timeout=5.0)

    async def test_recording_to_idle(self, commands: ClipCommands):
        """Should transition from RECORDING to IDLE."""
        await commands.ensure_idle()
        await commands.start_recording("normal")
        await commands.wait_for_recording_to_start(timeout=5.0)

        await commands.stop_recording()

        # Wait for the transition to complete
        stopped = await commands.wait_for_recording_to_stop(timeout=5.0)
        assert stopped, "Did not transition to IDLE state"

        state = await commands.get_state()
        assert state.state == "IDLE"

    async def test_wait_for_state(self, commands: ClipCommands):
        """Should wait for specific state."""
        await commands.ensure_idle()

        # Start recording and wait for RECORDING state
        await commands.start_recording("normal")
        result = await commands.wait_for_state("RECORDING", timeout=5.0)
        assert result is True

        # Stop and wait for IDLE state
        await commands.stop_recording()
        result = await commands.wait_for_state("IDLE", timeout=5.0)
        assert result is True


@pytest.mark.asyncio
class TestRecordingDuration:
    """Test recording duration tracking."""

    async def test_short_recording_duration(self, commands: ClipCommands):
        """Should track short recording duration accurately."""
        await commands.ensure_idle()

        await commands.start_recording("normal")
        await commands.wait_for_recording_to_start(timeout=5.0)
        await asyncio.sleep(3)

        result = await commands.stop_recording()
        await commands.wait_for_recording_to_stop(timeout=5.0)

        # Duration should be approximately 3 seconds (allow 1s tolerance for async processing)
        assert result.get("duration", 0) >= 2.0  # At least 2 seconds

    async def test_session_id_format(self, commands: ClipCommands):
        """Should generate properly formatted session IDs."""
        await commands.ensure_idle()

        session_id = await commands.start_recording("normal")

        # Format: YYYYMMDDHHMMSS (14 digits, no underscore)
        assert re.match(r'^\d{14}$', session_id)

        await commands.stop_recording()
        await commands.wait_for_recording_to_stop(timeout=5.0)

    async def test_concurrent_session_prevention(self, commands: ClipCommands):
        """Should prevent starting multiple sessions."""
        await commands.ensure_idle()

        session1 = await commands.start_recording("normal")
        await commands.wait_for_recording_to_start(timeout=5.0)

        # Trying to start another should fail
        with pytest.raises(StateError):
            await commands.start_recording("normal")

        # Session ID should remain the same
        state = await commands.get_state()
        assert state.session_id == session1

        await commands.stop_recording()
        await commands.wait_for_recording_to_stop(timeout=5.0)
