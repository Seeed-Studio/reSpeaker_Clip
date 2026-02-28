"""
File transfer handling for reSpeaker Clip device.

Provides high-level file download and session sync functionality.
"""

import asyncio
import json
import time
from pathlib import Path
from typing import Optional, Callable, Dict, List, Any

from .client import ClipDevice
from .commands import ClipCommands
from .exceptions import TransferError, TimeoutError, StateError


class FileTransfer:
    """
    Handle file transfer operations for reSpeaker Clip.

    Provides methods for downloading individual files and syncing sessions.

    Example:
        >>> async with ClipDevice() as device:
        ...     transfer = FileTransfer(device)
        ...     await transfer.download_session("20240101_120000", Path("./downloads"))
    """

    def __init__(self, device: ClipDevice, commands: Optional[ClipCommands] = None):
        """
        Initialize file transfer handler.

        Args:
            device: Connected ClipDevice instance
            commands: Optional ClipCommands instance (will create if None)
        """
        self.device = device
        self.commands = commands or ClipCommands(device)
        self._canceled = False

    async def download_file(
        self,
        session_id: str,
        filename: str,
        output_path: Optional[Path] = None,
        progress_callback: Optional[Callable[[int], None]] = None,
        timeout: float = 60.0,
    ) -> bytes:
        """
        Download a single file from a session.

        Args:
            session_id: Session ID
            filename: Filename to download
            output_path: Optional path to save file
            progress_callback: Optional callback with byte count
            timeout: Transfer timeout in seconds

        Returns:
            Downloaded file data

        Raises:
            TransferError: If download fails
        """
        file_path = f"{session_id}/{filename}"
        return await self._download_legacy(
            file_path,
            output_path,
            progress_callback,
            timeout,
        )

    async def _download_legacy(
        self,
        path: str,
        output_path: Optional[Path],
        progress_callback: Optional[Callable[[int], None]],
        timeout: float,
    ) -> bytes:
        """Download using legacy single-file mode."""
        self.device._clear_file_state()
        self._canceled = False

        # Start download
        response = await self.device.send_command(f"AT+DOWNLOAD={path}")
        if not response.get("ok"):
            raise TransferError(response.get("error", "Failed to start download"))

        # Wait for transfer
        start_time = time.time()
        last_size = 0
        total_received = 0

        while time.time() - start_time < timeout:
            await asyncio.sleep(0.1)

            # Check for completion
            if self.device._last_response:
                try:
                    notif = self.device._last_response
                    # Check for done notification in response
                    import json
                    try:
                        parsed = json.loads(notif)
                        if parsed.get("done"):
                            break
                    except json.JSONDecodeError:
                        pass
                except Exception:
                    pass

            # Check for cancellation
            if self._canceled:
                raise TransferError("Transfer canceled")

            # Track progress
            current_size = len(self.device._file_data_buffer)
            if current_size > last_size:
                new_bytes = current_size - last_size
                total_received += new_bytes
                last_size = current_size
                start_time = time.time()  # Reset timeout

                if progress_callback:
                    progress_callback(total_received)

        if time.time() - start_time >= timeout:
            raise TimeoutError("File transfer timed out")

        # Get data
        data = await self.device.get_file_data()

        # Save to file if requested
        if output_path:
            output_path = Path(output_path)
            output_path.parent.mkdir(parents=True, exist_ok=True)
            output_path.write_bytes(data)

        return data

    async def download_session(
        self,
        session_id: str,
        output_dir: Path,
        progress_callback: Optional[Callable[[str, int, int], None]] = None,
        stop_recording: bool = False,
        continuous: bool = False,
        timeout: float = 300.0,
        start_file: Optional[str] = None,
    ) -> Dict[str, Any]:
        """
        Download all files from a recording session.

        Args:
            session_id: Session ID to download
            output_dir: Directory to save files
            progress_callback: Optional callback(filename, received, total)
            stop_recording: Stop recording after starting download
            continuous: Keep waiting for new files (for active recordings)
            timeout: Maximum wait time in seconds
            start_file: Optional filename to start from (e.g., "0012.opus")

        Returns:
            Dict with download results including file count and paths
        """
        output_dir = Path(output_dir)
        output_dir.mkdir(parents=True, exist_ok=True)

        # Clear state
        self.device._clear_file_state()
        self.device._downloading = True
        self.device._transfer_complete = False
        self._canceled = False

        # Get session info
        sessions = await self.commands.list_sessions()
        session_info = None
        for s in sessions:
            if s.id == session_id:
                session_info = s
                break

        # Start download
        if start_file:
            response = await self.device.send_command(f"AT+DOWNLOAD={session_id}:{start_file}")
        else:
            response = await self.device.send_command(f"AT+DOWNLOAD={session_id}")
        if not response.get("ok"):
            raise TransferError(response.get("error", "Failed to start download"))

        # Wait for download to start
        await asyncio.sleep(0.5)

        # Optionally stop recording
        if stop_recording:
            await asyncio.sleep(1.0)
            state = await self.commands.get_state()
            if state.state == "RECORDING":
                await self.commands.stop_recording()

        # Wait for files
        result = await self._wait_for_session_files(
            session_id,
            output_dir,
            progress_callback,
            continuous,
            timeout,
        )

        # Merge files
        if result["files"]:
            merged_path = output_dir / f"{session_id}.opus"
            await self._merge_opus_files(result["files"], merged_path)
            result["merged_file"] = str(merged_path)

        return result

    async def _wait_for_session_files(
        self,
        session_id: str,
        output_dir: Path,
        progress_callback: Optional[Callable[[str, int, int], None]],
        continuous: bool,
        timeout: float,
    ) -> Dict[str, Any]:
        """Wait for all session files to be received."""
        start_time = time.time()
        last_file_time = time.time()
        no_file_timeout = 30.0 if continuous else 10.0

        files_received = []

        while time.time() - start_time < timeout:
            await asyncio.sleep(0.5)

            # Check for cancellation
            if self._canceled:
                raise TransferError("Transfer canceled")

            # Check for completed files
            for filename, data in list(self.device._session_files.items()):
                if filename not in [f["name"] for f in files_received]:
                    # Save file
                    file_path = output_dir / filename

                    # Skip if already exists with same size
                    if file_path.exists():
                        existing_size = file_path.stat().st_size
                        if existing_size == len(data):
                            files_received.append({
                                "name": filename,
                                "path": str(file_path),
                                "size": len(data),
                            })
                            last_file_time = time.time()

                            if progress_callback:
                                total_size = sum(f["size"] for f in files_received)
                                progress_callback(filename, len(files_received), total_size)
                            continue

                    # File doesn't exist or size differs, write it
                    file_path.write_bytes(data)
                    files_received.append({
                        "name": filename,
                        "path": str(file_path),
                        "size": len(data),
                    })
                    last_file_time = time.time()

                    if progress_callback:
                        total_size = sum(f["size"] for f in files_received)
                        progress_callback(filename, len(files_received), total_size)

            # Check if transfer is complete (check device flag, not FileTransfer flag)
            if self.device._transfer_complete:
                # Before breaking, check one more time for any pending files
                for filename, data in list(self.device._session_files.items()):
                    if filename not in [f["name"] for f in files_received]:
                        # Save file
                        file_path = output_dir / filename

                        # Skip if already exists with same size
                        if file_path.exists():
                            existing_size = file_path.stat().st_size
                            if existing_size == len(data):
                                files_received.append({
                                    "name": filename,
                                    "path": str(file_path),
                                    "size": len(data),
                                })
                                last_file_time = time.time()

                                if progress_callback:
                                    total_size = sum(f["size"] for f in files_received)
                                    progress_callback(filename, len(files_received), total_size)
                                continue

                        # File doesn't exist or size differs, write it
                        file_path.write_bytes(data)
                        files_received.append({
                            "name": filename,
                            "path": str(file_path),
                            "size": len(data),
                        })
                        last_file_time = time.time()

                        if progress_callback:
                            total_size = sum(f["size"] for f in files_received)
                            progress_callback(filename, len(files_received), total_size)
                break

            # Exit conditions
            if not continuous:
                if time.time() - last_file_time > no_file_timeout:
                    break
            else:
                # Continuous mode: wait longer for new files
                if time.time() - last_file_time > no_file_timeout:
                    break

        # Final check for any remaining files before returning
        for filename, data in list(self.device._session_files.items()):
            if filename not in [f["name"] for f in files_received]:
                # Save file
                file_path = output_dir / filename

                # Skip if already exists with same size
                if file_path.exists():
                    existing_size = file_path.stat().st_size
                    if existing_size == len(data):
                        files_received.append({
                            "name": filename,
                            "path": str(file_path),
                            "size": len(data),
                        })
                        continue

                # File doesn't exist or size differs, write it
                file_path.write_bytes(data)
                files_received.append({
                    "name": filename,
                    "path": str(file_path),
                    "size": len(data),
                })

        # Fetch bookmarks after all files are downloaded and save as JSON
        bookmarks = []
        bookmarks_path = output_dir / "bookmarks.json"
        try:
            bookmarks = await self.commands.get_bookmarks(session_id)
        except Exception as e:
            # Don't fail sync if bookmarks fetch fails
            pass

        # Always create bookmarks.json (empty if no bookmarks)
        # Simplified format: only offset and note
        bookmarks_data = [
            {"offset": b.offset, "note": b.note}
            for b in bookmarks
        ]
        bookmarks_path.write_text(json.dumps(bookmarks_data, indent=2))

        return {
            "session_id": session_id,
            "files": files_received,
            "total_size": sum(f["size"] for f in files_received),
            "file_count": len(files_received),
            "bookmarks": bookmarks,
            "bookmarks_path": str(bookmarks_path),
        }

    async def _merge_opus_files(self, files: List[Dict], output_path: Path) -> None:
        """
        Merge Opus files into single file.

        Args:
            files: List of file dicts with 'path' key
            output_path: Output file path
        """
        # Sort by filename (should be 001.opus, 002.opus, etc.)
        sorted_files = sorted(files, key=lambda f: f["name"])

        with open(output_path, "wb") as outfile:
            for file_info in sorted_files:
                file_path = Path(file_info["path"])
                if file_path.exists():
                    outfile.write(file_path.read_bytes())

    async def cancel(self) -> None:
        """Cancel the current transfer."""
        self._canceled = True
        try:
            await self.commands.cancel_transfer()
        except Exception:
            pass


class SessionSync(FileTransfer):
    """
    Enhanced session synchronization with resume support.

    Provides intelligent sync that:
    - Detects existing local files
    - Resumes from last downloaded file
    - Deletes sessions from device after successful sync
    - Shows progress with optional tqdm integration

    Example:
        >>> async with ClipDevice() as device:
        ...     sync = SessionSync(device)
        ...     await sync.sync("20240101_120000", Path("./downloads"))
    """

    def __init__(self, device: ClipDevice, commands: Optional[ClipCommands] = None):
        super().__init__(device, commands)

    async def sync(
        self,
        session_id: str,
        output_dir: Path,
        delete_after: bool = True,
        continuous: bool = False,
        progress_callback: Optional[Callable[[str, int, int], None]] = None,
    ) -> Dict[str, Any]:
        """
        Sync a session with resume support.

        Args:
            session_id: Session ID to sync
            output_dir: Directory to save files
            delete_after: Delete session from device after successful sync
            continuous: Keep waiting for new files
            progress_callback: Optional callback(filename, file_count, total_size)

        Returns:
            Dict with sync results
        """
        output_dir = Path(output_dir)
        output_dir.mkdir(parents=True, exist_ok=True)

        # Check for existing files
        existing_files = sorted(output_dir.glob("*.opus"))

        # Get session info from device (includes synced_files count)
        try:
            session_info = await self.commands.get_session_info(session_id)
            total_files = session_info.files
            synced_files = session_info.synced_files
        except Exception:
            # Fallback to list_sessions if get_session_info fails
            sessions = await self.commands.list_sessions()
            session_info = None
            synced_files = 0
            for s in sessions:
                if s.id == session_id:
                    session_info = s
                    break
            if session_info:
                total_files = session_info.files
            else:
                total_files = 0

        # Determine start file based on synced_files from device
        start_file = None
        if synced_files > 0 and synced_files < total_files:
            # Start from the file after the last synced file
            next_num = synced_files + 1
            start_file = f"{next_num:04d}.opus"
        elif existing_files:
            # Fallback: check local files if device doesn't have synced info
            try:
                last_num = int(existing_files[-1].stem)
                next_num = last_num + 1
                start_file = f"{next_num:04d}.opus"
            except ValueError:
                pass

        # Check if already synced (all files exist locally)
        # Skip this check in continuous mode - always check for new files
        if not continuous and total_files > 0 and synced_files >= total_files:
            merged_path = output_dir / f"{session_id}.opus"
            result = {
                "session_id": session_id,
                "files": [{"name": f.name, "path": str(f), "size": f.stat().st_size}
                         for f in existing_files],
                "file_count": len(existing_files),
                "total_size": sum(f.stat().st_size for f in existing_files),
                "status": "already_synced",
            }
            if merged_path.exists():
                result["merged_file"] = str(merged_path)
            return result

        # Log sync info
        if start_file:
            print(f"Resuming from: {start_file} (synced: {synced_files}/{total_files})")
        else:
            print(f"Starting from beginning ({total_files} files total)")

        # Download with merge (start_file is calculated above)
        result = await self.download_session(
            session_id,
            output_dir,
            progress_callback=progress_callback,
            continuous=continuous,
            start_file=start_file,
        )

        # Delete from device if requested
        if delete_after and result["file_count"] > 0:
            try:
                await self.commands.delete_session(session_id)
            except Exception:
                pass

        return result

    async def sync_all(
        self,
        output_dir: Path,
        delete_after: bool = True,
    ) -> List[Dict[str, Any]]:
        """
        Sync all sessions from device.

        Args:
            output_dir: Base directory for downloads
            delete_after: Delete sessions after successful sync

        Returns:
            List of sync results for each session
        """
        sessions = await self.commands.list_sessions()
        results = []

        for session in sessions:
            session_dir = output_dir / session.id
            try:
                result = await self.sync(
                    session.id,
                    session_dir,
                    delete_after,
                    continuous=False,
                )
                results.append(result)
            except Exception as e:
                results.append({
                    "session_id": session.id,
                    "error": str(e),
                    "status": "failed",
                })

        return results
