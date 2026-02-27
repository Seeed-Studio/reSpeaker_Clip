"""
Configuration command tests for reSpeaker Clip.

Tests configuration commands: BITRATE, MODE, COMPLEXITY, CHUNKSIZE, etc.
"""

import pytest

from clip import ClipCommands
from clip.exceptions import CommandError, ValueError


@pytest.mark.asyncio
class TestBitrate:
    """Test BITRATE command."""

    async def test_get_bitrate(self, commands: ClipCommands):
        """Should get current bitrate."""
        bitrate = await commands.get_bitrate()
        assert 16000 <= bitrate <= 64000

    async def test_set_bitrate(self, commands: ClipCommands, saved_state):
        """Should set bitrate."""
        async with saved_state:
            # Set to 32000
            result = await commands.set_bitrate(32000)
            assert result is True

            # Verify
            bitrate = await commands.get_bitrate()
            assert bitrate == 32000

    async def test_set_multiple_bitrates(self, commands: ClipCommands, saved_state):
        """Should set multiple different bitrates."""
        async with saved_state:
            bitrates = [16000, 24000, 32000, 48000, 64000]

            for br in bitrates:
                await commands.set_bitrate(br)
                assert await commands.get_bitrate() == br

    async def test_invalid_bitrate_too_low(self, commands: ClipCommands):
        """Should reject bitrate that's too low."""
        with pytest.raises((CommandError, ValueError)):
            await commands.set_bitrate(1000)

    async def test_invalid_bitrate_too_high(self, commands: ClipCommands):
        """Should reject bitrate that's too high."""
        with pytest.raises((CommandError, ValueError)):
            await commands.set_bitrate(999999)


@pytest.mark.asyncio
class TestMode:
    """Test MODE command."""

    async def test_get_mode(self, commands: ClipCommands):
        """Should get current mode."""
        mode = await commands.get_mode()
        assert mode in ["normal", "enhanced", "stereo", "merge"]

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

    async def test_set_mode_stereo(self, commands: ClipCommands, saved_state):
        """Should set stereo mode."""
        async with saved_state:
            result = await commands.set_mode("stereo")
            assert result is True
            assert await commands.get_mode() == "stereo"

    async def test_set_mode_merge(self, commands: ClipCommands, saved_state):
        """Should set merge mode."""
        async with saved_state:
            result = await commands.set_mode("merge")
            assert result is True
            assert await commands.get_mode() == "merge"

    async def test_invalid_mode(self, commands: ClipCommands):
        """Should reject invalid mode."""
        with pytest.raises(ValueError):
            await commands.set_mode("invalid_mode")


@pytest.mark.asyncio
class TestComplexity:
    """Test COMPLEXITY command."""

    async def test_get_complexity(self, commands: ClipCommands):
        """Should get current complexity."""
        complexity = await commands.get_complexity()
        assert 0 <= complexity <= 10

    async def test_set_complexity(self, commands: ClipCommands, saved_state):
        """Should set complexity."""
        async with saved_state:
            result = await commands.set_complexity(7)
            assert result is True

            complexity = await commands.get_complexity()
            assert complexity == 7

    async def test_set_complexity_range(self, commands: ClipCommands, saved_state):
        """Should set all valid complexity values."""
        async with saved_state:
            for i in range(11):
                await commands.set_complexity(i)
                assert await commands.get_complexity() == i

    async def test_invalid_complexity_negative(self, commands: ClipCommands):
        """Should reject negative complexity."""
        with pytest.raises(ValueError):
            await commands.set_complexity(-1)

    async def test_invalid_complexity_too_high(self, commands: ClipCommands):
        """Should reject complexity > 10."""
        with pytest.raises(ValueError):
            await commands.set_complexity(11)


@pytest.mark.asyncio
class TestChunkSize:
    """Test CHUNKSIZE command."""

    async def test_get_chunk_size(self, commands: ClipCommands):
        """Should get current chunk size."""
        size = await commands.get_chunk_size()
        assert 200 <= size <= 1000

    async def test_set_chunk_size(self, commands: ClipCommands, saved_state):
        """Should set chunk size."""
        async with saved_state:
            result = await commands.set_chunk_size(500)
            assert result is True

            size = await commands.get_chunk_size()
            assert size == 500

    async def test_set_various_chunk_sizes(self, commands: ClipCommands, saved_state):
        """Should set various chunk sizes."""
        async with saved_state:
            sizes = [200, 500, 750, 1000]

            for size in sizes:
                await commands.set_chunk_size(size)
                assert await commands.get_chunk_size() == size


@pytest.mark.asyncio
class TestAudioProcessing:
    """Test audio processing configuration."""

    async def test_get_noise_suppression(self, commands: ClipCommands):
        """Should get noise suppression level."""
        level = await commands.get_noise_suppression()
        assert 0 <= level <= 3

    async def test_set_noise_suppression(self, commands: ClipCommands, saved_state):
        """Should set noise suppression."""
        async with saved_state:
            await commands.set_noise_suppression(2)
            assert await commands.get_noise_suppression() == 2

    async def test_get_agc(self, commands: ClipCommands):
        """Should get AGC level."""
        level = await commands.get_agc()
        assert 0 <= level <= 3

    async def test_set_agc(self, commands: ClipCommands, saved_state):
        """Should set AGC level."""
        async with saved_state:
            await commands.set_agc(1)
            assert await commands.get_agc() == 1

    async def test_get_dereverb(self, commands: ClipCommands):
        """Should get dereverb state."""
        state = await commands.get_dereverb()
        assert isinstance(state, bool)

    async def test_set_dereverb(self, commands: ClipCommands, saved_state):
        """Should set dereverb state."""
        async with saved_state:
            await commands.set_dereverb(True)
            assert await commands.get_dereverb() is True

            await commands.set_dereverb(False)
            assert await commands.get_dereverb() is False


@pytest.mark.asyncio
class TestAutoDelete:
    """Test AUTODEL command."""

    async def test_get_auto_delete(self, commands: ClipCommands):
        """Should get auto-delete state."""
        state = await commands.get_auto_delete()
        assert isinstance(state, bool)

    async def test_set_auto_delete(self, commands: ClipCommands, saved_state):
        """Should set auto-delete state."""
        async with saved_state:
            await commands.set_auto_delete(True)
            assert await commands.get_auto_delete() is True

            await commands.set_auto_delete(False)
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
                'bitrate': 48000,
                'mode': 'enhanced',
                'complexity': 8,
            }

            await commands.set_config_dict(new_config)

            # Verify
            assert await commands.get_bitrate() == 48000
            assert await commands.get_mode() == 'enhanced'
            assert await commands.get_complexity() == 8

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
