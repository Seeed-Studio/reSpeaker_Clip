#!/usr/bin/env python3
"""
UDP AT Command Terminal for reSpeaker Clip WiFi AP

Interactive terminal for testing AT commands over UDP.
Device must be connected to the Clip's WiFi AP first.

WiFi AP Configuration:
- SSID: ClipAP_XXXX (XXXX = chip ID suffix)
- Password: 12345678
- IP: 192.168.4.1
- UDP Port: 8089

Usage:
    # Connect to WiFi AP first, then:
    python tests/tools/udp_terminal.py [--host 192.168.4.1] [--port 8089]
"""

import asyncio
import socket
import sys
import json
from pathlib import Path


class UDPTerminal:
    """Interactive UDP terminal for AT commands."""

    def __init__(self, host: str = "192.168.4.1", port: int = 8089, timeout: float = 2.0):
        self.host = host
        self.port = port
        self.timeout = timeout
        self.sock = None
        self.running = True

    def connect(self) -> bool:
        """Create UDP socket."""
        try:
            self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            self.sock.settimeout(self.timeout)
            print(f"UDP terminal ready: {self.host}:{self.port}")
            print("(Make sure you're connected to the Clip's WiFi AP)\n")
            return True
        except Exception as e:
            print(f"Failed to create socket: {e}")
            return False

    def disconnect(self):
        """Close socket."""
        if self.sock:
            self.sock.close()
            self.sock = None
            print("Connection closed")

    def send_command(self, cmd: str) -> dict:
        """Send AT command and return response."""
        try:
            # Strip whitespace and ensure AT prefix
            cmd = cmd.strip()
            if not cmd:
                return {"ok": False, "error": "Empty command"}

            # Add AT+ prefix if not present
            if not cmd.upper().startswith("AT"):
                cmd = f"AT+{cmd}"

            # Send command
            data = cmd.encode('utf-8')
            self.sock.sendto(data, (self.host, self.port))

            # Receive response
            resp_data, _ = self.sock.recvfrom(4096)
            response = resp_data.decode('utf-8', errors='ignore')

            # Parse JSON response
            try:
                return json.loads(response)
            except json.JSONDecodeError:
                # Return raw response if not JSON
                return {"ok": True, "raw": response}

        except socket.timeout:
            return {"ok": False, "error": "Timeout waiting for response"}
        except Exception as e:
            return {"ok": False, "error": str(e)}

    def run_interactive(self):
        """Main interactive terminal loop."""
        print("=" * 50)
        print("UDP AT Command Terminal")
        print("=" * 50)
        print(f"\nTarget: {self.host}:{self.port}")
        print("\nType AT commands and press Enter.")
        print("Special commands:")
        print("  quit, exit, q  - Exit terminal")
        print("  help           - Show command help")
        print("  status         - Show device status")
        print("  version        - Show version info")
        print("  test           - Run connection test")
        print()

        while self.running:
            try:
                cmd = input(">> ").strip()
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
                    self._send_and_show("AT+GSTAT")
                    continue

                if cmd.lower() == 'version':
                    self._send_and_show("AT+VERSION")
                    continue

                if cmd.lower() == 'test':
                    self._run_test()
                    continue

                # Send command and display response
                response = self.send_command(cmd)
                print(json.dumps(response, indent=2))
                print()

            except EOFError:
                print("\nExiting...")
                self.running = False
                break
            except KeyboardInterrupt:
                print()
                continue
            except Exception as e:
                print(f"Error: {e}")

    def _send_and_show(self, cmd: str):
        """Send command and pretty-print response."""
        response = self.send_command(cmd)
        if response.get("ok"):
            data = response.get("data", response)
            if isinstance(data, dict):
                print(json.dumps(data, indent=2))
            else:
                print(data)
        else:
            print(f"Error: {response.get('error', 'Unknown error')}")

    def _run_test(self):
        """Run connection test."""
        print("\n--- Connection Test ---")
        try:
            # Test GSTAT command
            print("Sending AT+GSTAT...")
            response = self.send_command("AT+GSTAT")
            if response.get("ok"):
                print("  ✓ Device responding")
                data = response.get("data", {})
                if isinstance(data, dict):
                    state = data.get("state", "unknown")
                    print(f"  State: {state}")
            else:
                print(f"  ✗ Error: {response.get('error')}")

            # Test VERSION command
            print("\nSending AT+VERSION...")
            response = self.send_command("AT+VERSION")
            if response.get("ok"):
                print("  ✓ Version info received")
                data = response.get("data", {})
                if isinstance(data, dict):
                    fw = data.get("firmware", "unknown")
                    print(f"  Firmware: {fw}")
            else:
                print(f"  ✗ Error: {response.get('error')}")

            print("\nTest complete!")
        except Exception as e:
            print(f"Test failed: {e}")
        print()

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
        print("\nWiFi AP Commands:")
        print("  AT+WIFIAP            - Start WiFi AP")
        print("  AT+WIFIAP=stop       - Stop WiFi AP")
        print("  AT+WIFIAP?           - Get WiFi AP status")
        print("\nStorage Management:")
        print("  AT+FORMAT            - Format SD card")
        print("  AT+DELETE=<session>  - Delete session")
        print("  AT+PURGE             - Delete all sessions")
        print()


def main():
    import argparse
    parser = argparse.ArgumentParser(
        description="UDP AT Command Terminal for reSpeaker Clip",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Default (192.168.4.1:8089)
  python udp_terminal.py

  # Custom host and port
  python udp_terminal.py --host 192.168.4.10 --port 9090

  # Quick command execution
  python -c "from udp_terminal import UDPTerminal; t=UDPTerminal(); t.connect(); print(t.send_command('AT+GSTAT'))"
        """
    )
    parser.add_argument("--host", "-H", default="192.168.4.1",
                       help="Device IP address (default: 192.168.4.1)")
    parser.add_argument("--port", "-p", type=int, default=8089,
                       help="UDP port (default: 8089)")
    parser.add_argument("--timeout", "-t", type=float, default=2.0,
                       help="Response timeout in seconds (default: 2.0)")
    parser.add_argument("--command", "-c", help="Send single command and exit")
    args = parser.parse_args()

    terminal = UDPTerminal(host=args.host, port=args.port, timeout=args.timeout)

    if not terminal.connect():
        return 1

    try:
        if args.command:
            # Single command mode
            response = terminal.send_command(args.command)
            print(json.dumps(response, indent=2))
        else:
            # Interactive mode
            terminal.run_interactive()
    finally:
        terminal.disconnect()

    return 0


if __name__ == "__main__":
    sys.exit(main())
