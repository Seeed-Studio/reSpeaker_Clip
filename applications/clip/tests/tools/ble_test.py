#!/usr/bin/env python3
"""
reSpeaker Clip BLE Protocol Test Script

Tests the BLE AT command protocol using the clip library.

Usage:
    python tools/ble_test.py [--device MAC_ADDRESS] [--test TEST_NAME]
"""

import asyncio
import sys
import time
from pathlib import Path

# Add parent directory to path for imports
sys.path.insert(0, str(Path(__file__).parent.parent))

from clip import ClipDevice, ClipCommands


class TestResult:
    """Store test results."""
    def __init__(self):
        self.passed = 0
        self.failed = 0
        self.errors = []

    def add_pass(self, name: str):
        self.passed += 1
        print(f"  ✓ {name}")

    def add_fail(self, name: str, reason: str):
        self.failed += 1
        self.errors.append((name, reason))
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


class BLEProtocolTests:
    """Test suite for reSpeaker Clip BLE protocol."""

    def __init__(self, device: ClipDevice):
        self.device = device
        self.commands = ClipCommands(device)
        self.results = TestResult()

    async def test_connection(self):
        """Test basic connection."""
        name = "Connection Test"
        try:
            if self.device.is_connected:
                self.results.add_pass(name)
            else:
                self.results.add_fail(name, "Not connected")
        except Exception as e:
            self.results.add_fail(name, str(e))

    async def test_version(self):
        """Test AT+VERSION command."""
        name = "AT+VERSION"
        try:
            version = await self.commands.get_version()
            print(f"    Firmware: {version.firmware}")
            print(f"    Hardware: {version.hardware}")
            print(f"    SDK: {version.sdk}")
            self.results.add_pass(name)
        except Exception as e:
            self.results.add_fail(name, str(e))

    async def test_gstat(self):
        """Test AT+GSTAT command."""
        name = "AT+GSTAT"
        try:
            state = await self.commands.get_state()
            print(f"    State: {state.state}")
            print(f"    Battery: {state.battery}%")
            print(f"    Charging: {state.charging}")
            print(f"    Mode: {state.mode}")
            print(f"    Bitrate: {state.bitrate}")
            self.results.add_pass(name)
        except Exception as e:
            self.results.add_fail(name, str(e))

    async def test_time(self):
        """Test AT+TIME commands."""
        name = "AT+TIME"
        try:
            timestamp = await self.commands.get_time()
            print(f"    Device time: {timestamp}")

            # Set time
            await self.commands.set_time(int(time.time()))
            self.results.add_pass(name)
        except Exception as e:
            self.results.add_fail(name, str(e))

    async def test_bitrate(self):
        """Test AT+BITRATE commands."""
        name = "AT+BITRATE"
        try:
            original = await self.commands.get_bitrate()
            print(f"    Original bitrate: {original}")

            await self.commands.set_bitrate(32000)
            new_value = await self.commands.get_bitrate()

            await self.commands.set_bitrate(original)

            if new_value == 32000:
                self.results.add_pass(name)
            else:
                self.results.add_fail(name, f"Bitrate not changed: {new_value}")
        except Exception as e:
            self.results.add_fail(name, str(e))

    async def test_mode(self):
        """Test AT+MODE command."""
        name = "AT+MODE"
        try:
            original = await self.commands.get_mode()
            print(f"    Original mode: {original}")

            new_mode = "enhanced" if original == "normal" else "normal"
            await self.commands.set_mode(new_mode)

            new_value = await self.commands.get_mode()
            await self.commands.set_mode(original)

            if new_value == new_mode:
                self.results.add_pass(name)
            else:
                self.results.add_fail(name, f"Mode not changed: {new_value}")
        except Exception as e:
            self.results.add_fail(name, str(e))

    async def test_list_sessions(self):
        """Test AT+LIST command."""
        name = "AT+LIST"
        try:
            sessions = await self.commands.list_sessions()
            print(f"    Found {len(sessions)} session(s)")
            for session in sessions[:3]:  # Show first 3
                print(f"      - {session.id}: {session.files} files")
            self.results.add_pass(name)
            return sessions
        except Exception as e:
            self.results.add_fail(name, str(e))
            return []

    async def test_recording_control(self):
        """Test recording start/stop."""
        name = "Recording Control"
        try:
            # Ensure idle
            await self.commands.ensure_idle()

            # Start recording
            print("    Starting recording...")
            session_id = await self.commands.start_recording("normal")
            print(f"    Recording started: {session_id}")

            # Wait a bit
            await asyncio.sleep(2)

            # Stop recording
            print("    Stopping recording...")
            result = await self.commands.stop_recording()
            duration = result.get("duration", 0)
            print(f"    Recording stopped. Duration: {duration}s")

            self.results.add_pass(name)
            return session_id
        except Exception as e:
            self.results.add_fail(name, str(e))
            return None

    async def test_bookmarks(self):
        """Test bookmark functionality."""
        name = "Bookmark Test"
        try:
            await self.commands.ensure_idle()

            # Start recording
            await self.commands.start_recording("normal")
            await asyncio.sleep(1)

            # Add bookmark
            print("    Adding bookmark...")
            bookmark = await self.commands.add_bookmark("Test bookmark")
            print(f"    Bookmark at offset: {bookmark.offset}s")

            await self.commands.stop_recording()
            self.results.add_pass(name)
        except Exception as e:
            self.results.add_fail(name, str(e))

    async def test_error_handling(self):
        """Test error handling."""
        name = "Error Handling"
        try:
            # Invalid command
            response = await self.device.send_command("AT+INVALID")
            if not response.get("ok"):
                print("    Invalid command rejected: ✓")
            else:
                self.results.add_fail(name, "Invalid command not rejected")
                return

            # Invalid parameter
            original = await self.commands.get_bitrate()
            try:
                await self.commands.set_bitrate(99999)
                self.results.add_fail(name, "Invalid parameter not rejected")
            except Exception:
                print("    Invalid parameter rejected: ✓")
            finally:
                await self.commands.set_bitrate(original)

            self.results.add_pass(name)
        except Exception as e:
            self.results.add_fail(name, str(e))

    async def run_all_tests(self):
        """Run all tests."""
        print("\n" + "="*60)
        print("reSpeaker Clip BLE Protocol Test Suite")
        print("="*60)

        await self.test_connection()
        await self.test_version()
        await self.test_gstat()
        await self.test_time()

        print("\n--- Configuration Tests ---")
        await self.test_bitrate()
        await self.test_mode()

        print("\n--- Recording Tests ---")
        await self.test_recording_control()
        await self.test_bookmarks()

        print("\n--- Error Handling Tests ---")
        await self.test_error_handling()

        return self.results.summary()


async def main():
    import argparse
    parser = argparse.ArgumentParser(description="reSpeaker Clip BLE Test Script")
    parser.add_argument("--device", "-d", help="Device MAC address")
    parser.add_argument("--test", "-t", help="Run specific test")

    args = parser.parse_args()

    # Create client
    print("Connecting to device...")
    device = ClipDevice(address=args.device)

    try:
        await device.connect()
    except Exception as e:
        print(f"Failed to connect: {e}")
        return 1

    try:
        tests = BLEProtocolTests(device)

        if args.test:
            test_method = getattr(tests, f"test_{args.test}", None)
            if test_method:
                await test_method()
            else:
                print(f"Unknown test: {args.test}")
                print(f"Available tests: {[m[5:] for m in dir(tests) if m.startswith('test_')]}")
                return 1
        else:
            success = await tests.run_all_tests()
            return 0 if success else 1
    finally:
        await device.disconnect()


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
