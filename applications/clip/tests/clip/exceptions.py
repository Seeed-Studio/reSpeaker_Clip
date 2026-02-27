"""
Custom exceptions for the clip library.
"""


class ClipError(Exception):
    """Base exception for all clip library errors."""
    def __init__(self, message: str = "", *args, **kwargs):
        super().__init__(message, *args)
        self.message = message


class ConnectionError(ClipError):
    """Raised when connection to the device fails."""
    pass


class DisconnectedError(ClipError):
    """Raised when the device disconnects unexpectedly."""
    pass


class CommandError(ClipError):
    """Raised when an AT command fails."""
    def __init__(self, message: str = "", command: str = None, *args, **kwargs):
        super().__init__(message, *args)
        self.message = message
        self.command = command


class TransferError(ClipError):
    """Raised when a file transfer operation fails."""
    pass


class TimeoutError(ClipError):
    """Raised when an operation times out."""
    pass


class ResponseError(ClipError):
    """Raised when the device returns an invalid or unexpected response."""
    pass


class StateError(ClipError):
    """Raised when the device is in an invalid state for the requested operation."""
    pass
