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
from pathlib import Path

# Add parent directory to path for imports
sys.path.insert(0, str(Path(__file__).parent.parent))

from clip import ClipDevice, ClipCommands, SessionSync
from clip.utils import format_bytes, format_duration


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
    # Create device and commands (debug=False to reduce log spam)
    device = ClipDevice(address=device_address, debug=False)
    commands = ClipCommands(device)
    sync = SessionSync(device)

    # State tracking
    recording = False
    session_id = None
    sync_task = None
    stats = {
        'files_received': 0,
        'total_bytes': 0,
    }

    def signal_handler(sig, frame):
        """Handle Ctrl+C gracefully"""
        print("\n\nStopping...")

    try:
        signal.signal(signal.SIGINT, signal_handler)
    except ValueError:
        pass  # Windows may not support all signals

    try:
        print("=" * 60)
        print("ReSpeaker Clip - Record & Sync")
        print("=" * 60)

        # Connect
        print("\nConnecting to device...")
        await device.connect()

        # Ensure idle state
        await commands.ensure_idle()

        # Get current state info
        state = await commands.get_state()
        print(f"Battery: {state.battery}%")
        # free_space is in MB from firmware
        print(f"Storage: {format_bytes(state.free_space * 1024 * 1024)} free")

        # Start recording
        print(f"\nStarting recording in {mode} mode...")
        session_id = await commands.start_recording(mode)
        print(f"Session ID: {session_id}")

        # Wait for recording to actually start
        await asyncio.sleep(0.5)

        recording = True

        # Create output directory
        output_path = output_dir / session_id
        output_path.mkdir(parents=True, exist_ok=True)

        # Start sync in background
        print(f"Starting real-time sync to: {output_path}")
        print(f"Recording... (Press Ctrl+C to stop)\n")

        sync_task = asyncio.create_task(
            sync.sync(
                session_id,
                output_path,
                delete_after=False,  # Keep on device
                continuous=True,     # Keep waiting for new files
            )
        )

        # Monitor progress
        last_files = 0
        start_time = asyncio.get_event_loop().time()

        while recording:
            await asyncio.sleep(1)

            # Get current session info
            try:
                sessions = await commands.list_sessions()
                current_session = next((s for s in sessions if s.id == session_id), None)

                if current_session:
                    files_on_device = current_session.files

                    # Calculate synced files (rough estimate)
                    # We can track this by checking the output directory
                    if output_path.exists():
                        files_synced = len(list(output_path.glob("*.opus")))
                    else:
                        files_synced = 0

                    elapsed = asyncio.get_event_loop().time() - start_time

                    # Display progress
                    status = f"\r[Recording] {format_duration(elapsed).ljust(10)} | "
                    status += f"Device: {files_on_device} files | "
                    status += f"Synced: {files_synced} files"
                    print(status, end='', flush=True)

                    last_files = files_on_device

            except Exception as e:
                print(f"\nMonitor error: {e}")
                break

            # Check if duration reached
            if duration and elapsed >= duration:
                print(f"\nDuration ({duration}s) reached")
                break

        # Stop recording
        print(f"\n\nStopping recording...")
        result = await commands.stop_recording()

        # Wait for sync to finish
        print("Waiting for sync to complete...")
        if sync_task:
            try:
                sync_result = await asyncio.wait_for(sync_task, timeout=10.0)
                stats['files_received'] = sync_result.get('file_count', 0)
                stats['total_bytes'] = sync_result.get('total_size', 0)
            except asyncio.TimeoutError:
                print("Sync timeout (some files may not be synced)")

        # Show summary
        duration = result.get('duration', 0)
        files = result.get('file_count', 0)

        print("\n" + "=" * 60)
        print("Recording Summary")
        print("=" * 60)
        print(f"  Session: {session_id}")
        print(f"  Duration: {format_duration(duration)}")
        print(f"  Files on device: {files}")
        print(f"  Files synced: {stats['files_received']}")
        print(f"  Total synced: {format_bytes(stats['total_bytes'])}")
        print(f"  Location: {output_path}")
        print("=" * 60)

        return 0

    except KeyboardInterrupt:
        print("\n\nInterrupted by user")
        if recording and session_id:
            print("Stopping recording...")
            await commands.stop_recording()
        return 0
    except Exception as e:
        print(f"\nError: {e}")
        import traceback
        traceback.print_exc()
        return 1
    finally:
        await device.disconnect()


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
