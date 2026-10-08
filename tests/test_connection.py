"""The bridge socket: hello, auth, timeouts, and retry-only-read-only."""

from __future__ import annotations

import asyncio
import time

import pytest

from conftest import FakeExtension, Reject, make_config
from plomada_bridge import __version__
from plomada_bridge.connection import SketchUpClient
from plomada_bridge.errors import (
    NOT_RESPONDING,
    NotResponding,
    OutcomeUnknown,
    SketchUpError,
    Unreachable,
    describe,
)


async def _with(fake: FakeExtension, tmp_path, body, **cfg):
    await fake.start()
    client = SketchUpClient(make_config(tmp_path, fake.port, **cfg))
    try:
        return await body(client)
    finally:
        await client.close()
        await fake.stop()


def test_hello_then_read(run, tmp_path):
    fake = FakeExtension(handlers={"status": lambda p: {"protocol": 1, "queue_length": 0}})

    async def body(c):
        return await c.call("status", {}, read_only=True)

    assert run(_with(fake, tmp_path, body)) == {"protocol": 1, "queue_length": 0}
    method, params = fake.seen[0]
    assert method == "hello"
    assert params["protocol"] == 1 and len(params["token"]) == 64 and params["client_version"] == __version__


def test_wrong_token_is_auth_error(run, tmp_path):
    fake = FakeExtension(token="0" * 64)

    async def body(c):
        with pytest.raises(SketchUpError) as info:
            await c.call("status", {}, read_only=True)
        return info.value

    err = run(_with(fake, tmp_path, body))
    assert err.code == -32001
    assert "restart SketchUp" in describe(err, "status")


def test_unanswered_hello_is_not_responding_within_the_timeout(run, tmp_path):
    fake = FakeExtension(answer_hello=False)

    async def body(c):
        t0 = time.perf_counter()
        with pytest.raises(NotResponding) as info:
            await c.call("model_info", {}, read_only=True)
        return info.value, time.perf_counter() - t0

    err, elapsed = run(_with(fake, tmp_path, body))
    assert str(err) == NOT_RESPONDING
    assert NOT_RESPONDING == "SketchUp is not responding: a modal dialog may be open in SketchUp, close it and retry"
    assert elapsed < 0.5 + 0.4


def test_unreachable_port(run, tmp_path):
    async def body():
        probe = await asyncio.start_server(lambda r, w: None, "127.0.0.1", 0)
        port = probe.sockets[0].getsockname()[1]
        probe.close()
        await probe.wait_closed()
        c = SketchUpClient(make_config(tmp_path, port))
        with pytest.raises(Unreachable) as info:
            await c.call("status", {}, read_only=True)
        return str(info.value), port

    msg, port = run(body())
    assert f"127.0.0.1:{port}" in msg and "Plomada extension" in msg


def test_read_only_call_reconnects_and_retries_once(run, tmp_path):
    fake = FakeExtension(drop_first={"model_info": 1}, handlers={"model_info": lambda p: {"units": "mm"}})

    async def body(c):
        return await c.call("model_info", {}, read_only=True)

    assert run(_with(fake, tmp_path, body)) == {"units": "mm"}
    assert fake.methods().count("model_info") == 2
    assert fake.hellos == 2


def test_mutation_is_never_replayed_after_a_drop(run, tmp_path):
    fake = FakeExtension(drop_first={"build_plan": 1})

    async def body(c):
        with pytest.raises(OutcomeUnknown) as info:
            await c.call("build_plan", {"plan": {}}, read_only=False)
        return str(info.value)

    msg = run(_with(fake, tmp_path, body))
    assert fake.methods().count("build_plan") == 1
    assert "outcome is unknown" in msg and "get_plan or status" in msg and "not replayed" in msg


def test_mutation_timeout_is_unknown_and_sends_cancel(run, tmp_path):
    fake = FakeExtension(silent={"build_plan"})

    async def body(c):
        with pytest.raises(OutcomeUnknown):
            await c.call("build_plan", {}, read_only=False, deadline_ms=200)
        await asyncio.sleep(0.1)

    run(_with(fake, tmp_path, body))
    assert fake.methods().count("build_plan") == 1
    cancels = [p for m, p in fake.seen if m == "cancel"]
    assert len(cancels) == 1 and isinstance(cancels[0]["id"], int)


def test_status_unanswered_on_a_live_socket_is_not_responding(run, tmp_path):
    fake = FakeExtension(silent={"status"})

    async def body(c):
        await c.call("ping", {}, read_only=True)
        with pytest.raises(NotResponding):
            await c.call("status", {}, read_only=True, timeout=0.3)
        # The socket survives: a late answer is dropped, the next call works.
        return await c.call("ping", {}, read_only=True)

    assert run(_with(fake, tmp_path, body))["method"] == "ping"


def test_progress_is_forwarded_in_order(run, tmp_path):
    fake = FakeExtension(progress={"build_plan": 3}, handlers={"build_plan": lambda p: {"steps": 3}})
    got = []

    async def body(c):
        async def on(p, total, msg):
            got.append((p, total, msg))

        return await c.call("build_plan", {}, read_only=False, on_progress=on)

    assert run(_with(fake, tmp_path, body)) == {"steps": 3}
    assert got == [(1, 3, "step 1"), (2, 3, "step 2"), (3, 3, "step 3")]


def test_extension_errors_keep_their_code(run, tmp_path):
    def refuse(_p):
        raise Reject(-32004, "walls[2].thickness must be greater than 0, got -200")

    fake = FakeExtension(handlers={"build_plan": refuse})

    async def body(c):
        with pytest.raises(SketchUpError) as info:
            await c.call("build_plan", {}, read_only=False)
        return info.value

    err = run(_with(fake, tmp_path, body))
    assert err.code == -32004
    assert describe(err, "build_plan") == (
        "build_plan refused its input (-32004): walls[2].thickness must be greater than 0, got -200. "
        "Fix that value and call it again."
    )


def test_missing_token_file(run, tmp_path):
    fake = FakeExtension()

    async def body():
        await fake.start()
        cfg = make_config(tmp_path, fake.port)
        (tmp_path / "bridge.token").unlink()
        c = SketchUpClient(cfg)
        try:
            with pytest.raises(SketchUpError) as info:
                await c.call("status", {}, read_only=True)
            return info.value
        finally:
            await c.close()
            await fake.stop()

    err = run(body())
    assert err.code == -32001 and "no token file" in err.message
