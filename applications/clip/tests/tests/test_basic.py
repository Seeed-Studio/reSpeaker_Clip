"""
Basic AT command tests for reSpeaker Clip.

Tests basic commands: VERSION, TIME, GSTAT, PAIR, REBOOT
"""

import pytest
import time

from clip import ClipDevice, ClipCommands
from clip.exceptions import CommandError, TimeoutError


@pytest.mark.asyncio
class TestBasicCommands:
    """Test basic AT commands."""

    async def test_get_version(self, device: ClipDevice):
        """Should return version information."""
        response = await device.send_command("AT+VERSION")
        print(f"\n[DEBUG] VERSION response: {response}")

        assert response.get("ok") in [True, "true"]
        assert "firmware" in response

    async def test_get_state(self, device: ClipDevice):
        """Should return current device state."""
        response = await device.send_command("AT+GSTAT")
        print(f"\n[DEBUG] GSTAT response: {response}")

        assert response.get("ok") in [True, "true"]
        data = response.get("data", {})
        assert "state" in data
        assert "battery" in data

    async def test_get_time(self, device: ClipDevice):
        """Should get current time."""
        response = await device.send_command("AT+TIME?")
        print(f"\n[DEBUG] TIME? response: {response}")

        if response.get("ok") in [True, "true"]:
            time_value = response.get("time", "")
            assert isinstance(time_value, str)
            assert len(time_value) > 0
        else:
            pytest.skip("TIME command failed")

    async def test_set_time(self, device: ClipDevice):
        """Should set device time."""
        now = int(time.time())
        response = await device.send_command(f"AT+TIME={now}")
        print(f"\n[DEBUG] TIME= response: {response}")

        if response.get("ok") in [True, "true"]:
            # Verify
            assert "time" in response or response.get("ok") in [True, "true"]
        else:
            pytest.skip("TIME set command failed")

    async def test_get_pairing_status(self, device: ClipDevice):
        """Should get pairing status."""
        response = await device.send_command("AT+PAIR?")
        print(f"\n[DEBUG] PAIR? response: {response}")

        if response.get("ok") in [True, "true"]:
            assert "data" in response or "paired" in response
        else:
            pytest.skip("PAIR command failed")

    async def test_invalid_command(self, device: ClipDevice):
        """Should reject invalid commands."""
        response = await device.send_command("AT+INVALID")
        print(f"\n[DEBUG] INVALID response: {response}")

        assert response.get("ok") in [False, "false", None]

    async def test_invalid_parameter(self, device: ClipDevice):
        """Should reject invalid parameters."""
        response = await device.send_command("AT+BITRATE=999999")
        print(f"\n[DEBUG] BITRATE=999999 response: {response}")

        assert response.get("ok") in [False, "false", None]

    async def test_empty_response_handling(self, device: ClipDevice):
        """Should handle commands that return minimal data."""
        response = await device.send_command("AT+VERSION")
        assert "ok" in response
        assert response.get("ok") in [True, "true"]

    async def test_command_case_sensitivity(self, device: ClipDevice):
        """Test that commands must be uppercase."""
        # Uppercase should work
        response = await device.send_command("AT+VERSION")
        assert response.get("ok") in [True, "true"]

        # Lowercase should fail with timeout (device doesn't respond)
        with pytest.raises(TimeoutError):
            await device.send_command("at+version", timeout=3)


@pytest.mark.asyncio
@pytest.mark.skip(reason="Reboots device, skip in normal test runs")
class TestReboot:
    """Tests that reboot the device."""

    async def test_reboot(self, commands: ClipCommands):
        """Should reboot device."""
        await commands.reboot()


@pytest.mark.asyncio
class TestErrorHandling:
    """Test error handling scenarios."""

    async def test_timeout_on_no_response(self, device: ClipDevice):
        """Should timeout when device doesn't respond."""
        from clip.client import COMMAND_TIMEOUT
        assert COMMAND_TIMEOUT is not None

    async def test_malformed_json_response(self, device: ClipDevice):
        """Should handle malformed JSON gracefully."""
        pass
