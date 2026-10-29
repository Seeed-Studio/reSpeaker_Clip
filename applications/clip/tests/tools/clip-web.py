#!/usr/bin/env python3
"""
clip-web — Web interface for reSpeaker Clip device.

REST API + WebSocket for real-time control and monitoring.

Usage:
  clip-web [--host 0.0.0.0] [--port 5000] [--transport ble|wifi]
  clip-web --transport wifi  # Use WiFi UDP transport
"""

import asyncio
import base64
import json
import sys
from pathlib import Path
from typing import Optional

# Add parent directory to path for imports
sys.path.insert(0, str(Path(__file__).parent.parent))

from clip import ClipDevice, ClipCommands, SessionSync
from clip.codec import convert_to_ogg_opus
from clip.utils import format_bytes, format_duration

from fastapi import FastAPI, WebSocket, WebSocketDisconnect
from fastapi.responses import HTMLResponse, FileResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel


# Global state
_device: Optional[object] = None
_transport = "ble"
_host = "192.168.4.1"
_port = 8089
_ws_clients: list[WebSocket] = []
_recordings_dir = Path("recordings")
_sync_task: Optional[asyncio.Task] = None
_sync_progress_info: dict = {}  # Shared progress state for WS broadcasting


def _get_commands():
    if isinstance(_device, ClipDevice):
        return ClipCommands(_device)
    return None


async def get_device():
    """Get or create device connection."""
    global _device

    if _device is not None:
        if isinstance(_device, ClipDevice) and _device.is_connected:
            return _device

    if _transport == "wifi":
        from clip.wifi import WiFiDevice
        _device = WiFiDevice(_host, _port)
        await _device.connect()
    else:
        _device = ClipDevice()
        await _device.connect(sync_time=False)

    # Set up audio visualization forwarding (BLE only)
    if isinstance(_device, ClipDevice) and not hasattr(_device, '_vis_callback_set'):
        _device._vis_callback_set = True

        async def _forward_audio_vis(data: bytes):
            b64 = base64.b64encode(data).decode('ascii')
            dead = []
            for ws in _ws_clients:
                try:
                    await ws.send_json({"type": "audio_vis", "data": b64})
                except Exception:
                    dead.append(ws)
            for ws in dead:
                if ws in _ws_clients:
                    _ws_clients.remove(ws)

        _device.set_audio_vis_callback(_forward_audio_vis)

    return _device


# ---- Pydantic models ----

class ConfigSetRequest(BaseModel):
    key: str
    value: str

class SyncRequest(BaseModel):
    session_id: Optional[str] = None
    start_file: Optional[str] = None
    delete_after: bool = False

class RecordStartRequest(BaseModel):
    mode: str = "normal"
    attach: bool = False
    session_id: Optional[str] = None


# ---- FastAPI app ----

app = FastAPI(title="Clip Control")

static_dir = Path(__file__).parent / "static"


@app.get("/")
async def index():
    index_path = static_dir / "index.html"
    if index_path.exists():
        return HTMLResponse(index_path.read_text(encoding='utf-8'))
    return HTMLResponse("<h1>clip-web</h1><p>Static files not found.</p>")


@app.get("/api/status")
async def api_status():
    device = await get_device()
    resp = await device.send_command("AT+GSTAT")
    # Append sync progress if active
    if _sync_progress_info.get("active"):
        if resp.get("ok"):
            resp["data"]["sync"] = {
                "files": _sync_progress_info.get("files", 0),
                "bytes": _sync_progress_info.get("bytes", 0),
                "filename": _sync_progress_info.get("filename", ""),
            }
    return resp


@app.get("/api/version")
async def api_version():
    device = await get_device()
    resp = await device.send_command("AT+VERSION")
    return resp


@app.get("/api/sessions")
async def api_sessions():
    device = await get_device()
    resp = await device.send_command("AT+LIST")
    return resp


@app.post("/api/record/start")
async def api_record_start(req: RecordStartRequest):
    global _sync_task
    device = await get_device()

    if req.attach and req.session_id:
        # Attach mode: device is already recording, just start sync
        await _start_realtime_sync(device, req.session_id)
        return {"ok": True, "data": {"session": req.session_id, "attached": True}}

    resp = await device.send_command(f"AT+START={req.mode}")

    if resp.get("ok"):
        session_id = (resp.get("data") or {}).get("session", "")
        if session_id:
            await _start_realtime_sync(device, session_id)

    return resp


async def _start_realtime_sync(device, session_id: str):
    """Start background sync task (continuous mode) while recording."""
    global _sync_task, _sync_progress_info

    # Cancel any previous sync task
    if _sync_task and not _sync_task.done():
        _sync_task.cancel()

    device_name = device.device_name or "Unknown_Device"
    device_dir = device_name.replace(' ', '_')
    device_dir = ''.join(c for c in device_dir if c.isalnum() or c in '_.-')
    session_dir = _recordings_dir / device_dir / session_id

    _sync_progress_info = {"session_id": session_id, "files": 0, "bytes": 0, "filename": "", "active": True}

    async def _sync_loop():
        try:
            sync = SessionSync(device)
            result = await sync.sync(
                session_id, session_dir,
                delete_after=False,
                continuous=True,
                progress_callback=_on_sync_progress,
            )
            # Convert to OGG after recording stops
            if result.get("file_count", 0) > 0:
                merged_path = session_dir / f"{session_id}.opus"
                ogg_path = session_dir / f"{session_id}.ogg"
                if merged_path.exists() and merged_path.stat().st_size > 0:
                    channels = result.get("channels", 1)
                    sample_rate = result.get("sample_rate", 16000)
                    convert_to_ogg_opus(merged_path, ogg_path,
                                         sample_rate=sample_rate, channels=channels)
            _sync_progress_info["active"] = False
            await _broadcast_sync_done(result)
        except asyncio.CancelledError:
            _sync_progress_info["active"] = False
        except Exception as e:
            _sync_progress_info["active"] = False
            await _broadcast({"type": "sync_error", "error": str(e)})

    def _on_sync_progress(filename, file_count, total_size):
        _sync_progress_info.update({
            "filename": filename, "files": file_count, "bytes": total_size
        })
        asyncio.create_task(_broadcast({
            "type": "sync_progress",
            "session_id": session_id,
            "filename": filename,
            "file_count": file_count,
            "total_size": total_size,
        }))

    _sync_task = asyncio.create_task(_sync_loop())


async def _broadcast(msg):
    """Send message to all WebSocket clients."""
    dead = []
    for ws in _ws_clients:
        try:
            await ws.send_json(msg)
        except Exception:
            dead.append(ws)
    for ws in dead:
        if ws in _ws_clients:
            _ws_clients.remove(ws)


async def _broadcast_sync_done(result):
    """Broadcast sync completion."""
    await _broadcast({
        "type": "sync_done",
        "session_id": _sync_progress_info.get("session_id"),
        "file_count": result.get("file_count", 0),
        "total_size": result.get("total_size", 0),
    })


@app.post("/api/record/stop")
async def api_record_stop():
    device = await get_device()
    resp = await device.send_command("AT+STOP")
    # sync task will detect recording stopped via continuous mode
    return resp


@app.post("/api/record/pause")
async def api_record_pause():
    device = await get_device()
    resp = await device.send_command("AT+PAUSE")
    return resp


@app.post("/api/record/resume")
async def api_record_resume():
    device = await get_device()
    resp = await device.send_command("AT+RESUME")
    return resp


@app.post("/api/record/bookmark")
async def api_record_bookmark():
    device = await get_device()
    resp = await device.send_command("AT+MARK")
    return resp


@app.post("/api/sync/{session_id}")
async def api_sync_session(session_id: str, req: SyncRequest = None):
    """Sync a specific session."""
    if req is None:
        req = SyncRequest(session_id=session_id)

    device = await get_device()
    sync = SessionSync(device)

    device_name = device.device_name or "Unknown_Device"
    device_dir = device_name.replace(' ', '_')
    device_dir = ''.join(c for c in device_dir if c.isalnum() or c in '_.-')

    session_dir = _recordings_dir / device_dir / session_id

    def ws_progress(filename, file_count, total_size):
        for ws in _ws_clients:
            try:
                asyncio.create_task(ws.send_json({
                    "type": "sync_progress",
                    "filename": filename,
                    "file_count": file_count,
                    "total_size": total_size,
                }))
            except Exception:
                pass

    try:
        result = await sync.sync(
            session_id, session_dir,
            delete_after=req.delete_after,
            start_file=req.start_file,
            progress_callback=ws_progress,
        )

        # Convert to OGG
        if result.get("file_count", 0) > 0:
            merged_path = session_dir / f"{session_id}.opus"
            ogg_path = session_dir / f"{session_id}.ogg"
            if merged_path.exists() and merged_path.stat().st_size > 0:
                channels = result.get("channels", 1)
                sample_rate = result.get("sample_rate", 16000)
                convert_to_ogg_opus(merged_path, ogg_path,
                                     sample_rate=sample_rate, channels=channels)

        return {"ok": True, **result}
    except Exception as e:
        return {"ok": False, "error": str(e)}


@app.delete("/api/sessions/{session_id}")
async def api_delete_session(session_id: str):
    device = await get_device()
    resp = await device.send_command(f"AT+DELETE={session_id}")
    return resp


@app.get("/api/config")
async def api_config():
    commands = _get_commands()
    if commands:
        config = await commands.get_config_dict()
        return {"ok": True, "data": config}
    device = await get_device()
    resp = await device.send_command("AT+GSTAT")
    return resp


@app.put("/api/config")
async def api_config_set(req: ConfigSetRequest):
    device = await get_device()
    cmd_map = {
        "mode": f"AT+MODE={req.value}",
        "noise": f"AT+NOISE={req.value}",
        "dereverb": f"AT+DEREVERB={req.value}",
    }
    cmd = cmd_map.get(req.key)
    if not cmd:
        return {"ok": False, "error": f"Unknown key: {req.key}"}
    return await device.send_command(cmd)


# ---- Recordings API ----

@app.get("/api/recordings")
async def api_list_recordings():
    """List synced recordings on disk."""
    recordings = []
    if not _recordings_dir.exists():
        return {"ok": True, "data": recordings}

    for device_dir in sorted(_recordings_dir.iterdir()):
        if not device_dir.is_dir():
            continue
        for session_dir in sorted(device_dir.iterdir()):
            if not session_dir.is_dir():
                continue
            # Look for .ogg files
            ogg_files = list(session_dir.glob("*.ogg"))
            opus_files = list(session_dir.glob("*.opus"))
            if not ogg_files and not opus_files:
                continue
            # Prefer .ogg for playback
            audio_file = ogg_files[0] if ogg_files else opus_files[0]
            recordings.append({
                "session_id": session_dir.name,
                "device": device_dir.name,
                "file": audio_file.name,
                "size": audio_file.stat().st_size,
                "path": str(audio_file),
            })

    # Sort by session_id descending (newest first)
    recordings.sort(key=lambda r: r["session_id"], reverse=True)
    return {"ok": True, "data": recordings}


@app.get("/api/play/{path:path}")
async def api_play_file(path: str):
    """Stream an audio file for playback."""
    file_path = Path(path)
    # Security: only allow files under recordings dir
    try:
        file_path = file_path.resolve()
        recordings_resolve = _recordings_dir.resolve()
        if not str(file_path).startswith(str(recordings_resolve)):
            return {"ok": False, "error": "Access denied"}
    except Exception:
        return {"ok": False, "error": "Invalid path"}

    if not file_path.exists():
        return {"ok": False, "error": "File not found"}

    return FileResponse(
        file_path,
        media_type="audio/ogg",
        headers={"Content-Disposition": f"inline; filename=\"{file_path.name}\""}
    )


@app.websocket("/ws")
async def websocket_endpoint(ws: WebSocket):
    await ws.accept()
    _ws_clients.append(ws)
    push_task = None

    async def _push_status():
        """Background task: periodically push device status to this client."""
        while True:
            try:
                await asyncio.sleep(3)
                device = await get_device()
                status = await device.send_command("AT+GSTAT")
                await ws.send_json({"type": "state_update", "data": status})
            except asyncio.CancelledError:
                break
            except Exception:
                pass

    try:
        # Start background status push for all connected clients
        push_task = asyncio.create_task(_push_status())
        while True:
            message = await ws.receive_text()
            try:
                msg = json.loads(message)
                cmd_type = msg.get("type")

                if cmd_type == "command":
                    device = await get_device()
                    resp = await device.send_command(msg.get("command", ""))
                    await ws.send_json({"type": "response", "data": resp})

            except json.JSONDecodeError:
                await ws.send_json({"type": "error", "message": "Invalid JSON"})
    except WebSocketDisconnect:
        pass
    except Exception:
        pass
    finally:
        if push_task:
            push_task.cancel()
        if ws in _ws_clients:
            _ws_clients.remove(ws)


def main():
    import argparse
    import uvicorn

    parser = argparse.ArgumentParser(description="clip-web — Web interface for Clip")
    parser.add_argument("--host", default="0.0.0.0", help="Bind host")
    parser.add_argument("--port", type=int, default=5000, help="Bind port")
    parser.add_argument("--transport", choices=["ble", "wifi"], default="ble",
                       help="Transport type (default: ble)")
    parser.add_argument("--wifi-host", default="192.168.4.1", help="WiFi device host")
    parser.add_argument("--wifi-port", type=int, default=8089, help="WiFi device port")
    args = parser.parse_args()

    global _transport, _host, _port
    _transport = args.transport
    _host = args.wifi_host
    _port = args.wifi_port

    print(f"clip-web starting on http://{args.host}:{args.port}")
    print(f"Transport: {args.transport}")

    if args.transport == "wifi":
        print(f"WiFi target: {_host}:{_port}")

    uvicorn.run(app, host=args.host, port=args.port, log_level="info")


if __name__ == "__main__":
    main()
