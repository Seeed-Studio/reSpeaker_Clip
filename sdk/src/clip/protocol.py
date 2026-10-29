"""Protocol constants and strict decoders shared by BLE and UDP transports."""

from __future__ import annotations

import json
import struct
from dataclasses import dataclass
from typing import Any

from .exceptions import ProtocolError
from .validation import chunk_name, session_id

SERVICE_UUID = "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"
COMMAND_UUID = "6E400002-B5A3-F393-E0A9-E50E24DCCA9E"
RESPONSE_UUID = "6E400003-B5A3-F393-E0A9-E50E24DCCA9E"
FILE_DATA_UUID = "6E400004-B5A3-F393-E0A9-E50E24DCCA9E"
AUDIO_VIS_UUID = "6E400005-B5A3-F393-E0A9-E50E24DCCA9E"

FRAME_DATA = 0x01
FRAME_FILE_ACK = 0x03
FRAME_FILE_START = 0x10
FRAME_FILE_END = 0x11
FRAME_TRANSFER_DONE = 0x12
FRAME_STREAM_START = 0x13
FRAME_STREAM_DATA = 0x14
FRAME_STREAM_END = 0x15
FRAME_AT_RESPONSE = 0x20
FRAME_HEARTBEAT = 0x30


class JsonNotificationDecoder:
    """Incrementally decode one or more UTF-8 JSON values from notifications."""

    def __init__(self) -> None:
        self._buffer = bytearray()
        self._decoder = json.JSONDecoder()

    def feed(self, data: bytes) -> list[dict[str, Any]]:
        self._buffer.extend(data)
        try:
            text = self._buffer.decode("utf-8")
        except UnicodeDecodeError as exc:
            if exc.reason == "unexpected end of data":
                return []
            self._buffer.clear()
            raise ProtocolError("response notification is not UTF-8") from exc

        values: list[dict[str, Any]] = []
        offset = 0
        while True:
            while offset < len(text) and text[offset].isspace():
                offset += 1
            if offset == len(text):
                self._buffer.clear()
                return values
            try:
                value, end = self._decoder.raw_decode(text, offset)
            except json.JSONDecodeError as exc:
                # JSONDecodeError does not reliably distinguish a malformed
                # object from an object cut mid-token (e.g. `{"ok":tr`).  Keep
                # the tail until another notification arrives, but bound it so
                # corrupt traffic cannot retain unbounded memory.
                tail = text[offset:].encode("utf-8")
                if len(tail) > 4096:
                    self._buffer.clear()
                    raise ProtocolError(f"oversized or malformed JSON response: {exc.msg}") from exc
                self._buffer[:] = tail
                return values
            if not isinstance(value, dict):
                self._buffer.clear()
                raise ProtocolError("command response must be a JSON object")
            values.append(value)
            offset = end


@dataclass(frozen=True)
class DataFrame:
    sequence: int
    payload: bytes


@dataclass(frozen=True)
class FileStartFrame:
    filename: str
    size: int


@dataclass(frozen=True)
class FileEndFrame:
    crc32: int


@dataclass(frozen=True)
class TransferDoneFrame:
    session_id: str
    file_count: int


@dataclass(frozen=True)
class StreamStartFrame:
    session_id: str


@dataclass(frozen=True)
class StreamDataFrame:
    sequence: int
    payload: bytes


@dataclass(frozen=True)
class StreamEndFrame:
    reason: int


TransferFrame = (
    DataFrame
    | FileStartFrame
    | FileEndFrame
    | TransferDoneFrame
    | StreamStartFrame
    | StreamDataFrame
    | StreamEndFrame
)


def decode_file_frame(data: bytes, *, udp: bool = False) -> TransferFrame:
    """Decode a firmware file-data notification/datagram.

    BLE DATA frames use a 5-byte header. UDP DATA frames add a per-datagram
    CRC32 field, which is checked here before the payload is accepted.
    """
    if not data:
        raise ProtocolError("empty transfer frame")
    frame_type = data[0]

    if frame_type == FRAME_DATA:
        header_size = 9 if udp else 5
        if len(data) < header_size:
            raise ProtocolError("truncated DATA frame")
        sequence, payload_size = struct.unpack_from("<HH", data, 1)
        offset = 5
        if udp:
            expected_crc = struct.unpack_from("<I", data, offset)[0]
            offset += 4
        if len(data) != offset + payload_size:
            raise ProtocolError("DATA frame length does not match its header")
        payload = data[offset:]
        if udp:
            import zlib

            if (zlib.crc32(payload) & 0xFFFFFFFF) != expected_crc:
                raise ProtocolError("UDP DATA frame CRC32 mismatch")
        return DataFrame(sequence=sequence, payload=payload)

    if frame_type == FRAME_FILE_START:
        if len(data) < 6:
            raise ProtocolError("truncated FILE_START frame")
        name_size = data[1]
        expected_size = 2 + name_size + 4
        if name_size == 0 or len(data) != expected_size:
            raise ProtocolError("invalid FILE_START frame")
        try:
            filename = data[2 : 2 + name_size].decode("utf-8")
        except UnicodeDecodeError as exc:
            raise ProtocolError("FILE_START filename is not UTF-8") from exc
        chunk_name(filename)
        size = struct.unpack_from("<I", data, 2 + name_size)[0]
        return FileStartFrame(filename=filename, size=size)

    if frame_type == FRAME_FILE_END:
        if len(data) != 5:
            raise ProtocolError("invalid FILE_END frame")
        return FileEndFrame(crc32=struct.unpack_from("<I", data, 1)[0])

    if frame_type == FRAME_TRANSFER_DONE:
        if len(data) < 7:
            raise ProtocolError("truncated TRANSFER_DONE frame")
        sid_size = data[1]
        expected_size = 2 + sid_size + 4
        if sid_size == 0 or len(data) != expected_size:
            raise ProtocolError("invalid TRANSFER_DONE frame")
        try:
            sid = data[2 : 2 + sid_size].decode("ascii")
        except UnicodeDecodeError as exc:
            raise ProtocolError("TRANSFER_DONE session id is not ASCII") from exc
        session_id(sid)
        count = struct.unpack_from("<I", data, 2 + sid_size)[0]
        return TransferDoneFrame(session_id=sid, file_count=count)

    if frame_type == FRAME_STREAM_START:
        if len(data) < 2:
            raise ProtocolError("truncated STREAM_START frame")
        sid_size = data[1]
        if sid_size == 0 or len(data) != 2 + sid_size:
            raise ProtocolError("invalid STREAM_START frame")
        try:
            sid = data[2 : 2 + sid_size].decode("ascii")
        except UnicodeDecodeError as exc:
            raise ProtocolError("STREAM_START session id is not ASCII") from exc
        session_id(sid)
        return StreamStartFrame(session_id=sid)

    if frame_type == FRAME_STREAM_DATA:
        if len(data) < 5:
            raise ProtocolError("truncated STREAM_DATA frame")
        sequence, payload_size = struct.unpack_from("<HH", data, 1)
        if len(data) != 5 + payload_size:
            raise ProtocolError("STREAM_DATA frame length does not match its header")
        return StreamDataFrame(sequence=sequence, payload=data[5:])

    if frame_type == FRAME_STREAM_END:
        if len(data) != 2:
            raise ProtocolError("invalid STREAM_END frame")
        return StreamEndFrame(reason=data[1])

    raise ProtocolError(f"unexpected transfer frame type 0x{frame_type:02x}")
