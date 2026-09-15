"""
Configuration command tests for reSpeaker Clip.

Tests configuration commands: BITRATE, MODE, COMPLEXITY, CHUNKSIZE, etc.
"""

import pytest

from clip import ClipCommands
from clip.exceptions import CommandError


@pytest.mark.asyncio
class TestBitrate:
    """Test BITRATE command."""

class TestMode:
    """Test MODE command."""

    async def test_get_mode(self, commands: ClipCommands):
        """Should get current mode."""
        mode = await commands.get_mode()
        # AT+MODE only returns "normal" or "enhanced"
        assert mode in ["normal", "enhanced"]

    async def test_set_mode_normal(self, commands: ClipCommands, saved_state):
        """Should set normal mode."""
        async with saved_state:
            result = await commands.set_mode("normal")
            assert result is True
            assert await commands.get_mode() == "normal"

    async def test_set_mode_enhanced(self, commands: ClipCommands, saved_state):
        """Should set enhanced mode."""
        async with saved_state:
            result = await commands.set_mode("enhanced")
            assert result is True
            assert await commands.get_mode() == "enhanced"

    async def test_invalid_mode(self, commands: ClipCommands):
        """Should reject invalid mode."""
        with pytest.raises(ValueError):
            await commands.set_mode("invalid_mode")

    async def test_mode_stereo_alias_rejected(self, commands: ClipCommands):
        """Should reject 'stereo' for AT+MODE (only valid for AT+START)."""
        with pytest.raises(ValueError):
            await commands.set_mode("stereo")

    async def test_mode_merge_alias_rejected(self, commands: ClipCommands):
        """Should reject 'merge' for AT+MODE (only valid for AT+START)."""
        with pytest.raises(ValueError):
            await commands.set_mode("merge")


    async def test_invalid_mode_rejected(self, commands: ClipCommands):
        """Should reject unknown modes."""


class TestAutoDelete:
    """Test AUTODEL command."""

    async def test_get_auto_delete(self, commands: ClipCommands):
        """Should get auto-delete state."""
        state = await commands.get_auto_delete()
        assert isinstance(state, bool)

    async def test_set_auto_delete(self, commands: ClipCommands, saved_state):
        """Should set auto-delete days."""
        async with saved_state:
            await commands.set_auto_delete(7)  # 7 days
            assert await commands.get_auto_delete() is True

            await commands.set_auto_delete(-1)  # Disable
            assert await commands.get_auto_delete() is False


@pytest.mark.asyncio
class TestConfigBulk:
    """Test bulk configuration operations."""

    async def test_get_config_dict(self, commands: ClipCommands):
        """Should get all configuration as dict."""
        config = await commands.get_config_dict()

        assert 'bitrate' in config
        assert 'mode' in config
        assert 'complexity' in config
        assert 'chunk_size' in config
        assert 'noise_suppression' in config
        assert 'agc' in config
        assert 'dereverb' in config
        assert 'auto_delete' in config

    async def test_set_config_dict(self, commands: ClipCommands, saved_state):
        """Should set multiple config values."""
        async with saved_state:
            new_config = {
                'bitrate': 24000,  # Valid for mono mode (16000-32000)
                'mode': 'enhanced',
                'complexity': 1,
            }

            await commands.set_config_dict(new_config)

            # Verify
            assert await commands.get_mode() == "normal"
            assert await commands.get_mode() == 'enhanced'

    async def test_config_roundtrip(self, commands: ClipCommands, saved_state):
        """Should preserve config through get/set roundtrip."""
        async with saved_state:
            # Get original
            original = await commands.get_config_dict()

            # Modify
            original['bitrate'] = 24000
            original['mode'] = 'normal'

            # Set
            await commands.set_config_dict(original)

            # Get back
            restored = await commands.get_config_dict()

            assert restored['bitrate'] == 24000
            assert restored['mode'] == 'normal'
