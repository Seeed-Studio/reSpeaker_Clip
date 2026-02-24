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
from bleak import BleakClient, BleakScanner
from pathlib import Path

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
        self.last_response = None
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

        self.client = BleakClient(self.address, disconnected_callback=self._disconnect_callback)
        print(f"Connecting to {device.address}...")
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
        self.last_response = data.decode('utf-8').strip()

    def _file_data_handler(self, sender, data):
        if self.downloading_file:
            self.file_data.extend(data)

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

        session = response.get("session")
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

        # Create download directory
        session_dir = DOWNLOAD_DIR / session_id
        session_dir.mkdir(parents=True, exist_ok=True)

        # First, get marks to know how many files
        response = await self.send_command(f"AT+MARKS={session_id}")
        if response.get("ok"):
            marks = response.get("data", {}).get("bookmarks", [])
            print(f"  Session has {len(marks)} bookmarks")
            # Extract unique file indices from marks
            file_indices = sorted(set(m.get("file") for m in marks))
            print(f"  Files to download: {file_indices}")
        else:
            # Try to list session files another way
            file_indices = None

        # Download by trying common file names (001.opus, 002.opus, etc.)
        file_index = 1
        total_downloaded = 0

        while True:
            filename = f"{file_index:03d}.opus"
            full_response = await self.send_command(f"AT+DOWNLOAD={session_id}/{filename}")

            if not full_response.get("ok"):
                # Check if it's because file doesn't exist
                if "not found" in full_response.get("error", "").lower():
                    break
                print(f"  ✗ {filename}: {full_response.get('error')}")
                file_index += 1
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
                        filepath = session_dir / filename
                        with open(filepath, "wb") as f:
                            f.write(self.file_data)
                        print(f"  ✓ {filename}: {size} bytes")
                        total_downloaded += 1

                        self.file_data = bytearray()
                        self.downloading_file = False
                        break
                    elif transferred == last_size:
                        no_progress_count += 1
                        if no_progress_count > 5:
                            print(f"  ✗ {filename}: No progress, timeout")
                            break
                    else:
                        last_size = transferred
                        no_progress_count = 0

            file_index += 1

            # Break if we've tried 10 consecutive files without success
            if file_index - total_downloaded > 10:
                break

        print(f"\n✓ Downloaded {total_downloaded} file(s) to {session_dir}")
        return total_downloaded > 0

    async def run_test(self):
        """Run recording and download test"""
        try:
            print("\n" + "="*50)
            print("Recording and File Transfer Test")
            print("="*50)

            # Set time first
            if not await self.set_time():
                return

            # Start recording (5 seconds)
            success, session = await self.start_recording(duration=5)
            if not success:
                return

            # List sessions
            sessions = await self.list_sessions()

            # Download the session we just recorded
            if session:
                await self.download_session(session)

            print("\n" + "="*50)
            print("Download complete!")
            print("="*50)
            print(f"\nFiles saved to: {DOWNLOAD_DIR.absolute()}/")
            print("\nTo merge Opus files into one:")
            print("  Option 1: Concatenate (for streaming):")
            print(f"    cat {DOWNLOAD_DIR.absolute()}/{session}/*.opus > merged.opus")
            print("  Option 2: Decode to WAV and re-encode:")
            print(f"    for f in {DOWNLOAD_DIR.absolute()}/{session}/*.opus; do")
            print("        opusdec --rate 48000 \"$f\" - | opusenc --bitrate 48000 - \"${f%.opus}.wav\"")
            print("        ffmpeg -i \"${f%.opus}.wav\" -c copy output.wav")
            print("    done")
            print("    ffmpeg -f concat -i list.txt -c copy output.wav")
            print("  Option 3: Use opusdec to decode all to PCM:")
            print(f"    for f in {DOWNLOAD_DIR.absolute()}/{session}/*.opus; do")
            print("        opusdec --rate 48000 \"$f\" \"$f.wav\"")
            print("    done")
            print("    # Then merge WAV files with ffmpeg or other tool")

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
