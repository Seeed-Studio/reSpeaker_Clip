#!/usr/bin/env python3
"""
reSpeaker Clip BLE Protocol Test Script

This script tests the BLE AT command protocol for the reSpeaker Clip device.
It uses the Bleak library for cross-platform BLE connectivity.

Requirements:
    pip install bleak

Usage:
    python ble_test.py [--device MAC_ADDRESS] [--test TEST_NAME]

Examples:
    python ble_test.py                    # Auto-discover device
    python ble_test.py --device AA:BB:CC:DD:EE:FF
    python ble_test.py --test test_recording
"""

import asyncio
import json
import struct
import time
import argparse
from typing import Optional, Callable, Any
from bleak import BleakClient, BleakScanner
from bleak.exc import BleakError

# ============================= Constants =============================

# Service and Characteristic UUIDs
SERVICE_UUID = "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"
CMD_RECV_UUID = "6E400002-B5A3-F393-E0A9-E50E24DCCA9E"
RESP_SEND_UUID = "6E400003-B5A3-F393-E0A9-E50E24DCCA9E"
FILE_DATA_UUID = "6E400004-B5A3-F393-E0A9-E50E24DCCA9E"

# Device name filter
DEVICE_NAME_FILTER = "reSpeaker"  # Adjust based on actual device name

# Timeouts (seconds)
CONNECT_TIMEOUT = 10.0
COMMAND_TIMEOUT = 5.0
TRANSFER_TIMEOUT = 60.0

# ============================= Test Framework =============================

class TestResult:
    """Store test results"""
    def __init__(self):
        self.passed = 0
        self.failed = 0
        self.errors = []
        self.test_names = []

    def add_pass(self, name: str):
        self.passed += 1
        self.test_names.append(name)
        print(f"  ✓ {name}")

    def add_fail(self, name: str, reason: str):
        self.failed += 1
        self.errors.append((name, reason))
        self.test_names.append(name)
        print(f"  ✗ {name}: {reason}")

    def summary(self):
        total = self.passed + self.failed
        print(f"\n{'='*60}")
        print(f"Test Summary: {self.passed}/{total} passed")
        if self.failed > 0:
            print(f"\nFailed tests:")
            for name, reason in self.errors:
                print(f"  - {name}: {reason}")
        print(f"{'='*60}")
        return self.failed == 0


# ============================= BLE Client =============================

class ReSpeakerClipClient:
    """BLE client for reSpeaker Clip device"""

    def __init__(self, address: Optional[str] = None):
        self.address = address
        self.client: Optional[BleakClient] = None
        self.file_data_buffer = bytearray()
        self.transfer_progress = 0
        self.last_notification = None

    async def connect(self) -> bool:
        """Connect to the device"""
        if self.address is None:
            print("Scanning for device...")
            device = await BleakScanner.find_device_by_filter(
                lambda d, _: d.name and DEVICE_NAME_FILTER in d.name
            )
            if device is None:
                print(f"Error: Device '{DEVICE_NAME_FILTER}' not found")
                return False
            self.address = device.address
            print(f"Found device: {device.name} ({self.address})")

        self.client = BleakClient(self.address, timeout=CONNECT_TIMEOUT)

        try:
            print(f"Connecting to {self.address}...")
            await self.client.connect()
            print("Connected!")

            # Verify service
            services = self.client.services
            if SERVICE_UUID not in [str(s.uuid) for s in services]:
                print(f"Error: Service {SERVICE_UUID} not found")
                return False

            # Setup notification handler
            await self.client.start_notify(RESP_SEND_UUID, self._notification_handler)
            await self.client.start_notify(FILE_DATA_UUID, self._file_data_handler)

            return True

        except BleakError as e:
            print(f"Connection failed: {e}")
            return False

    async def disconnect(self):
        """Disconnect from the device"""
        if self.client and self.client.is_connected:
            await self.client.stop_notify(RESP_SEND_UUID)
            await self.client.stop_notify(FILE_DATA_UUID)
            await self.client.disconnect()
            print("Disconnected")

    def _notification_handler(self, sender, data: bytearray):
        """Handle notifications from response characteristic"""
        try:
            text = data.decode('utf-8').strip()
            self.last_notification = text
        except:
            self.last_notification = data.hex()

    def _file_data_handler(self, sender, data: bytearray):
        """Handle file data during transfer"""
        self.file_data_buffer.extend(data)

    async def send_command(self, command: str) -> dict:
        """Send AT command and wait for response"""
        self.last_notification = None
        self.file_data_buffer.clear()

        # Send command
        cmd_bytes = command.encode('utf-8')
        await self.client.write_gatt_char(CMD_RECV_UUID, cmd_bytes)

        # Wait for response
        for _ in range(int(COMMAND_TIMEOUT * 10)):
            await asyncio.sleep(0.1)
            if self.last_notification:
                break

        if not self.last_notification:
            raise TimeoutError(f"No response to command: {command}")

        # Parse JSON response
        try:
            response = json.loads(self.last_notification)
            return response
        except json.JSONDecodeError as e:
            raise ValueError(f"Invalid JSON response: {self.last_notification}")

    async def download_file(self, path: str, chunk_size: int = 500,
                            progress_callback: Optional[Callable] = None) -> tuple[bool, bytes]:
        """Download file from device"""
        self.file_data_buffer.clear()
        self.transfer_progress = 0

        # Start download
        response = await self.send_command(f"AT+DOWNLOAD={path}")
        if not response.get("ok"):
            return False, b""

        # Wait for file data (transmission happens in background)
        start_time = time.time()
        last_size = 0

        while time.time() - start_time < TRANSFER_TIMEOUT:
            await asyncio.sleep(0.1)

            # Check for completion notification
            if self.last_notification:
                try:
                    notif = json.loads(self.last_notification)
                    if notif.get("done"):
                        return True, bytes(self.file_data_buffer)

                    # Update progress
                    if "progress" in notif:
                        self.transfer_progress = notif["progress"]
                        if progress_callback:
                            progress_callback(self.transfer_progress)
                except json.JSONDecodeError:
                    pass

            # Check if we're still receiving data
            current_size = len(self.file_data_buffer)
            if current_size > last_size:
                last_size = current_size
                start_time = time.time()  # Reset timeout on data received

        return False, b"Timeout waiting for file transfer"

    async def wait_for_event(self, event_type: str, timeout: float = 5.0) -> Optional[dict]:
        """Wait for unsolicited event notification"""
        start_time = time.time()
        while time.time() - start_time < timeout:
            await asyncio.sleep(0.1)
            if self.last_notification:
                try:
                    notif = json.loads(self.last_notification)
                    if notif.get("event") == event_type:
                        return notif
                except json.JSONDecodeError:
                    pass
        return None


# ============================= Test Cases =============================

class BLEProtocolTests:
    """Test suite for reSpeaker Clip BLE protocol"""

    def __init__(self, client: ReSpeakerClipClient):
        self.client = client
        self.results = TestResult()

    async def test_connection(self):
        """Test basic connection"""
        name = "Connection Test"
        try:
            if self.client.client.is_connected:
                self.results.add_pass(name)
            else:
                self.results.add_fail(name, "Not connected")
        except Exception as e:
            self.results.add_fail(name, str(e))

    async def test_gstat(self):
        """Test AT+GSTAT command"""
        name = "AT+GSTAT"
        try:
            response = await self.client.send_command("AT+GSTAT")
            if response.get("ok") and "data" in response:
                data = response["data"]
                required_fields = ["state", "battery", "charging", "mode", "bitrate"]
                for field in required_fields:
                    if field not in data:
                        self.results.add_fail(name, f"Missing field: {field}")
                        return

                print(f"    State: {data['state']}")
                print(f"    Battery: {data['battery']}%")
                print(f"    Charging: {data['charging']}")
                print(f"    Mode: {data['mode']}")
                print(f"    Bitrate: {data['bitrate']}")
                self.results.add_pass(name)
            else:
                self.results.add_fail(name, f"Invalid response: {response}")
        except Exception as e:
            self.results.add_fail(name, str(e))

    async def test_version(self):
        """Test AT+VERSION command"""
        name = "AT+VERSION"
        try:
            response = await self.client.send_command("AT+VERSION")
            if response.get("ok"):
                print(f"    Firmware: {response.get('firmware')}")
                print(f"    Hardware: {response.get('hardware')}")
                print(f"    SDK: {response.get('sdk')}")
                print(f"    Build: {response.get('build')}")
                self.results.add_pass(name)
            else:
                self.results.add_fail(name, response.get("error", "Unknown error"))
        except Exception as e:
            self.results.add_fail(name, str(e))

    async def test_time(self):
        """Test AT+TIME commands"""
        name = "AT+TIME"
        try:
            # Get time
            response = await self.client.send_command("AT+TIME?")
            if response.get("ok") and "value" in response:
                print(f"    Device time: {response['value']}")
                self.results.add_pass(name)
            else:
                self.results.add_fail(name, "Failed to get time")
        except Exception as e:
            self.results.add_fail(name, str(e))

    async def test_pairing(self):
        """Test AT+PAIR command"""
        name = "AT+PAIR"
        try:
            response = await self.client.send_command("AT+PAIR?")
            if response.get("ok"):
                print(f"    Pairing status: {response.get('value')}")
                print(f"    Address: {response.get('addr', 'N/A')}")
                self.results.add_pass(name)
            else:
                self.results.add_fail(name, response.get("error", "Unknown error"))
        except Exception as e:
            self.results.add_fail(name, str(e))

    async def test_bitrate(self):
        """Test AT+BITRATE commands"""
        name = "AT+BITRATE"
        try:
            # Get current bitrate
            response = await self.client.send_command("AT+BITRATE?")
            original = response.get("value")
            print(f"    Original bitrate: {original}")

            # Set new bitrate
            await self.client.send_command("AT+BITRATE=32000")

            # Verify change
            response = await self.client.send_command("AT+BITRATE?")
            new_value = response.get("value")

            # Restore original
            await self.client.send_command(f"AT+BITRATE={original}")

            if new_value == 32000:
                self.results.add_pass(name)
            else:
                self.results.add_fail(name, f"Bitrate not changed: {new_value}")
        except Exception as e:
            self.results.add_fail(name, str(e))

    async def test_complexity(self):
        """Test AT+COMPLEXITY command"""
        name = "AT+COMPLEXITY"
        try:
            # Get current complexity
            response = await self.client.send_command("AT+COMPLEXITY?")
            original = response.get("value")
            print(f"    Original complexity: {original}")

            # Set new complexity
            await self.client.send_command("AT+COMPLEXITY=7")

            # Verify change
            response = await self.client.send_command("AT+COMPLEXITY?")
            new_value = response.get("value")

            # Restore original
            await self.client.send_command(f"AT+COMPLEXITY={original}")

            if new_value == 7:
                self.results.add_pass(name)
            else:
                self.results.add_fail(name, f"Complexity not changed: {new_value}")
        except Exception as e:
            self.results.add_fail(name, str(e))

    async def test_mode(self):
        """Test AT+MODE command"""
        name = "AT+MODE"
        try:
            # Get current mode
            response = await self.client.send_command("AT+MODE?")
            original = response.get("value")
            print(f"    Original mode: {original}")

            # Set new mode
            new_mode = "enhanced" if original == "normal" else "normal"
            await self.client.send_command(f"AT+MODE={new_mode}")

            # Verify change
            response = await self.client.send_command("AT+MODE?")
            new_value = response.get("value")

            # Restore original
            await self.client.send_command(f"AT+MODE={original}")

            if new_value == new_mode:
                self.results.add_pass(name)
            else:
                self.results.add_fail(name, f"Mode not changed: {new_value}")
        except Exception as e:
            self.results.add_fail(name, str(e))

    async def test_chunksize(self):
        """Test AT+CHUNKSIZE command"""
        name = "AT+CHUNKSIZE"
        try:
            # Get current chunk size
            response = await self.client.send_command("AT+CHUNKSIZE?")
            original = response.get("value")
            print(f"    Original chunk size: {original}")

            # Set new chunk size
            await self.client.send_command("AT+CHUNKSIZE=1000")

            # Verify change
            response = await self.client.send_command("AT+CHUNKSIZE?")
            new_value = response.get("value")

            # Restore original
            await self.client.send_command(f"AT+CHUNKSIZE={original}")

            if new_value == 1000:
                self.results.add_pass(name)
            else:
                self.results.add_fail(name, f"Chunk size not changed: {new_value}")
        except Exception as e:
            self.results.add_fail(name, str(e))

    async def test_list_sessions(self):
        """Test AT+LIST command (no parameter)"""
        name = "AT+LIST (sessions)"
        try:
            response = await self.client.send_command("AT+LIST")
            if response.get("ok") and "data" in response:
                sessions = response["data"]
                print(f"    Found {len(sessions)} session(s)")
                for session in sessions:
                    print(f"      - {session}")
                self.results.add_pass(name)
                return sessions
            else:
                self.results.add_fail(name, response.get("error", "Unknown error"))
                return []
        except Exception as e:
            self.results.add_fail(name, str(e))
            return []

    async def test_list_files(self, session: str):
        """Test AT+LIST command (with session parameter)"""
        name = f"AT+LIST ({session})"
        try:
            response = await self.client.send_command(f"AT+LIST={session}")
            if response.get("ok") and "data" in response:
                files = response["data"]
                print(f"    Found {len(files)} file(s)")
                for file in files:
                    print(f"      - {file}")
                self.results.add_pass(name)
                return files
            else:
                self.results.add_fail(name, response.get("error", "Unknown error"))
                return []
        except Exception as e:
            self.results.add_fail(name, str(e))
            return []

    async def test_recording_control(self):
        """Test recording start/stop"""
        name = "Recording Control"
        try:
            # Check current state
            response = await self.client.send_command("AT+GSTAT")
            initial_state = response["data"]["state"]

            if initial_state == "RECORDING":
                print("    Device is already recording, stopping first...")
                response = await self.client.send_command("AT+STOP")
                if not response.get("ok"):
                    self.results.add_fail(name, "Failed to stop recording")
                    return
                await asyncio.sleep(1)

            # Start recording
            print("    Starting recording...")
            response = await self.client.send_command("AT+START=normal")

            if not response.get("ok"):
                self.results.add_fail(name, f"Failed to start: {response.get('error')}")
                return

            session_id = response["data"].get("session")
            print(f"    Recording started: {session_id}")

            # Wait a bit
            await asyncio.sleep(2)

            # Stop recording
            print("    Stopping recording...")
            response = await self.client.send_command("AT+STOP")

            if not response.get("ok"):
                self.results.add_fail(name, f"Failed to stop: {response.get('error')}")
                return

            duration = response["data"].get("duration")
            print(f"    Recording stopped. Duration: {duration}s")

            self.results.add_pass(name)
            return session_id

        except Exception as e:
            self.results.add_fail(name, str(e))
            return None

    async def test_bookmarks(self):
        """Test bookmark functionality"""
        name = "Bookmark Test"
        try:
            # Check if recording
            response = await self.client.send_command("AT+GSTAT")
            state = response["data"]["state"]

            if state != "RECORDING":
                print("    Not recording, starting test recording...")
                await self.client.send_command("AT+START=normal")
                await asyncio.sleep(1)

            # Add bookmark
            print("    Adding bookmark...")
            response = await self.client.send_command("AT+MARK=Test bookmark")

            if response.get("ok"):
                data = response["data"]
                print(f"    Bookmark added at offset: {data.get('offset')}s")
                print(f"    File: {data.get('file')}")
                self.results.add_pass(name)
            else:
                self.results.add_fail(name, response.get("error", "Unknown error"))

            # Stop test recording
            await self.client.send_command("AT+STOP")

        except Exception as e:
            self.results.add_fail(name, str(e))

    async def test_file_transfer(self):
        """Test file download"""
        name = "File Transfer"
        try:
            # List sessions
            sessions = await self.test_list_sessions()
            if not sessions:
                print("    No sessions found, skipping file transfer test")
                self.results.add_pass(name + " (skipped)")
                return

            session = sessions[0]

            # List files
            files = await self.test_list_files(session)
            if not files:
                print(f"    No files in session {session}, skipping")
                self.results.add_pass(name + " (skipped)")
                return

            # Download first file
            file_path = f"{session}/{files[0]}"
            print(f"    Downloading: {file_path}")

            def progress_cb(percent):
                print(f"    Progress: {percent}%")

            success, data = await self.client.download_file(file_path, progress_callback=progress_cb)

            if success:
                print(f"    Downloaded {len(data)} bytes")
                self.results.add_pass(name)
            else:
                self.results.add_fail(name, f"Download failed: {data.decode('utf-8', errors='ignore')}")

        except Exception as e:
            self.results.add_fail(name, str(e))

    async def test_non_blocking_commands(self):
        """Test non-blocking commands during transfer"""
        name = "Non-Blocking Commands"
        try:
            # List sessions
            sessions = await self.test_list_sessions()
            if not sessions:
                self.results.add_pass(name + " (skipped - no sessions)")
                return

            session = sessions[0]
            files = await self.test_list_files(session)
            if not files:
                self.results.add_pass(name + " (skipped - no files)")
                return

            # Start download in background
            file_path = f"{session}/{files[0]}"
            print(f"    Starting download: {file_path}")

            # Start transfer (don't wait)
            download_task = asyncio.create_task(
                self.client.download_file(file_path)
            )

            # Wait a bit for transfer to start
            await asyncio.sleep(1)

            # Try to send command during transfer
            print("    Sending AT+GSTAT during transfer...")
            response = await self.client.send_command("AT+GSTAT")

            if response.get("ok") and response["data"]["state"] == "TRANSMITTING":
                print("    Command succeeded during transfer!")

                # Wait for download to complete or timeout
                try:
                    await asyncio.wait_for(download_task, timeout=30.0)
                    self.results.add_pass(name)
                except asyncio.TimeoutError:
                    self.results.add_fail(name, "Transfer timeout")
            else:
                self.results.add_fail(name, "State not TRANSMITTING during transfer")

        except Exception as e:
            self.results.add_fail(name, str(e))

    async def test_error_handling(self):
        """Test error handling"""
        name = "Error Handling"
        try:
            # Invalid command
            response = await self.client.send_command("AT+INVALID")
            if not response.get("ok"):
                print("    Invalid command rejected: ✓")
            else:
                self.results.add_fail(name, "Invalid command not rejected")
                return

            # Invalid parameter
            response = await self.client.send_command("AT+BITRATE=99999")
            if not response.get("ok"):
                print("    Invalid parameter rejected: ✓")
            else:
                self.results.add_fail(name, "Invalid parameter not rejected")
                return

            # Download non-existent file
            response = await self.client.send_command("AT+DOWNLOAD=nonexistent/file.opus")
            if not response.get("ok"):
                print("    Non-existent file rejected: ✓")
            else:
                self.results.add_fail(name, "Non-existent file not rejected")
                return

            self.results.add_pass(name)

        except Exception as e:
            self.results.add_fail(name, str(e))

    async def run_all_tests(self):
        """Run all tests"""
        print("\n" + "="*60)
        print("reSpeaker Clip BLE Protocol Test Suite")
        print("="*60)

        await self.test_connection()
        await self.test_version()
        await self.test_gstat()
        await self.test_time()
        await self.test_pairing()

        print("\n--- Configuration Tests ---")
        await self.test_bitrate()
        await self.test_complexity()
        await self.test_mode()
        await self.test_chunksize()

        print("\n--- Recording Tests ---")
        await self.test_recording_control()
        await self.test_bookmarks()

        print("\n--- File Transfer Tests ---")
        await self.test_file_transfer()
        await self.test_non_blocking_commands()

        print("\n--- Error Handling Tests ---")
        await self.test_error_handling()

        # Print summary
        return self.results.summary()


# ============================= Interactive Mode =============================

class InteractiveMode:
    """Interactive mode for manual testing"""

    def __init__(self, client: ReSpeakerClipClient):
        self.client = client
        self.running = True

    async def run(self):
        """Run interactive mode"""
        print("\n" + "="*60)
        print("reSpeaker Clip Interactive Mode")
        print("="*60)
        print("\nCommands:")
        print("  help          - Show this help")
        print("  gstat         - Get device status")
        print("  start [mode]  - Start recording (normal/enhanced)")
        print("  stop          - Stop recording")
        print("  mark [note]   - Add bookmark")
        print("  list          - List sessions")
        print("  list <session> - List session files")
        print("  download <path> - Download file")
        print("  bitrate <bps>  - Set bitrate")
        print("  mode <mode>    - Set mode (normal/enhanced)")
        print("  time          - Get device time")
        print("  version       - Get version info")
        print("  quit          - Exit")
        print("="*60)

        while self.running:
            try:
                cmd = input("\n> ").strip()
                if not cmd:
                    continue

                await self.process_command(cmd)

            except EOFError:
                print("\nExiting...")
                break
            except KeyboardInterrupt:
                print("\nUse 'quit' to exit")
            except Exception as e:
                print(f"Error: {e}")

    async def process_command(self, cmd: str):
        """Process interactive command"""
        parts = cmd.split(maxsplit=1)
        command = parts[0].lower()
        args = parts[1] if len(parts) > 1 else None

        if command == "help":
            self.show_help()

        elif command == "quit" or command == "exit":
            self.running = False

        elif command == "gstat":
            response = await self.client.send_command("AT+GSTAT")
            print(json.dumps(response, indent=2))

        elif command == "start":
            mode = args if args in ["normal", "enhanced"] else "normal"
            response = await self.client.send_command(f"AT+START={mode}")
            print(json.dumps(response, indent=2))

        elif command == "stop":
            response = await self.client.send_command("AT+STOP")
            print(json.dumps(response, indent=2))

        elif command == "mark":
            note = args or ""
            response = await self.client.send_command(f"AT+MARK={note}")
            print(json.dumps(response, indent=2))

        elif command == "list":
            if args:
                response = await self.client.send_command(f"AT+LIST={args}")
            else:
                response = await self.client.send_command("AT+LIST")
            print(json.dumps(response, indent=2))

        elif command == "download":
            if not args:
                print("Usage: download <session/file>")
                return

            print(f"Downloading {args}...")
            success, data = await self.client.download_file(args)
            if success:
                print(f"Downloaded {len(data)} bytes")
                # Save to file
                filename = args.split("/")[-1]
                with open(filename, "wb") as f:
                    f.write(data)
                print(f"Saved to {filename}")
            else:
                print(f"Download failed: {data.decode('utf-8', errors='ignore')}")

        elif command == "bitrate":
            if args:
                response = await self.client.send_command(f"AT+BITRATE={args}")
            else:
                response = await self.client.send_command("AT+BITRATE?")
            print(json.dumps(response, indent=2))

        elif command == "mode":
            if args:
                response = await self.client.send_command(f"AT+MODE={args}")
            else:
                response = await self.client.send_command("AT+MODE?")
            print(json.dumps(response, indent=2))

        elif command == "time":
            response = await self.client.send_command("AT+TIME?")
            print(json.dumps(response, indent=2))

        elif command == "version":
            response = await self.client.send_command("AT+VERSION")
            print(json.dumps(response, indent=2))

        else:
            # Try as raw AT command
            try:
                response = await self.client.send_command(cmd.upper() if cmd.startswith("at") else cmd)
                print(json.dumps(response, indent=2))
            except Exception as e:
                print(f"Unknown command: {cmd}")

    def show_help(self):
        """Show help information"""
        print("\nAvailable commands:")
        print("  gstat         - Get device status")
        print("  start [mode]  - Start recording (normal/enhanced)")
        print("  stop          - Stop recording")
        print("  mark [note]   - Add bookmark")
        print("  list          - List sessions")
        print("  list <session> - List session files")
        print("  download <path> - Download file")
        print("  bitrate <bps>  - Set/get bitrate")
        print("  mode <mode>    - Set/get mode")
        print("  time          - Get device time")
        print("  version       - Get version info")
        print("  quit          - Exit")


# ============================= Main =============================

async def main():
    """Main entry point"""
    parser = argparse.ArgumentParser(description="reSpeaker Clip BLE Test Script")
    parser.add_argument("--device", "-d", help="Device MAC address (auto-discover if not specified)")
    parser.add_argument("--test", "-t", help="Run specific test")
    parser.add_argument("--interactive", "-i", action="store_true", help="Run in interactive mode")

    args = parser.parse_args()

    # Create client
    client = ReSpeakerClipClient(args.device)

    # Connect
    if not await client.connect():
        print("Failed to connect to device")
        return 1

    try:
        if args.interactive:
            # Interactive mode
            interactive = InteractiveMode(client)
            await interactive.run()
        else:
            # Test mode
            tests = BLEProtocolTests(client)

            if args.test:
                # Run specific test
                test_method = getattr(tests, f"test_{args.test}", None)
                if test_method:
                    await test_method()
                else:
                    print(f"Unknown test: {args.test}")
                    print(f"Available tests: {[m[5:] for m in dir(tests) if m.startswith('test_')]}")
            else:
                # Run all tests
                success = await tests.run_all_tests()
                return 0 if success else 1

    finally:
        await client.disconnect()

    return 0


if __name__ == "__main__":
    exit_code = asyncio.run(main())
    exit(exit_code)
