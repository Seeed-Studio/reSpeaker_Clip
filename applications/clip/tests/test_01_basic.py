#!/usr/bin/env python3
"""
Basic AT Commands Test - Test 1

Tests basic commands: VERSION, TIME, GSTAT, PAIR

Usage:
    python test_01_basic.py [--device MAC_ADDRESS]
"""

import asyncio
import json
import argparse
from bleak import BleakClient, BleakScanner

# UUIDs
SERVICE_UUID = "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"
CMD_RECV_UUID = "6E400002-B5A3-F393-E0A9-E50E24DCCA9E"
RESP_SEND_UUID = "6E400003-B5A3-F393-E0A9-E50E24DCCA9E"

DEVICE_NAME_FILTER = "reSpeaker"

class ClipClient:
    def __init__(self, address=None):
        self.address = address
        self.client = None
        self.last_response = None

    def _disconnect_callback(self, client):
        print(f"\n[!] Device disconnected")

    async def connect(self):
        if not self.address:
            print("Scanning...")
            device = await BleakScanner.find_device_by_filter(
                lambda d, _: d.name and DEVICE_NAME_FILTER in d.name
            )
            if not device:
                print(f"Device '{DEVICE_NAME_FILTER}' not found")
                return False
            self.address = device.address
            print(f"Found: {device.name} ({self.address})")

        self.client = BleakClient(self.address, disconnected_callback=self._disconnect_callback)
        print(f"Connecting to {self.address}...")
        try:
            await self.client.connect(timeout=30.0)
            print("Connected!")

            await self.client.start_notify(RESP_SEND_UUID, self._notification_handler)
            # Small delay to ensure notifications are ready
            await asyncio.sleep(0.2)
            return True
        except Exception as e:
            print(f"Connection failed: {e}")
            return False

    async def disconnect(self):
        if self.client and self.client.is_connected:
            await self.client.stop_notify(RESP_SEND_UUID)
            await self.client.disconnect()
            print("Disconnected")

    def _notification_handler(self, sender, data):
        self.last_response = data.decode('utf-8').strip()
        print(f"    <- {self.last_response}")

    async def send_command(self, cmd, timeout=2.0):
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

async def test_version(client):
    """Test AT+VERSION command"""
    print("\n=== Test: AT+VERSION ===")
    response = await client.send_command("AT+VERSION")
    if response.get("ok"):
        print(f"✓ Firmware: {response.get('firmware')}")
        return True
    else:
        print(f"✗ Failed: {response.get('error')}")
        return False

async def test_time(client):
    """Test AT+TIME commands"""
    print("\n=== Test: AT+TIME ===")

    # Get time
    print("\n1. Get current time:")
    response = await client.send_command("AT+TIME?")
    if response.get("ok") and "time" in response:
        print(f"✓ Device time: {response['time']}")
    else:
        print(f"✗ Failed to get time: {response}")

    # Set time
    print("\n2. Set time (Unix timestamp):")
    import time
    current_ts = int(time.time())
    response = await client.send_command(f"AT+TIME={current_ts}")
    if response.get("ok"):
        print(f"✓ Time set to: {response['time']}")
    else:
        print(f"✗ Failed to set time: {response.get('error')}")
        return False

    # Verify
    print("\n3. Verify time was set:")
    response = await client.send_command("AT+TIME?")
    if response.get("ok") and "time" in response:
        print(f"✓ Device time: {response['time']}")
        return True
    else:
        print(f"✗ Failed: {response}")
        return False

async def test_gstat(client):
    """Test AT+GSTAT command"""
    print("\n=== Test: AT+GSTAT ===")
    response = await client.send_command("AT+GSTAT")
    if response.get("ok") and "data" in response:
        data = response["data"]
        print(f"✓ State: {data['state']}")
        print(f"  Battery: {data['battery']}%")
        print(f"  Charging: {data['charging']}")
        print(f"  Mode: {data['mode']}")
        print(f"  Bitrate: {data['bitrate']}")
        return True
    else:
        print(f"✗ Failed: {response}")
        return False

async def test_pairing(client):
    """Test AT+PAIR command"""
    print("\n=== Test: AT+PAIR ===")
    response = await client.send_command("AT+PAIR?")
    if response.get("ok"):
        print(f"✓ Pairing status: {response.get('value', 'N/A')}")
        print(f"  Address: {response.get('addr', 'N/A')}")
        return True
    else:
        print(f"✗ Failed: {response.get('error')}")
        return False

async def main():
    parser = argparse.ArgumentParser(description="Basic AT Commands Test")
    parser.add_argument("--device", "-d", help="Device MAC address")
    args = parser.parse_args()

    client = ClipClient(args.device)
    if not await client.connect():
        return 1

    try:
        print("\n" + "="*50)
        print("Basic AT Commands Test")
        print("="*50)

        results = []
        results.append(await test_version(client))
        results.append(await test_time(client))
        results.append(await test_gstat(client))
        results.append(await test_pairing(client))

        print("\n" + "="*50)
        print(f"Results: {sum(results)}/{len(results)} passed")
        print("="*50)

    finally:
        await client.disconnect()

if __name__ == "__main__":
    asyncio.run(main())
