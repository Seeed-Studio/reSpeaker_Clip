"""
Diagnostic script for BLE client testing.

Run this on Windows with the device connected to get detailed debug output.
"""

import asyncio
import sys
import threading
from pathlib import Path

# Add parent directory to path
sys.path.insert(0, str(Path(__file__).parent.parent))

from clip import ClipDevice


async def main():
    """Run diagnostic tests."""
    print("=" * 60)
    print("BLE Client Diagnostic Tool")
    print("=" * 60)
    print()

    # Show thread info
    print(f"Main thread: {threading.current_thread().name}")
    print(f"Event loop: {asyncio.get_running_loop()}")
    print()

    device = ClipDevice()

    try:
        print("Connecting to device...")
        await device.connect()
        print(f"Connected to: {device.address}")
        print(f"Event loop saved: {device._loop}")
        print()

        # Test 1: Simple command
        print("-" * 40)
        print("Test 1: AT+VERSION")
        print("-" * 40)
        print(f"Sending command from thread: {threading.current_thread().name}")

        response = await device.send_command("AT+VERSION", timeout=10)
        print(f"Response: {response}")
        print()

        # Test 2: State command
        print("-" * 40)
        print("Test 2: AT+GSTAT")
        print("-" * 40)
        response = await device.send_command("AT+GSTAT", timeout=10)
        print(f"Response: {response}")
        print()

        # Test 3: Time command
        print("-" * 40)
        print("Test 3: AT+TIME?")
        print("-" * 40)
        response = await device.send_command("AT+TIME?", timeout=10)
        print(f"Response: {response}")
        print()

        print("=" * 60)
        print("All tests PASSED!")
        print("=" * 60)

    except Exception as e:
        print()
        print("=" * 60)
        print(f"ERROR: {type(e).__name__}: {e}")
        print("=" * 60)
        import traceback
        traceback.print_exc()
    finally:
        print()
        print("Disconnecting...")
        await device.disconnect()
        print("Done.")


if __name__ == "__main__":
    asyncio.run(main())
