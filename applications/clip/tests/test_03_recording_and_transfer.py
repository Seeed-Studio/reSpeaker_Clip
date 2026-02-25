#!/usr/bin/env python3
"""
Recording and File Transfer Test - Test 3

Tests: START, STOP, LIST, DOWNLOAD, file merging

Usage:
    python test_03_recording.py [--device MAC_ADDRESS]
"""

import asyncio
import json
import os
import struct
import sys
import threading
import wave
from bleak import BleakClient, BleakScanner
from pathlib import Path

# Try to import tqdm for progress bar
try:
    from tqdm import tqdm
    HAS_TQDM = True
except ImportError:
    HAS_TQDM = False
    print("Note: tqdm not installed. Install with: pip install tqdm")

# Try to import opuslib for decoding (requires native libopus)
HAS_OPUSLIB = False
try:
    import opuslib
    # Test if decoder actually works (may fail on Windows without libopus)
    decoder = opuslib.Decoder(fs=16000, channels=2)
    HAS_OPUSLIB = True
    print("✓ Opus decoding available via opuslib")
except Exception as e:
    print(f"Note: Opus decoding not available ({e})")
    print("  Raw Opus files will be saved. Use ffmpeg to decode:")
    print("  ffmpeg -i merged.opus -c copy output.wav")

# UUIDs
SERVICE_UUID = "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"
CMD_RECV_UUID = "6E400002-B5A3-F393-E0A9-E50E24DCCA9E"
RESP_SEND_UUID = "6E400003-B5A3-F393-E0A9-E50E24DCCA9E"
FILE_DATA_UUID = "6E400004-B5A3-F393-E0A9-E50E24DCCA9E"

DEVICE_NAME_FILTER = "reSpeaker"

# Download directory
DOWNLOAD_DIR = Path("downloads")

class ClipClient:
    def __init__(self):
        self.client = None
        self.address = None
        self.last_response = None
        self.response_buffer = bytearray()  # Buffer for fragmented responses
        self.file_data = bytearray()
        self.current_file_data = bytearray()  # Buffer for current file being received
        self.downloading_file = False
        self.download_filename = None
        self._should_stop_download = False  # Signal to stop download
        self._stop_requested = False  # User pressed Enter
        self._recording_stopped = False  # AT+STOP was sent
        self.completed_files = []  # List of completed (filename, data) tuples
        self._last_filename = None  # Last file that received file_ready event
        self._last_file_size = 0
        self.session_dir = None  # Download directory for current session
        # Progress bar support
        self._current_file_progress = 0  # Bytes received for current file
        self._progress_bar = None  # tqdm progress bar
        self._progress_lock = threading.Lock()  # Thread-safe progress updates
        self._last_progress_update = 0  # For throttling progress updates
        self._transfer_complete = False  # Flag for transfer_complete event

    def stop_download(self):
        """Signal the download to stop after current file completes"""
        self._stop_requested = True

    async def wait_for_enter(self):
        """Wait for Enter key press without blocking event loop"""
        loop = asyncio.get_event_loop()
        # Read from stdin in a thread pool to avoid blocking
        await loop.run_in_executor(None, sys.stdin.readline)

    def _disconnect_callback(self, client):
        print("\n[!] Device disconnected")
        # Save any partial data and merge files
        if self.downloading_file and self.session_dir:
            print("[!] Saving partial data...")
            if len(self.current_file_data) > 0 and self._last_filename:
                filepath = self.session_dir / self._last_filename
                with open(filepath, "wb") as f:
                    f.write(self.current_file_data)
                print(f"[!] Saved partial: {self._last_filename} ({len(self.current_file_data)} bytes)")
                # Add to completed files for merging
                if self._last_filename not in [f[0] for f in self.completed_files]:
                    self.completed_files.append((self._last_filename, bytes(self.current_file_data)))

    async def connect(self):
        print("Scanning...")
        device = await BleakScanner.find_device_by_filter(
            lambda d, _: d.name and DEVICE_NAME_FILTER in d.name
        )
        if not device:
            print(f"Device '{DEVICE_NAME_FILTER}' not found")
            return False
        print(f"Found: {device.name} ({device.address})")

        self.address = device.address

        self.client = BleakClient(self.address, disconnected_callback=self._disconnect_callback)
        print(f"Connecting to {self.address}...")
        try:
            await self.client.connect(timeout=30.0)
            print("Connected!")

            await self.client.start_notify(RESP_SEND_UUID, self._notification_handler)
            await self.client.start_notify(FILE_DATA_UUID, self._file_data_handler)
            await asyncio.sleep(0.2)
            return True
        except Exception as e:
            print(f"Connection failed: {e}")
            return False

    async def disconnect(self):
        if self.client and self.client.is_connected:
            await self.client.stop_notify(RESP_SEND_UUID)
            await self.client.stop_notify(FILE_DATA_UUID)
            await self.client.disconnect()
            print("Disconnected")

    def _notification_handler(self, sender, data):
        # Append data to buffer
        self.response_buffer.extend(data)

        # Try to decode and check if we have a complete JSON response
        try:
            response_str = self.response_buffer.decode('utf-8').strip()

            # Check if response looks complete (ends with })
            if response_str.endswith('}'):
                # Try to parse as JSON
                try:
                    event_data = json.loads(response_str)
                    event_type = event_data.get("event", "")

                    if event_type == "file_complete":
                        filename = event_data.get("filename", "")
                        # Close progress bar
                        self._close_progress_bar()
                        print(f"\n  [DEBUG] file_complete: {filename}, data_size={len(self.current_file_data)}, last_file={self._last_filename}", flush=True)
                        # Only save if matches the last ready file AND has data
                        if filename == self._last_filename and len(self.current_file_data) > 0:
                            filepath = self.session_dir / filename
                            with open(filepath, "wb") as f:
                                f.write(self.current_file_data)
                            print(f"\n  [SAVED TO DISK] {filename} ({len(self.current_file_data)} bytes)", flush=True)
                            self.completed_files.append((filename, bytes(self.current_file_data)))
                            self.current_file_data = bytearray()
                            self._last_filename = None
                        else:
                            print(f"\n  [DEBUG] Skipping save: match={filename == self._last_filename}, data_size={len(self.current_file_data)}", flush=True)

                    elif event_type == "transfer_complete":
                        # All files in session have been transferred
                        session_id = event_data.get("session_id", "")
                        files_count = event_data.get("files", 0)
                        print(f"\n  [TRANSFER COMPLETE] Session: {session_id}, Files: {files_count}", flush=True)
                        # Set a flag to indicate transfer is complete
                        self._transfer_complete = True

                    elif event_type == "file_ready":
                        filename = event_data.get("filename", "")
                        size = event_data.get("size", 0)
                        print(f"\n  [FILE READY] {filename} ({size} bytes)", flush=True)
                        # Only switch to new file if we're not currently receiving data for a different file
                        # The device will send file_complete for each file in order
                        if self._last_filename is None or self._last_filename == filename:
                            # No file currently being received, or same file (duplicate event)
                            self._last_filename = filename
                            self._last_file_size = size
                            self._current_file_progress = 0
                            # Create new progress bar
                            self._create_progress_bar(filename, size)
                        # else: we're currently receiving a different file, ignore this event
                        # the device will send file_complete when current file is done
                    else:
                        # Not an event, store as regular response
                        self.last_response = response_str

                except json.JSONDecodeError:
                    # Not valid JSON, store as regular response
                    self.last_response = response_str

                # Clear buffer for next response
                self.response_buffer.clear()
        except UnicodeDecodeError:
            pass  # Wait for more data

    def _file_data_handler(self, sender, data):
        if self.downloading_file:
            # Regular file data
            self.current_file_data.extend(data)
            self.file_data.extend(data)  # Also keep in main buffer for progress tracking
            # Update progress bar
            self._update_progress(len(data))

    def _create_progress_bar(self, filename, total_size):
        """Create a new progress bar for file transfer"""
        if not HAS_TQDM:
            return
        with self._progress_lock:
            if self._progress_bar is not None:
                self._progress_bar.close()
            self._progress_bar = tqdm(
                total=total_size,
                unit='B',
                unit_scale=True,
                unit_divisor=1024,
                desc=f"  {filename}",
                ncols=60,
                leave=False,
                file=sys.stdout
            )
            self._current_file_progress = 0
            self._last_progress_update = 0

    def _update_progress(self, chunk_size):
        """Update progress bar with received data (throttled)"""
        if not HAS_TQDM or self._progress_bar is None:
            return
        with self._progress_lock:
            self._current_file_progress += chunk_size
            # Only update UI every 4KB to reduce overhead
            if self._current_file_progress - self._last_progress_update >= 4096:
                self._progress_bar.update(self._current_file_progress - self._last_progress_update)
                self._last_progress_update = self._current_file_progress

    def _close_progress_bar(self):
        """Close the current progress bar"""
        if not HAS_TQDM:
            return
        with self._progress_lock:
            if self._progress_bar is not None:
                # Final update to show 100%
                if self._current_file_progress > self._last_progress_update:
                    self._progress_bar.update(self._current_file_progress - self._last_progress_update)
                self._progress_bar.close()
                self._progress_bar = None

    def decode_opus_to_wav(self, opus_data, wav_path, sample_rate=16000, channels=2):
        """Decode Opus frame data to WAV file.

        Args:
            opus_data: Raw bytes containing length-prefixed Opus frames
            wav_path: Output WAV file path
            sample_rate: Sample rate (default 16000 Hz)
            channels: Number of channels (default 2 for stereo)

        Returns:
            True if successful, False otherwise
        """
        if not HAS_OPUSLIB:
            return False

        try:
            # Create Opus decoder
            decoder = opuslib.Decoder(fs=sample_rate, channels=channels)
            frame_size = sample_rate // 50  # 20ms frames

            pcm_frames = []
            offset = 0

            while offset < len(opus_data):
                # Read 2-byte little-endian length
                if offset + 2 > len(opus_data):
                    break
                frame_len = struct.unpack('<H', opus_data[offset:offset+2])[0]
                offset += 2

                # Read frame data
                if offset + frame_len > len(opus_data):
                    print(f"Warning: Incomplete frame at offset {offset}")
                    break

                frame_data = opus_data[offset:offset+frame_len]
                offset += frame_len

                # Decode Opus frame to PCM
                try:
                    pcm_data = decoder.decode(frame_data, frame_size, decode_fec=False)
                    pcm_frames.append(pcm_data)
                except Exception as e:
                    print(f"Warning: Failed to decode frame: {e}")
                    continue

            if not pcm_frames:
                print("No valid Opus frames decoded")
                return False

            # Combine all PCM frames
            all_pcm = b''.join(pcm_frames)

            # Write WAV file
            with wave.open(str(wav_path), 'wb') as wf:
                wf.setnchannels(channels)
                wf.setsampwidth(2)  # 16-bit
                wf.setframerate(sample_rate)
                wf.writeframes(all_pcm)

            duration = len(all_pcm) / (sample_rate * channels * 2)
            print(f"  ✓ Decoded to WAV: {wav_path}")
            print(f"    Duration: {duration:.2f}s, Frames: {len(pcm_frames)}")
            return True

        except Exception as e:
            print(f"  ✗ Opus decode error: {e}")
            import traceback
            traceback.print_exc()
            return False

    async def send_command(self, cmd, timeout=10.0):
        self.last_response = None
        print(f" -> {cmd}")
        await self.client.write_gatt_char(CMD_RECV_UUID, cmd.encode('utf-8'))
        # Small delay to let command be processed
        await asyncio.sleep(0.2)

        for i in range(int(timeout * 10)):
            await asyncio.sleep(0.1)
            if self.last_response:
                try:
                    parsed = json.loads(self.last_response)
                    # Debug: print parsed response
                    if "session" in parsed or "event" in parsed:
                        print(f"  [DEBUG] Parsed response: {parsed}", flush=True)
                    return parsed
                except:
                    return {"ok": False, "error": "Invalid JSON"}

        return {"ok": False, "error": "Timeout"}

    async def set_time(self):
        """Set current time"""
        import time
        current_ts = int(time.time())
        response = await self.send_command(f"AT+TIME={current_ts}")
        if response.get("ok"):
            print(f"✓ Time set to: {current_ts}")
            return True
        else:
            print(f"✗ Failed to set time: {response.get('error')}")
            return False

    async def start_recording(self, duration=5):
        """Start recording"""
        print(f"\n=== Starting recording ({duration}s) ===")
        response = await self.send_command("AT+START")
        if not response.get("ok"):
            print(f"✗ Failed to start: {response.get('error')}")
            return False, None

        session = str(response.get("session", ""))
        print(f"✓ Recording started, session: {session}")
        print(f"  Recording for {duration} seconds...")

        await asyncio.sleep(duration)

        # Stop recording
        response = await self.send_command("AT+STOP")
        if response.get("ok"):
            print("✓ Recording stopped")
            return True, session
        return False, None

    async def list_sessions(self):
        """List all sessions"""
        print("\n=== Listing sessions ===")
        response = await self.send_command("AT+LIST")
        if not response.get("ok"):
            print(f"✗ Failed: {response.get('error')}")
            return []

        sessions = response.get("data", [])
        print(f"Found {len(sessions)} session(s):")
        for sess in sessions:
            synced = sess.get('synced', 0)
            print(f"  - {sess['id']}: {sess['files']} files, {sess['size']} bytes, {synced} synced")
        return sessions

    async def get_session_info(self, session_id):
        """Get session info (file count, total size, synced count)"""
        print(f"\n=== Getting session info: {session_id} ===")
        response = await self.send_command(f"AT+LIST={session_id}")
        if not response.get("ok"):
            print(f"✗ Failed: {response.get('error')}")
            return None

        data = response.get("data", {})
        info = {
            'files': data.get('files', 0),
            'size': data.get('size', 0),
            'synced': data.get('synced', 0)
        }
        print(f"  Files: {info['files']}, Size: {info['size']}, Synced: {info['synced']}")
        return info

    async def delete_session(self, session_id):
        """Delete a session from device after successful sync"""
        print(f"\n=== Deleting session: {session_id} ===")
        response = await self.send_command(f"AT+DELETE={session_id}")
        if response.get("ok"):
            print(f"✓ Session deleted: {session_id}")
            return True
        else:
            print(f"✗ Failed to delete: {response.get('error')}")
            return False

    async def download_session(self, session_id):
        """Download all files from a session continuously until all files transferred"""
        print(f"\n=== Downloading session: {session_id} ===")
        print(f"  [DEBUG] download_session called", flush=True)

        session_id = str(session_id)

        # Create download directory
        self.session_dir = DOWNLOAD_DIR / session_id
        self.session_dir.mkdir(parents=True, exist_ok=True)

        # Clear any previous state
        self.completed_files = []
        self.current_file_data = bytearray()
        self.file_data = bytearray()
        self._stop_requested = False  # User pressed Enter
        self._recording_stopped = False  # AT+STOP was sent
        self._transfer_complete = False  # Reset transfer complete flag

        # Start download
        print("  Starting download...", flush=True)
        response = await self.send_command(f"AT+DOWNLOAD={session_id}")
        if not response.get("ok"):
            print(f"  ✗ Failed to start: {response.get('error')}")
            return False

        self.downloading_file = True
        self._should_stop_download = False  # Reset flag

        print("  Downloading... files will be saved as they complete (press Enter to stop)", flush=True)

        last_file_count = 0
        no_new_files_count = 0

        try:
            # Continue until stop signal AND all files transferred
            while True:
                await asyncio.sleep(1)

                # Check if transfer is complete (all files transferred)
                if self._transfer_complete:
                    print("  ✓ All files transferred (received transfer_complete event)", flush=True)
                    break

                # Check if user requested stop (Enter pressed)
                if self._stop_requested and not self._recording_stopped:
                    print("\n  [INFO] Stop requested, waiting for transfer to complete...", flush=True)
                    self._recording_stopped = True
                    # Don't break yet - continue to wait for files

                # Check if we should exit after recording stopped
                if self._recording_stopped:
                    # Check if we have received new files recently
                    current_file_count = len(self.completed_files)
                    if current_file_count > last_file_count:
                        last_file_count = current_file_count
                        no_new_files_count = 0
                    else:
                        no_new_files_count += 1
                        print(f"  Waiting for transfer... ({no_new_files_count}/5)", flush=True)

                        # If 5 seconds (5 checks) with no new files, assume done
                        if no_new_files_count >= 5:
                            print("  ✓ All files transferred", flush=True)
                            break
        finally:
            # Always save and merge files, even if disconnected
            print(f"\n\n  Processing {len(self.completed_files)} files...")
            await self._save_and_merge_files(session_id)

            # Delete session from device after successful transfer
            if len(self.completed_files) > 0:
                print("\n  Deleting session from device after successful transfer...")
                await self.delete_session(session_id)

        self.downloading_file = False
        return True

    async def _save_and_merge_files(self, session_id):
        """Save any remaining data and merge all files into one"""
        # Save any remaining data (last file might still be recording)
        if len(self.current_file_data) > 0 and self._last_filename:
            print(f"  Saving partial file: {self._last_filename}")
            filepath = self.session_dir / self._last_filename
            with open(filepath, "wb") as f:
                f.write(self.current_file_data)
            # Also add to completed files
            if self._last_filename not in [f[0] for f in self.completed_files]:
                self.completed_files.append((self._last_filename, bytes(self.current_file_data)))

        # Sort files by name (001.opus, 002.opus, etc.)
        sorted_files = sorted(self.completed_files, key=lambda x: x[0])

        if not sorted_files:
            print("  No files to merge")
            return

        # Merge all Opus files into one
        merged_file = self.session_dir.parent / f"{session_id}.opus"
        print(f"\n  Merging {len(sorted_files)} files -> {merged_file.name}...", flush=True)

        total_size = 0
        with open(merged_file, "wb") as outfile:
            for filename, data in sorted_files:
                outfile.write(data)
                total_size += len(data)
                print(f"    + {filename} ({len(data)} bytes)", flush=True)

        print(f"  ✓ Merged: {merged_file.name} ({total_size} bytes)", flush=True)

    async def get_local_files(self, session_id):
        """Get list of files already downloaded locally"""
        session_dir = DOWNLOAD_DIR / session_id
        if not session_dir.exists():
            return []

        local_files = []
        for f in sorted(session_dir.glob("*.opus")):
            local_files.append(f.name)
        return local_files

    async def download_session_with_resume(self, session_id, auto_reconnect=True):
        """
        Download session with automatic reconnection and resume support.

        If disconnected, will:
        1. Reconnect to device
        2. List files on device
        3. Compare with local files
        4. Resume from first missing file
        """
        print(f"\n=== Downloading session: {session_id} (with resume support) ===")

        session_id = str(session_id)

        # Create download directory
        self.session_dir = DOWNLOAD_DIR / session_id
        self.session_dir.mkdir(parents=True, exist_ok=True)

        # Get existing local files
        local_files = await self.get_local_files(session_id)
        if local_files:
            print(f"  Found {len(local_files)} existing local files")
            print(f"  Local files: {', '.join(local_files[:5])}{'...' if len(local_files) > 5 else ''}")

        # Start download from first missing file
        start_file = None
        if local_files:
            # Find the last local file, we'll start from the next one
            # Files are named 001.opus, 002.opus, etc.
            try:
                last_num = int(local_files[-1].split('.')[0])
                next_num = last_num + 1
                start_file = f"{next_num:03d}.opus"
                print(f"  Resuming from: {start_file}")
            except (ValueError, IndexError):
                print(f"  Warning: Could not determine resume point, starting from beginning")
                start_file = None

        max_retries = 10 if auto_reconnect else 0
        retry_count = 0

        while retry_count <= max_retries:
            # Clear state for this attempt
            self.completed_files = []
            self.current_file_data = bytearray()
            self.file_data = bytearray()
            self._stop_requested = False
            self._recording_stopped = False
            self._transfer_complete = False  # Reset transfer complete flag

            # Start or resume download
            if start_file:
                cmd = f"AT+DOWNLOAD={session_id}:{start_file}"
                print(f"  Sending: {cmd}")
            else:
                cmd = f"AT+DOWNLOAD={session_id}"
                print(f"  Sending: {cmd}")

            response = await self.send_command(cmd)
            if not response.get("ok"):
                print(f"  ✗ Failed to start: {response.get('error')}")
                # If failed and not first attempt, might be disconnected
                if retry_count > 0:
                    connection_lost = True
                else:
                    return False

            self.downloading_file = True

            print("  Downloading... (files will be saved as they complete)", flush=True)

            # Wait for transfer with timeout for each file
            last_file_count = len(self.completed_files)
            no_new_files_count = 0
            connection_lost = False
            no_response_count = 0

            try:
                while True:
                    await asyncio.sleep(1)

                    # Check if transfer is complete (all files transferred)
                    if self._transfer_complete:
                        print("  ✓ All files transferred (received transfer_complete event)")
                        break

                    # Check if connection is still alive by checking client status
                    if not self.client or not self.client.is_connected:
                        print("\n  [!] Connection lost (is_connected=False)!")
                        connection_lost = True
                        break

                    # Also try to detect disconnect by checking if we can send a command
                    # Do a simple ping check
                    try:
                        # Send a quick GSTAT to verify connection is alive
                        gstat_response = await self.send_command("AT+GSTAT", timeout=2)
                        if gstat_response is None:
                            no_response_count += 1
                            if no_response_count >= 3:
                                print("\n  [!] No response from device (disconnected?)")
                                connection_lost = True
                                break
                        else:
                            no_response_count = 0  # Reset counter on successful response
                    except Exception as e:
                        no_response_count += 1
                        if no_response_count >= 3:
                            print(f"\n  [!] Connection check failed: {e}")
                            connection_lost = True
                            break

                    # Check if we have received new files
                    current_file_count = len(self.completed_files)
                    if current_file_count > last_file_count:
                        last_file_count = current_file_count
                        no_new_files_count = 0
                        no_response_count = 0  # Reset on progress
                        # Update start_file for potential resume
                        if self.completed_files:
                            last_filename = self.completed_files[-1][0]
                            try:
                                last_num = int(last_filename.split('.')[0])
                                next_num = last_num + 1
                                start_file = f"{next_num:03d}.opus"
                            except (ValueError, IndexError):
                                pass
                    else:
                        no_new_files_count += 1

                    # If no new files for 10 seconds and recording stopped, we're done
                    if self._recording_stopped and no_new_files_count >= 10:
                        print("  ✓ All files transferred")
                        break

                    # If just waiting for more files, continue
                    if no_new_files_count < 30:  # 30 second timeout
                        continue

                    # Check if session is closed
                    try:
                        gstat_resp = await self.send_command("AT+GSTAT", timeout=5)
                        if gstat_resp and gstat_resp.get("ok"):
                            state = gstat_resp["data"].get("state")
                            if state == "IDLE":
                                print("  Session closed, transfer complete")
                                break
                    except:
                        pass  # Ignore errors, continue

            except asyncio.CancelledError:
                print("\n  [!] Download cancelled")
                connection_lost = True
            except Exception as e:
                print(f"\n  [!] Error: {e}")
                connection_lost = True

            # Save received files before reconnecting
            if self.completed_files:
                print(f"\n  [*] Saving {len(self.completed_files)} received files before reconnect...")
                for filename, data in self.completed_files:
                    filepath = self.session_dir / filename
                    if not filepath.exists():
                        with open(filepath, "wb") as f:
                            f.write(data)
                        print(f"    + {filename}")

            if not connection_lost:
                # Success, no reconnection needed
                await self._save_and_merge_files(session_id)
                self.downloading_file = False
                return True

            # Connection lost - try to reconnect
            if retry_count >= max_retries:
                print(f"\n  [!] Max retries ({max_retries}) reached")
                self.downloading_file = False
                await self._save_and_merge_files(session_id)
                return False

            retry_count += 1
            print(f"\n  [*] Attempting to reconnect... (retry {retry_count}/{max_retries})")

            # Disconnect properly first
            try:
                await self.disconnect()
            except:
                pass  # Ignore errors during disconnect

            # Wait before reconnecting
            await asyncio.sleep(2)

            # Try to reconnect - use the same address if we have it
            print(f"  [*] Connecting to {self.address if self.address else 'device (scanning)'}...")
            if await self.connect():
                print("  ✓ Reconnected!")

                # Restart notifications after reconnect
                try:
                    await self.client.start_notify(RESP_SEND_UUID, self._notification_handler)
                    await self.client.start_notify(FILE_DATA_UUID, self._file_data_handler)
                    await asyncio.sleep(0.2)
                    print("  ✓ Notifications restarted")
                except Exception as e:
                    print(f"  ✗ Failed to restart notifications: {e}")
                    await self._save_and_merge_files(session_id)
                    return False
            else:
                print("  ✗ Reconnection failed")
                await self._save_and_merge_files(session_id)
                return False

        self.downloading_file = False
        await self._save_and_merge_files(session_id)
        return True

    async def run_test(self):
        """Run recording with simultaneous transfer - manual stop with Enter key"""
        try:
            print("\n" + "="*50)
            print("Recording and Simultaneous Transfer Test")
            print("="*50)

            # Set time first
            if not await self.set_time():
                return

            # Start recording (no time limit - wait for user to stop)
            print("\n=== Starting recording ===")
            print("Note: Recording will continue until you press Enter")
            response = await self.send_command("AT+START", timeout=10)
            if not response.get("ok"):
                print(f"✗ Failed to start: {response.get('error')}")
                return

            print(f"  [DEBUG] Full response: {response}", flush=True)
            session = str(response.get("session", ""))
            print(f"  [DEBUG] Session value: {repr(session)}", flush=True)
            print(f"✓ Recording started, session: {session}", flush=True)

            # Start transfer immediately in background
            print("\n=== Starting simultaneous transfer ===", flush=True)
            print("Transfer will continue in background as you record...", flush=True)
            try:
                download_task = asyncio.create_task(self.download_session(session))
                print("  (Download task created)", flush=True)
            except Exception as e:
                print(f"  ✗ Failed to create download task: {e}")
                import traceback
                traceback.print_exc()

            # Wait for user to press Enter to stop (non-blocking)
            print("\nRecording... Press Enter to stop:", flush=True)
            await self.wait_for_enter()

            # Stop recording
            print("\n=== Stopping recording ===")
            response = await self.send_command("AT+STOP")
            if response.get("ok"):
                print("✓ Recording stopped")
            else:
                print(f"✗ Failed to stop: {response.get('error')}")

            # Signal download to stop after recording stops
            # Download will finish current files before exiting
            print("\n=== Finishing transfer ===")
            self.stop_download()

            # Wait for transfer to complete
            try:
                await download_task
            except Exception as e:
                print(f"\n[!] Transfer interrupted: {e}")
                # Still try to merge any files we received
                if self.session_dir and self.completed_files:
                    print("[!] Merging received files...")
                    await self._save_and_merge_files(session)

            print("\n" + "="*50)
            print("Test complete!")
            print("="*50)
            print(f"\nFiles saved to: {DOWNLOAD_DIR.absolute()}")

            # Show merged file info
            merged_file = DOWNLOAD_DIR / f"{session}.opus"
            if merged_file.exists():
                size = merged_file.stat().st_size
                print(f"  Merged file: {merged_file.name} ({size} bytes)")
            else:
                print(f"  Note: Merged file not created")

        finally:
            await self.disconnect()

    async def test_disconnect_resume(self):
        """
        Test disconnect and resume - simulate connection loss during transfer

        This will:
        1. Start recording
        2. Start transfer and run continuously
        3. YOU disconnect manually (turn off bluetooth, etc.)
        4. Script detects disconnect
        5. Script auto-reconnects and resumes
        """
        print("\n" + "="*50)
        print("Disconnect & Resume Test")
        print("="*50)
        print("\nThis test will:")
        print("1. Start recording and transfer")
        print("2. Run transfer continuously")
        print("3. When YOU disconnect (turn off bluetooth), script will detect it")
        print("4. Script will auto-reconnect and resume transfer")
        print("\nPress Enter when ready...")
        input()

        # Set time
        if not await self.set_time():
            return

        # Start recording
        print("\n=== Starting recording ===")
        response = await self.send_command("AT+START")
        if not response.get("ok"):
            print(f"✗ Failed to start: {response.get('error')}")
            return

        session = str(response.get("session", ""))
        print(f"✓ Recording started, session: {session}")

        # Use the resume-capable download function
        print("\n=== Starting transfer (with auto-reconnect) ===")
        print("Transfer will run until you stop it with Ctrl+C")
        print("Try disconnecting bluetooth - it will auto-reconnect!")
        print("(Press Ctrl+C twice to stop completely)", flush=True)

        try:
            success = await self.download_session_with_resume(session_id=session, auto_reconnect=True)
            if success:
                print("\n✓ Transfer completed!")
            else:
                print("\n✗ Transfer failed")
        except KeyboardInterrupt:
            print("\n[!] Interrupted by user")

        # Stop recording
        print("\n=== Stopping recording ===")
        await self.send_command("AT+STOP")
        print("✓ Done")

        if success:
            print("\n✓ Resume test complete!")
        else:
            print("\n✗ Resume test failed")

        # Stop recording
        print("\n=== Stopping recording ===")
        await self.send_command("AT+STOP")

async def main():
    import argparse
    parser = argparse.ArgumentParser(description="Recording and Transfer Test")
    parser.add_argument("--test-disconnect", action="store_true",
                       help="Test disconnect and resume scenario")
    args = parser.parse_args()

    client = ClipClient()
    if not await client.connect():
        return 1

    if args.test_disconnect:
        await client.test_disconnect_resume()
    else:
        await client.run_test()

    return 0


if __name__ == "__main__":
    import sys
    sys.exit(asyncio.run(main()))
