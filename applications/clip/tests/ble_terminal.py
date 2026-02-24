#!/usr/bin/env python3
"""
Bluetooth AT Command Terminal

Interactive terminal for testing AT commands over BLE.

Usage:
    python ble_terminal.py
"""

import asyncio
import sys
from bleak import BleakClient, BleakScanner

# UUIDs
SERVICE_UUID = "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"
CMD_RECV_UUID = "6E400002-B5A3-F393-E0A9-E50E24DCCA9E"
RESP_SEND_UUID = "6E400003-B5A3-F393-E0A9-E50E24DCCA9E"

DEVICE_NAME_FILTER = "reSpeaker"


class BLETerminal:
    def __init__(self):
        self.client = None
        self.last_response = None
        self.running = True

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
        self.address = device.address
        print(f"Found: {device.name} ({self.address})")

        self.client = BleakClient(self.address, disconnected_callback=self._disconnect_callback)
        print(f"Connecting to {self.address}...")
        try:
            await self.client.connect(timeout=30.0)
            print("Connected!\n")

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
        # Print response on a new line for clarity
        print(f"\n{self.last_response}")
        # Show prompt again
        print(">> ", end="", flush=True)

    async def send_command(self, cmd, timeout=2.0):
        self.last_response = None
        print(f">> {cmd}")
        await self.client.write_gatt_char(CMD_RECV_UUID, cmd.encode('utf-8'))

        # Wait for response
        for _ in range(int(timeout * 10)):
            await asyncio.sleep(0.1)
            if self.last_response:
                return self.last_response

        return None

    async def run(self):
        """Main interactive terminal loop"""
        print("\n" + "="*50)
        print("BLE AT Command Terminal")
        print("="*50)
        print("\nType AT commands and press Enter.")
        print("Special commands:")
        print("  quit, exit, q  - Exit terminal")
        print("  help           - Show command help")
        print()

        while self.running:
            try:
                cmd = await asyncio.get_event_loop().run_in_executor(
                    None, input, ">> "
                )

                cmd = cmd.strip()
                if not cmd:
                    continue

                if cmd.lower() in ['quit', 'exit', 'q']:
                    print("Exiting...")
                    self.running = False
                    break

                if cmd.lower() == 'help':
                    self._show_help()
                    continue

                # Send command
                await self.send_command(cmd)

            except EOFError:
                print("\nExiting...")
                self.running = False
                break
            except KeyboardInterrupt:
                print("\nUse 'quit' to exit.")

    def _show_help(self):
        """Show command help"""
        print("\n" + "="*50)
        print("Available AT Commands:")
        print("="*50)
        print("\nBasic Commands:")
        print("  AT+VERSION           - Get firmware version")
        print("  AT+TIME              - Get current time")
        print("  AT+TIME=<timestamp>  - Set time (Unix timestamp)")
        print("  AT+GSTAT             - Get device status")
        print("  AT+PAIR?             - Get pairing status")
        print("\nConfiguration:")
        print("  AT+BITRATE?          - Get bitrate")
        print("  AT+BITRATE=<value>   - Set bitrate (e.g., 32000)")
        print("  AT+MODE?             - Get audio mode")
        print("  AT+MODE=<mode>       - Set mode (normal/enhanced)")
        print("  AT+COMPLEXITY?       - Get complexity")
        print("  AT+COMPLEXITY=<val>  - Set complexity (0-10)")
        print("  AT+CHUNKSIZE?        - Get chunk size")
        print("  AT+CHUNKSIZE=<val>   - Set chunk size (bytes)")
        print("\nRecording Control:")
        print("  AT+START             - Start recording")
        print("  AT+STOP              - Stop recording")
        print("  AT+MARK              - Add bookmark")
        print("\nFile Operations:")
        print("  AT+LIST              - List sessions")
        print("  AT+DOWNLOAD=<sid>    - Download session")
        print("  AT+DOWNLOAD=<sid>/<file> - Download specific file")
        print("  AT+PROGRESS          - Get transfer progress")
        print("  AT+PAUSE             - Pause transfer")
        print("  AT+RESUME            - Resume transfer")
        print("  AT+CANCEL            - Cancel transfer")
        print("\nStorage Management:")
        print("  AT+FORMAT            - Format SD card")
        print("  AT+DELETE=<sid>      - Delete session")
        print("  AT+PURGE             - Delete all sessions")
        print()


async def main():
    terminal = BLETerminal()
    if not await terminal.connect():
        return 1

    try:
        await terminal.run()
    finally:
        await terminal.disconnect()

    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
