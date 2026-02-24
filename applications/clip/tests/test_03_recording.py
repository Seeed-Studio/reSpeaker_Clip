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
import wave
from bleak import BleakClient, BleakScanner
from pathlib import Path

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

                    elif event_type == "file_ready":
                        filename = event_data.get("filename", "")
                        size = event_data.get("size", 0)
                        print(f"\n  [FILE READY] {filename} ({size} bytes) - will start transfer", flush=True)
                        # Clear previous file data when new file is ready
                        if len(self.current_file_data) > 0 and self._last_filename and self._last_filename != filename:
                            print(f"\n  [DEBUG] Clearing previous data for: {self._last_filename}", flush=True)
                            self.current_file_data = bytearray()
                        self._last_filename = filename
                        self._last_file_size = size
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
            print(f"  - {sess['id']}: {sess['files']} files, {sess['size']} bytes")
        return sessions

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

        # Continue until stop signal AND all files transferred
        while True:
            await asyncio.sleep(1)

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

        # Save all completed files
        print(f"\n\n  Saving {len(self.completed_files)} files...")
        for filename, file_data in self.completed_files:
            filepath = session_dir / filename
            with open(filepath, "wb") as f:
                f.write(file_data)
            print(f"  ✓ Saved: {filename} ({len(file_data)} bytes)")

        # Save any remaining data (last file might still be recording)
        if len(self.current_file_data) > 0:
            # Get current file list to find the last file
            list_resp = await self.send_command(f"AT+LIST={session_id}")
            if list_resp.get("ok"):
                current_files = list_resp.get("data", [])
                if current_files:
                    # Find which file we haven't saved yet
                    saved_filenames = [f[0] for f in self.completed_files]
                    for f in current_files:
                        if f not in saved_filenames:
                            filepath = session_dir / f
                            with open(filepath, "wb") as f:
                                f.write(self.current_file_data)
                            print(f"  ✓ Saved: {f} ({len(self.current_file_data)} bytes)")
                            break

        print(f"\n  ✓ Download complete: {len(self.completed_files)} files saved")
        self.downloading_file = False
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
            await download_task

            print("\n" + "="*50)
            print("Test complete!")
            print("="*50)
            print(f"\nFiles saved to: {DOWNLOAD_DIR.absolute()}/")

            if HAS_OPUSLIB:
                print("Note: Opus files have been automatically decoded to WAV.")
            else:
                print("\nTo decode Opus files manually:")
                print("  ffmpeg -f opus -i merged.opus -ar 16000 output.wav")
                print("  (Windows users: download ffmpeg from https://ffmpeg.org/)")

        finally:
            await self.disconnect()

async def main():
    client = ClipClient()
    if not await client.connect():
        return 1

    await client.run_test()

    return 0


if __name__ == "__main__":
    import sys
    sys.exit(asyncio.run(main()))
