#!/usr/bin/env python3
"""
Bluetooth AT Command Terminal for reSpeaker Clip

Interactive terminal for testing AT commands over BLE.

Usage:
    python tools/ble_terminal.py [--device MAC_ADDRESS]
"""

import asyncio
import sys
from pathlib import Path

# Add parent directory to path for imports
sys.path.insert(0, str(Path(__file__).parent.parent))

from clip import ClipDevice, ClipCommands


class BLETerminal:
    """Interactive BLE terminal."""

    def __init__(self, address: str = None):
        self.address = address
        self.device = None
        self.commands = None
        self.running = True

    async def connect(self) -> bool:
        """Connect to device."""
        print("Scanning for device...")
        self.device = ClipDevice(address=self.address)

        try:
            await self.device.connect()
            self.commands = ClipCommands(self.device)
            self.device.event_callback = self._on_event
            print("Connected!\n")
            return True
        except Exception as e:
            print(f"Connection failed: {e}")
            return False

    def _on_event(self, event: dict):
        """Print unsolicited device events (e.g. state_change)."""
        import json
        data = event.get('data', event)
        if isinstance(data, dict) and data.get('event') == 'state_change':
            old = data.get('old', '?')
            new = data.get('new', '?')
            print(f"\n[EVENT] state_change: {old} -> {new}")
        else:
            print(f"\n[EVENT] {json.dumps(event)}")

    async def disconnect(self):
        """Disconnect from device."""
        if self.device:
            await self.device.disconnect()
            print("Disconnected")

    async def send_command(self, cmd: str) -> dict:
        """Send command and display response."""
        try:
            response = await self.device.send_command(cmd)
            return response
        except Exception as e:
            return {"ok": False, "error": str(e)}

    async def run(self):
        """Main interactive terminal loop."""
        print("\n" + "=" * 50)
        print("BLE AT Command Terminal")
        print("=" * 50)
        print("\nType AT commands and press Enter.")
        print("Special commands:")
        print("  quit, exit, q  - Exit terminal")
        print("  help           - Show command help")
        print("  status         - Show device status")
        print("  version        - Show version info")
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

                if cmd.lower() == 'status':
                    await self._show_status()
                    continue

                if cmd.lower() == 'version':
                    await self._show_version()
                    continue

                # Send as raw AT command
                response = await self.send_command(
                    cmd.upper() if cmd.upper().startswith("AT") else f"AT+{cmd.upper()}"
                )

                # Display response
                import json
                print(json.dumps(response, indent=2))

            except EOFError:
                print("\nExiting...")
                self.running = False
                break
            except KeyboardInterrupt:
                print("\nUse 'quit' to exit.")
            except Exception as e:
                print(f"Error: {e}")

    async def _show_status(self):
        """Show device status."""
        try:
            state = await self.commands.get_state()
            print(f"\n  State: {state.state}")
            print(f"  Battery: {state.battery}%")
            print(f"  Charging: {state.charging}")
            print(f"  Mode: {state.mode}")
            print(f"  Bitrate: {state.bitrate}")
            if state.session_id:
                print(f"  Session: {state.session_id}")
            if state.duration:
                print(f"  Duration: {state.duration}s")
        except Exception as e:
            print(f"Error: {e}")

    async def _show_version(self):
        """Show version info."""
        try:
            version = await self.commands.get_version()
            print(f"\n  Firmware: {version.firmware}")
            print(f"  Hardware: {version.hardware}")
            print(f"  SDK: {version.sdk}")
            print(f"  Build: {version.build}")
        except Exception as e:
            print(f"Error: {e}")

    def _show_help(self):
        """Show command help."""
        print("\n" + "=" * 50)
        print("Available AT Commands:")
        print("=" * 50)
        print("\nBasic Commands:")
        print("  AT+VERSION           - Get firmware version")
        print("  AT+TIME?             - Get current time")
        print("  AT+TIME=<timestamp>  - Set time (Unix timestamp)")
        print("  AT+GSTAT             - Get device status")
        print("  AT+PAIR?             - Get pairing status")
        print("\nConfiguration:")
        print("  AT+BITRATE?          - Get bitrate")
        print("  AT+BITRATE=<value>   - Set bitrate (e.g., 32000)")
        print("  AT+MODE?             - Get audio mode")
        print("  AT+MODE=<mode>       - Set mode (normal/enhanced/stereo/merge)")
        print("  AT+COMPLEXITY?       - Get complexity")
        print("  AT+COMPLEXITY=<val>  - Set complexity (0-10)")
        print("  AT+CHUNKSIZE?        - Get chunk size")
        print("  AT+CHUNKSIZE=<val>   - Set chunk size (bytes)")
        print("\nRecording Control:")
        print("  AT+START=<mode>      - Start recording")
        print("  AT+STOP              - Stop recording")
        print("  AT+MARK=<note>       - Add bookmark")
        print("  AT+PAUSE             - Pause recording")
        print("  AT+RESUME            - Resume recording")
        print("\nFile Operations:")
        print("  AT+LIST              - List sessions")
        print("  AT+LIST=<session>    - List session files")
        print("  AT+DOWNLOAD=<path>   - Download session or file")
        print("  AT+PROGRESS          - Get transfer progress")
        print("  AT+PAUSE             - Pause transfer")
        print("  AT+RESUME            - Resume transfer")
        print("  AT+CANCEL            - Cancel transfer")
        print("\nStorage Management:")
        print("  AT+FORMAT            - Format SD card")
        print("  AT+DELETE=<session>  - Delete session")
        print("  AT+PURGE             - Delete all sessions")
        print()


async def main():
    import argparse
    parser = argparse.ArgumentParser(description="BLE AT Command Terminal")
    parser.add_argument("--device", "-d", help="Device MAC address")
    args = parser.parse_args()

    terminal = BLETerminal(args.device)

    if not await terminal.connect():
        return 1

    try:
        await terminal.run()
    finally:
        await terminal.disconnect()

    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
