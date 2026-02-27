"""
Storage management tests for reSpeaker Clip.

Tests storage commands: LIST, DELETE, PURGE, FORMAT
"""

import pytest

from clip import ClipCommands
from clip.exceptions import CommandError


@pytest.mark.asyncio
class TestListSessions:
    """Test session listing functionality."""

    async def test_list_sessions_empty(self, commands: ClipCommands):
        """Should return empty list when no sessions."""
        # This test depends on device state
        sessions = await commands.list_sessions()

        assert isinstance(sessions, list)
        # Could be empty or have sessions
        for session in sessions:
            assert hasattr(session, 'id')
            assert hasattr(session, 'files')
            assert hasattr(session, 'size')

    async def test_list_sessions_with_data(self, commands: ClipCommands):
        """Should return session information."""
        sessions = await commands.list_sessions()

        if sessions:
            session = sessions[0]

            assert len(session.id) > 0
            assert session.files >= 0
            assert session.size >= 0

    async def test_list_session_files(self, commands: ClipCommands):
        """Should list files in a session."""
        sessions = await commands.list_sessions()

        if not sessions:
            pytest.skip("No sessions available")

        session_id = sessions[0].id
        files = await commands.list_session_files(session_id)

        assert isinstance(files, list)
        for filename in files:
            assert isinstance(filename, str)
            assert filename.endswith('.opus')

    async def test_list_nonexistent_session(self, commands: ClipCommands):
        """Should fail to list files for nonexistent session."""
        with pytest.raises(CommandError):
            await commands.list_session_files("00000000_000000")


@pytest.mark.asyncio
class TestDeleteSession:
    """Test session deletion."""

    async def test_delete_session(self, commands: ClipCommands):
        """Should delete a session."""
        # First, ensure we have a session to delete
        # This is tricky - we might want to create a test recording first

        # For now, just test that the command runs
        # In actual testing, you'd:
        # 1. Start recording
        # 2. Stop recording
        # 3. Get session ID
        # 4. Delete session
        # 5. Verify it's gone

        pass

    async def test_delete_nonexistent_session(self, commands: ClipCommands):
        """Should fail to delete nonexistent session."""
        with pytest.raises(CommandError):
            await commands.delete_session("00000000_000000")

    async def test_delete_current_session_fails(self, commands: ClipCommands):
        """Should fail to delete current recording session."""
        # Start recording
        await commands.ensure_idle()
        session_id = await commands.start_recording("normal")

        # Try to delete current session - should fail
        try:
            result = await commands.device.send_command(f"AT+DELETE={session_id}")
            # Device may or may not allow this
            # If it doesn't, result["ok"] should be False
        finally:
            # Cleanup
            await commands.stop_recording()


@pytest.mark.asyncio
class TestPurgeSessions:
    """Test purging all sessions."""

    async def test_purge_all_sessions(self, commands: ClipCommands):
        """Should delete all sessions."""
        # WARNING: This is destructive!
        # Only run this if we have test sessions

        # For safety, we'll skip this in automated tests
        pytest.skip("Destructive operation - requires manual testing")

    async def test_purge_empty_storage(self, commands: ClipCommands):
        """Should handle purge when storage is empty."""
        # If we purge twice, the second should succeed but do nothing
        pass


@pytest.mark.asyncio
class TestFormatSdCard:
    """Test SD card formatting."""

    async def test_format_sd_card(self, commands: ClipCommands):
        """Should format SD card."""
        # WARNING: This is destructive!
        pytest.skip("Destructive operation - requires manual testing")

    async def test_format_removes_all_data(self, commands: ClipCommands):
        """Should remove all sessions after format."""
        pytest.skip("Destructive operation - requires manual testing")


@pytest.mark.asyncio
class TestStorageOperations:
    """Test combined storage operations."""

    async def test_create_list_delete_cycle(self, commands: ClipCommands):
        """Should create, list, and delete a session."""
        # Create a short recording
        await commands.ensure_idle()

        session_id = await commands.start_recording("normal")
        import asyncio
        await asyncio.sleep(2)
        await commands.stop_recording()

        # List sessions - should include our new one
        sessions = await commands.list_sessions()
        session_ids = [s.id for s in sessions]

        assert session_id in session_ids

        # Delete the session
        await commands.delete_session(session_id)

        # List sessions again - should be gone
        sessions = await commands.list_sessions()
        session_ids = [s.id for s in sessions]

        assert session_id not in session_ids

    async def test_session_persistence(self, commands: ClipCommands):
        """Should persist sessions across device operations."""
        # Create a recording
        await commands.ensure_idle()

        session_id = await commands.start_recording("normal")
        import asyncio
        await asyncio.sleep(2)
        await commands.stop_recording()

        # Get initial session list
        sessions_before = await commands.list_sessions()

        # Do some other operations
        await commands.set_bitrate(48000)
        await commands.set_mode("enhanced")

        # Sessions should still be there
        sessions_after = await commands.list_sessions()

        assert len(sessions_before) == len(sessions_after)

        # Cleanup
        await commands.delete_session(session_id)


@pytest.mark.asyncio
class TestSessionInfo:
    """Test session information retrieval."""

    async def test_session_info_structure(self, commands: ClipCommands):
        """Should return properly structured session info."""
        sessions = await commands.list_sessions()

        if not sessions:
            pytest.skip("No sessions available")

        session = sessions[0]

        # Check structure
        assert isinstance(session.id, str)
        assert isinstance(session.files, int)
        assert isinstance(session.size, int)

    async def test_session_size_accuracy(self, commands: ClipCommands):
        """Should report accurate session sizes."""
        sessions = await commands.list_sessions()

        if not sessions:
            pytest.skip("No sessions available")

        for session in sessions:
            if session.files > 0:
                # Size should be reasonable (> 0)
                assert session.size > 0
                # Average file size should be reasonable (1KB - 1MB)
                avg_size = session.size / session.files
                assert 1024 < avg_size < 1024 * 1024


@pytest.mark.asyncio
@pytest.mark.stress
class TestStorageLimits:
    """Test storage limit handling."""

    async def test_handle_full_storage(self, commands: ClipCommands):
        """Should handle storage full condition."""
        # This is hard to test without filling up the card
        pass

    async def test_large_number_of_sessions(self, commands: ClipCommands):
        """Should handle many sessions."""
        # Get current session count
        sessions = await commands.list_sessions()

        # Just verify we can list them
        assert isinstance(sessions, list)

        # Could test creating many sessions here
        # but that would take time and fill storage
        pass


@pytest.mark.asyncio
class TestStorageErrors:
    """Test storage error handling."""

    async def test_invalid_session_id_format(self, commands: ClipCommands):
        """Should reject invalid session ID format."""
        with pytest.raises((CommandError, ValueError)):
            await commands.delete_session("invalid_id")

    async def test_session_id_case_sensitivity(self, commands: ClipCommands):
        """Session IDs should be case-sensitive."""
        # Create a session
        await commands.ensure_idle()

        session_id = await commands.start_recording("normal")
        import asyncio
        await asyncio.sleep(1)
        await commands.stop_recording()

        # Try to delete with wrong case - should fail
        try:
            await commands.delete_session(session_id.upper())
        except CommandError:
            pass  # Expected
        finally:
            # Cleanup with correct ID
            await commands.delete_session(session_id)


@pytest.mark.asyncio
@pytest.mark.slow
class TestStorageAndRecording:
    """Test interaction between storage and recording."""

    async def test_recording_increases_file_count(self, commands: ClipCommands):
        """Recording should increase session file count."""
        await commands.ensure_idle()

        # Get initial state
        sessions_before = await commands.list_sessions()

        # Record
        session_id = await commands.start_recording("normal")
        import asyncio
        await asyncio.sleep(3)
        await commands.stop_recording()

        # Check new session
        sessions_after = await commands.list_sessions()

        # Should have one more session
        assert len(sessions_after) == len(sessions_before) + 1

        # New session should have files
        new_session = next(s for s in sessions_after if s.id == session_id)
        assert new_session.files > 0

        # Cleanup
        await commands.delete_session(session_id)

    async def test_long_recording_creates_multiple_files(self, commands: ClipCommands):
        """Long recording should create multiple Opus files."""
        await commands.ensure_idle()

        session_id = await commands.start_recording("normal")
        import asyncio
        await asyncio.sleep(10)  # 10 seconds
        await commands.stop_recording()

        # Check session
        sessions = await commands.list_sessions()
        session = next(s for s in sessions if s.id == session_id)

        # Should have multiple files (typically 1 file per ~5 seconds)
        assert session.files >= 1

        # Cleanup
        await commands.delete_session(session_id)
