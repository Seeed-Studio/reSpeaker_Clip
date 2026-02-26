#!/usr/bin/env python3
"""
NVS Persistence Test - Fully Automated

Tests that ALL configuration settings persist across device reboots.

This test is FULLY AUTOMATED - it uses AT+REBOOT to restart the device.

Configuration items tested:
- bitrate, complexity, mode, noise_suppress, chunk_size
- auto_delete_days, agc_enabled, agc_target, dereverb_enabled

Usage:
    python test_nvs.py [--device MAC_ADDRESS]
"""

import asyncio
import sys
import json
from bleak import BleakClient, BleakScanner
from typing import Dict, Any, Optional, Tuple

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

    async def connect(self, device_address=None) -> bool:
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

    async def send_command(self, cmd: str, timeout: int = 5) -> Optional[str]:
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

    def parse_json(self, response: str) -> Optional[Dict[str, Any]]:
        """Parse JSON response"""
        try:
            return json.loads(response)
        except:
            return None

    async def get_setting(self, cmd: str) -> Optional[Any]:
        """Get a setting value via AT command"""
        response = await self.send_command(cmd)
        if response:
            data = self.parse_json(response)
            if data and data.get("ok"):
                return data.get("value") or data.get("data")
        return None

    async def set_setting(self, cmd: str) -> bool:
        """Set a setting value via AT command"""
        response = await self.send_command(cmd)
        if response:
            data = self.parse_json(response)
            return data and data.get("ok")
        return False

    # Configuration getters
    async def get_bitrate(self) -> Optional[int]:
        data = await self.parse_command("AT+BITRATE?")
        if data and data.get("ok"):
            # Handle both {"value":...} and {"data":{"value":...}} formats
            val = data.get("value")
            if val is None:
                val = data.get("data", {}).get("value")
            return int(val) if val is not None else None
        return None

    async def get_complexity(self) -> Optional[int]:
        data = await self.parse_command("AT+COMPLEXITY?")
        if data and data.get("ok"):
            val = data.get("value")
            if val is None:
                val = data.get("data", {}).get("value")
            return int(val) if val is not None else None
        return None

    async def get_mode(self) -> Optional[str]:
        data = await self.parse_command("AT+MODE?")
        if data and data.get("ok"):
            val = data.get("value")
            if val is None:
                val = data.get("data", {}).get("value")
            return val
        return None

    async def get_noise_suppress(self) -> Optional[int]:
        data = await self.parse_command("AT+NOISE?")
        if data and data.get("ok"):
            val = data.get("value")
            if val is None:
                val = data.get("data", {}).get("value")
            return int(val) if val is not None else None
        return None

    async def get_chunk_size(self) -> Optional[int]:
        data = await self.parse_command("AT+CHUNKSIZE?")
        if data and data.get("ok"):
            val = data.get("value")
            if val is None:
                val = data.get("data", {}).get("value")
            return int(val) if val is not None else None
        return None

    async def get_auto_delete(self) -> Optional[Any]:
        data = await self.parse_command("AT+AUTODEL?")
        if data and data.get("ok"):
            val = data.get("value")
            if val is None:
                val = data.get("data", {}).get("value")
            return val
        return None

    async def get_agc(self) -> Optional[Dict[str, Any]]:
        """Get AGC settings (enabled and target)"""
        return await self.parse_command("AT+AGC?")

    async def get_dereverb(self) -> Optional[Dict[str, Any]]:
        """Get dereverb settings (enabled, level, decay)"""
        return await self.parse_command("AT+DEREVERB?")

    # Helper to parse command and return JSON data
    async def parse_command(self, cmd: str) -> Optional[Dict[str, Any]]:
        """Send command and return parsed JSON data"""
        response = await self.send_command(cmd)
        if response:
            return self.parse_json(response)
        return None

    # Configuration setters
    async def set_bitrate(self, value: int) -> bool:
        return await self.set_setting(f"AT+BITRATE={value}")

    async def set_complexity(self, value: int) -> bool:
        return await self.set_setting(f"AT+COMPLEXITY={value}")

    async def set_mode(self, value: str) -> bool:
        return await self.set_setting(f"AT+MODE={value}")

    async def set_noise_suppress(self, value: int) -> bool:
        return await self.set_setting(f"AT+NOISE={value}")

    async def set_chunk_size(self, value: int) -> bool:
        return await self.set_setting(f"AT+CHUNKSIZE={value}")

    async def set_auto_delete(self, value: str) -> bool:
        return await self.set_setting(f"AT+AUTODEL={value}")

    async def set_agc(self, enabled: bool, target: int = 20) -> bool:
        return await self.set_setting(f"AT+AGC={'on' if enabled else 'off'},{target}")

    async def set_dereverb(self, enabled: bool, level: int = 5, decay: int = 0) -> bool:
        return await self.set_setting(f"AT+DEREVERB={'on' if enabled else 'off'},{level},{decay}")

    async def get_all_settings(self) -> Dict[str, Any]:
        """Get all current settings"""
        settings = {}

        settings["bitrate"] = await self.get_bitrate()
        settings["complexity"] = await self.get_complexity()
        settings["mode"] = await self.get_mode()
        settings["noise_suppress"] = await self.get_noise_suppress()
        settings["chunk_size"] = await self.get_chunk_size()

        auto_del = await self.get_auto_delete()
        if isinstance(auto_del, dict):
            # Check both formats: {"value":...} or {"data":{"value":...}}
            val = auto_del.get("value")
            if val is None:
                val = auto_del.get("data", {}).get("value")
            # Convert "off" string to -1 for consistency
            if val == "off":
                settings["auto_delete_days"] = -1
            else:
                settings["auto_delete_days"] = val
        else:
            settings["auto_delete_days"] = auto_del

        agc = await self.get_agc()
        if agc and isinstance(agc, dict):
            agc_data = agc.get("data", {})
            settings["agc_enabled"] = agc_data.get("enabled")
            settings["agc_target"] = agc_data.get("target")

        dereverb = await self.get_dereverb()
        if dereverb and isinstance(dereverb, dict):
            dereverb_data = dereverb.get("data", {})
            settings["dereverb_enabled"] = dereverb_data.get("enabled")

        return settings

    async def run_test(self) -> bool:
        """Run the complete NVS persistence test"""
        print("="*70)
        print("NVS Persistence Test - All Configuration Items")
        print("="*70)

        # Test values for each setting
        test_values = {
            "bitrate": 64000,
            "complexity": 5,
            "mode": "normal",
            "noise_suppress": 30,
            "chunk_size": 1000,
            "auto_delete_days": "off",
            "agc_enabled": True,
            "agc_target": 25,
            "dereverb_enabled": True,
        }

        # Step 1: Read initial settings
        print("\n=== Step 1: Reading initial settings ===")
        initial = await self.get_all_settings()
        for key, value in initial.items():
            print(f"  {key:20s}: {value}")

        # Step 2: Set new values
        print("\n=== Step 2: Setting test values ===")
        print("  Setting bitrate to 64000...")
        if not await self.set_bitrate(test_values["bitrate"]):
            print("  ✗ Failed to set bitrate")
            return False

        print("  Setting complexity to 5...")
        if not await self.set_complexity(test_values["complexity"]):
            print("  ✗ Failed to set complexity")
            return False

        print("  Setting mode to normal...")
        if not await self.set_mode(test_values["mode"]):
            print("  ✗ Failed to set mode")
            return False

        print("  Setting noise_suppress to 30...")
        if not await self.set_noise_suppress(test_values["noise_suppress"]):
            print("  ✗ Failed to set noise_suppress")
            return False

        print("  Setting chunk_size to 1000...")
        if not await self.set_chunk_size(test_values["chunk_size"]):
            print("  ✗ Failed to set chunk_size")
            return False

        print("  Setting auto_delete_days to off...")
        if not await self.set_auto_delete(test_values["auto_delete_days"]):
            print("  ✗ Failed to set auto_delete_days")
            return False

        print("  Setting AGC to on,25...")
        if not await self.set_agc(test_values["agc_enabled"], test_values["agc_target"]):
            print("  ✗ Failed to set AGC")
            return False

        print("  Setting dereverb to on,5,0...")
        if not await self.set_dereverb(test_values["dereverb_enabled"], 5, 0):
            print("  ✗ Failed to set dereverb")
            return False

        print("  ✓ All settings applied")

        # Verify before reboot
        print("\n=== Step 3: Verifying settings before reboot ===")
        before_reboot = await self.get_all_settings()
        for key, value in before_reboot.items():
            print(f"  {key:20s}: {value}")

        # Step 4: Reboot device automatically
        print("\n" + "="*70)
        print("Step 4: Rebooting device (AT+REBOOT)")
        print("="*70)

        response = await self.send_command("AT+REBOOT")
        if response:
            data = self.parse_json(response)
            if data and data.get("ok"):
                print("  ✓ Reboot command sent")
            else:
                print(f"  ✗ Reboot command failed: {response}")
                return False
        else:
            print("  ✗ No response to REBOOT command")
            return False

        # Wait for device to disconnect and reboot
        print("  Waiting for device to reboot...")
        await self.disconnect()
        await asyncio.sleep(3)  # Wait for reboot

        # Reconnect
        print("\n=== Reconnecting to device ===")
        reconnect_attempts = 0
        max_reconnect_attempts = 10

        while reconnect_attempts < max_reconnect_attempts:
            await asyncio.sleep(1)
            reconnect_attempts += 1
            print(f"  Attempt {reconnect_attempts}/{max_reconnect_attempts}...", end="\r")

            if await self.connect():
                print(f"\n  ✓ Reconnected after {reconnect_attempts} attempts")
                break
        else:
            print(f"\n✗ Failed to reconnect after {max_reconnect_attempts} attempts")
            return False

        # Step 5: Read settings after reboot
        print("\n=== Step 5: Reading settings after reboot ===")
        after_reboot = await self.get_all_settings()
        for key, value in after_reboot.items():
            print(f"  {key:20s}: {value}")

        # Step 6: Compare and report results
        print("\n" + "="*70)
        print("Test Results")
        print("="*70)

        results = []
        all_passed = True

        # Check each setting
        checks = [
            ("bitrate", test_values["bitrate"], after_reboot.get("bitrate")),
            ("complexity", test_values["complexity"], after_reboot.get("complexity")),
            ("mode", test_values["mode"], after_reboot.get("mode")),
            ("noise_suppress", test_values["noise_suppress"], after_reboot.get("noise_suppress")),
            ("chunk_size", test_values["chunk_size"], after_reboot.get("chunk_size")),
            ("auto_delete_days", -1, -1 if after_reboot.get("auto_delete_days") in ["off", "off", None] else after_reboot.get("auto_delete_days")),
            ("agc_enabled", test_values["agc_enabled"], after_reboot.get("agc_enabled")),
            ("agc_target", test_values["agc_target"], after_reboot.get("agc_target")),
            ("dereverb_enabled", test_values["dereverb_enabled"], after_reboot.get("dereverb_enabled")),
        ]

        print("\n┌─────────────────────┬──────────┬──────────┬────────┐")
        print("│ Setting             │ Expected │ Got      │ Result │")
        print("├─────────────────────┼──────────┼──────────┼────────┤")

        for name, expected, actual in checks:
            passed = (expected == actual)
            status = "✓ PASS" if passed else "✗ FAIL"
            all_passed = all_passed and passed

            # Format for display
            exp_str = str(expected) if expected is not None else "N/A"
            act_str = str(actual) if actual is not None else "N/A"

            print(f"│ {name:19s} │ {exp_str:8s} │ {act_str:8s} │ {status:6s} │")
            results.append((name, passed, expected, actual))

        print("└─────────────────────┴──────────┴──────────┴────────┘")

        # Summary
        passed_count = sum(1 for _, p, _, _ in results if p)
        total_count = len(results)

        print("\n" + "="*70)
        if all_passed:
            print(f"✓✓✓ ALL TESTS PASSED! ({passed_count}/{total_count}) ✓✓✓")
            print("All configuration items correctly persisted across reboot.")
        else:
            print(f"✗✗✗ SOME TESTS FAILED! ({passed_count}/{total_count} passed) ✗✗✗")
            print("\nFailed settings:")
            for name, passed, expected, actual in results:
                if not passed:
                    print(f"  - {name}: expected {expected}, got {actual}")
        print("="*70)

        return all_passed


async def main():
    import argparse
    parser = argparse.ArgumentParser(description="NVS Persistence Test - All Configuration Items")
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
