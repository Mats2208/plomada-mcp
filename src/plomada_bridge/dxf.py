"""Reads the plan records AutoCAD MCP Pro stores in a DXF.

Every architectural object travels as XDATA under the registered application
ACADMCP_ARCH on one entity: a 1001 group with the app name, then 1000 strings
that, concatenated in order, form one JSON object with "v": 1 and a "kind" of
wall, opening, stair or room. A record with any other version is refused by
name; nothing is guessed. The extension never reads DXF: the bridge sends it
the normalized plan.
"""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import ezdxf
from ezdxf.document import Drawing

from .models import RECORD_VERSION, Plan, parse_plan

APP_ID = "ACADMCP_ARCH"
KINDS = ("wall", "opening", "stair", "room")


class DxfPlanError(ValueError):
    """The DXF cannot be turned into a plan; the message says why."""


@dataclass
class DxfPlan:
    plan: Plan
    path: Path
    records: int
    warnings: list[str] = field(default_factory=list)


def _payload(entity: Any) -> dict[str, Any]:
    tags = entity.get_xdata(APP_ID)
    text = "".join(str(tag.value) for tag in tags if tag.code == 1000)
    handle = entity.dxf.handle
    try:
        payload = json.loads(text)
    except json.JSONDecodeError as exc:
        raise DxfPlanError(f"{APP_ID} XDATA on entity {handle} is not JSON ({exc.msg})") from None
    if not isinstance(payload, dict):
        raise DxfPlanError(f"{APP_ID} XDATA on entity {handle} is a {type(payload).__name__}, not an object")
    version = payload.get("v")
    if version != RECORD_VERSION:
        raise DxfPlanError(
            f"{APP_ID} record on entity {handle} has version {version!r}; Plomada reads version "
            f"{RECORD_VERSION} only"
        )
    kind = payload.get("kind")
    if kind not in KINDS:
        raise DxfPlanError(f"{APP_ID} record on entity {handle} has kind {kind!r}; kinds are {', '.join(KINDS)}")
    return payload


def records(doc: Drawing) -> list[dict[str, Any]]:
    """Every ACADMCP_ARCH payload in the drawing, in database order, deduplicated."""
    found: dict[tuple[str, str], dict[str, Any]] = {}
    for entity in doc.entitydb.values():
        if not hasattr(entity, "has_xdata") or not entity.has_xdata(APP_ID):
            continue
        payload = _payload(entity)
        key = (payload["kind"], str(payload.get("id")))
        if key in found and found[key] != payload:
            raise DxfPlanError(f"two different {payload['kind']} records share the id {key[1]!r}")
        found[key] = payload
    return list(found.values())


def read_plan(path: str | Path, storey_height: float | None = None) -> DxfPlan:
    """Parses the DXF with ezdxf and validates the records into a Plan."""
    p = Path(path)
    if not p.is_file():
        raise DxfPlanError(f"dxf_path {str(p)!r} is not a file")
    try:
        doc = ezdxf.readfile(p)
    except (OSError, ezdxf.DXFStructureError) as exc:
        raise DxfPlanError(f"cannot read {p.name} as DXF: {exc}") from None
    recs = records(doc)
    if not recs:
        raise DxfPlanError(
            f"{p.name} holds no {APP_ID} records; export it from AutoCAD MCP Pro, whose arch_* tools write them"
        )
    warnings: list[str] = []
    stairs = [r for r in recs if r["kind"] == "stair"]
    if stairs:
        warnings.append(f"{len(stairs)} stair record(s) skipped: this version builds no stairs")
    raw: dict[str, Any] = {
        "walls": [r for r in recs if r["kind"] == "wall"],
        "openings": [r for r in recs if r["kind"] == "opening"],
        "rooms": [r for r in recs if r["kind"] == "room"],
    }
    if storey_height is not None:
        raw["storey"] = {"height": storey_height}
    try:
        plan = parse_plan(raw)
    except ValueError as exc:
        raise DxfPlanError(f"{p.name}: {exc}") from None
    return DxfPlan(plan=plan, path=p, records=len(recs), warnings=warnings)
