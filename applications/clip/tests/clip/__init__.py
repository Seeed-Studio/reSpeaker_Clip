"""
reSpeaker Clip - Python BLE Control Library

A Python library for controlling the reSpeaker Clip device via BLE.
Provides high-level APIs for device management, AT commands, and file transfer.
"""

from .client import ClipDevice
from .commands import ClipCommands
from .transfer import FileTransfer, SessionSync
from .exceptions import (
    ClipError,
    ConnectionError,
    CommandError,
    TransferError,
    TimeoutError,
)

__version__ = "1.0.0"
__all__ = [
    "ClipDevice",
    "ClipCommands",
    "FileTransfer",
    "SessionSync",
    "ClipError",
    "ConnectionError",
    "CommandError",
    "TransferError",
    "TimeoutError",
]
