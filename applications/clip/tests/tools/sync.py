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
from pathlib import Path

# Add parent directory to path for imports
sys.path.insert(0, str(Path(__file__).parent.parent))

from clip import ClipDevice, SessionSync, ClipCommands
from clip.utils import format_bytes, format_duration


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
        if hasattr(device, '_client') and hasattr(device._client, '_ble_device'):
            device_name = device._client._ble_device.name
            print(f"Device: {device_name}")

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

            results = await sync.sync_all(
                args.output,
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

        def progress_callback(filename: str, file_count: int, total_size: int):
            sync_stats['last_filename'] = filename
            sync_stats['file_count'] = file_count
            sync_stats['total_bytes'] = total_size

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

        # Create sync task
        sync_task = asyncio.create_task(
            sync.sync(
                session_id,
                args.output / session_id,
                delete_after=not args.keep,
                continuous=continuous,
                progress_callback=progress_callback,
            )
        )

        # Show progress while syncing
        last_count = 0
        last_shown = 0.0
        no_progress_count = 0

        while not sync_task.done():
            try:
                await asyncio.wait_for(stop_event.wait(), timeout=0.5)
                # User pressed Ctrl+C
                print("\nStopping sync...")
                await sync.cancel()
                break
            except asyncio.TimeoutError:
                pass

            elapsed = time.time() - sync_start

            # Show progress every 3 seconds (only if files received)
            if elapsed - last_shown > 3.0 and sync_stats['file_count'] > 0:
                speed = sync_stats['total_bytes'] / elapsed if elapsed > 0 else 0
                print(f"  Progress: {sync_stats['last_filename']} ({sync_stats['file_count']} files, "
                      f"{format_bytes(sync_stats['total_bytes'])}, {format_duration(elapsed)}, "
                      f"{format_speed(speed)})")
                last_count = sync_stats['file_count']
                last_shown = elapsed
                no_progress_count = 0

            # Check for no progress (60 seconds without new files)
            if sync_stats['file_count'] > 0 and elapsed - last_shown > 60:
                no_progress_count += 1
                if no_progress_count >= 2:  # 120 seconds with no progress
                    print(f"\nNo new files for 2 minutes, assuming transfer complete")
                    await sync.cancel()
                    break
            elif sync_stats['file_count'] == 0 and elapsed > 120:
                # No files at all after 2 minutes - something wrong
                print(f"\nNo files received after 2 minutes, aborting")
                await sync.cancel()
                break

        # Get result (handle TransferError gracefully)
        try:
            result = await sync_task
        except Exception as e:
            # Check if it's just a canceled transfer
            if "canceled" in str(e).lower() or "cancel" in str(e).lower():
                # User canceled or timeout - get partial results from filesystem
                print(f"\nSync was stopped ({type(e).__name__})")

                # Check what we actually got
                output_path = args.output / session_id
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

        if result.get('merged_file'):
            print(f"  Merged: {result['merged_file']}")
        print(f"  Location: {args.output / session_id}")
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
