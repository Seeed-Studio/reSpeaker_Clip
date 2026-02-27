"""
Recording control tests for reSpeaker Clip.

Tests recording commands: START, STOP, MARK, PAUSE, RESUME
"""

import pytest
import asyncio

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
        assert len(session_id) > 0
        assert "_" in session_id  # Format: YYYYMMDD_HHMMSS

        # Verify state
        state = await commands.get_state()
        assert state.state == "RECORDING"
        assert state.session_id == session_id

        # Cleanup
        await commands.stop_recording()

    async def test_start_recording_enhanced(self, commands: ClipCommands):
        """Should start recording in enhanced mode."""
        await commands.ensure_idle()

        session_id = await commands.start_recording("enhanced")

        assert session_id is not None

        state = await commands.get_state()
        assert state.state == "RECORDING"

        await commands.stop_recording()

    async def test_start_recording_stereo(self, commands: ClipCommands):
        """Should start recording in stereo mode."""
        await commands.ensure_idle()

        session_id = await commands.start_recording("stereo")

        assert session_id is not None

        state = await commands.get_state()
        assert state.state == "RECORDING"

        await commands.stop_recording()

    async def test_start_recording_merge(self, commands: ClipCommands):
        """Should start recording in merge mode."""
        await commands.ensure_idle()

        session_id = await commands.start_recording("merge")

        assert session_id is not None

        state = await commands.get_state()
        assert state.state == "RECORDING"

        await commands.stop_recording()

    async def test_stop_recording(self, commands: ClipCommands):
        """Should stop recording and return duration."""
        await commands.ensure_idle()

        # Start recording
        await commands.start_recording("normal")

        # Wait a bit
        await asyncio.sleep(2)

        # Stop
        result = await commands.stop_recording()

        assert "duration" in result
        assert result["duration"] >= 2  # At least 2 seconds

        # Verify state
        state = await commands.get_state()
        assert state.state == "IDLE"

    async def test_start_while_recording_fails(self, commands: ClipCommands):
        """Should fail to start if already recording."""
        await commands.ensure_idle()

        # First start
        await commands.start_recording("normal")

        # Second start should fail
        with pytest.raises(StateError):
            await commands.start_recording("normal")

        # Cleanup
        await commands.stop_recording()


@pytest.mark.asyncio
class TestBookmarks:
    """Test bookmark functionality."""

    async def test_add_bookmark(self, commands: ClipCommands):
        """Should add bookmark during recording."""
        await commands.ensure_idle()

        # Start recording
        await commands.start_recording("normal")

        # Wait a bit
        await asyncio.sleep(1)

        # Add bookmark
        bookmark = await commands.add_bookmark("Test bookmark")

        assert bookmark.offset > 0
        assert len(bookmark.file) > 0
        assert bookmark.note == "Test bookmark"

        # Cleanup
        await commands.stop_recording()

    async def test_add_bookmark_without_note(self, commands: ClipCommands):
        """Should add bookmark without note."""
        await commands.ensure_idle()

        await commands.start_recording("normal")
        await asyncio.sleep(1)

        bookmark = await commands.add_bookmark()

        assert bookmark.offset > 0
        assert bookmark.note == ""

        await commands.stop_recording()

    async def test_add_multiple_bookmarks(self, commands: ClipCommands):
        """Should add multiple bookmarks."""
        await commands.ensure_idle()

        await commands.start_recording("normal")

        bookmarks = []
        for i in range(3):
            await asyncio.sleep(0.5)
            bm = await commands.add_bookmark(f"Mark {i+1}")
            bookmarks.append(bm)

        assert len(bookmarks) == 3
        # Offsets should be increasing
        assert bookmarks[0].offset < bookmarks[1].offset < bookmarks[2].offset

        await commands.stop_recording()

    async def test_bookmark_when_not_recording(self, commands: ClipCommands):
        """Should fail to add bookmark when not recording."""
        await commands.ensure_idle()

        with pytest.raises((StateError, CommandError)):
            await commands.add_bookmark("Test")


@pytest.mark.asyncio
class TestPauseResume:
    """Test pause/resume functionality."""

    async def test_pause_recording(self, commands: ClipCommands):
        """Should pause recording."""
        await commands.ensure_idle()

        await commands.start_recording("normal")
        await asyncio.sleep(1)

        result = await commands.pause_recording()
        assert result is True

        state = await commands.get_state()
        assert state.state == "PAUSED"

        # Cleanup
        await commands.stop_recording()

    async def test_resume_recording(self, commands: ClipCommands):
        """Should resume paused recording."""
        await commands.ensure_idle()

        await commands.start_recording("normal")
        await asyncio.sleep(1)

        await commands.pause_recording()

        await asyncio.sleep(0.5)
        await commands.resume_recording()

        state = await commands.get_state()
        assert state.state == "RECORDING"

        await commands.stop_recording()

    async def test_pause_resume_cycle(self, commands: ClipCommands):
        """Should handle multiple pause/resume cycles."""
        await commands.ensure_idle()

        await commands.start_recording("normal")

        for _ in range(3):
            await asyncio.sleep(0.5)
            await commands.pause_recording()

            state = await commands.get_state()
            assert state.state == "PAUSED"

            await asyncio.sleep(0.3)
            await commands.resume_recording()

            state = await commands.get_state()
            assert state.state == "RECORDING"

        await commands.stop_recording()


@pytest.mark.asyncio
class TestStateTransitions:
    """Test state machine transitions."""

    async def test_idle_to_recording(self, commands: ClipCommands):
        """Should transition from IDLE to RECORDING."""
        await commands.ensure_idle()

        state = await commands.get_state()
        assert state.state == "IDLE"

        await commands.start_recording("normal")

        state = await commands.get_state()
        assert state.state == "RECORDING"

        await commands.stop_recording()

    async def test_recording_to_idle(self, commands: ClipCommands):
        """Should transition from RECORDING to IDLE."""
        await commands.ensure_idle()
        await commands.start_recording("normal")

        await commands.stop_recording()

        state = await commands.get_state()
        assert state.state == "IDLE"

    async def test_recording_to_paused_to_recording(self, commands: ClipCommands):
        """Should transition RECORDING -> PAUSED -> RECORDING."""
        await commands.ensure_idle()
        await commands.start_recording("normal")

        await commands.pause_recording()
        state = await commands.get_state()
        assert state.state == "PAUSED"

        await commands.resume_recording()
        state = await commands.get_state()
        assert state.state == "RECORDING"

        await commands.stop_recording()

    async def test_wait_for_state(self, commands: ClipCommands):
        """Should wait for specific state."""
        await commands.ensure_idle()

        # Start recording in background
        asyncio.create_task(commands.start_recording("normal"))

        # Wait for recording state
        result = await commands.wait_for_state("RECORDING", timeout=5.0)
        assert result is True

        # Wait for idle (after stop)
        stop_task = asyncio.create_task(commands.stop_recording())
        result = await commands.wait_for_state("IDLE", timeout=5.0)
        assert result is True

        await stop_task


@pytest.mark.asyncio
class TestRecordingDuration:
    """Test recording duration tracking."""

    async def test_short_recording_duration(self, commands: ClipCommands):
        """Should track short recording duration accurately."""
        await commands.ensure_idle()

        await commands.start_recording("normal")
        await asyncio.sleep(3)

        result = await commands.stop_recording()

        # Duration should be approximately 3 seconds (allow 0.5s tolerance)
        assert 2.5 <= result["duration"] <= 4.0

    async def test_session_id_format(self, commands: ClipCommands):
        """Should generate properly formatted session IDs."""
        await commands.ensure_idle()

        session_id = await commands.start_recording("normal")

        # Format: YYYYMMDD_HHMMSS
        import re
        assert re.match(r'^\d{8}_\d{6}$', session_id)

        await commands.stop_recording()

    async def test_concurrent_session_prevention(self, commands: ClipCommands):
        """Should prevent starting multiple sessions."""
        await commands.ensure_idle()

        session1 = await commands.start_recording("normal")

        # Trying to start another should fail
        with pytest.raises(StateError):
            await commands.start_recording("normal")

        # Session ID should remain the same
        state = await commands.get_state()
        assert state.session_id == session1

        await commands.stop_recording()
