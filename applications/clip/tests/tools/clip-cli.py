#!/usr/bin/env python3
"""
clip-cli — Unified CLI for reSpeaker Clip device.

Supports both BLE and WiFi (UDP) transports.

Usage:
  # BLE (default, auto-discover device)
  clip-cli status
  clip-cli record [--mode normal|enhanced] [--duration 60]
  clip-cli sync [--session ID] [--file FILE] [--all] [--delete]
  clip-cli list
  clip-cli config [get|set KEY=VAL]
  clip-cli delete SESSION
  clip-cli bookmark
  clip-cli terminal
  clip-cli version

  # WiFi (connect device WiFi AP)
  clip-cli --transport wifi status
  clip-cli --transport wifi list
  clip-cli --transport wifi sync --session ID [--file FILE] [--delete]
  clip-cli --transport wifi sync --all [--delete]
  clip-cli --transport wifi terminal
"""

import asyncio
import json
import sys
from pathlib import Path

# Add parent directory to path for imports
sys.path.insert(0, str(Path(__file__).parent.parent))

from clip import ClipDevice, ClipCommands, SessionSync
from clip.utils import format_bytes, format_duration, format_speed


async def cmd_status(device, args):
    """Show device status."""
    commands = ClipCommands(device)

    if isinstance(device, dict):
        # WiFiDevice doesn't have ClipCommands, use send_command directly
        resp = await device.send_command("AT+GSTAT")
        if not resp.get("ok"):
            print(f"Error: {resp.get('error')}")
            return 1
        data = resp.get("data", {})
        print(f"State:    {data.get('state', '?')}")
        print(f"Battery:  {data.get('battery', '?')}%")
        print(f"Mode:     {data.get('mode', '?')}")
        print(f"Bitrate:  {data.get('bitrate', '?')}")
        if data.get("free_space"):
            print(f"Storage:  {format_bytes(data.get('free_space') * 1024 * 1024)} free")
        if data.get("session"):
            print(f"Session:  {data.get('session')}")
        return 0

    state = await commands.get_state()
    print(f"State:    {state.state}")
    print(f"Battery:  {state.battery}%")
    print(f"Mode:     {state.mode}")
    print(f"Bitrate:  {state.bitrate}")
    if state.free_space:
        print(f"Storage:  {format_bytes(state.free_space * 1024 * 1024)} free")
    if state.session_id:
        print(f"Session:  {state.session_id}")
        if state.session_files:
            print(f"Files:    {state.session_files}")
        if state.duration:
            print(f"Duration: {format_duration(state.duration)}")
    return 0


async def cmd_version(device, args):
    """Show firmware version."""
    if isinstance(device, dict):
        resp = await device.send_command("AT+VERSION")
        if not resp.get("ok"):
            print(f"Error: {resp.get('error')}")
            return 1
        data = resp.get("data", {})
        print(f"Firmware:  {data.get('firmware', '?')}")
        print(f"Hardware:  {data.get('hardware', '?')}")
        print(f"SDK:       {data.get('sdk', '?')}")
        print(f"Build:     {data.get('build', '?')}")
        return 0

    commands = ClipCommands(device)
    ver = await commands.get_version()
    print(f"Firmware:  {ver.firmware}")
    print(f"Hardware:  {ver.hardware}")
    print(f"SDK:       {ver.sdk}")
    print(f"Build:     {ver.build}")
    return 0


async def cmd_list(device, args):
    """List sessions."""
    if isinstance(device, dict):
        # WiFi: use WiFiSync
        from clip.wifi import WiFiSync
        sync = WiFiSync()
        if not sync.connect():
            print("Connection failed")
            return 1
        sessions = sync.list_sessions()
        sync.disconnect()
    else:
        commands = ClipCommands(device)
        sessions = await commands.list_sessions()

    if not sessions:
        print("No sessions found")
        return 0

    print(f"Sessions: {len(sessions)}")
    for s in sessions:
        sid = s.get('id', '?') if isinstance(s, dict) else s.id
        files = s.get('files', '?') if isinstance(s, dict) else s.files
        size = s.get('size', 0) if isinstance(s, dict) else s.size
        print(f"  {sid}: {files} files, {format_bytes(size)}")
    return 0


async def cmd_sync_ble(device, args):
    """Sync sessions via BLE."""
    commands = ClipCommands(device)
    sync = SessionSync(device)

    device_name = device.device_name or "Unknown_Device"
    device_dir = device_name.replace(' ', '_')
    device_dir = ''.join(c for c in device_dir if c.isalnum() or c in '_.-')

    if args.all_sessions:
        sessions = await commands.list_sessions()
        if not sessions:
            print("No sessions found")
            return 0

        results = []
        for idx, session in enumerate(sessions, 1):
            print(f"\n[{idx}/{len(sessions)}] {session.id}")
            session_dir = args.output / device_dir / session.id
            result = await sync.sync(
                session.id, session_dir,
                delete_after=args.delete,
                force=args.resync,
            )
            results.append(result)

            # Convert to OGG
            if result.get("file_count", 0) > 0:
                from clip.codec import convert_to_ogg_opus
                merged_path = session_dir / f"{session.id}.opus"
                ogg_path = session_dir / f"{session.id}.ogg"
                if merged_path.exists() and merged_path.stat().st_size > 0:
                    channels = result.get("channels", 1)
                    sample_rate = result.get("sample_rate", 16000)
                    if convert_to_ogg_opus(merged_path, ogg_path,
                                            sample_rate=sample_rate, channels=channels):
                        print(f"  OGG: OK")
                    else:
                        print(f"  OGG: Failed")

        success = sum(1 for r in results if r.get("file_count", 0) > 0)
        print(f"\nDone: {success}/{len(results)}")
        return 0 if success == len(results) else 1

    # Single session
    session_id = args.session
    if not session_id:
        sessions = await commands.list_sessions()
        if sessions:
            session_id = sessions[-1].id
            print(f"Latest session: {session_id}")
        else:
            print("No sessions found")
            return 1

    session_dir = args.output / device_dir / session_id
    result = await sync.sync(
        session_id, session_dir,
        delete_after=args.delete,
        force=args.resync,
        start_file=args.file,
    )

    # Convert to OGG
    if result.get("file_count", 0) > 0:
        from clip.codec import convert_to_ogg_opus
        merged_path = session_dir / f"{session_id}.opus"
        ogg_path = session_dir / f"{session_id}.ogg"
        if merged_path.exists() and merged_path.stat().st_size > 0:
            channels = result.get("channels", 1)
            sample_rate = result.get("sample_rate", 16000)
            if convert_to_ogg_opus(merged_path, ogg_path,
                                    sample_rate=sample_rate, channels=channels):
                print(f"OGG: OK")
            else:
                print(f"OGG: Failed")

    print(f"Files: {result.get('file_count', 0)}, "
          f"Total: {format_bytes(result.get('total_size', 0))}")
    print(f"Location: {session_dir}")
    return 0


async def cmd_sync_wifi(args):
    """Sync sessions via WiFi."""
    from clip.wifi import WiFiSync

    sync = WiFiSync(args.host, args.port, args.timeout)
    if not sync.connect():
        print("Connection failed")
        return 1

    try:
        if args.all_sessions:
            sessions = sync.list_sessions()
            if not sessions:
                print("No sessions found")
                return 0

            ok = 0
            for idx, s in enumerate(sessions, 1):
                sid = s.get("id", "?")
                print(f"\n[{idx}/{len(sessions)}] {sid}")
                if sync.download_session(
                    sid, args.output,
                    start_file=args.file,
                    delete_after=args.delete,
                ):
                    ok += 1
                else:
                    print(f"  Failed")
            print(f"\nDone: {ok}/{len(sessions)}")
            return 0 if ok == len(sessions) else 1

        session_id = args.session
        if not session_id:
            sessions = sync.list_sessions()
            if sessions:
                session_id = sessions[-1].get("id", "")
                print(f"Latest session: {session_id}")
            else:
                print("No sessions found")
                return 1

        print(f"Session: {session_id}")
        if sync.download_session(
            session_id, args.output,
            start_file=args.file,
            delete_after=args.delete,
        ):
            print("Done")
            return 0
        else:
            print("Failed")
            return 1
    finally:
        sync.disconnect()


async def cmd_record(device, args):
    """Record with optional sync."""
    commands = ClipCommands(device)
    await commands.ensure_idle()

    session_id = await commands.start_recording(args.mode)
    print(f"Recording started: {session_id}")
    print(f"Mode: {args.mode}")
    print(f"Press Ctrl+C to stop")

    try:
        if args.duration:
            await asyncio.sleep(args.duration)
        else:
            while True:
                await asyncio.sleep(1)
    except KeyboardInterrupt:
        pass

    result = await commands.stop_recording()
    duration = result.get("duration", 0)
    print(f"\nStopped. Duration: {format_duration(duration)}")
    return 0


async def cmd_config(device, args):
    """Get/set configuration."""
    if args.action == "get":
        if args.key:
            cmd_map = {
                "mode": "AT+MODE?",
                "autodel": "AT+AUTODEL?",
                "brightness": "AT+BRIGHTNESS?",
                "wificfg": "AT+WIFICFG?",
                "log": "AT+LOG?",
            }
            cmd = cmd_map.get(args.key)
            if not cmd:
                print(f"Unknown key: {args.key}")
                return 1
            resp = await device.send_command(cmd)
            print(json.dumps(resp, indent=2))
        else:
            # Get all config
            from clip.commands import ClipCommands
            commands = ClipCommands(device)
            config = await commands.get_config_dict()
            for k, v in config.items():
                print(f"  {k}: {v}")
    elif args.action == "set":
        if not args.key_value:
            print("Usage: config set KEY=VALUE")
            return 1
        key, _, value = args.key_value.partition("=")
        cmd_map = {
            "mode": f"AT+MODE={value}",
            "autodel": f"AT+AUTODEL={value}",
            "brightness": f"AT+BRIGHTNESS={value}",
            "name": f"AT+NAME={value}",
            "log": f"AT+LOG={value}",
        }
        cmd = cmd_map.get(key)
        if not cmd:
            print(f"Unknown key: {key}")
            return 1
        resp = await device.send_command(cmd)
        if resp.get("ok"):
            print(f"  {key} = {value}")
        else:
            print(f"Error: {resp.get('error')}")
            return 1
    return 0


async def cmd_delete(device, args):
    """Delete a session."""
    if isinstance(device, dict):
        resp = await device.send_command(f"AT+DELETE={args.session}")
    else:
        commands = ClipCommands(device)
        await commands.delete_session(args.session)
        resp = {"ok": True}

    if resp.get("ok"):
        print(f"Deleted: {args.session}")
    else:
        print(f"Error: {resp.get('error')}")
        return 1
    return 0


async def cmd_bookmark(device, args):
    """Add a bookmark."""
    if isinstance(device, dict):
        resp = await device.send_command("AT+MARK")
    else:
        commands = ClipCommands(device)
        bm = await commands.add_bookmark()
        print(f"Bookmark at {bm.offset}s")
        return 0

    if resp.get("ok"):
        data = resp.get("data", {})
        print(f"Bookmark at {data.get('offset', '?')}s")
    else:
        print(f"Error: {resp.get('error')}")
        return 1
    return 0


async def cmd_terminal(device, args):
    """Interactive terminal."""
    print("\nInteractive mode. Type 'quit' to exit.\n")

    try:
        while True:
            cmd = input("clip> ").strip()
            if not cmd:
                continue
            if cmd.lower() in ('quit', 'exit', 'q'):
                break
            if not cmd.upper().startswith("AT"):
                cmd = "AT+" + cmd

            print(f"> {cmd}")
            resp = await device.send_command(cmd)
            print(f"< {json.dumps(resp, indent=2)}")
    except (EOFError, KeyboardInterrupt):
        print("\nBye")
    return 0


def build_parser():
    parser = argparse.ArgumentParser(
        prog="clip-cli",
        description="Unified CLI for reSpeaker Clip device",
    )
    parser.add_argument("--transport", choices=["ble", "wifi"], default="ble",
                       help="Transport type (default: ble)")
    parser.add_argument("--host", default="192.168.4.1",
                       help="WiFi host (default: 192.168.4.1)")
    parser.add_argument("--port", type=int, default=8089,
                       help="WiFi port (default: 8089)")
    parser.add_argument("--timeout", type=float, default=10.0,
                       help="Command timeout in seconds (default: 10)")
    parser.add_argument("--output", "-o", type=Path, default=Path("recordings"),
                       help="Output directory (default: recordings/)")
    parser.add_argument("--device", "-d", help="BLE device MAC address")

    sub = parser.add_subparsers(dest="command", help="Command")

    # status
    sub.add_parser("status", help="Show device status")

    # version
    sub.add_parser("version", help="Show firmware version")

    # list
    sub.add_parser("list", help="List sessions")

    # sync
    sync_p = sub.add_parser("sync", help="Sync sessions")
    sync_p.add_argument("--session", "-s", help="Session ID")
    sync_p.add_argument("--file", "-f", help="Start from file (e.g., 0015.opus)")
    sync_p.add_argument("--all", "-a", action="store_true", help="Sync all sessions")
    sync_p.add_argument("--delete", action="store_true", help="Delete from device after sync")
    sync_p.add_argument("--resync", "-r", action="store_true", help="Force re-sync")

    # record
    rec_p = sub.add_parser("record", help="Start recording")
    rec_p.add_argument("--mode", "-m", default="normal",
                       choices=["normal", "enhanced", "stereo", "merge"])
    rec_p.add_argument("--duration", "-t", type=int, help="Duration in seconds")

    # config
    cfg_p = sub.add_parser("config", help="Get/set configuration")
    cfg_p.add_argument("action", nargs="?", choices=["get", "set"], default="get")
    cfg_p.add_argument("key", nargs="?", help="Config key")
    cfg_p.add_argument("key_value", nargs="?", help="KEY=VALUE for set")

    # delete
    del_p = sub.add_parser("delete", help="Delete a session")
    del_p.add_argument("session", help="Session ID")

    # bookmark
    sub.add_parser("bookmark", help="Add bookmark")

    # terminal
    sub.add_parser("terminal", help="Interactive terminal")

    return parser


async def main():
    parser = build_parser()
    args = parser.parse_args()

    if not args.command:
        parser.print_help()
        return 0

    def _make_device(address):
        d = ClipDevice(address=address)
        d.event_callback = lambda e: print(
            f"[EVENT] {e.get('event', '?')}: {e.get('state', e.get('status', ''))}"
        )
        return d

    if args.command in ("status", "version", "list", "config", "delete",
                        "bookmark", "terminal"):
        if args.transport == "wifi":
            from clip.wifi import WiFiDevice
            async with WiFiDevice(args.host, args.port, args.timeout) as device:
                return await globals()[f"cmd_{args.command}"](device, args)
        else:
            device = _make_device(args.device)
            await device.connect()
            try:
                return await globals()[f"cmd_{args.command}"](device, args)
            finally:
                await device.disconnect()

    elif args.command == "sync":
        if args.transport == "wifi":
            return await cmd_sync_wifi(args)
        else:
            device = _make_device(args.device)
            await device.connect()
            try:
                return await cmd_sync_ble(device, args)
            finally:
                await device.disconnect()

    elif args.command == "record":
        if args.transport == "wifi":
            print("Error: Recording is only supported via BLE")
            return 1
        device = ClipDevice(address=args.device)
        await device.connect()
        try:
            return await cmd_record(device, args)
        finally:
            await device.disconnect()

    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
