#!/usr/bin/env python3
"""
NVS Persistence Test

Tests that configuration settings persist across device reboots.

Usage:
    python test_nvs.py [--device MAC_ADDRESS]
"""

import asyncio
import sys
from bleak import BleakClient, BleakScanner

# UUIDs
SERVICE_UUID = "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"
CMD_RECV_UUID = "6E400002-B5A3-F393-E0A9-E50E24DCCA9E"
RESP_SEND_UUID = "6E400003-B5A3-F393-E0A9-E50E24DCCA9E"

DEVICE_NAME_FILTER = "reSpeaker"


class NVSTester:
    def __init__(self):
        self.client = None
        self.address = None
        self.response_data = bytearray()

    async def connect(self, device_address=None):
        """Connect to the device"""
        if device_address:
            self.address = device_address
            print(f"Connecting to {self.address}...")
        else:
            print("Scanning for device...")
            device = await BleakScanner.find_device_by_filter(
                lambda d, adv_data: DEVICE_NAME_FILTER in (adv_data.local_name or "")
            )
            if not device:
                print("Device not found!")
                return False
            self.address = device.address
            print(f"Found device: {self.address}")

        self.client = BleakClient(self.address)
        await self.client.connect()
        print("✓ Connected\n")

        # Subscribe to notifications
        await self.client.start_notify(RESP_SEND_UUID, self._notification_handler)
        return True

    async def disconnect(self):
        """Disconnect from the device"""
        if self.client and self.client.is_connected:
            await self.client.stop_notify(RESP_SEND_UUID)
            await self.client.disconnect()
            print("\n✓ Disconnected")

    def _notification_handler(self, sender, data):
        """Handle incoming notifications"""
        self.response_data.extend(data)

    async def send_command(self, cmd, timeout=5):
        """Send AT command and wait for response"""
        self.response_data.clear()

        # Send command with newline
        cmd_bytes = (cmd + "\n").encode()
        await self.client.write_gatt_char(CMD_RECV_UUID, cmd_bytes)

        # Wait for response
        for _ in range(timeout * 10):
            await asyncio.sleep(0.1)
            if len(self.response_data) > 0:
                response = self.response_data.decode().strip()
                return response

        return None

    def parse_json(self, response):
        """Parse JSON response"""
        import json
        try:
            return json.loads(response)
        except:
            return None

    async def get_mode(self):
        """Get current mode setting"""
        response = await self.send_command("AT+MODE?")
        if response:
            data = self.parse_json(response)
            if data and data.get("ok"):
                return data.get("value")
        return None

    async def get_bitrate(self):
        """Get current bitrate setting"""
        response = await self.send_command("AT+BITRATE?")
        if response:
            data = self.parse_json(response)
            if data and data.get("ok"):
                return int(data.get("value", 0))
        return None

    async def run_test(self):
        """Run the NVS persistence test"""
        print("="*60)
        print("NVS Persistence Test")
        print("="*60)

        # Step 1: Get initial settings
        print("\n=== Step 1: Read initial settings ===")
        initial_mode = await self.get_mode()
        initial_bitrate = await self.get_bitrate()
        print(f"  Initial mode: {initial_mode}")
        print(f"  Initial bitrate: {initial_bitrate}")

        # Step 2: Set new values
        print("\n=== Step 2: Set new values ===")
        test_mode = "normal"
        test_bitrate = 64000

        print(f"  Setting mode to: {test_mode}")
        response = await self.send_command(f"AT+MODE={test_mode}")
        print(f"  Response: {response}")

        print(f"  Setting bitrate to: {test_bitrate}")
        response = await self.send_command(f"AT+BITRATE={test_bitrate}")
        print(f"  Response: {response}")

        # Verify they were set
        current_mode = await self.get_mode()
        current_bitrate = await self.get_bitrate()
        print(f"  ✓ Mode is now: {current_mode}")
        print(f"  ✓ Bitrate is now: {current_bitrate}")

        if current_mode != test_mode or current_bitrate != test_bitrate:
            print("\n✗ Failed to set values!")
            return False

        # Step 3: Ask user to reboot device
        print("\n" + "="*60)
        print("Step 3: REBOOT THE DEVICE NOW")
        print("="*60)
        print("Please power cycle the device (turn off and on again)")
        print("Then press Enter to continue...")
        input()

        # Reconnect
        print("\n=== Reconnecting to device ===")
        await self.disconnect()
        await asyncio.sleep(1)
        if not await self.connect():
            print("✗ Failed to reconnect!")
            return False

        # Step 4: Verify settings persisted
        print("\n=== Step 4: Verify settings persisted ===")
        persisted_mode = await self.get_mode()
        persisted_bitrate = await self.get_bitrate()
        print(f"  Mode after reboot: {persisted_mode}")
        print(f"  Bitrate after reboot: {persisted_bitrate}")

        # Check if values match
        mode_ok = persisted_mode == test_mode
        bitrate_ok = persisted_bitrate == test_bitrate

        print("\n" + "="*60)
        print("Test Results")
        print("="*60)
        print(f"  Mode: {'✓ PASS' if mode_ok else '✗ FAIL'}")
        print(f"    Expected: {test_mode}")
        print(f"    Got:      {persisted_mode}")
        print(f"  Bitrate: {'✓ PASS' if bitrate_ok else '✗ FAIL'}")
        print(f"    Expected: {test_bitrate}")
        print(f"    Got:      {persisted_bitrate}")
        print("="*60)

        if mode_ok and bitrate_ok:
            print("\n✓✓✓ NVS TEST PASSED! ✓✓✓")
            print("Configuration correctly persisted across reboot.")
            return True
        else:
            print("\n✗✗✗ NVS TEST FAILED! ✗✗✗")
            print("Configuration was NOT persisted.")
            return False


async def main():
    import argparse
    parser = argparse.ArgumentParser(description="NVS Persistence Test")
    parser.add_argument("--device", help="Device MAC address (optional)")
    args = parser.parse_args()

    tester = NVSTester()

    try:
        if not await tester.connect(args.device):
            return 1

        success = await tester.run_test()
        return 0 if success else 1

    except KeyboardInterrupt:
        print("\n[!] Test interrupted by user")
        return 1
    except Exception as e:
        print(f"\n[!] Error: {e}")
        import traceback
        traceback.print_exc()
        return 1
    finally:
        await tester.disconnect()


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
