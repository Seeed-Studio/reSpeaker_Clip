#!/usr/bin/env python3
"""
ReSpeaker Clip Record Tool

Record and sync in real-time.

Usage:
    python tools/record.py [--mode MODE] [--duration SECONDS] [--output DIR]
"""

import asyncio
import sys
import signal
import time
from pathlib import Path

# Add parent directory to path for imports
sys.path.insert(0, str(Path(__file__).parent.parent))

from clip import ClipDevice, ClipCommands, SessionSync
from clip.utils import format_bytes, format_duration


def format_speed(bytes_per_sec: float) -> str:
    """Format transfer speed."""
    if bytes_per_sec < 1024:
        return f"{bytes_per_sec:.1f} B/s"
    elif bytes_per_sec < 1024 * 1024:
        return f"{bytes_per_sec / 1024:.1f} KB/s"
    else:
        return f"{bytes_per_sec / (1024 * 1024):.2f} MB/s"


async def record_and_sync(
    mode: str = "normal",
    duration: int = None,
    output_dir: Path = Path("recordings"),
    device_address: str = None
):
    """
    Record and sync in real-time.

    Args:
        mode: Recording mode (normal, enhanced, stereo, merge)
        duration: Recording duration in seconds (None = wait for Ctrl+C)
        output_dir: Output directory for recordings
        device_address: Device MAC address
    """
    device = ClipDevice(address=device_address, debug=False)
    commands = ClipCommands(device)
    sync = SessionSync(device)

    recording = False
    session_id = None
    sync_task = None
    stop_event = asyncio.Event()

    sync_start_time = time.time()
    sync_stats = {'file_count': 0, 'total_bytes': 0, 'last_filename': ''}

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
        await commands.ensure_idle()

        state = await commands.get_state()
        print(f"Battery: {state.battery}%")
        print(f"Storage: {format_bytes(state.free_space * 1024 * 1024)} free")

        print(f"\nStarting recording in {mode} mode...")
        session_id = await commands.start_recording(mode)
        print(f"Session ID: {session_id}")

        await asyncio.sleep(0.5)
        recording = True

        output_path = output_dir / session_id
        output_path.mkdir(parents=True, exist_ok=True)

        print(f"Starting real-time sync to: {output_path}")
        print(f"Recording... (Press Ctrl+C to stop)\n")

        sync_task = asyncio.create_task(
            sync.sync(
                session_id,
                output_path,
                delete_after=True,   # Delete from device after sync
                continuous=True,
                progress_callback=progress_callback,
            )
        )

        # Monitor progress
        start_time = asyncio.get_event_loop().time()

        while recording:
            try:
                await asyncio.wait_for(stop_event.wait(), timeout=1.0)
                break
            except asyncio.TimeoutError:
                pass

            elapsed = asyncio.get_event_loop().time() - start_time
            if duration and elapsed >= duration:
                print(f"\nDuration ({duration}s) reached")
                break

            # Display progress
            try:
                current_speed = sync_stats['total_bytes'] / (time.time() - sync_start_time) if (time.time() - sync_start_time) > 0 else 0
                status = f"\r[Recording] {format_duration(elapsed).ljust(10)} | "
                status += f"Files: {sync_stats['file_count']} | "
                status += f"Total: {format_bytes(sync_stats['total_bytes'])} | "
                status += f"Speed: {format_speed(current_speed)}"
                print(status, end='', flush=True)
            except Exception:
                pass

        # Stop recording
        print(f"\n\nStopping recording...")
        result = await commands.stop_recording()

        # Wait for sync to complete
        print("Waiting for sync to complete...")
        if sync_task and not sync_task.done():
            wait_start = time.time()
            last_count = 0

            while not sync_task.done():
                await asyncio.sleep(0.3)
                elapsed = time.time() - wait_start

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
                sync_result = await sync_task
            except Exception:
                sync_result = None

        # Show summary
        duration_sec = result.get('duration', 0)
        sync_elapsed = time.time() - sync_start_time
        avg_speed = sync_stats['total_bytes'] / sync_elapsed if sync_elapsed > 0 else 0

        # Check for merged file
        merged_path = output_path / f"{session_id}.opus"
        if merged_path.exists():
            total_bytes = merged_path.stat().st_size
            individual_count = len([f for f in output_path.glob("*.opus") if f.name != f"{session_id}.opus"])
        else:
            total_bytes = sync_stats['total_bytes']
            individual_count = sync_stats['file_count']

        print("\n" + "=" * 60)
        print("Recording Summary")
        print("=" * 60)
        print(f"  Session: {session_id}")
        print(f"  Duration: {format_duration(duration_sec)}")
        if merged_path.exists():
            print(f"  Merged file: {merged_path.name} ({format_bytes(total_bytes)})")
        else:
            print(f"  Files synced: {individual_count}")
        print(f"  Total synced: {format_bytes(total_bytes)}")
        print(f"  Avg speed: {format_speed(avg_speed)}")
        print(f"  Location: {output_path}")
        print("=" * 60)

        return 0

    except KeyboardInterrupt:
        print("\n\nInterrupted by user")
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
  # Record and sync (stop with Ctrl+C)
  python tools/record.py

  # Record in enhanced mode (mono + DSP)
  python tools/record.py --mode enhanced

  # Record for 30 seconds
  python tools/record.py --duration 30

  # Record to custom directory
  python tools/record.py --output ./my_recordings

  # Specify device
  python tools/record.py --device AA:BB:CC:DD:EE:FF
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
        device_address=args.device
    )


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
