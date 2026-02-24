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
        self.downloading_file = False
        self.download_filename = None

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

            # Check if response looks complete (ends with } or ])
            if response_str.endswith('}') or response_str.endswith(']'):
                self.last_response = response_str
                # Clear buffer for next response
                self.response_buffer.clear()
        except UnicodeDecodeError:
            pass  # Wait for more data

    def _file_data_handler(self, sender, data):
        if self.downloading_file:
            self.file_data.extend(data)

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

    async def send_command(self, cmd, timeout=5.0):
        self.last_response = None
        print(f" -> {cmd}")
        await self.client.write_gatt_char(CMD_RECV_UUID, cmd.encode('utf-8'))

        for _ in range(int(timeout * 10)):
            await asyncio.sleep(0.1)
            if self.last_response:
                try:
                    return json.loads(self.last_response)
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
        """Download all files from a session"""
        print(f"\n=== Downloading session: {session_id} ===")

        # Ensure session_id is a string (JSON might parse large numbers as int)
        session_id = str(session_id)

        # Create download directory
        session_dir = DOWNLOAD_DIR / session_id
        session_dir.mkdir(parents=True, exist_ok=True)

        # Get list of files in this session
        response = await self.send_command(f"AT+LIST={session_id}")
        if not response.get("ok"):
            print(f"  ✗ Failed to list files: {response.get('error')}")
            return False

        files = response.get("data", [])
        if not files:
            print(f"  No files found in session")
            return False

        print(f"  Found {len(files)} file(s): {', '.join(files)}")

        # First, try session-level download (all files at once)
        print("  Attempting session-level download...")
        response = await self.send_command(f"AT+DOWNLOAD={session_id}")

        if response.get("ok"):
            # Session-level download started, wait for completion
            self.file_data = bytearray()
            self.downloading_file = True

            timeout = 60  # seconds - longer for multiple files
            start_time = asyncio.get_event_loop().time()
            last_size = 0
            no_progress_count = 0
            total_files_seen = 0

            print("  Downloading all files in session...")
            while asyncio.get_event_loop().time() - start_time < timeout:
                await asyncio.sleep(0.5)

                # Check progress
                progress_resp = await self.send_command("AT+PROGRESS")
                if progress_resp.get("ok"):
                    data = progress_resp.get("data", {})
                    transferred = data.get("transferred", 0)
                    total = data.get("total", 0)

                    if total > 0:
                        progress = (transferred * 100) // total
                        received = len(self.file_data)
                        print(f"    Progress: {progress}% ({transferred}/{total} bytes, received: {received})", end='\r')

                    if transferred > 0 and transferred == total and total > 0:
                        # All files downloaded
                        print(f"\n  ✓ Download complete: {len(self.file_data)} bytes received (expected: {total})")
                        # Split data into individual files (since we don't have file boundaries)
                        # Save as single file for now
                        filepath = session_dir / "merged.opus"
                        file_bytes = bytes(self.file_data)  # Copy before clearing
                        with open(filepath, "wb") as f:
                            f.write(file_bytes)
                        self.file_data = bytearray()
                        self.downloading_file = False
                        print(f"\n✓ Saved merged file to {filepath}")

                        # Try to decode Opus to WAV
                        wav_path = session_dir / "merged.wav"
                        if not self.decode_opus_to_wav(file_bytes, wav_path):
                            print("  (Opus decoding skipped - raw file saved)")

                        return True
                    elif transferred == last_size and transferred > 0:
                        no_progress_count += 1
                        if no_progress_count > 10:
                            print(f"\n  ✗ No progress, canceling")
                            await self.send_command("AT+CANCEL")
                            await asyncio.sleep(0.5)
                            break
                    else:
                        last_size = transferred
                        no_progress_count = 0

        # Fall back to individual file download
        print("  Session-level download not available, downloading individual files...")

        total_downloaded = 0

        for filename in files:
            full_response = await self.send_command(f"AT+DOWNLOAD={session_id}/{filename}")

            if not full_response.get("ok"):
                print(f"  ✗ {filename}: {full_response.get('error')}")
                continue

            # Wait for file data
            self.file_data = bytearray()
            self.downloading_file = True
            self.download_filename = filename

            # Wait for download to complete (monitor PROGRESS)
            timeout = 30  # seconds
            start_time = asyncio.get_event_loop().time()
            last_size = 0
            no_progress_count = 0

            while asyncio.get_event_loop().time() - start_time < timeout:
                await asyncio.sleep(0.5)

                # Check progress
                progress_resp = await self.send_command("AT+PROGRESS")
                if progress_resp.get("ok"):
                    data = progress_resp.get("data", {})
                    transferred = data.get("transferred", 0)
                    total = data.get("total", 0)

                    if transferred > 0 and transferred == total:
                        # Download complete
                        size = len(self.file_data)
                        file_bytes = bytes(self.file_data)  # Copy before clearing
                        filepath = session_dir / filename
                        with open(filepath, "wb") as f:
                            f.write(file_bytes)
                        print(f"  ✓ {filename}: {size} bytes")
                        total_downloaded += 1

                        # Try to decode Opus to WAV
                        if filename.endswith('.opus'):
                            wav_filename = filename.replace('.opus', '.wav')
                            wav_path = session_dir / wav_filename
                            if not self.decode_opus_to_wav(file_bytes, wav_path):
                                print("    (Opus decoding skipped)")

                        self.file_data = bytearray()
                        self.downloading_file = False
                        break
                    elif transferred == last_size:
                        no_progress_count += 1
                        if no_progress_count > 5:
                            print(f"  ✗ {filename}: No progress, canceling transfer")
                            # Cancel the stuck transfer
                            await self.send_command("AT+CANCEL")
                            await asyncio.sleep(0.5)  # Wait for cleanup
                            break
                    else:
                        last_size = transferred
                        no_progress_count = 0

        print(f"\n✓ Downloaded {total_downloaded}/{len(files)} file(s) to {session_dir}")
        return total_downloaded > 0

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

            session = str(response.get("session", ""))
            print(f"✓ Recording started, session: {session}")

            # Start transfer immediately in background
            print("\n=== Starting simultaneous transfer ===")
            print("Transfer will continue in background as you record...")
            download_task = asyncio.create_task(self.download_session(session))

            # Wait for user to press Enter to stop
            print("\nRecording... Press Enter to stop:")
            input()

            # Stop recording
            print("\n=== Stopping recording ===")
            response = await self.send_command("AT+STOP")
            if response.get("ok"):
                print("✓ Recording stopped")
            else:
                print(f"✗ Failed to stop: {response.get('error')}")

            # Wait for transfer to complete
            print("\n=== Waiting for transfer to complete ===")
            print("(This may take a while if you recorded for a long time)")
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
