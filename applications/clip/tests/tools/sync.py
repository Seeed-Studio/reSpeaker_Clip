#!/usr/bin/env python3
"""
ReSpeaker Clip Sync Tool

Sync/Download files from the device using the clip library.

Usage:
    python tools/sync.py [--device MAC_ADDRESS] [--session SESSION_ID] [--all-sessions]
"""

import asyncio
import sys
from pathlib import Path

# Add parent directory to path for imports
sys.path.insert(0, str(Path(__file__).parent.parent))

from clip import ClipDevice, SessionSync
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
    parser.add_argument("--output", "-o", type=Path, default=Path("downloads"),
                       help="Output directory (default: downloads/)")
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

        # Create sync handler
        sync = SessionSync(device)

        # Show status
        if args.status:
            from clip import ClipCommands
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

            success = sum(1 for r in results if r.get("status") != "failed")
            failed = len(results) - success

            print(f"  Total: {len(results)}")
            print(f"  Success: {success}")
            print(f"  Failed: {failed}")

            return 0 if failed == 0 else 1

        # Sync single session
        session_id = args.session
        continuous = not args.oneshot

        # Auto-detect session if not specified
        if not session_id:
            from clip import ClipCommands
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
        print("=" * 60)

        result = await sync.sync(
            session_id,
            args.output / session_id,
            delete_after=not args.keep,
            continuous=continuous,
        )

        # Show results
        print("\n" + "=" * 60)
        print("Sync Complete!")
        print("=" * 60)
        print(f"  Session: {result['session_id']}")
        print(f"  Status: {result.get('status', 'unknown')}")
        if result.get('file_count', 0) > 0:
            print(f"  Files: {result['file_count']}")
            print(f"  Total: {format_bytes(result.get('total_size', 0))}")
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


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
