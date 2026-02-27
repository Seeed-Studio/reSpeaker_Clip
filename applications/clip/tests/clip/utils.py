"""
Utility functions for the clip library.
"""

import asyncio
import json
import re
import subprocess
import sys
from pathlib import Path
from typing import Optional, List, Any
from datetime import datetime


def parse_session_id(session_id: str) -> dict:
    """
    Parse a session ID into components.

    Args:
        session_id: Session ID string (e.g., "20240101_120000")

    Returns:
        Dict with year, month, day, hour, minute, second
    """
    match = re.match(r'(\d{4})(\d{2})(\d{2})_(\d{2})(\d{2})(\d{2})', session_id)
    if not match:
        return {}

    return {
        'year': int(match.group(1)),
        'month': int(match.group(2)),
        'day': int(match.group(3)),
        'hour': int(match.group(4)),
        'minute': int(match.group(5)),
        'second': int(match.group(6)),
    }


def format_session_id(timestamp: Optional[float] = None) -> str:
    """
    Create a session ID from timestamp.

    Args:
        timestamp: Unix timestamp (default: now)

    Returns:
        Session ID string (YYYYMMDD_HHMMSS)
    """
    if timestamp is None:
        timestamp = datetime.now().timestamp()
    dt = datetime.fromtimestamp(timestamp)
    return dt.strftime('%Y%m%d_%H%M%S')


def format_bytes(size: int) -> str:
    """
    Format byte count as human-readable string.

    Args:
        size: Size in bytes

    Returns:
        Formatted string (e.g., "1.5 MB")
    """
    for unit in ['B', 'KB', 'MB', 'GB']:
        if size < 1024.0:
            return f"{size:.1f} {unit}"
        size /= 1024.0
    return f"{size:.1f} TB"


def format_duration(seconds: float) -> str:
    """
    Format duration in seconds as human-readable string.

    Args:
        seconds: Duration in seconds

    Returns:
        Formatted string (e.g., "1:23:45" or "45s")
    """
    if seconds < 60:
        return f"{int(seconds)}s"
    elif seconds < 3600:
        minutes = int(seconds // 60)
        secs = int(seconds % 60)
        return f"{minutes}:{secs:02d}"
    else:
        hours = int(seconds // 3600)
        minutes = int((seconds % 3600) // 60)
        secs = int(seconds % 60)
        return f"{hours}:{minutes:02d}:{secs:02d}"


def get_device_address(device_name: str = "reSpeaker") -> Optional[str]:
    """
    Scan for BLE device and return its address.

    Args:
        device_name: Device name filter

    Returns:
        Device MAC address or None if not found
    """
    try:
        import asyncio
        from bleak import BleakScanner

        async def find():
            device = await BleakScanner.find_device_by_filter(
                lambda d, _: d.name and device_name in d.name
            )
            return device.address if device else None

        return asyncio.run(find())
    except Exception:
        return None


def check_ffmpeg_available() -> bool:
    """
    Check if ffmpeg is installed and available.

    Returns:
        True if ffmpeg is available
    """
    try:
        subprocess.run(
            ['ffmpeg', '-version'],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=True,
        )
        return True
    except (subprocess.CalledProcessError, FileNotFoundError):
        return False


def install_opuslib() -> bool:
    """
    Install opuslib if not available.

    Returns:
        True if installation succeeded
    """
    try:
        import opuslib
        return True
    except ImportError:
        try:
            subprocess.check_call(
                [sys.executable, "-m", "pip", "install", "opuslib"]
            )
            return True
        except Exception:
            return False


class ProgressReporter:
    """
    Simple progress reporter without tqdm dependency.

    Example:
        >>> reporter = ProgressReporter("Downloading", 100)
        >>> reporter.update(50)
        >>> reporter.finish()
    """

    def __init__(self, description: str, total: int):
        self.description = description
        self.total = total
        self.current = 0
        self.last_reported = 0
        self.start_time = asyncio.get_event_loop().time()
        self._finished = False

    def update(self, n: int = 1) -> None:
        """Update progress by n items."""
        self.current += n
        percent = (self.current / self.total) * 100 if self.total > 0 else 0

        # Report every 5% or every 10 items
        if (percent - self.last_reported >= 5) or (n >= 10):
            elapsed = asyncio.get_event_loop().time() - self.start_time
            rate = self.current / elapsed if elapsed > 0 else 0
            remaining = (self.total - self.current) / rate if rate > 0 else 0

            print(f"\r  {self.description}: {self.current}/{self.total} "
                  f"({percent:.0f}%) - {format_bytes(self.current * 1024)}/s - "
                  f"ETA: {format_duration(remaining)}", end='', flush=True)
            self.last_reported = percent

    def finish(self) -> None:
        """Mark progress as complete."""
        if not self._finished:
            elapsed = asyncio.get_event_loop().time() - self.start_time
            print(f"\r  {self.description}: {self.current}/{self.total} - "
                  f"Complete in {format_duration(elapsed)}")
            self._finished = True


def load_config_from_file(config_path: Path) -> dict:
    """
    Load configuration from JSON file.

    Args:
        config_path: Path to config file

    Returns:
        Config dict
    """
    if not config_path.exists():
        return {}

    try:
        with open(config_path, 'r') as f:
            return json.load(f)
    except Exception:
        return {}


def save_config_to_file(config: dict, config_path: Path) -> bool:
    """
    Save configuration to JSON file.

    Args:
        config: Config dict
        config_path: Path to save

    Returns:
        True if successful
    """
    try:
        config_path.parent.mkdir(parents=True, exist_ok=True)
        with open(config_path, 'w') as f:
            json.dump(config, f, indent=2)
        return True
    except Exception:
        return False


def find_session_files(session_dir: Path) -> List[Path]:
    """
    Find all Opus files in a session directory.

    Args:
        session_dir: Session directory path

    Returns:
        Sorted list of Opus file paths
    """
    if not session_dir.exists():
        return []

    return sorted(session_dir.glob("*.opus"))


def validate_session_id(session_id: str) -> bool:
    """
    Validate session ID format.

    Args:
        session_id: Session ID to validate

    Returns:
        True if valid format
    """
    return bool(re.match(r'^\d{8}_\d{6}$', session_id))


def merge_opus_files(file_paths: List[Path], output_path: Path) -> bool:
    """
    Merge multiple Opus files into one.

    Args:
        file_paths: List of Opus file paths (sorted)
        output_path: Output file path

    Returns:
        True if successful
    """
    try:
        output_path.parent.mkdir(parents=True, exist_ok=True)
        with open(output_path, 'wb') as outfile:
            for path in file_paths:
                if path.exists():
                    outfile.write(path.read_bytes())
        return True
    except Exception:
        return False
