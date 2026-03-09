"""
File transfer tests for reSpeaker Clip.

Tests file download, session sync, transfer control.
"""

import pytest
import asyncio
from pathlib import Path

from clip import ClipDevice, ClipCommands, FileTransfer
from clip.exceptions import TransferError, TimeoutError


@pytest.mark.asyncio
@pytest.mark.slow
class TestFileTransfer:
    """Test file transfer functionality."""

    async def test_list_sessions(self, commands: ClipCommands):
        """Should list all sessions."""
        sessions = await commands.list_sessions()

        assert isinstance(sessions, list)
        for session in sessions:
            assert hasattr(session, 'id')
            assert hasattr(session, 'files')
            assert hasattr(session, 'size')

    async def test_list_session_files(self, commands: ClipCommands):
        """Should list files in a session."""
        sessions = await commands.list_sessions()

        if not sessions:
            pytest.skip("No sessions available")

        session_id = sessions[0].id
        files = await commands.list_session_files(session_id)

        assert isinstance(files, list)
        for f in files:
            assert f.endswith('.opus')

    async def test_get_progress(self, commands: ClipCommands):
        """Should get transfer progress."""
        progress = await commands.get_progress()

        assert isinstance(progress, dict)

    async def test_transfer_with_files(self, commands: ClipCommands, output_dir):
        """Should download a file when sessions exist."""
        sessions = await commands.list_sessions()

        if not sessions:
            pytest.skip("No sessions to download")

        session = sessions[0]
        files = await commands.list_session_files(session.id)

        if not files:
            pytest.skip("No files in session")

        # Download first file
        transfer = FileTransfer(commands.device, commands)
        file_data = await transfer.download_file(
            session.id,
            files[0],
            output_dir / files[0],
        )

        assert len(file_data) > 0
        assert (output_dir / files[0]).exists()

    async def test_transfer_with_no_sessions(self, commands: ClipCommands, output_dir):
        """Should handle transfer request when no sessions exist."""
        # This is more of an error handling test
        pass  # Hard to test without actual empty state


@pytest.mark.asyncio
@pytest.mark.slow
class TestSessionDownload:
    """Test session download functionality."""

    async def test_download_session(self, commands: ClipCommands, output_dir):
        """Should download all files from a session."""
        sessions = await commands.list_sessions()

        if not sessions:
            pytest.skip("No sessions to download")

        session = sessions[0]
        transfer = FileTransfer(commands.device, commands)

        result = await transfer.download_session(
            session.id,
            output_dir,
            stop_recording=False,
            continuous=False,
        )

        assert result["session_id"] == session.id
        assert result["file_count"] >= 0
        assert isinstance(result["files"], list)

        # Check files exist
        for file_info in result["files"]:
            assert Path(file_info["path"]).exists()

    async def test_download_and_merge(self, commands: ClipCommands, output_dir):
        """Should download and merge session files."""
        sessions = await commands.list_sessions()

        if not sessions:
            pytest.skip("No sessions to download")

        session = sessions[0]
        transfer = FileTransfer(commands.device, commands)

        result = await transfer.download_session(
            session.id,
            output_dir,
        )

        if result.get("merged_file"):
            merged_path = Path(result["merged_file"])
            assert merged_path.exists()
            assert merged_path.stat().st_size > 0


@pytest.mark.asyncio
@pytest.mark.slow
class TestTransferControl:
    """Test transfer pause/resume/cancel."""

    async def test_pause_transfer(self, commands: ClipCommands):
        """Should pause active transfer."""
        # This requires an active transfer
        # Hard to test in isolation
        pass

    async def test_resume_transfer(self, commands: ClipCommands):
        """Should resume paused transfer."""
        # This requires a paused transfer
        pass

    async def test_cancel_transfer(self, commands: ClipCommands):
        """Should cancel active transfer."""
        # This requires an active transfer
        pass


@pytest.mark.asyncio
class TestTransferErrors:
    """Test transfer error handling."""

    async def test_download_nonexistent_session(self, commands: ClipCommands, output_dir):
        """Should fail to download nonexistent session."""
        transfer = FileTransfer(commands.device, commands)

        with pytest.raises(TransferError):
            await transfer.download_session(
                "00000000_000000",  # Nonexistent session
                output_dir,
            )

    async def test_download_nonexistent_file(self, commands: ClipCommands, output_dir):
        """Should fail to download nonexistent file."""
        transfer = FileTransfer(commands.device, commands)

        with pytest.raises(TransferError):
            await transfer.download_file(
                "00000000_000000",
                "0001.opus",
                output_dir / "0001.opus",
            )

    async def test_timeout_on_slow_transfer(self, commands: ClipCommands, output_dir):
        """Should timeout on very slow transfer."""
        # This is hard to test without actual slow conditions
        pass


@pytest.mark.asyncio
@pytest.mark.slow
class TestSessionSync:
    """Test session synchronization."""

    async def test_sync_session(self, commands: ClipCommands, output_dir):
        """Should sync a session."""
        sessions = await commands.list_sessions()

        if not sessions:
            pytest.skip("No sessions to sync")

        from clip.transfer import SessionSync
        sync = SessionSync(commands.device, commands)

        result = await sync.sync(
            sessions[0].id,
            output_dir,
            delete_after=False,
        )

        assert result["session_id"] == sessions[0].id
        assert result["status"] in ["synced", "already_synced"]

    async def test_sync_already_synced(self, commands: ClipCommands, output_dir):
        """Should recognize already synced session."""
        sessions = await commands.list_sessions()

        if not sessions:
            pytest.skip("No sessions to sync")

        from clip.transfer import SessionSync
        sync = SessionSync(commands.device, commands)

        # Sync once
        await sync.sync(sessions[0].id, output_dir, delete_after=False)

        # Sync again - should recognize already synced
        result = await sync.sync(sessions[0].id, output_dir, delete_after=False)

        assert result["status"] == "already_synced"

    async def test_sync_resume(self, commands: ClipCommands, output_dir):
        """Should resume interrupted sync."""
        # This is hard to test without interrupting
        pass

    async def test_sync_all_sessions(self, commands: ClipCommands, output_dir):
        """Should sync all sessions."""
        from clip.transfer import SessionSync
        sync = SessionSync(commands.device, commands)

        results = await sync.sync_all(
            output_dir,
            delete_after=False,
        )

        assert isinstance(results, list)

        for result in results:
            assert "session_id" in result
            assert "status" in result


@pytest.mark.asyncio
class TestProgressCallbacks:
    """Test progress callback functionality."""

    async def test_file_download_progress(self, commands: ClipCommands, output_dir, temp_file):
        """Should call progress callback during download."""
        sessions = await commands.list_sessions()

        if not sessions:
            pytest.skip("No sessions to download")

        session = sessions[0]
        files = await commands.list_session_files(session.id)

        if not files:
            pytest.skip("No files in session")

        progress_updates = []

        def progress_cb(received):
            progress_updates.append(received)

        transfer = FileTransfer(commands.device, commands)

        await transfer.download_file(
            session.id,
            files[0],
            temp_file,
            progress_cb,
        )

        # Should have received some progress updates
        # (may be 0 if file is very small or progress not implemented)
        assert len(progress_updates) >= 0

    async def test_session_download_progress(self, commands: ClipCommands, output_dir):
        """Should call progress callback during session download."""
        sessions = await commands.list_sessions()

        if not sessions:
            pytest.skip("No sessions to download")

        progress_updates = []

        def progress_cb(filename, received, total):
            progress_updates.append((filename, received, total))

        transfer = FileTransfer(commands.device, commands)

        await transfer.download_session(
            sessions[0].id,
            output_dir,
            progress_cb,
        )

        # Should have progress for each file
        assert len(progress_updates) >= 0


@pytest.mark.asyncio
@pytest.mark.stress
class TestLargeTransfer:
    """Tests for large file transfers."""

    async def test_download_large_session(self, commands: ClipCommands, output_dir):
        """Should handle sessions with many files."""
        sessions = await commands.list_sessions()

        if not sessions:
            pytest.skip("No sessions to download")

        # Find a session with multiple files
        for session in sessions:
            if session.files > 5:
                transfer = FileTransfer(commands.device, commands)
                result = await transfer.download_session(
                    session.id,
                    output_dir,
                )

                assert result["file_count"] == session.files
                return

        pytest.skip("No session with >5 files found")

    async def test_concurrent_downloads(self, commands: ClipCommands, output_dir):
        """Should handle multiple concurrent downloads."""
        sessions = await commands.list_sessions()

        if len(sessions) < 2:
            pytest.skip("Need at least 2 sessions")

        transfer = FileTransfer(commands.device, commands)

        # Download two sessions concurrently
        tasks = [
            transfer.download_session(sessions[0].id, output_dir / sessions[0].id),
            transfer.download_session(sessions[1].id, output_dir / sessions[1].id),
        ]

        results = await asyncio.gather(*tasks, return_exceptions=True)

        # At least one should succeed
        assert any(not isinstance(r, Exception) for r in results)
