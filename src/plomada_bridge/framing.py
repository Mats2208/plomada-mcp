"""Length-prefixed JSON frames: 4-byte big-endian length, then UTF-8 JSON."""

from __future__ import annotations

import asyncio
import json
import struct
from typing import Any

HEADER = struct.Struct(">I")


class FrameTooLarge(Exception):
    pass


def encode(message: dict[str, Any], max_bytes: int) -> bytes:
    body = json.dumps(message, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    if not body:
        raise ValueError("refusing to send an empty frame")
    if len(body) > max_bytes:
        raise FrameTooLarge(f"frame of {len(body)} bytes exceeds the {max_bytes}-byte limit")
    return HEADER.pack(len(body)) + body


async def read_frame(reader: asyncio.StreamReader, max_bytes: int) -> dict[str, Any]:
    """The next frame; raises asyncio.IncompleteReadError at EOF."""
    header = await reader.readexactly(HEADER.size)
    (size,) = HEADER.unpack(header)
    if size > max_bytes:
        raise FrameTooLarge(f"frame of {size} bytes exceeds the {max_bytes}-byte limit")
    body = await reader.readexactly(size)
    return json.loads(body.decode("utf-8"))
