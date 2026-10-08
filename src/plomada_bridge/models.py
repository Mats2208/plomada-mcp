"""Pydantic models that mirror the AutoCAD MCP Pro plan records (ACADMCP_ARCH, v 1).

All lengths are millimetres in world coordinates. Validation errors become
one line that starts with the field path, e.g.
``walls[2].thickness must be greater than 0, got -200`` - the same wording the
extension uses for its own checks.
"""

from __future__ import annotations

import math
from typing import Annotated, Any, Literal

from pydantic import BaseModel, ConfigDict, Field, ValidationError, field_validator, model_validator

RECORD_VERSION = 1
MAX_MM = 1_000_000.0  # 1 km: anything larger is a units mistake

Mm = Annotated[float, Field(allow_inf_nan=False)]
Point = Annotated[tuple[Mm, Mm], Field(description="[x, y] in mm")]


class _Record(BaseModel):
    model_config = ConfigDict(extra="ignore", populate_by_name=True)

    v: int | None = Field(default=None, description="record version; only 1 is read")

    @field_validator("v")
    @classmethod
    def _version(cls, value: int | None) -> int | None:
        if value is not None and value != RECORD_VERSION:
            raise ValueError(f"is {value}; Plomada reads record version {RECORD_VERSION} only")
        return value


class Wall(_Record):
    id: Annotated[str, Field(min_length=1, description="wall id, unique in the plan")]
    axis: Annotated[list[Point], Field(min_length=2, description="axis polyline, mm")]
    thickness: Annotated[float, Field(gt=0, le=MAX_MM, description="wall thickness, mm")]
    justification: Literal["center", "left", "right"] = Field(
        default="center", description="side of the axis the wall lies on, looking from its first point"
    )
    material: str = Field(default="brick", min_length=1)
    closed: bool = False
    height: Annotated[float | None, Field(gt=0, le=MAX_MM, description="wall height, mm")] = None

    @model_validator(mode="after")
    def _shape(self) -> Wall:
        need = 3 if self.closed else 2
        if len(self.axis) < need:
            kind = "closed" if self.closed else "open"
            raise ValueError(f"axis must hold at least {need} points for a {kind} wall, got {len(self.axis)}")
        for i in range(1, len(self.axis)):
            if math.dist(self.axis[i - 1], self.axis[i]) <= 1e-9:
                raise ValueError(f"axis[{i}] repeats axis[{i - 1}]; a zero-length segment has no direction")
        if self.closed and math.dist(self.axis[-1], self.axis[0]) <= 1e-9:
            raise ValueError(f"axis[{len(self.axis) - 1}] repeats axis[0]; closed already closes the loop")
        return self


class Opening(_Record):
    id: Annotated[str, Field(min_length=1)]
    wall: Annotated[str, Field(min_length=1, description="id of the host wall")]
    opening_kind: Literal["door", "window"]
    offset: Annotated[float, Field(ge=0, le=MAX_MM, description="mm along the host axis to the near jamb")]
    width: Annotated[float, Field(gt=0, le=MAX_MM, description="mm")]
    sill: Annotated[float | None, Field(ge=0, le=MAX_MM, description="mm; null is 0 for doors")] = None
    height: Annotated[float | None, Field(gt=0, le=MAX_MM, description="mm")] = None
    swing: Literal["in", "out"] = "in"
    hand: Literal["left", "right"] = "left"
    tag: str | None = None


class Room(_Record):
    id: Annotated[str, Field(min_length=1)]
    name: Annotated[str, Field(min_length=1)]
    number: str | None = None
    at: Point
    area: Annotated[float, Field(ge=0, description="mm2")] = 0.0

    @field_validator("number", mode="before")
    @classmethod
    def _number_text(cls, value: Any) -> Any:
        return str(value) if isinstance(value, int) and not isinstance(value, bool) else value


class Storey(BaseModel):
    model_config = ConfigDict(extra="forbid")

    name: str = "N00"
    height: Annotated[float, Field(gt=0, le=MAX_MM, description="storey and wall height, mm")] = 2800.0


class Plan(BaseModel):
    model_config = ConfigDict(extra="ignore")

    walls: Annotated[list[Wall], Field(min_length=1)]
    openings: list[Opening] = Field(default_factory=list)
    rooms: list[Room] = Field(default_factory=list)
    storey: Storey | None = None

    @model_validator(mode="after")
    def _references(self) -> Plan:
        _unique("walls", [w.id for w in self.walls])
        _unique("openings", [o.id for o in self.openings])
        _unique("rooms", [r.id for r in self.rooms])
        ids = {w.id for w in self.walls}
        for i, o in enumerate(self.openings):
            if o.wall not in ids:
                raise ValueError(
                    f"openings[{i}].wall names {o.wall!r}, which is not in the plan; walls are {', '.join(ids)}"
                )
        return self

    def to_wire(self) -> dict[str, Any]:
        """The JSON the extension's build_plan takes (records carry v and kind)."""
        out: dict[str, Any] = {
            "walls": [{"v": 1, "kind": "wall", **w.model_dump(exclude={"v"}, exclude_none=True)} for w in self.walls],
            "openings": [{"v": 1, "kind": "opening", **o.model_dump(exclude={"v"})} for o in self.openings],
            "rooms": [{"v": 1, "kind": "room", **r.model_dump(exclude={"v"})} for r in self.rooms],
        }
        if self.storey is not None:
            out["storey"] = self.storey.model_dump()
        return out


def _unique(path: str, ids: list[str]) -> None:
    seen: dict[str, int] = {}
    for i, value in enumerate(ids):
        if value in seen:
            raise ValueError(f"{path}[{i}].id repeats {value!r} from {path}[{seen[value]}]")
        seen[value] = i


# --- error wording ------------------------------------------------------------------


def field_path(loc: tuple[Any, ...]) -> str:
    out = ""
    for part in loc:
        if isinstance(part, int):
            out += f"[{part}]"
        else:
            out += f".{part}" if out else str(part)
    return out


def _num(value: Any) -> str:
    if isinstance(value, bool):
        return repr(value)
    if isinstance(value, (int, float)):
        f = float(value)
        return str(int(f)) if f.is_integer() else f"{f:g}"
    return repr(value)


def describe_error(err: ValidationError) -> str:
    """The first validation error as 'path message', e.g. 'walls[2].thickness must be greater than 0, got -200'."""
    first = err.errors(include_url=False)[0]
    loc = tuple(p for p in first["loc"] if not (isinstance(p, str) and p.startswith("function-")))
    path = field_path(loc)
    kind = first["type"]
    ctx = first.get("ctx") or {}
    got = first.get("input")
    if kind == "greater_than":
        text = f"must be greater than {_num(ctx['gt'])}, got {_num(got)}"
    elif kind == "greater_than_equal":
        text = f"must be greater than or equal to {_num(ctx['ge'])}, got {_num(got)}"
    elif kind == "less_than_equal":
        text = f"must be at most {_num(ctx['le'])}, got {_num(got)}"
    elif kind == "missing":
        text = "is required"
    elif kind == "literal_error":
        text = f"must be one of {ctx['expected']}, got {got!r}"
    elif kind in {"float_parsing", "float_type", "int_parsing", "int_type"}:
        text = f"must be a number, got {got!r}"
    elif kind in {"finite_number"}:
        text = f"must be finite, got {got!r}"
    elif kind == "too_short":
        text = f"must hold at least {ctx.get('min_length')} items, got {ctx.get('actual_length')}"
    elif kind == "string_too_short":
        text = "must not be empty"
    elif kind == "bool_type" or kind == "bool_parsing":
        text = f"must be true or false, got {got!r}"
    elif kind == "value_error":
        text = str(ctx.get("error", first["msg"]))
        return text if not path else f"{path}.{text}" if text.startswith("axis") else f"{path} {text}"
    else:
        text = first["msg"]
    return f"{path} {text}" if path else text


def parse_plan(raw: dict[str, Any]) -> Plan:
    """Validates a plan dict; raises ValueError with the path-style message."""
    try:
        return Plan.model_validate(raw)
    except ValidationError as exc:
        raise ValueError(describe_error(exc)) from None
