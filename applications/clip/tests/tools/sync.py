#!/usr/bin/env python3
"""
ReSpeaker Clip Sync Tool

Sync/Download files from the device using the clip library.

Usage:
    python tools/sync.py [--device MAC_ADDRESS] [--session SESSION_ID] [--all-sessions]
"""

import asyncio
import sys
import time
import struct
from pathlib import Path

# Add parent directory to path for imports
sys.path.insert(0, str(Path(__file__).parent.parent))

from clip import ClipDevice, SessionSync, ClipCommands
from clip.utils import format_bytes, format_duration

try:
    from tqdm import tqdm
    from tqdm.utils import _screen_shape_wrapper
    HAS_TQDM = True
except ImportError:
    HAS_TQDM = False


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
    """Simple OGG Opus file writer."""

    OPUS_INTERNAL_RATE = 48000

    def __init__(self, filename: str, sample_rate: int = 16000, channels: int = 1):
        self.file = open(filename, 'wb')
        self.sample_rate = sample_rate
        self.channels = channels
        self.serial = 0x12345678
        self.page_seq = 0
        self.granule = 0
        self.frame_size = self.OPUS_INTERNAL_RATE // 50  # 20ms = 960 samples at 48kHz

    def _write_page(self, granule: int, header_type: int, data: bytes):
        """Write an OGG page."""
        segment_table = []
        remaining = len(data)
        while remaining > 0:
            seg_size = min(255, remaining)
            segment_table.append(seg_size)
            remaining -= seg_size

        if not segment_table:
            segment_table = [0]

        header = bytearray()
        header.extend(b'OggS')
        header.append(0)
        header.append(header_type)
        header.extend(struct.pack('<Q', granule))
        header.extend(struct.pack('<I', self.serial))
        header.extend(struct.pack('<I', self.page_seq))
        header.extend(struct.pack('<I', 0))  # CRC placeholder
        header.append(len(segment_table))
        header.extend(bytes(segment_table))

        page_data = bytes(header) + data
        crc = ogg_crc32(page_data)
        struct.pack_into('<I', header, 22, crc)

        self.file.write(bytes(header) + data)
        self.page_seq += 1

    def write_header(self):
        """Write OpusHead and OpusTags pages."""
        opus_head = bytearray()
        opus_head.extend(b'OpusHead')
        opus_head.append(1)
        opus_head.append(self.channels)
        opus_head.extend(struct.pack('<H', 312))  # Pre-skip
        opus_head.extend(struct.pack('<I', self.sample_rate))
        opus_head.extend(struct.pack('<H', 0))  # Output gain
        opus_head.append(0)  # Channel mapping family

        self._write_page(0, 0x02, bytes(opus_head))

        opus_tags = bytearray()
        opus_tags.extend(b'OpusTags')
        vendor = b'ReSpeaker Clip'
        opus_tags.extend(struct.pack('<I', len(vendor)))
        opus_tags.extend(vendor)
        opus_tags.extend(struct.pack('<I', 0))

        self._write_page(0, 0x00, bytes(opus_tags))

    def write_packet(self, opus_data: bytes):
        """Write an Opus audio packet."""
        self.granule += self.frame_size
        self._write_page(self.granule, 0x00, opus_data)

    def close(self):
        """Close file."""
        self.file.close()


def parse_raw_opus_frames(raw_data: bytes):
    """Parse raw Opus frames from device format."""
    frames = []
    offset = 0

    while offset < min(200, len(raw_data)):
        if offset + 2 > len(raw_data):
            break
        frame_len = struct.unpack('<H', raw_data[offset:offset+2])[0]
        if 10 <= frame_len <= 500:
            break
        offset += 2

    while offset < len(raw_data):
        if offset + 2 > len(raw_data):
            break

        frame_len = struct.unpack('<H', raw_data[offset:offset+2])[0]
        offset += 2

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
    """Convert raw Opus frames to OGG Opus format."""
    with open(input_file, 'rb') as f:
        raw_data = f.read()

    if len(raw_data) == 0:
        return False

    frames = parse_raw_opus_frames(raw_data)
    if not frames:
        return False

    try:
        output_file.parent.mkdir(parents=True, exist_ok=True)

        writer = OggOpusWriter(str(output_file), sample_rate, channels)
        writer.write_header()

        for frame in frames:
            writer.write_packet(frame)

        writer.close()

        duration = len(frames) * 20 / 1000
        print(f"  Created: {output_file.name} ({format_bytes(output_file.stat().st_size)}, {duration:.1f}s)")
        return True

    except Exception as e:
        print(f"  Error: {e}")
        return False


async def main():
    import argparse
    parser = argparse.ArgumentParser(
        description="ReSpeaker Clip Sync Tool",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Sync latest session (auto-detect if recording)
  python tools/sync.py

  # Sync specific session
  python tools/sync.py --session 20240101_120000

  # Sync all sessions
  python tools/sync.py --all-sessions

  # Show status only
  python tools/sync.py --status
        """
    )

    parser.add_argument("--device", "-d", help="Device MAC address")
    parser.add_argument("--session", "-s", help="Specific session to sync")
    parser.add_argument("--all-sessions", "-a", action="store_true",
                       help="Sync all sessions from device")
    parser.add_argument("--status", action="store_true", help="Show status and exit")
    parser.add_argument("--output", "-o", type=Path, default=Path("recordings"),
                       help="Output directory (default: recordings/)")
    parser.add_argument("--keep", "-k", action="store_true",
                       help="Keep sessions on device after sync")
    parser.add_argument("--oneshot", action="store_true",
                       help="One-shot mode: exit when no new files")

    args = parser.parse_args()

    # Create device
    print("Connecting to device...")
    device = ClipDevice(address=args.device)

    try:
        await device.connect()

        # Print device name
        device_dir_name = "Unknown_Device"
        if hasattr(device, '_client') and hasattr(device._client, '_ble_device'):
            device_name = device._client._ble_device.name
            print(f"Device: {device_name}")
            # Sanitize device name for filesystem use
            device_dir_name = device_name.replace(' ', '_')
            device_dir_name = ''.join(c for c in device_dir_name if c.isalnum() or c in '_.-')
            print(f"Device directory: {device_dir_name}")

        # Create sync handler
        sync = SessionSync(device)

        # Show status
        if args.status:
            cmds = ClipCommands(device)

            state = await cmds.get_state()
            print(f"\nDevice Status:")
            print(f"  State: {state.state}")
            print(f"  Battery: {state.battery}%")
            print(f"  Mode: {state.mode}")
            print(f"  Bitrate: {state.bitrate}")

            sessions = await cmds.list_sessions()
            print(f"\nSessions: {len(sessions)}")
            for s in sessions:
                print(f"  - {s.id}: {s.files} files, {format_bytes(s.size)}")
            return 0

        # Sync all sessions
        if args.all_sessions:
            print("\n" + "=" * 60)
            print("Sync All Sessions")
            print("=" * 60)

            # First, list all sessions
            cmds = ClipCommands(device)
            sessions = await cmds.list_sessions()
            print(f"\nFound {len(sessions)} session(s) on device:")
            for s in sessions:
                print(f"  - {s.id}: {s.files} files, {format_bytes(s.size)}")

            print(f"\nStarting sync...")

            results = await sync.sync_all(
                args.output / device_dir_name,
                delete_after=not args.keep,
            )

            print("\n" + "=" * 60)
            print("Summary")
            print("=" * 60)

            success = sum(1 for r in results if r.get("file_count", 0) > 0)
            failed = len(results) - success

            print(f"  Total: {len(results)}")
            print(f"  Success: {success}")
            print(f"  Failed: {failed}")

            return 0 if failed == 0 else 1

        # Sync single session
        session_id = args.session
        continuous = not args.oneshot
        sync_stats = {'file_count': 0, 'total_bytes': 0, 'last_filename': ''}

        # Auto-detect session if not specified
        if not session_id:
            cmds = ClipCommands(device)

            state = await cmds.get_state()

            if state.state == "RECORDING":
                print("\nDevice is recording, getting current session...")
                sessions = await cmds.list_sessions()
                if sessions:
                    session_id = sessions[-1].id  # Latest
                    print(f"  Session: {session_id}")
                    print(f"  Using continuous mode")
                    continuous = True
                else:
                    print("No sessions found")
                    return 1
            else:
                print("\nDevice is not recording")
                sessions = await cmds.list_sessions()
                if sessions:
                    session_id = sessions[-1].id  # Latest
                    print(f"  Session: {session_id}")
                    print(f"  Using oneshot mode")
                    continuous = False
                else:
                    print("No sessions to sync")
                    return 1

        # Sync the session
        print("\n" + "=" * 60)
        print(f"Sync Session: {session_id}")
        if continuous:
            print("  (Recording in progress - will sync files as they are created)")
            print("  (Press Ctrl+C to stop)")
        else:
            print("  (Waiting for files to transfer...)")
        if HAS_TQDM:
            print("  (Progress bar with transfer rate)")
        else:
            print("  (Install tqdm for better progress: pip install tqdm)")
        print("=" * 60)

        sync_start = time.time()
        stop_event = asyncio.Event()

        def signal_handler(sig, frame):
            print("\n\nStopping...")
            stop_event.set()

        try:
            import signal
            signal.signal(signal.SIGINT, signal_handler)
        except ValueError:
            pass

        # tqdm progress bar (if available)
        pbar = None
        if HAS_TQDM:
            pbar = tqdm(
                total=0,
                unit="B",
                unit_scale=True,
                unit_divisor=1024,
                desc=f"{session_id[:8]}",
                leave=False,
                bar_format="{l_bar}{bar}| {n_fmt}/{total_fmt} [{elapsed}<{remaining}, {rate_fmt}]"
            )
        else:
            # Fallback: show initial message
            print(f"  Syncing... (waiting for first file)")

        # Update progress callback to use tqdm
        def update_progress(filename: str, file_count: int, total_size: int):
            sync_stats['last_filename'] = filename
            sync_stats['file_count'] = file_count
            sync_stats['total_bytes'] = total_size

            if pbar:
                pbar.set_description(f"{filename[:15]}")
                pbar.total = total_size if total_size > 0 else 1
                pbar.n = total_size
                pbar.refresh()
            else:
                # Fallback: print progress on first file
                if file_count == 1:
                    print(f"  Receiving: {filename}")

        # Create sync task
        sync_task = asyncio.create_task(
            sync.sync(
                session_id,
                args.output / device_dir_name / session_id,
                delete_after=not args.keep,
                continuous=continuous,
                progress_callback=update_progress,
            )
        )

        # Show progress while syncing
        last_count = 0
        last_shown = 0.0
        no_progress_count = 0

        while not sync_task.done():
            try:
                await asyncio.wait_for(stop_event.wait(), timeout=0.1)
                # User pressed Ctrl+C
                if pbar:
                    pbar.close()
                print("\nStopping sync...")
                await sync.cancel()
                break
            except asyncio.TimeoutError:
                pass

            elapsed = time.time() - sync_start

            # Update tqdm with rate if available
            if pbar and sync_stats['total_bytes'] > 0:
                speed = sync_stats['total_bytes'] / elapsed if elapsed > 0 else 0
                # tqdm automatically calculates rate from n/elapsed
                pbar.n = sync_stats['total_bytes']
                pbar.refresh()

            # Fallback: show progress without tqdm every 3 seconds
            if not HAS_TQDM and elapsed - last_shown > 3.0 and sync_stats['file_count'] > 0:
                speed = sync_stats['total_bytes'] / elapsed if elapsed > 0 else 0
                print(f"  Progress: {sync_stats['last_filename']} ({sync_stats['file_count']} files, "
                      f"{format_bytes(sync_stats['total_bytes'])}, {format_speed(speed)})")
                last_count = sync_stats['file_count']
                last_shown = elapsed
                no_progress_count = 0

            # Check for no progress (60 seconds without new files)
            if sync_stats['file_count'] > 0 and elapsed - last_shown > 60:
                no_progress_count += 1
                if no_progress_count >= 2:  # 120 seconds with no progress
                    if pbar:
                        pbar.close()
                    print(f"\nNo new files for 2 minutes, assuming transfer complete")
                    await sync.cancel()
                    break
            elif sync_stats['file_count'] == 0 and elapsed > 120:
                # No files at all after 2 minutes - something wrong
                if pbar:
                    pbar.close()
                print(f"\nNo files received after 2 minutes, aborting")
                await sync.cancel()
                break

        # Close progress bar
        if pbar:
            pbar.close()

        # Get result (handle TransferError gracefully)
        try:
            result = await sync_task
        except Exception as e:
            # Check if it's just a canceled transfer
            if "canceled" in str(e).lower() or "cancel" in str(e).lower():
                # User canceled or timeout - get partial results from filesystem
                print(f"\nSync was stopped ({type(e).__name__})")

                # Check what we actually got
                output_path = args.output / device_dir_name / session_id
                if output_path.exists():
                    files = list(output_path.glob("*.opus"))
                    merged_file = output_path / f"{session_id}.opus"

                    result = {
                        'session_id': session_id,
                        'file_count': len([f for f in files if f.name != f"{session_id}.opus"]),
                        'total_size': sum(f.stat().st_size for f in files),
                    }
                    if merged_file.exists():
                        result['merged_file'] = str(merged_file)
                else:
                    print("No files received")
                    return 1
            else:
                print(f"\nSync error: {e}")
                import traceback
                traceback.print_exc()
                return 1

        # Show results
        elapsed = time.time() - sync_start
        avg_speed = result.get('total_size', 0) / elapsed if elapsed > 0 else 0

        print("\n" + "=" * 60)
        print("Sync Complete!")
        print("=" * 60)
        print(f"  Session: {result['session_id']}")
        print(f"  Files: {result.get('file_count', 0)}")
        print(f"  Total: {format_bytes(result.get('total_size', 0))}")
        print(f"  Avg speed: {format_speed(avg_speed)}")

        # Show bookmarks
        bookmarks = result.get('bookmarks', [])
        if bookmarks:
            print(f"  Bookmarks: {len(bookmarks)}")
            for bm in bookmarks[:3]:  # Show first 3
                note = f" - {bm.note}" if bm.note else ""
                print(f"    {bm.offset}s{note}")
            if len(bookmarks) > 3:
                print(f"    ... and {len(bookmarks) - 3} more")
            print(f"  Saved: {result.get('bookmarks_path', 'bookmarks.json')}")

        merged_path = None

        # Check if merged file exists in result
        if result.get('merged_file'):
            merged_path = Path(result['merged_file'])
            print(f"  Merged: {merged_path}")
        else:
            # Fallback: check if merged file exists locally
            potential_merged = args.output / device_dir_name / session_id / f"{session_id}.opus"
            if potential_merged.exists():
                merged_path = potential_merged
                print(f"  Merged: {merged_path}")

        # Convert to OGG Opus format
        if merged_path and merged_path.exists() and merged_path.stat().st_size > 0:
            # Get audio format from session info
            try:
                cmds = ClipCommands(device)
                session_info = await cmds.get_session_info(session_id)
                if session_info:
                    channels = session_info.channels
                    sample_rate = session_info.sample_rate
                else:
                    channels = 1
                    sample_rate = 16000
            except Exception:
                channels = 1
                sample_rate = 16000

            ch_str = "stereo" if channels == 2 else "mono"
            print(f"\nConverting to OGG Opus ({ch_str}, {sample_rate//1000}kHz)...")
            ogg_path = merged_path.parent / f"{session_id}.ogg"
            convert_to_ogg_opus(merged_path, ogg_path, sample_rate=sample_rate, channels=channels)

        print(f"  Location: {args.output / device_dir_name / session_id}")
        print("=" * 60)

        return 0

    except KeyboardInterrupt:
        print("\nInterrupted by user")
        return 130
    except Exception as e:
        print(f"\nError: {e}")
        import traceback
        traceback.print_exc()
        return 1
    finally:
        await device.disconnect()


def format_speed(bytes_per_sec: float) -> str:
    """Format transfer speed."""
    if bytes_per_sec < 1024:
        return f"{bytes_per_sec:.1f} B/s"
    elif bytes_per_sec < 1024 * 1024:
        return f"{bytes_per_sec / 1024:.1f} KB/s"
    else:
        return f"{bytes_per_sec / (1024 * 1024):.2f} MB/s"


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
