"""Typed errors from the extension and the one actionable sentence each becomes."""

from __future__ import annotations

from typing import Any

AUTH = -32001
PROTOCOL = -32002
CANCELLED = -32003
INVALID_PARAMS = -32004
SKETCHUP = -32005
QUEUE_FULL = -32006
MODEL_CHANGED = -32007
RUBY_DISABLED = -32010
PARSE_ERROR = -32700
INVALID_REQUEST = -32600
METHOD_NOT_FOUND = -32601

NOT_RESPONDING = "SketchUp is not responding: a modal dialog may be open in SketchUp, close it and retry"


class BridgeError(Exception):
    """Base class: str(err) is the sentence the model reads."""


class SketchUpError(BridgeError):
    """The extension answered with a JSON-RPC error."""

    def __init__(self, code: int, message: str, data: Any = None) -> None:
        super().__init__(message)
        self.code = code
        self.message = message
        self.data = data


class NotResponding(BridgeError):
    """SketchUp accepted the socket but its pump did not answer in time."""

    def __init__(self) -> None:
        super().__init__(NOT_RESPONDING)


class Unreachable(BridgeError):
    """Nothing listens on the port."""


class ConnectionLost(BridgeError):
    """The socket closed while a request was in flight."""


class OutcomeUnknown(BridgeError):
    """A mutation timed out or its connection dropped: it may or may not have run."""


class InvalidInput(BridgeError):
    """Input refused by the bridge before anything was sent (DXF or pydantic)."""


def describe(err: BaseException, tool: str) -> str:
    """One actionable sentence for the model."""
    if isinstance(err, SketchUpError):
        return _describe_code(err, tool)
    return str(err)


def _describe_code(err: SketchUpError, tool: str) -> str:
    msg = err.message.rstrip(".")
    code = err.code
    if code == AUTH:
        return (
            f"{tool} was refused (-32001 auth): the token in bridge.token does not match the "
            "running extension; restart SketchUp so it rewrites %LOCALAPPDATA%\\Plomada\\bridge.token, "
            "then retry."
        )
    if code == PROTOCOL:
        return (
            f"{tool} failed (-32002 protocol): {msg}. Install the same Plomada version for the "
            "extension and the bridge (scripts/install.ps1), restart SketchUp and retry."
        )
    if code == CANCELLED:
        reverted = isinstance(err.data, dict) and err.data.get("reverted")
        tail = " The model was restored to its state before the call." if reverted else ""
        return f"{tool} did not finish (-32003): {msg}.{tail} Call it again if you still want it."
    if code == INVALID_PARAMS:
        return f"{tool} refused its input (-32004): {msg}. Fix that value and call it again."
    if code == SKETCHUP:
        return (
            f"SketchUp raised an error during {tool} (-32005): {msg}. Its changes were rolled back; "
            "check the input or call status."
        )
    if code == QUEUE_FULL:
        return f"{tool} was not queued (-32006): {msg}. Wait for the running job (job_status) and retry."
    if code == MODEL_CHANGED:
        return f"{tool} stopped (-32007): {msg}. Call get_plan to see what is in the model before retrying."
    if code == RUBY_DISABLED:
        return (
            "execute_ruby is disabled (-32010). Enable 'Allow execute_ruby' in SketchUp under "
            "Extensions > Plomada > Settings if you trust this session, then retry."
        )
    if code == METHOD_NOT_FOUND:
        return (
            f"The SketchUp extension does not know {tool} (-32601): update the Plomada extension to "
            "the bridge's version with scripts/install.ps1 and restart SketchUp."
        )
    return f"{tool} failed ({code}): {msg}."
