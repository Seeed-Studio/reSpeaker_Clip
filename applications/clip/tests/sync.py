#!/usr/bin/env python3
"""
ReSpeaker Clip Sync Tool

Sync/Download files from the device.
- Queries device status
- If recording, gets the latest session
- Downloads all files (resumes if partially downloaded)
- Merges all files into one

Usage:
    python sync.py [--device MAC_ADDRESS] [--session SESSION_ID]
"""

import asyncio
import json
import sys
from pathlib import Path
from bleak import BleakClient, BleakScanner
from typing import Optional

# UUIDs
SERVICE_UUID = "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"
CMD_RECV_UUID = "6E400002-B5A3-F393-E0A9-E50E24DCCA9E"
RESP_SEND_UUID = "6E400003-B5A3-F393-E0A9-E50E24DCCA9E"
FILE_DATA_UUID = "6E400004-B5A3-F393-E0A9-E50E24DCCA9E"

DEVICE_NAME_FILTER = "reSpeaker"

# Download directory
DOWNLOAD_DIR = Path("downloads")


class ReSpeakerSync:
    def __init__(self, address: Optional[str] = None):
        self.address = address
        self.client: Optional[BleakClient] = None
        self.last_response = None
        self.response_buffer = bytearray()

        # File download state
        self.current_file_data = bytearray()
        self.downloading_file = False
        self.completed_files = []  # (filename, data) tuples
        self._last_filename = None
        self._last_file_size = 0
        self.session_dir = None
        self._early_data_buffer = bytearray()  # Buffer data before file_ready event

        # Progress bar support
        try:
            from tqdm import tqdm
            self.tqdm = tqdm
            self.has_tqdm = True
        except ImportError:
            self.tqdm = None
            self.has_tqdm = False
        self._progress_bar = None
        self._overall_progress = None  # Overall progress bar for all files

    async def connect(self) -> bool:
        """Connect to the device"""
        if self.address is None:
            print("Scanning...")
            device = await BleakScanner.find_device_by_filter(
                lambda d, _: d.name and DEVICE_NAME_FILTER in d.name
            )
            if not device:
                print(f"Device '{DEVICE_NAME_FILTER}' not found")
                return False
            print(f"Found: {device.name} ({device.address})")

            self.address = device.address

        self.client = BleakClient(self.address)
        print(f"Connecting to {self.address}...")

        try:
            await self.client.connect(timeout=30.0)
            print("Connected!")

            # Setup notification handlers (same as test_03_recording.py)
            await self.client.start_notify(RESP_SEND_UUID, self._notification_handler)
            await self.client.start_notify(FILE_DATA_UUID, self._file_data_handler)
            await asyncio.sleep(0.2)
            return True

        except Exception as e:
            print(f"Connection failed: {e}")
            import traceback
            traceback.print_exc()
            return False

    async def disconnect(self):
        if self.client and self.client.is_connected:
            await self.client.stop_notify(RESP_SEND_UUID)
            await self.client.stop_notify(FILE_DATA_UUID)
            await self.client.disconnect()
            print("Disconnected")

    def _notification_handler(self, sender, data):
        """Handle notifications from response characteristic"""
        self.response_buffer.extend(data)

        # Try to find and extract complete JSON objects
        # BLE notifications can be fragmented, so we need to handle partial data
        buffer_str = self.response_buffer.decode('utf-8', errors='ignore')

        # Try to parse JSON objects from buffer
        # We look for complete JSON objects (enclosed in {})
        while True:
            # Find the start of a JSON object
            start_idx = buffer_str.find('{')
            if start_idx == -1:
                # No JSON object found, clear invalid data
                self.response_buffer.clear()
                break

            # Remove any data before the first {
            if start_idx > 0:
                buffer_str = buffer_str[start_idx:]
                self.response_buffer = bytearray(buffer_str, 'utf-8')

            # Try to find the matching closing brace
            # This is a simple approach - for properly nested objects we'd need more complex parsing
            brace_count = 0
            end_idx = -1
            for i, char in enumerate(buffer_str):
                if char == '{':
                    brace_count += 1
                elif char == '}':
                    brace_count -= 1
                    if brace_count == 0:
                        end_idx = i + 1
                        break

            if end_idx == -1:
                # Incomplete JSON object, wait for more data
                break

            # Extract the complete JSON object
            json_str = buffer_str[:end_idx]

            # Try to parse it
            try:
                event_data = json.loads(json_str)
                event_type = event_data.get("event", "")

                if event_type == "file_complete":
                    filename = event_data.get("filename", "")
                    self._close_progress_bar()

                    # Combine buffered data with current data
                    if len(self._early_data_buffer) > 0:
                        self.current_file_data.extend(self._early_data_buffer)
                        self._early_data_buffer.clear()

                    # If file_ready was missed, set filename now
                    if self._last_filename is None:
                        self._last_filename = filename

                    # Save file if we have any data
                    if len(self.current_file_data) > 0:
                        # Use filename from event if we don't have one set
                        save_filename = self._last_filename if self._last_filename else filename
                        filepath = self.session_dir / save_filename

                        # Check if file already exists with same size (skip re-downloading)
                        skip_save = False
                        if filepath.exists():
                            existing_size = filepath.stat().st_size
                            if existing_size == len(self.current_file_data):
                                skip_save = True

                        if not skip_save:
                            with open(filepath, "wb") as f:
                                f.write(self.current_file_data)
                            # Only add to completed_files if not already there
                            if save_filename not in [f[0] for f in self.completed_files]:
                                self.completed_files.append((save_filename, bytes(self.current_file_data)))

                        # Update overall progress (only count newly downloaded files)
                        if self._overall_progress and not skip_save:
                            self._overall_progress.update(1)

                        # Clear for next file
                        self.current_file_data = bytearray()
                        self._last_filename = None
                    else:
                        # Still clear state for next file
                        self._last_filename = None

                elif event_type == "file_ready":
                    filename = event_data.get("filename", "")
                    size = event_data.get("size", 0)

                    if self._last_filename is None or self._last_filename == filename:
                        self._last_filename = filename
                        self._last_file_size = size
                        self._create_progress_bar(filename, size)

                        # Apply any buffered data that arrived before this event
                        if len(self._early_data_buffer) > 0:
                            self.current_file_data.extend(self._early_data_buffer)
                            self._update_progress(len(self._early_data_buffer))
                            self._early_data_buffer.clear()
                    # else: ignore duplicate file_ready for different file
                else:
                    self.last_response = json_str

            except json.JSONDecodeError:
                # Invalid JSON, store as regular response
                self.last_response = json_str

            # Remove the processed JSON object from buffer
            buffer_str = buffer_str[end_idx:]
            self.response_buffer = bytearray(buffer_str, 'utf-8')

            # If buffer is now empty or too small, we're done
            if len(buffer_str) < 2:
                self.response_buffer.clear()
                break

    def _file_data_handler(self, sender, data):
        """Handle file data during transfer"""
        if self.downloading_file:
            if self._last_filename:
                # Filename known, store data directly
                self.current_file_data.extend(data)
                self._update_progress(len(data))
            else:
                # Filename not set yet (file_ready not processed), buffer the data
                # This handles race condition where data arrives before file_ready event
                self._early_data_buffer.extend(data)

    def _create_progress_bar(self, filename, total_size):
        if not self.has_tqdm:
            return
        if self._progress_bar:
            self._progress_bar.close()
        self._progress_bar = self.tqdm(
            total=total_size,
            unit='B',
            unit_scale=True,
            unit_divisor=1024,
            desc=f"  {filename}",
            ncols=60,
            leave=False,
        )

    def _update_progress(self, chunk_size):
        if not self.has_tqdm or not self._progress_bar:
            return
        self._progress_bar.update(chunk_size)

    def _close_progress_bar(self):
        if not self.has_tqdm or not self._progress_bar:
            return
        self._progress_bar.close()
        self._progress_bar = None

    async def send_command(self, cmd: str, timeout: float = 5.0):
        """Send AT command and wait for response"""
        self.last_response = None

        await self.client.write_gatt_char(CMD_RECV_UUID, cmd.encode('utf-8'))

        for _ in range(int(timeout * 10)):
            await asyncio.sleep(0.1)
            if self.last_response:
                try:
                    return json.loads(self.last_response)
                except json.JSONDecodeError:
                    return {"ok": False, "error": "Invalid JSON"}

        return {"ok": False, "error": "Timeout"}

    async def get_status(self):
        """Get device status"""
        print("Querying device status...")
        response = await self.send_command("AT+GSTAT")

        if response.get("ok"):
            data = response["data"]
            state = data.get("state", "UNKNOWN")
            battery = data.get("battery", 0)
            mode = data.get("mode", "unknown")

            print(f"\nDevice Status:")
            print(f"  State: {state}")
            print(f"  Battery: {battery}%")
            print(f"  Mode: {mode}")

            return data
        else:
            print(f"Error: {response.get('error')}")
            return None

    async def list_sessions(self):
        """List all recording sessions"""
        print("Listing sessions...")
        response = await self.send_command("AT+LIST")

        if response.get("ok"):
            sessions = response.get("data", [])
            print(f"\nFound {len(sessions)} session(s):")
            for sess in sessions:
                print(f"  - {sess['id']}: {sess['files']} files, {sess['size']} bytes")
            return sessions
        else:
            print(f"Error: {response.get('error')}")
            return []

    async def get_latest_session(self):
        """Get the latest (most recent) session"""
        sessions = await self.list_sessions()
        if sessions:
            # Last session in list is the latest (newest)
            latest = sessions[-1]
            print(f"\nLatest session: {latest['id']}")
            return latest['id']
        return None

    async def sync_session(self, session_id: str, continuous: bool = True):
        """Sync/download all files from a session

        Args:
            session_id: Session ID to sync
            continuous: If True, keep waiting for new files (for active recordings).
                       If False, stop when no new files for 10 seconds.
        """
        session_id = str(session_id)

        # Create download directory
        self.session_dir = DOWNLOAD_DIR / session_id
        self.session_dir.mkdir(parents=True, exist_ok=True)

        # Get existing local files
        local_files = []
        if self.session_dir.exists():
            local_files = sorted([f.name for f in self.session_dir.glob("*.opus")])

        # Get session info from device to know total file count
        sessions = await self.list_sessions()
        session_info = None
        total_files = 0
        for sess in sessions:
            if sess['id'] == session_id:
                session_info = sess
                total_files = sess.get('files', 0)
                break

        if local_files:
            print(f"\nFound {len(local_files)} existing local files")
            print(f"  Local: {', '.join(local_files[:5])}{'...' if len(local_files) > 5 else ''}")

        if total_files > 0:
            print(f"  Device reports: {total_files} files in session")
            remaining = max(0, total_files - len(local_files))
            print(f"  Remaining to sync: ~{remaining} files")

        # Determine starting file
        start_file = None

        # Check if already synced all files
        if total_files > 0 and len(local_files) >= total_files:
            print(f"\n{'='*60}")
            print(f"✓ Sync Complete!")
            print(f"  Session: {session_id}")
            print(f"  Files: {len(local_files)}/{total_files} already synced locally")
            print(f"  Status: All files up to date")
            print(f"{'='*60}")
            # Close progress bar if it was created
            if self._overall_progress:
                self._overall_progress.close()
                self._overall_progress = None
            return True

        if local_files:
            try:
                last_num = int(local_files[-1].split('.')[0])
                next_num = last_num + 1
                start_file = f"{next_num:03d}.opus"

                # Don't request files beyond the device's total count
                if total_files > 0 and next_num > total_files:
                    print(f"\n{'='*60}")
                    print(f"✓ Sync Complete!")
                    print(f"  Session: {session_id}")
                    print(f"  Files: {len(local_files)}/{total_files} already synced")
                    print(f"  Status: All files up to date")
                    print(f"{'='*60}")
                    if self._overall_progress:
                        self._overall_progress.close()
                        self._overall_progress = None
                    return True

                print(f"  Resuming from: {start_file}")
            except (ValueError, IndexError):
                print("  Warning: Could not determine resume point")

        # Clear state
        self.completed_files = []
        self.current_file_data = bytearray()
        self._early_data_buffer = bytearray()
        self.downloading_file = True
        self._last_filename = None

        # Create overall progress bar (starting from existing file count)
        if self.has_tqdm and total_files > 0:
            overall_desc = f"  Overall ({session_id[-6:]})"
            self._overall_progress = self.tqdm(
                total=total_files,
                unit='file',
                desc=overall_desc,
                ncols=60,
                leave=True,
                initial=len(local_files),  # Start from existing file count
            )
        else:
            self._overall_progress = None

        # Start download
        if start_file:
            cmd = f"AT+DOWNLOAD={session_id}:{start_file}"
            print(f"\nStarting sync from: {start_file}")
        else:
            cmd = f"AT+DOWNLOAD={session_id}"
            print(f"\nStarting sync from: beginning")

        response = await self.send_command(cmd)
        if not response.get("ok"):
            error = response.get("error", "")
            print(f"Error starting download: {error}")

            # If error is about busy transfer, try to cancel first
            if "busy" in error.lower() or "already in progress" in error.lower():
                print("\nTransfer already in progress, cancelling...")
                cancel_response = await self.send_command("AT+CANCEL")
                print(f"Cancel response: {cancel_response}")

                # Wait a bit and try again
                await asyncio.sleep(1)
                response = await self.send_command(cmd)
                if not response.get("ok"):
                    print(f"Still failed: {response.get('error')}")
                    if self._overall_progress:
                        self._overall_progress.close()
                    return False
                else:
                    print("Successfully started after cancel")
            else:
                if self._overall_progress:
                    self._overall_progress.close()
                return False

        print("Syncing files... (Press Ctrl+C to stop)\n")

        # Wait for files
        last_file_count = 0
        no_new_files_count = 0

        try:
            while True:
                await asyncio.sleep(1)

                # Check connection
                if not self.client.is_connected:
                    print("\n[!] Connection lost!")
                    break

                # Check progress
                current_file_count = len(self.completed_files)
                if current_file_count > last_file_count:
                    last_file_count = current_file_count
                    no_new_files_count = 0
                else:
                    no_new_files_count += 1

                # For non-continuous mode, stop if no new files for 10 seconds
                if not continuous and no_new_files_count >= 10:
                    if len(self.completed_files) == 0:
                        print("\n✓ All files already up to date (no new files to transfer)")
                    else:
                        print(f"\n✓ Synced {len(self.completed_files)} new file(s)!")
                    break

                # Check device state periodically (both modes) - handles lost file_complete events
                if no_new_files_count >= 10:
                    # Check if recording is still active
                    status_response = await self.send_command("AT+GSTAT", timeout=3)
                    if status_response.get("ok"):
                        state = status_response.get("data", {}).get("state", "")
                        session_files = status_response.get("data", {}).get("session_files", 0)

                        # Count total local files (existing + newly downloaded)
                        local_file_count = len(list(self.session_dir.glob("*.opus"))) if self.session_dir.exists() else 0

                        # Exit if device is IDLE or we have all session files
                        if state == "IDLE":
                            print(f"\n✓ Recording stopped, {local_file_count} files synced")
                            break
                        elif session_files > 0 and local_file_count >= session_files:
                            print(f"\n✓ All {local_file_count} files synced (session complete)")
                            break
                        elif continuous:
                            print(f"\n  Still recording... ({local_file_count} files so far, press Ctrl+C to stop)")

                        no_new_files_count = 0  # Reset counter and check again

        except KeyboardInterrupt:
            print("\n[!] Interrupted by user")

        # Close overall progress bar
        if self._overall_progress:
            self._overall_progress.close()
            self._overall_progress = None

        # Show sync summary
        print(f"\n{'='*60}")
        print(f"✓ Sync Complete!")
        print(f"  Session: {session_id}")

        # Count total local files
        local_file_count = len(list(self.session_dir.glob("*.opus"))) if self.session_dir.exists() else 0
        new_files = len(self.completed_files)

        print(f"  Total files: {local_file_count}")
        if new_files > 0:
            print(f"  Newly synced: {new_files}")
        print(f"  Location: {self.session_dir.absolute()}")
        print(f"{'='*60}")

        # Merge files
        await self._merge_files(session_id)

        return True

    async def _merge_files(self, session_id: str):
        """Merge all Opus files into one"""
        # Include both newly transferred files and existing local files
        session_dir = DOWNLOAD_DIR / session_id

        # Get all local files
        all_files = {}
        if session_dir.exists():
            for f in sorted(session_dir.glob("*.opus")):
                # Read existing local file
                with open(f, "rb") as file:
                    all_files[f.name] = file.read()

        # Add newly transferred files (in memory)
        for filename, data in self.completed_files:
            if filename not in all_files:
                all_files[filename] = data
            else:
                # File already exists locally, don't overwrite
                pass

        # Sort by filename
        sorted_files = sorted(all_files.items())

        if not sorted_files:
            print("No files to merge")
            return

        # Merge
        merged_file = DOWNLOAD_DIR / f"{session_id}.opus"
        print(f"\nMerging {len(sorted_files)} files -> {merged_file.name}...")

        total_size = 0
        with open(merged_file, "wb") as outfile:
            for filename, data in sorted_files:
                outfile.write(data)
                total_size += len(data)
                print(f"  + {filename} ({len(data)} bytes)")

        print(f"✓ Merged: {merged_file.name} ({total_size} bytes)")
        print(f"✓ Files saved to: {session_dir.absolute()}")


    async def sync_all_sessions(self, continuous: bool = False):
        """Sync all sessions from device

        Args:
            continuous: If True, keep waiting for new files (for active recordings)
        """
        print("\n" + "="*60)
        print("Sync All Sessions Mode")
        print("="*60)

        # Get all sessions
        sessions = await self.list_sessions()
        if not sessions:
            print("\nNo sessions found on device")
            return False

        # Sort by session ID (oldest first for stable download order)
        sessions = sorted(sessions, key=lambda x: x['id'])

        print(f"\nFound {len(sessions)} session(s) to sync")

        # Calculate total files
        total_files = sum(sess.get('files', 0) for sess in sessions)
        total_size = sum(sess.get('size', 0) for sess in sessions)

        print(f"Total files across all sessions: {total_files}")
        print(f"Total size: {total_size:,} bytes ({total_size / 1024 / 1024:.1f} MB)")

        # Create overall progress bar for all sessions
        if self.has_tqdm and len(sessions) > 0:
            all_sessions_pbar = self.tqdm(
                total=len(sessions),
                unit='session',
                desc="  All sessions",
                ncols=60,
                leave=True,
            )
        else:
            all_sessions_pbar = None

        # Sync each session
        completed_count = 0
        failed_sessions = []

        for i, sess in enumerate(sessions):
            session_id = sess['id']
            session_files = sess.get('files', 0)
            session_size = sess.get('size', 0)

            print(f"\n{'='*60}")
            print(f"Session [{i+1}/{len(sessions)}]: {session_id}")
            print(f"  Files: {session_files}, Size: {session_size} bytes")
            print(f"{'='*60}")

            # Sync this session (oneshot mode for completed sessions)
            try:
                result = await self.sync_session(session_id, continuous=continuous)
                if result:
                    completed_count += 1
                else:
                    failed_sessions.append(session_id)
            except Exception as e:
                print(f"  ✗ Error syncing session: {e}")
                failed_sessions.append(session_id)

            # Update overall progress
            if all_sessions_pbar:
                all_sessions_pbar.update(1)

        # Close overall progress bar
        if all_sessions_pbar:
            all_sessions_pbar.close()

        # Final summary
        print(f"\n{'='*60}")
        print("All Sessions Sync Summary")
        print(f"{'='*60}")
        print(f"  Total sessions: {len(sessions)}")
        print(f"  Successfully synced: {completed_count}")
        print(f"  Failed: {len(failed_sessions)}")

        if failed_sessions:
            print(f"\n  Failed sessions:")
            for sess_id in failed_sessions:
                print(f"    - {sess_id}")

        print(f"{'='*60}")

        return len(failed_sessions) == 0


async def main():
    import argparse
    parser = argparse.ArgumentParser(description="ReSpeaker Clip Sync Tool")
    parser.add_argument("--device", "-d", help="Device MAC address")
    parser.add_argument("--session", "-s", help="Specific session to sync")
    parser.add_argument("--all-sessions", "-a", action="store_true",
                       help="Sync all sessions from device")
    parser.add_argument("--status", action="store_true", help="Show status and exit")
    parser.add_argument("--oneshot", action="store_true",
                       help="One-shot mode: exit when no new files (default: continuous for active recordings)")
    args = parser.parse_args()

    sync = ReSpeakerSync(args.device)

    if not await sync.connect():
        return 1

    try:
        # Get status
        status = await sync.get_status()

        if args.status:
            return 0

        # Sync all sessions
        if args.all_sessions:
            return 0 if await sync.sync_all_sessions(continuous=not args.oneshot) else 1

        # Determine which session to sync
        session_id = args.session
        continuous = not args.oneshot  # Default is continuous mode

        if not session_id:
            state = status.get("state", "") if status else ""
            if state == "RECORDING":
                print("\nDevice is recording, getting latest session...")
                session_id = await sync.get_latest_session()
                if not session_id:
                    print("No sessions found")
                    return 1
                continuous = True  # Always use continuous mode for active recordings
                print(f"  Using continuous mode (will keep syncing new files)")
            else:
                print("\nDevice is not recording")
                session_id = await sync.get_latest_session()
                if not session_id:
                    print("No sessions to sync")
                    return 1
                continuous = False  # Use oneshot mode for completed sessions
                print(f"  Using oneshot mode (will exit after syncing existing files)")

        # Sync the session
        await sync.sync_session(session_id, continuous=continuous)

    finally:
        await sync.disconnect()

    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
