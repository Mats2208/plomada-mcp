"""The bridge's one persistent socket to the SketchUp extension.

Connects lazily on the first call, says hello with the token, then
multiplexes: writes go out under an asyncio.Lock, one reader task routes
responses to waiting calls by id and progress notifications to callbacks.

Read-only calls retry once on a stale socket. Mutating calls never retry:
after a timeout or a dropped connection the outcome is unknown, and the
error says so instead of replaying the mutation.
"""

from __future__ import annotations

import asyncio
import contextlib
import itertools
from collections.abc import Awaitable, Callable
from typing import Any

from . import __version__
from .config import BridgeConfig
from .errors import (
    AUTH,
    PROTOCOL,
    ConnectionLost,
    NotResponding,
    OutcomeUnknown,
    SketchUpError,
    Unreachable,
)
from .framing import FrameTooLarge, encode, read_frame

ProgressCallback = Callable[[float, float | None, str | None], Awaitable[None]]


class SketchUpClient:
    def __init__(self, config: BridgeConfig) -> None:
        self.config = config
        self._lock = asyncio.Lock()
        self._reader: asyncio.StreamReader | None = None
        self._writer: asyncio.StreamWriter | None = None
        self._read_task: asyncio.Task[None] | None = None
        self._pending: dict[int, asyncio.Future[dict[str, Any]]] = {}
        self._progress: dict[int, ProgressCallback] = {}
        self._ids = itertools.count(1)
        self.hello: dict[str, Any] | None = None

    # --- connection ------------------------------------------------------------

    @property
    def connected(self) -> bool:
        return self._read_task is not None and not self._read_task.done() and self.hello is not None

    async def ensure_connected(self) -> dict[str, Any]:
        if self.connected and self.hello is not None:
            return self.hello
        async with self._lock:
            if self.connected and self.hello is not None:
                return self.hello
            await self._drop()
            try:
                return await asyncio.wait_for(self._connect(), timeout=self.config.connect_timeout_s)
            except TimeoutError:
                await self._drop()
                raise NotResponding() from None

    async def _connect(self) -> dict[str, Any]:
        cfg = self.config
        try:
            reader, writer = await asyncio.open_connection(cfg.host, cfg.port)
        except OSError as exc:
            raise Unreachable(
                f"SketchUp is not reachable on {cfg.host}:{cfg.port} ({exc.strerror or exc}): start "
                "SketchUp with the Plomada extension enabled (Extensions > Extension Manager) and retry."
            ) from None
        self._reader, self._writer = reader, writer
        token = self._read_token()
        hello_id = next(self._ids)
        future: asyncio.Future[dict[str, Any]] = asyncio.get_running_loop().create_future()
        self._pending[hello_id] = future
        self._read_task = asyncio.create_task(self._read_loop(reader), name="plomada-reader")
        writer.write(
            encode(
                {
                    "jsonrpc": "2.0",
                    "id": hello_id,
                    "method": "hello",
                    "params": {"protocol": cfg.protocol, "client_version": __version__, "token": token},
                },
                cfg.max_frame_bytes,
            )
        )
        await writer.drain()
        reply = await future
        if "error" in reply:
            err = reply["error"]
            await self._drop()
            raise SketchUpError(err.get("code", PROTOCOL), err.get("message", "hello refused"), err.get("data"))
        self.hello = reply["result"]
        return self.hello

    def _read_token(self) -> str:
        path = self.config.token_path
        try:
            return path.read_text(encoding="ascii").strip()
        except OSError:
            raise SketchUpError(
                AUTH,
                f"no token file at {path}; SketchUp writes it the first time the Plomada extension loads",
            ) from None

    async def _read_loop(self, reader: asyncio.StreamReader) -> None:
        try:
            while True:
                msg = await read_frame(reader, self.config.max_frame_bytes)
                if "method" in msg and "id" not in msg:
                    await self._notify(msg)
                    continue
                future = self._pending.pop(msg.get("id"), None)  # type: ignore[arg-type]
                if future is not None and not future.done():
                    future.set_result(msg)
        except (asyncio.IncompleteReadError, ConnectionError, OSError, FrameTooLarge, ValueError):
            pass
        finally:
            self.hello = None
            for future in self._pending.values():
                if not future.done():
                    future.set_exception(ConnectionLost("the connection to SketchUp closed"))
            self._pending.clear()

    async def _notify(self, msg: dict[str, Any]) -> None:
        if msg.get("method") != "progress":
            return
        params = msg.get("params") or {}
        callback = self._progress.get(params.get("id"))
        if callback is None:
            return
        with contextlib.suppress(Exception):
            await callback(params.get("progress", 0), params.get("total"), params.get("message"))

    async def _drop(self) -> None:
        self.hello = None
        task, self._read_task = self._read_task, None
        writer, self._writer = self._writer, None
        if writer is not None:
            writer.close()
            with contextlib.suppress(Exception):
                await writer.wait_closed()
        if task is not None and not task.done():
            task.cancel()
            with contextlib.suppress(asyncio.CancelledError, Exception):
                await task

    async def close(self) -> None:
        async with self._lock:
            await self._drop()

    # --- calls -------------------------------------------------------------------

    async def call(
        self,
        method: str,
        params: dict[str, Any] | None = None,
        *,
        read_only: bool,
        timeout: float | None = None,
        deadline_ms: int | None = None,
        on_progress: ProgressCallback | None = None,
    ) -> Any:
        """One request. Read-only calls reconnect and retry once on a stale
        socket; mutations raise OutcomeUnknown instead of replaying."""
        cfg = self.config
        if read_only:
            limit = timeout if timeout is not None else cfg.read_timeout_s
        else:
            deadline_ms = deadline_ms or cfg.default_deadline_ms
            limit = deadline_ms / 1000.0 + cfg.mutation_grace_s
        for attempt in (0, 1):
            await self.ensure_connected()
            req_id = next(self._ids)
            future: asyncio.Future[dict[str, Any]] = asyncio.get_running_loop().create_future()
            self._pending[req_id] = future
            if on_progress is not None:
                self._progress[req_id] = on_progress
            message: dict[str, Any] = {"jsonrpc": "2.0", "id": req_id, "method": method, "params": params or {}}
            if deadline_ms is not None:
                message["deadline_ms"] = deadline_ms
            try:
                frame = encode(message, cfg.max_frame_bytes)
                async with self._lock:
                    if self._writer is None:
                        raise ConnectionLost("the connection to SketchUp closed")
                    self._writer.write(frame)
                    await self._writer.drain()
                reply = await asyncio.wait_for(future, timeout=limit)
            except (ConnectionLost, ConnectionError, OSError) as exc:
                self._pending.pop(req_id, None)
                await self._reset()
                if read_only and attempt == 0:
                    continue
                if read_only:
                    raise ConnectionLost(f"the connection to SketchUp dropped during {method}; retry") from exc
                raise OutcomeUnknown(
                    f"The connection to SketchUp dropped during {method}, so its outcome is unknown. "
                    "Call get_plan or status to see the model before retrying; it was not replayed."
                ) from exc
            except TimeoutError:
                self._pending.pop(req_id, None)
                if read_only:
                    raise NotResponding() from None
                await self._send_cancel(req_id)
                raise OutcomeUnknown(
                    f"{method} did not answer within {limit:.0f} s, so its outcome is unknown. Call "
                    "get_plan or status to see the model before retrying; it was not replayed."
                ) from None
            except asyncio.CancelledError:
                self._pending.pop(req_id, None)
                if not read_only:
                    await asyncio.shield(self._send_cancel(req_id))
                raise
            finally:
                self._progress.pop(req_id, None)
            if "error" in reply:
                err = reply["error"]
                raise SketchUpError(err.get("code", -32000), err.get("message", "error"), err.get("data"))
            return reply.get("result")
        raise ConnectionLost(f"{method} could not reach SketchUp")  # pragma: no cover

    async def _reset(self) -> None:
        async with self._lock:
            await self._drop()

    async def _send_cancel(self, target: int) -> None:
        """Best effort: ask the extension to drop or stop a request we gave up on."""
        if not self.connected or self._writer is None:
            return
        frame = encode(
            {"jsonrpc": "2.0", "id": next(self._ids), "method": "cancel", "params": {"id": target}},
            self.config.max_frame_bytes,
        )
        with contextlib.suppress(Exception):
            async with self._lock:
                self._writer.write(frame)
                await self._writer.drain()


async def check_hello(client: SketchUpClient) -> dict[str, Any]:
    """Connects (if needed) and returns the hello answer; used by status."""
    hello = await client.ensure_connected()
    if hello.get("protocol") != client.config.protocol:
        raise SketchUpError(PROTOCOL, f"extension speaks protocol {hello.get('protocol')}")
    return hello
