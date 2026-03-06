#!/usr/bin/env python3
"""
ReSpeaker Clip Record Tool

Record and sync in real-time. Press SPACE to pause/resume, M to add bookmarks.

Usage:
    python tools/record.py [--mode MODE] [--duration SECONDS] [--output DIR]
"""

import asyncio
import sys
import signal
import time
import struct
import threading
from pathlib import Path
from typing import Optional, List

# Add parent directory to path for imports
sys.path.insert(0, str(Path(__file__).parent.parent))

from clip import ClipDevice, ClipCommands, SessionSync
from clip.utils import format_bytes, format_duration


# ============================================================================
# Audio Visualization Display
# ============================================================================

class AudioVisualizer:
    """Display audio waveform visualization in terminal."""

    def __init__(self):
        self.bars = [0] * 13  # 13 energy history values (0-10)
        self.last_display = ""
        self.enabled = True

    def update(self, data: bytes):
        """Update energy history from BLE notification data (7 bytes packed format).

        Format: 13 values (4 bits each) packed into 7 bytes (oldest to newest).
        Byte 0: [val0:val1], Byte 1: [val2:val3], ..., Byte 5: [val10:val11]
        Byte 6: [val12:0x0]
        """
        if len(data) >= 7:
            # Unpack 7 bytes into 13 values (4 bits each)
            self.bars = []
            for i in range(6):
                byte_val = data[i]
                self.bars.append(byte_val & 0x0F)         # Low nibble
                self.bars.append((byte_val >> 4) & 0x0F)  # High nibble
            # Last byte: only low nibble is valid
            self.bars.append(data[6] & 0x0F)
            # Clamp values to 0-10 range
            self.bars = [min(10, max(0, b)) for b in self.bars]

    def render(self) -> str:
        """Render the visualization as ASCII art (energy trend: left=oldest, right=newest)."""
        if not self.enabled:
            return ""

        max_height = 10

        # Build visualization from top to bottom
        lines = []
        for level in range(max_height, 0, -1):
            line = "  "
            for height in self.bars:
                if height >= level:
                    # Different characters for different heights
                    if level >= 8:
                        line += "█"  # Full bar at top
                    elif level >= 5:
                        line += "▓"  # Medium-high
                    elif level >= 3:
                        line += "▒"  # Medium
                    else:
                        line += "░"  # Low
                else:
                    line += " "
                line += " "
            lines.append(line)

        # Add current energy level indicator (rightmost/newest)
        current_energy = self.bars[-1] if self.bars else 0
        energy_bar = "=" * current_energy + "-" * (10 - current_energy)
        lines.append(f"  [{energy_bar}] {current_energy}/10")

        return "\n".join(lines)

    def display(self, force_clear: bool = False):
        """Display the visualization (only if changed)."""
        new_display = self.render()
        if new_display != self.last_display or force_clear:
            # Clear previous visualization area
            if self.last_display:
                line_count = self.last_display.count('\n') + 1
                sys.stdout.write("\033[F\033[J" * line_count)  # Clear lines
            sys.stdout.write(new_display + "\n")
            sys.stdout.flush()
            self.last_display = new_display

    def clear(self):
        """Clear the visualization display."""
        if self.last_display:
            line_count = self.last_display.count('\n') + 1
            sys.stdout.write("\033[F\033[J" * line_count)
            sys.stdout.flush()
            self.last_display = ""


def format_speed(bytes_per_sec: float) -> str:
    """Format transfer speed."""
    if bytes_per_sec < 1024:
        return f"{bytes_per_sec:.1f} B/s"
    elif bytes_per_sec < 1024 * 1024:
        return f"{bytes_per_sec / 1024:.1f} KB/s"
    else:
        return f"{bytes_per_sec / (1024 * 1024):.2f} MB/s"


# ============================================================================
# OGG CRC32 Implementation (OGG-specific polynomial)
# ============================================================================

def _ogg_crc32_init():
    """Generate CRC32 lookup table for OGG (polynomial 0x04C11DB7)."""
    table = []
    for i in range(256):
        crc = i << 24
        for _ in range(8):
            if crc & 0x80000000:
                crc = (crc << 1) ^ 0x04C11DB7
            else:
                crc = crc << 1
            crc &= 0xFFFFFFFF
        table.append(crc)
    return table

_OGG_CRC_TABLE = _ogg_crc32_init()

def ogg_crc32(data: bytes) -> int:
    """Calculate OGG CRC32 (uses different polynomial than standard CRC32)."""
    crc = 0
    for byte in data:
        crc = ((crc << 8) ^ _OGG_CRC_TABLE[((crc >> 24) ^ byte) & 0xFF]) & 0xFFFFFFFF
    return crc


# ============================================================================
# Simple OGG Opus Writer (no external dependencies)
# ============================================================================

class OggOpusWriter:
    """
    Simple OGG Opus file writer.

    Creates a valid OGG Opus file from raw Opus packets.
    No external dependencies required.
    """

    # Opus internally runs at 48kHz, granule positions must use this rate
    OPUS_INTERNAL_RATE = 48000

    def __init__(self, filename: str, sample_rate: int = 16000, channels: int = 1):
        self.file = open(filename, 'wb')
        self.sample_rate = sample_rate  # Input sample rate (for OpusHead)
        self.channels = channels
        self.serial = 0x12345678  # Fixed serial for simplicity
        self.page_seq = 0
        self.granule = 0
        # Granule is in Opus internal rate (48kHz), 20ms = 960 samples
        self.frame_size = self.OPUS_INTERNAL_RATE // 50  # 20ms = 960 samples at 48kHz

        # Buffer for collecting packets into pages
        self.page_packets = []
        self.page_granule = 0

    def _write_page(self, granule: int, header_type: int, data: bytes):
        """Write an OGG page."""
        # Build segment table
        segment_table = []
        remaining = len(data)
        offset = 0
        while remaining > 0:
            seg_size = min(255, remaining)
            segment_table.append(seg_size)
            remaining -= seg_size

        if not segment_table:
            segment_table = [0]

        # Build page header (27 bytes + segment table)
        header = bytearray()
        header.extend(b'OggS')                      # Capture pattern (4)
        header.append(0)                             # Stream structure version (1)
        header.append(header_type)                   # Header type (1)
        header.extend(struct.pack('<Q', granule))    # Granule position (8)
        header.extend(struct.pack('<I', self.serial))  # Bitstream serial number (4)
        header.extend(struct.pack('<I', self.page_seq))  # Page sequence number (4)
        header.extend(struct.pack('<I', 0))          # CRC checksum (4) - placeholder
        header.append(len(segment_table))            # Number of page segments (1)
        header.extend(bytes(segment_table))          # Segment table (N)

        # Calculate CRC over header + data
        page_data = bytes(header) + data
        crc = ogg_crc32(page_data)

        # Insert CRC into header (at offset 22)
        struct.pack_into('<I', header, 22, crc)

        # Write complete page
        self.file.write(bytes(header) + data)
        self.page_seq += 1

    def write_header(self):
        """Write OpusHead and OpusTags pages."""
        # OpusHead packet
        # https://wiki.xiph.org/OggOpus#ID_Header
        opus_head = bytearray()
        opus_head.extend(b'OpusHead')        # Magic signature (8)
        opus_head.append(1)                   # Version (1)
        opus_head.append(self.channels)       # Output channel count (1)
        opus_head.extend(struct.pack('<H', 312))  # Pre-skip (2) - 312 samples (6ms at 48kHz)
        opus_head.extend(struct.pack('<I', self.sample_rate))  # Input sample rate (4)
        opus_head.extend(struct.pack('<H', 0))   # Output gain (2)
        opus_head.append(0)                   # Channel mapping family (1)

        # First page: BOS (beginning of stream)
        self._write_page(0, 0x02, bytes(opus_head))

        # OpusTags packet
        opus_tags = bytearray()
        opus_tags.extend(b'OpusTags')         # Magic signature (8)
        vendor = b'ReSpeaker Clip'
        opus_tags.extend(struct.pack('<I', len(vendor)))  # Vendor string length (4)
        opus_tags.extend(vendor)              # Vendor string (N)
        opus_tags.extend(struct.pack('<I', 0))  # User comment list length (4)

        # Second page
        self._write_page(0, 0x00, bytes(opus_tags))

    def write_packet(self, opus_data: bytes):
        """Write an Opus audio packet."""
        self.granule += self.frame_size
        self._write_page(self.granule, 0x00, opus_data)

    def close(self):
        """Close file."""
        self.file.close()


def parse_raw_opus_frames(raw_data: bytes) -> List[bytes]:
    """
    Parse raw Opus frames from device format.

    Device format: [2-byte LE length][Opus frame]...

    Frame size guide (20ms at 16kHz):
    - Mono 16kbps: ~40 bytes
    - Mono 32kbps: ~80 bytes
    - Stereo 32kbps: ~80 bytes (mono bitrate x2)
    - Stereo 64kbps: ~160 bytes
    """
    frames = []
    offset = 0

    # Find first valid frame (allow larger range for stereo)
    while offset < min(200, len(raw_data)):
        if offset + 2 > len(raw_data):
            break
        frame_len = struct.unpack('<H', raw_data[offset:offset+2])[0]
        if 10 <= frame_len <= 500:  # Wider range for stereo
            break
        offset += 2

    # Parse all frames
    while offset < len(raw_data):
        if offset + 2 > len(raw_data):
            break

        frame_len = struct.unpack('<H', raw_data[offset:offset+2])[0]
        offset += 2

        # Allow larger frames for stereo (up to ~500 bytes for 64kbps stereo)
        if frame_len < 10 or frame_len > 1000:
            break

        if offset + frame_len > len(raw_data):
            break

        frame_data = raw_data[offset:offset+frame_len]
        offset += frame_len
        frames.append(frame_data)

    return frames


def convert_to_ogg_opus(input_file: Path, output_file: Path,
                        sample_rate: int = 16000, channels: int = 1) -> bool:
    """
    Convert raw Opus frames to OGG Opus format.

    No external dependencies required!
    """
    # Read raw data
    with open(input_file, 'rb') as f:
        raw_data = f.read()

    if len(raw_data) == 0:
        print("  Error: Input file is empty")
        return False

    # Parse frames
    frames = parse_raw_opus_frames(raw_data)
    if not frames:
        print("  Error: No valid Opus frames found")
        return False

    try:
        output_file.parent.mkdir(parents=True, exist_ok=True)

        writer = OggOpusWriter(str(output_file), sample_rate, channels)
        writer.write_header()

        for frame in frames:
            writer.write_packet(frame)

        writer.close()

        duration = len(frames) * 20 / 1000  # 20ms per frame
        print(f"  Created: {output_file.name} ({format_bytes(output_file.stat().st_size)}, {duration:.1f}s)")
        return True

    except Exception as e:
        print(f"  Error: {e}")
        import traceback
        traceback.print_exc()
        return False


# ============================================================================
# Keyboard Listener
# ============================================================================

class KeyboardListener:
    """Non-blocking keyboard listener for space key presses."""

    def __init__(self):
        self.running = False
        self._thread: Optional[threading.Thread] = None
        self._key_queue: asyncio.Queue = None
        self._loop: asyncio.AbstractEventLoop = None

    async def start(self) -> 'KeyboardListener':
        """Start listening for keyboard input."""
        self._key_queue = asyncio.Queue()
        self._loop = asyncio.get_running_loop()
        self.running = True

        self._thread = threading.Thread(target=self._listen_thread, daemon=True)
        self._thread.start()
        return self

    def _listen_thread(self):
        """Background thread for reading keyboard input."""
        if sys.platform == 'win32':
            self._listen_windows()
        else:
            self._listen_unix()

    def _listen_windows(self):
        """Listen using msvcrt (Windows)."""
        import msvcrt

        while self.running:
            try:
                if msvcrt.kbhit():
                    ch = msvcrt.getch()
                    if ch == b' ':
                        if self._loop and not self._loop.is_closed():
                            self._loop.call_soon_threadsafe(
                                self._key_queue.put_nowait, 'space'
                            )
                    elif ch == b'm' or ch == b'M':
                        if self._loop and not self._loop.is_closed():
                            self._loop.call_soon_threadsafe(
                                self._key_queue.put_nowait, 'mark'
                            )
                    elif ch == b'q' or ch == b'Q':
                        if self._loop and not self._loop.is_closed():
                            self._loop.call_soon_threadsafe(
                                self._key_queue.put_nowait, 'quit'
                            )
                    elif ch == b'\x03':  # Ctrl+C
                        break
                else:
                    time.sleep(0.05)
            except Exception:
                break

    def _listen_unix(self):
        """Listen using termios (Unix/Linux/macOS)."""
        import termios
        import tty

        fd = sys.stdin.fileno()
        old_settings = termios.tcgetattr(fd)

        try:
            tty.setraw(fd)
            while self.running:
                ch = sys.stdin.read(1)
                if not self.running:
                    break
                if ch == ' ':
                    if self._loop and not self._loop.is_closed():
                        self._loop.call_soon_threadsafe(
                            self._key_queue.put_nowait, 'space'
                        )
                elif ch == 'm' or ch == 'M':
                    if self._loop and not self._loop.is_closed():
                        self._loop.call_soon_threadsafe(
                            self._key_queue.put_nowait, 'mark'
                        )
                elif ch == '\x03':  # Ctrl+C
                    if self._loop and not self._loop.is_closed():
                        self._loop.call_soon_threadsafe(
                            self._key_queue.put_nowait, 'ctrl_c'
                        )
                    break
                elif ch == 'q' or ch == 'Q':
                    if self._loop and not self._loop.is_closed():
                        self._loop.call_soon_threadsafe(
                            self._key_queue.put_nowait, 'quit'
                        )
        finally:
            termios.tcsetattr(fd, termios.TCSADRAIN, old_settings)

    def stop(self):
        """Stop listening."""
        self.running = False

    async def get_key(self, timeout: float = 0.1) -> Optional[str]:
        """Get key press with timeout."""
        try:
            return await asyncio.wait_for(self._key_queue.get(), timeout=timeout)
        except asyncio.TimeoutError:
            return None


# ============================================================================
# Main Recording Function
# ============================================================================

async def record_and_sync(
    mode: str = "normal",
    duration: int = None,
    output_dir: Path = Path("recordings"),
    device_address: str = None,
):
    """Record and sync in real-time. Press SPACE to add bookmarks."""
    device = ClipDevice(address=device_address, debug=False)
    commands = ClipCommands(device)
    sync = SessionSync(device)

    # Audio visualizer for waveform display
    visualizer = AudioVisualizer()

    # Audio visualization callback
    async def audio_vis_callback(data: bytes):
        visualizer.update(data)

    # Helper to get device name for directory organization
    def get_device_name():
        if hasattr(device, '_client') and hasattr(device._client, '_ble_device'):
            name = device._client._ble_device.name
            if name:
                # Sanitize device name for filesystem use
                # Replace spaces with underscores and remove invalid chars
                name = name.replace(' ', '_')
                name = ''.join(c for c in name if c.isalnum() or c in '_.-')
                return name
        return "Unknown_Device"

    recording = False
    session_id = None
    sync_task = None
    stop_event = asyncio.Event()
    keyboard: Optional[KeyboardListener] = None

    sync_start_time = time.time()
    sync_stats = {'file_count': 0, 'total_bytes': 0, 'last_filename': ''}
    bookmark_count = 0

    def progress_callback(filename: str, file_count: int, total_size: int):
        sync_stats['last_filename'] = filename
        sync_stats['file_count'] = file_count
        sync_stats['total_bytes'] = total_size

    def signal_handler(sig, frame):
        print("\n\nStopping...")
        stop_event.set()

    try:
        signal.signal(signal.SIGINT, signal_handler)
    except ValueError:
        pass

    try:
        print("=" * 60)
        print("ReSpeaker Clip - Record & Sync")
        print("=" * 60)

        print("\nConnecting to device...")
        await device.connect()

        # Set up audio visualization callback
        device.set_audio_vis_callback(audio_vis_callback)

        if hasattr(device, '_client') and hasattr(device._client, '_ble_device'):
            device_name = device._client._ble_device.name
            print(f"Device: {device_name}")

        # Get device name for directory organization
        device_dir_name = get_device_name()
        print(f"Device directory: {device_dir_name}")

        # Get current device state
        state = await commands.get_state()
        print(f"Battery: {state.battery}%")
        print(f"Storage: {format_bytes(state.free_space * 1024 * 1024)} free")

        # Check if already recording
        if state.state == "RECORDING":
            print("\nDevice is already recording!")
            print("Attaching to existing session...")

            # Get current session
            sessions = await commands.list_sessions()
            if not sessions:
                print("Error: No sessions found")
                return 1

            session_id = sessions[-1].id
            print(f"Session ID: {session_id}")

            # Try to get session info for format details
            try:
                session_info = await commands.get_session_info(session_id)
                channels = session_info.channels
                sample_rate = session_info.sample_rate
                mode = session_info.mode
                print(f"Format: {mode} ({'stereo' if channels == 2 else 'mono'}), {sample_rate//1000}kHz")
            except Exception:
                # Use defaults if session info not available
                channels = 2 if mode in ["normal", "stereo"] else 1
                sample_rate = 16000

            recording = True
            attach_mode = True  # Flag: we attached to existing recording
            can_control = False  # Cannot control (pause/resume/stop) existing recording from app

        else:
            # Not recording - start new recording
            print(f"\nStarting recording in {mode} mode...")

            # Ensure idle state before starting
            await commands.ensure_idle()

            session_id = await commands.start_recording(mode)
            print(f"Session ID: {session_id}")

            await asyncio.sleep(0.5)
            recording = True
            attach_mode = False
            can_control = True  # Can control recording we started

            channels = 2 if mode == "stereo" else 1
            sample_rate = 16000

        # Organize recordings by device name
        output_path = output_dir / device_dir_name / session_id
        output_path.mkdir(parents=True, exist_ok=True)

        # Save session.json immediately with format info
        import json
        session_json = {
            "session_id": session_id,
            "mode": mode,
            "channels": channels,
            "sample_rate": sample_rate,
        }
        session_json_path = output_path / "session.json"
        session_json_path.write_text(json.dumps(session_json, indent=2))

        if attach_mode:
            print(f"Syncing to: {output_path}")
            print(f"\nInfo:")
            print(f"  - Attached to existing recording")
            print(f"  - Audio visualization enabled")
            print(f"  - Real-time sync enabled")
            print(f"  - Press Q or Ctrl+C to stop sync and exit")
            print(f"\nMonitoring...\n")
        else:
            print(f"Starting real-time sync to: {output_path}")
            print(f"\nControls:")
            print(f"  SPACE  - Pause/Resume recording")
            print(f"  M      - Add bookmark mark")
            print(f"  Q      - Stop recording")
            print(f"  Ctrl+C - Stop recording")
            print(f"\nRecording...\n")

        keyboard = await KeyboardListener().start()
        paused = False

        sync_task = asyncio.create_task(
            sync.sync(
                session_id,
                output_path,
                delete_after=True,
                continuous=True,
                progress_callback=progress_callback,
            )
        )

        start_time = asyncio.get_event_loop().time()

        while recording:
            try:
                key = await keyboard.get_key(timeout=0.1)
                if key == 'space':
                    # Toggle pause/resume (only if we started the recording)
                    if not can_control:
                        print(f"\n  [Cannot pause: attached to existing recording]")
                        continue
                    paused = not paused
                    if paused:
                        try:
                            await commands.pause_recording()
                            print(f"\n  [PAUSED]")
                        except Exception as e:
                            print(f"\n  [Pause failed: {e}]")
                            paused = False
                    else:
                        try:
                            await commands.resume_recording()
                            print(f"\n  [RESUMED]")
                        except Exception as e:
                            print(f"\n  [Resume failed: {e}]")
                            paused = False
                elif key == 'mark':
                    # Add bookmark (only if we started the recording)
                    if not can_control:
                        print(f"\n  [Cannot add bookmark: attached to existing recording]")
                        continue
                    try:
                        bookmark = await commands.add_bookmark("")
                        bookmark_count += 1
                        print(f"\n  [Mark #{bookmark_count}]")
                    except Exception as e:
                        print(f"\n  [Mark failed: {e}]")
                        print(f"\n  [Mark #{bookmark_count}]")
                    except Exception as e:
                        print(f"\n  [Mark failed: {e}]")
                elif key == 'quit' or key == 'ctrl_c':
                    print("\nStopping recording...")
                    break

                await asyncio.wait_for(stop_event.wait(), timeout=0.1)
                break
            except asyncio.TimeoutError:
                pass

            # Check if sync task died due to BLE disconnect
            if sync_task.done():
                try:
                    sync_result = sync_task.result()
                except Exception as e:
                    print(f"\n\nSync stopped: {e}")
                    print("BLE connection lost, saving what we have...")
                    recording = False
                    break

            # Check BLE connection
            if not device.is_connected:
                print(f"\n\nBLE disconnected, saving what we have...")
                recording = False
                break

            elapsed = asyncio.get_event_loop().time() - start_time
            if duration and elapsed >= duration:
                print(f"\nDuration ({duration}s) reached")
                break

            # Update audio visualization display
            if not paused:
                visualizer.display()

            try:
                current_speed = sync_stats['total_bytes'] / (time.time() - sync_start_time) if (time.time() - sync_start_time) > 0 else 0
                if attach_mode:
                    # Attached mode: show monitoring status
                    state_str = "[Monitoring]"
                else:
                    state_str = "[PAUSED]" if paused else "[Recording]"
                status = f"\r{state_str} {format_duration(elapsed).ljust(10)} | "
                status += f"Files: {sync_stats['file_count']} | "
                status += f"Total: {format_bytes(sync_stats['total_bytes'])} | "
                status += f"Speed: {format_speed(current_speed)}"
                if not attach_mode:
                    status += f" | Marks: {bookmark_count}"
                print(status, end='', flush=True)
            except Exception:
                pass

        if keyboard:
            keyboard.stop()

        # Clear audio visualization display
        visualizer.clear()

        if attach_mode:
            # Attached mode: don't stop recording, just disconnect sync
            print(f"\n\nDetaching from session...")
            print(f"  Recording continues on device")
        else:
            # Normal mode: stop recording
            print(f"\n\nStopping recording...")

            # Try to stop recording on device (may fail if BLE disconnected)
            result = None
            if device.is_connected:
                try:
                    result = await commands.stop_recording()
                except Exception as e:
                    print(f"  Warning: Could not stop recording on device: {e}")
                    print(f"  (Recording will continue on device until timeout)")
            else:
                print(f"  Warning: BLE disconnected, could not stop recording on device")
                print(f"  (Recording will continue on device until timeout)")

        # Only wait for sync if BLE is still connected
        sync_result = None
        if device.is_connected and sync_task and not sync_task.done():
            print("Waiting for sync to complete...")
            wait_start = time.time()
            last_count = 0

            while not sync_task.done():
                await asyncio.sleep(0.3)
                elapsed = time.time() - wait_start

                # Stop waiting if BLE disconnected
                if not device.is_connected:
                    print("  BLE disconnected, stopping sync wait...")
                    break

                if elapsed > 1.0:
                    current_files = sync_stats['file_count']
                    if current_files > last_count:
                        print(f"  Progress: {sync_stats['last_filename']} ({current_files} files, {elapsed:.0f}s)", flush=True)
                        last_count = current_files
                    else:
                        print(f"  Waiting... ({current_files} files, {elapsed:.0f}s)", flush=True)

                if elapsed > 60.0:
                    print("  Timeout, stopping sync...")
                    await sync.cancel()
                    break

            try:
                if sync_task.done():
                    sync_result = sync_task.result()
                else:
                    sync_result = None
            except Exception:
                sync_result = None
        elif not device.is_connected:
            print("BLE disconnected, skipping sync wait (files will remain on device)")
            # Cancel the sync task
            if sync_task and not sync_task.done():
                try:
                    await sync.cancel()
                except Exception:
                    pass

        # Delete session from device after successful sync
        # Note: Get audio format info BEFORE deleting
        # In attach mode, don't delete session (recording still in progress)
        channels = 2 if mode in ["normal", "stereo"] else 1
        sample_rate = 16000
        audio_mode = mode
        try:
            if device.is_connected:
                session_info = await commands.get_session_info(session_id)
                if session_info:
                    channels = session_info.channels
                    sample_rate = session_info.sample_rate
                    audio_mode = session_info.mode
        except Exception:
            pass  # Use defaults from mode

        # Only delete session if we started the recording (not attached mode)
        if not attach_mode and device.is_connected and session_id:
            try:
                print(f"Deleting session from device: {session_id}")
                await commands.delete_session(session_id)
                print(f"  Session deleted successfully")
            except Exception as e:
                print(f"  Warning: Could not delete session: {e}")
                print(f"  (Session will remain on device)")
        elif attach_mode:
            print(f"  Session kept on device (recording still in progress)")

        duration_sec = result.get('duration', 0) if result else 0
        sync_elapsed = time.time() - sync_start_time
        avg_speed = sync_stats['total_bytes'] / sync_elapsed if sync_elapsed > 0 else 0

        merged_path = output_path / f"{session_id}.opus"
        if merged_path.exists():
            total_bytes = merged_path.stat().st_size
        else:
            total_bytes = sync_stats['total_bytes']

        bookmarks = sync_result.get('bookmarks', []) if sync_result else []

        print("\n" + "=" * 60)
        if attach_mode:
            print("Sync Summary (Attached)")
        else:
            print("Recording Summary")
        print("=" * 60)
        print(f"  Session: {session_id}")
        if not attach_mode:
            print(f"  Duration: {format_duration(duration_sec)}")

        ch_str = "stereo" if channels == 2 else "mono"
        print(f"  Format: {audio_mode} ({ch_str}), {sample_rate//1000}kHz, Opus")
        if merged_path.exists():
            print(f"  Merged file: {merged_path.name} ({format_bytes(total_bytes)})")
        print(f"  Total synced: {format_bytes(total_bytes)}")
        print(f"  Avg speed: {format_speed(avg_speed)}")
        if not attach_mode:
            print(f"  Bookmarks: {bookmark_count}")

        if bookmarks:
            print(f"\n  Bookmark details:")
            for bm in bookmarks[:5]:
                note = f" - {bm.note}" if bm.note else ""
                print(f"    {bm.offset}s{note}")
            if len(bookmarks) > 5:
                print(f"    ... and {len(bookmarks) - 5} more")

        # Convert to OGG Opus (no dependencies!)
        if merged_path.exists() and merged_path.stat().st_size > 0:
            # Use channels/sample_rate from session_info we already fetched
            ch_str = "stereo" if channels == 2 else "mono"
            print(f"\nConverting to OGG Opus ({ch_str}, {sample_rate//1000}kHz)...")
            ogg_path = output_path / f"{session_id}.ogg"
            convert_to_ogg_opus(merged_path, ogg_path, sample_rate=sample_rate, channels=channels)
        else:
            # No merged file - check if we have individual .opus files to merge
            opus_files = list(output_path.glob("*.opus"))
            if opus_files:
                print(f"\nNo merged file found, merging {len(opus_files)} individual files...")
                merged_path = output_path / f"{session_id}.opus"
                with open(merged_path, "wb") as outfile:
                    for opus_file in sorted(opus_files, key=lambda x: x.name):
                        outfile.write(opus_file.read_bytes())
                print(f"  Created: {merged_path.name} ({format_bytes(merged_path.stat().st_size)})")

                # Now convert to OGG
                ch_str = "stereo" if channels == 2 else "mono"
                print(f"\nConverting to OGG Opus ({ch_str}, {sample_rate//1000}kHz)...")
                ogg_path = output_path / f"{session_id}.ogg"
                convert_to_ogg_opus(merged_path, ogg_path, sample_rate=sample_rate, channels=channels)
            else:
                print(f"\nNo audio files found to convert")

        print(f"\n  Location: {output_path}")
        print("=" * 60)

        return 0

    except KeyboardInterrupt:
        print("\n\nInterrupted by user")
        if keyboard:
            keyboard.stop()
        if recording and session_id:
            await commands.stop_recording()
        return 0
    except Exception as e:
        print(f"\nError: {e}")
        import traceback
        traceback.print_exc()
        return 1
    finally:
        try:
            await device.disconnect()
        except Exception:
            pass


async def main():
    import argparse
    parser = argparse.ArgumentParser(
        description="ReSpeaker Clip Record & Sync Tool",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Record and sync (stop with Ctrl+C or Q)
  python tools/record.py

  # Record in enhanced mode (mono + DSP)
  python tools/record.py --mode enhanced

  # Record for 30 seconds
  python tools/record.py --duration 30

Controls during recording:
  SPACE  - Pause/Resume recording
  M      - Add bookmark mark
  Q      - Stop recording
  Ctrl+C - Stop recording

Output files:
  {session}.opus - Raw merged Opus (device format)
  {session}.ogg  - OGG Opus (standard format, playable)
        """
    )

    parser.add_argument("--device", "-d", help="Device MAC address")
    parser.add_argument("--mode", "-m", default="normal",
                       choices=["normal", "enhanced", "stereo", "merge"],
                       help="Recording mode (default: normal)")
    parser.add_argument("--duration", "-t", type=int,
                       help="Auto-stop after N seconds (default: wait for Ctrl+C)")
    parser.add_argument("--output", "-o", type=Path, default=Path("recordings"),
                       help="Output directory (default: recordings/)")

    args = parser.parse_args()

    await record_and_sync(
        mode=args.mode,
        duration=args.duration,
        output_dir=args.output,
        device_address=args.device,
    )


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
