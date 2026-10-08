"""The MCP server: tool definitions over the SketchUp connection.

Every length is millimetres. Read-only tools may be retried by the bridge on
a stale socket; mutating tools never are. Each mutating call is one undo step
in SketchUp.
"""

from __future__ import annotations

import asyncio
import base64
import functools
from collections.abc import Awaitable, Callable
from typing import Annotated, Any, Literal

from mcp.server.mcpserver import Context, Image, MCPServer
from mcp.server.mcpserver.exceptions import ToolError
from mcp_types import CallToolResult, TextContent, ToolAnnotations
from pydantic import BaseModel, Field, ValidationError

from . import __version__
from .config import BridgeConfig, load_config
from .connection import SketchUpClient
from .dxf import DxfPlanError, read_plan
from .errors import NOT_RESPONDING, BridgeError, NotResponding, describe
from .models import Opening, Plan, Room, Stair, Wall, describe_error

INSTRUCTIONS = """\
Plomada models architecture inside a running SketchUp 2025 (Windows) from plans drawn by
AutoCAD MCP Pro. All lengths are millimetres in world coordinates; z is up, the floor is z 0.

Typical flow: status -> build_from_autocad(dxf_path) -> capture_view -> get_plan.
build_from_autocad turns the ACADMCP_ARCH records of a DXF into manifold walls with real
openings, window and door components, a floor slab, a roof, stairs and room labels, as ONE undo
step. Several floors: one DXF per floor, built in order with storey="N00", "N01", ...; each new
storey is stacked on the one below, its slab gets the stair wells, the roof below is replaced.
Edit afterwards with move_opening, set_wall_height, add_wall, add_opening, add_slab, add_roof,
set_material; they read the plan back from the model, never from the DXF, and take storey
when the model has several.
If a mutating call times out or the connection drops, its outcome is unknown: call get_plan or
status before retrying. execute_ruby is off unless the user enables it in SketchUp.
"""

READ = ToolAnnotations(read_only_hint=True, destructive_hint=False, idempotent_hint=True, open_world_hint=False)


def _mut(destructive: bool, idempotent: bool) -> ToolAnnotations:
    return ToolAnnotations(
        read_only_hint=False, destructive_hint=destructive, idempotent_hint=idempotent, open_world_hint=False
    )


def exact_errors(fn: Callable[..., Awaitable[Any]]) -> Callable[..., Awaitable[Any]]:
    """Returns refusals as an error result carrying exactly our sentence (the
    SDK would prefix a raised ToolError with "Error executing tool <name>:")."""

    @functools.wraps(fn)
    async def wrapper(*args: Any, **kwargs: Any) -> Any:
        try:
            return await fn(*args, **kwargs)
        except ToolError as exc:
            return CallToolResult(content=[TextContent(type="text", text=str(exc))], is_error=True)

    return wrapper


Mm = float
DeadlineMs = Annotated[
    int, Field(ge=1_000, le=600_000, description="ms the job may run in SketchUp before it aborts and reverts")
]
STOREY_PATTERN = r"^[A-Za-z0-9_-]{1,16}$"
StoreyName = Annotated[
    str | None,
    Field(
        pattern=STOREY_PATTERN,
        description="storey: N00 ground, N01 first floor...; required when the model has several",
    ),
]


class PlanInput(BaseModel):
    """A plan in the AutoCAD MCP Pro record format (mm)."""

    walls: Annotated[list[Wall], Field(min_length=1, description="wall records")]
    openings: Annotated[list[Opening], Field(default_factory=list, description="door and window records")]
    rooms: Annotated[list[Room], Field(default_factory=list, description="room records")]
    stairs: Annotated[
        list[Stair], Field(default_factory=list, description="stair records: from this storey up to the next")
    ]


class Bridge:
    """Holds the one SketchUp connection the tools share."""

    def __init__(self, config: BridgeConfig | None = None) -> None:
        self.config = config or load_config()
        self.client = SketchUpClient(self.config)

    async def read(
        self, tool: str, method: str, params: dict[str, Any] | None = None, timeout: float | None = None
    ) -> Any:
        try:
            return await self.client.call(method, params or {}, read_only=True, timeout=timeout)
        except BridgeError as err:
            raise ToolError(describe(err, tool)) from None

    async def mutate(
        self,
        tool: str,
        method: str,
        params: dict[str, Any],
        ctx: Context | None,
        deadline_ms: int | None = None,
    ) -> Any:
        async def progress(done: float, total: float | None, message: str | None) -> None:
            if ctx is not None:
                await ctx.report_progress(done, total, message)

        try:
            return await self.client.call(
                method,
                params,
                read_only=False,
                deadline_ms=deadline_ms or self.config.default_deadline_ms,
                on_progress=progress,
            )
        except BridgeError as err:
            raise ToolError(describe(err, tool)) from None


def build_options(
    storey_height: float,
    slab: bool,
    roof: str,
    overhang: float,
    replace: bool,
    storey: str = "N00",
    elevation: float | None = None,
) -> dict[str, Any]:
    opts: dict[str, Any] = {
        "storey_height": storey_height,
        "slab": slab,
        "roof": roof,
        "overhang": overhang,
        "replace": replace,
        "storey": storey,
    }
    if elevation is not None:
        opts["elevation"] = elevation
    return opts


def with_storey(params: dict[str, Any], storey: str | None) -> dict[str, Any]:
    if storey is not None:
        params["storey"] = storey
    return params


def create_server(bridge: Bridge | None = None) -> MCPServer:
    b = bridge or Bridge()
    cfg = b.config
    mcp = MCPServer("plomada", instructions=INSTRUCTIONS, version=__version__)

    # --- read-only ----------------------------------------------------------------------

    @mcp.tool(annotations=READ)
    @exact_errors
    async def status(
        reset_max_tick: Annotated[
            bool, Field(description="start measuring max_tick_ms afresh after this answer (for benchmarks)")
        ] = False,
    ) -> dict[str, Any]:
        """Connection to SketchUp, versions, capabilities (pro, entities_build, pbr, fbx_export), queue
        length, the running job with its progress, and the longest pump tick (max_tick_ms)."""
        params = {"reset_max_tick": True} if reset_max_tick else {}
        try:
            st = await b.client.call("status", params, read_only=True, timeout=cfg.status_timeout_s)
        except NotResponding:
            raise ToolError(NOT_RESPONDING) from None
        except BridgeError as err:
            raise ToolError(describe(err, "status")) from None
        st["bridge_version"] = __version__
        return st

    @mcp.tool(annotations=READ)
    @exact_errors
    async def model_info(
        detail: Annotated[
            bool, Field(description="also check the house: manifold walls, internal faces, doors, windows, glass panes")
        ] = False,
    ) -> dict[str, Any]:
        """Model path, units, top-level entity counts per tag and type, Plomada objects, and the bounding
        box in mm."""
        return await b.read("model_info", "model_info", {"detail": True} if detail else {})

    @mcp.tool(annotations=READ)
    @exact_errors
    async def list_entities(
        tag: Annotated[str | None, Field(description="only entities on this tag, e.g. Muros")] = None,
        cursor: Annotated[int | None, Field(description="next_cursor from the previous page (persistent_id)")] = None,
        limit: Annotated[int, Field(ge=1, le=200, description="entities per page")] = 200,
    ) -> dict[str, Any]:
        """Top-level entities ordered by persistent_id, a page at a time; bounds in mm."""
        params: dict[str, Any] = {"limit": limit}
        if tag is not None:
            params["tag"] = tag
        if cursor is not None:
            params["cursor"] = cursor
        return await b.read("list_entities", "list_entities", params)

    @mcp.tool(annotations=READ)
    @exact_errors
    async def list_tags() -> dict[str, Any]:
        """Tags (layers) with visibility, colour and top-level entity count."""
        return await b.read("list_tags", "list_tags")

    @mcp.tool(annotations=READ)
    @exact_errors
    async def list_materials() -> dict[str, Any]:
        """Materials with RGB, alpha, texture flag and PBR factors when set."""
        return await b.read("list_materials", "list_materials")

    @mcp.tool(annotations=READ)
    @exact_errors
    async def get_plan(
        storey: Annotated[str | None, Field(pattern=STOREY_PATTERN, description="storey; default the lowest")] = None,
    ) -> dict[str, Any]:
        """The plan of one storey read back from the model's plomada attributes: walls, openings, rooms,
        stairs and storey settings (name, height, elevation) in the AutoCAD MCP Pro record format (mm),
        plus every storey in the model."""
        return await b.read("get_plan", "get_plan", with_storey({}, storey))

    @mcp.tool(annotations=READ, structured_output=False)
    @exact_errors
    async def capture_view(
        width: Annotated[int, Field(ge=64, le=8192, description="image width, px")] = cfg.capture_width,
        height: Annotated[int, Field(ge=64, le=8192, description="image height, px")] = cfg.capture_height,
        style: Annotated[
            Literal["shaded", "hidden_line", "lines_only"], Field(description="render mode for this image only")
        ] = "shaded",
        view: Annotated[
            Literal["current", "fit"], Field(description="current camera, or a south-west view framing the house")
        ] = "current",
    ) -> list[Any]:
        """A JPEG of the SketchUp viewport (quality 0.7, shrunk until under 350 KB). The camera and render
        mode are restored afterwards. Returns the image and its file path in %TEMP%."""
        res = await b.read(
            "capture_view", "capture_view", {"width": width, "height": height, "style": style, "view": view}
        )
        data = base64.b64decode(res.pop("data_base64"))
        return [Image(data=data, format="jpeg"), res]

    @mcp.tool(annotations=READ)
    @exact_errors
    async def job_status() -> dict[str, Any]:
        """The running job (id, method, progress), queued jobs, and the last finished jobs."""
        return await b.read("job_status", "job_status")

    # --- the flagship -----------------------------------------------------------------------

    @mcp.tool(annotations=_mut(destructive=True, idempotent=False))
    @exact_errors
    async def build_from_autocad(
        dxf_path: Annotated[
            str, Field(min_length=1, description="DXF exported by AutoCAD MCP Pro (ACADMCP_ARCH records)")
        ],
        ctx: Context,
        storey_height: Annotated[
            float, Field(gt=0, le=10_000, description="storey and wall height, mm")
        ] = cfg.storey_height_mm,
        slab: Annotated[bool, Field(description="build the 150 mm floor slab under the exterior wall")] = True,
        roof: Annotated[
            Literal["flat", "gable", "none"], Field(description="gable needs a rectangular footprint")
        ] = "flat",
        overhang: Annotated[
            float, Field(ge=0, le=3_000, description="roof overhang past the outer face, mm")
        ] = cfg.overhang_mm,
        replace: Annotated[
            bool, Field(description="first erase the groups and components Plomada built before on this storey")
        ] = True,
        storey: Annotated[
            str,
            Field(
                pattern=STOREY_PATTERN, description="N00 ground, N01 first floor...; replace erases only this storey"
            ),
        ] = "N00",
        elevation: Annotated[
            float | None,
            Field(
                ge=-100_000, le=1_000_000, description="mm of this storey's floor; default stacked on the storey below"
            ),
        ] = None,
        deadline_ms: DeadlineMs = cfg.default_deadline_ms,
    ) -> dict[str, Any]:
        """Builds the exact 3D house of an AutoCAD MCP Pro plan in one call and one undo step: manifold
        walls with real openings (jambs, sills, soffits), window and door components with glass and leaves,
        floor slab, roof and room labels. The DXF is read by the bridge; SketchUp only gets the plan."""
        try:
            parsed = await asyncio.to_thread(read_plan, dxf_path, storey_height)
        except DxfPlanError as exc:
            raise ToolError(
                f"build_from_autocad refused its input (-32004): {exc}. Fix the DXF or the path and call it again."
            ) from None
        params = {
            "plan": parsed.plan.to_wire(),
            "options": build_options(storey_height, slab, roof, overhang, replace, storey, elevation),
            "label": f"build from AutoCAD ({parsed.path.name})",
        }
        res = await b.mutate("build_from_autocad", "build_plan", params, ctx, deadline_ms)
        res["dxf"] = str(parsed.path)
        res["records"] = parsed.records
        res["warnings"] = list(res.get("warnings", [])) + parsed.warnings
        return res

    @mcp.tool(annotations=_mut(destructive=True, idempotent=False))
    @exact_errors
    async def build_plan(
        plan: Annotated[PlanInput, Field(description="walls, openings and rooms in mm")],
        ctx: Context,
        storey_height: Annotated[
            float, Field(gt=0, le=10_000, description="storey and wall height, mm")
        ] = cfg.storey_height_mm,
        slab: Annotated[bool, Field(description="build the floor slab under the exterior wall")] = True,
        roof: Annotated[
            Literal["flat", "gable", "none"], Field(description="gable needs a rectangular footprint")
        ] = "flat",
        overhang: Annotated[float, Field(ge=0, le=3_000, description="roof overhang, mm")] = cfg.overhang_mm,
        replace: Annotated[bool, Field(description="first erase what Plomada built before on this storey")] = True,
        storey: Annotated[
            str,
            Field(
                pattern=STOREY_PATTERN, description="N00 ground, N01 first floor...; replace erases only this storey"
            ),
        ] = "N00",
        elevation: Annotated[
            float | None,
            Field(
                ge=-100_000, le=1_000_000, description="mm of this storey's floor; default stacked on the storey below"
            ),
        ] = None,
        deadline_ms: DeadlineMs = cfg.default_deadline_ms,
    ) -> dict[str, Any]:
        """Builds a house from plan JSON (the same records build_from_autocad reads from a DXF), as one undo step."""
        try:
            checked = Plan.model_validate(plan.model_dump())
        except ValidationError as exc:
            raise ToolError(
                f"build_plan refused its input (-32004): plan.{describe_error(exc)}. Fix it and call again."
            ) from None
        params = {
            "plan": checked.to_wire(),
            "options": build_options(storey_height, slab, roof, overhang, replace, storey, elevation),
        }
        return await b.mutate("build_plan", "build_plan", params, ctx, deadline_ms)

    # --- edits ------------------------------------------------------------------------------

    @mcp.tool(annotations=_mut(destructive=False, idempotent=False))
    @exact_errors
    async def add_wall(
        id: Annotated[str, Field(min_length=1, description="new wall id, unique")],
        axis: Annotated[list[tuple[Mm, Mm]], Field(min_length=2, description="axis polyline [[x, y], ...], mm")],
        thickness: Annotated[float, Field(gt=0, le=2_000, description="mm")],
        ctx: Context,
        justification: Annotated[
            Literal["center", "left", "right"],
            Field(description="side of the axis the wall lies on, from its first point"),
        ] = "center",
        material: Annotated[str, Field(description="record material, e.g. brick, gypsum_board")] = "brick",
        closed: Annotated[bool, Field(description="close the axis into a loop")] = False,
        height: Annotated[float | None, Field(gt=0, le=10_000, description="mm; default the storey height")] = None,
        storey: StoreyName = None,
    ) -> dict[str, Any]:
        """Adds a wall to the house and rebuilds the walls (T junctions and mitres resolved), one undo step."""
        params: dict[str, Any] = {
            "id": id,
            "axis": [list(p) for p in axis],
            "thickness": thickness,
            "justification": justification,
            "material": material,
            "closed": closed,
        }
        if height is not None:
            params["height"] = height
        return await b.mutate("add_wall", "add_wall", with_storey(params, storey), ctx)

    @mcp.tool(annotations=_mut(destructive=False, idempotent=False))
    @exact_errors
    async def add_opening(
        id: Annotated[str, Field(min_length=1, description="new opening id, unique")],
        wall: Annotated[str, Field(min_length=1, description="host wall id")],
        opening_kind: Annotated[Literal["door", "window"], Field(description="door or window")],
        offset: Annotated[
            float, Field(ge=0, description="mm along the host axis from its first point to the near jamb")
        ],
        width: Annotated[float, Field(gt=0, description="mm")],
        ctx: Context,
        sill: Annotated[
            float | None, Field(ge=0, description="mm above the floor; null is 0 for doors, 900 for windows")
        ] = None,
        height: Annotated[float | None, Field(gt=0, description="mm; null is 2100 for doors, 1200 for windows")] = None,
        swing: Annotated[Literal["in", "out"], Field(description="in opens to the left of the host axis")] = "in",
        hand: Annotated[Literal["left", "right"], Field(description="hinge jamb seen from the swing side")] = "left",
        tag: Annotated[str | None, Field(description="component name, default the id")] = None,
        storey: StoreyName = None,
    ) -> dict[str, Any]:
        """Cuts a new door or window into a wall and places its component, one undo step."""
        params = {
            "id": id,
            "wall": wall,
            "opening_kind": opening_kind,
            "offset": offset,
            "width": width,
            "sill": sill,
            "height": height,
            "swing": swing,
            "hand": hand,
            "tag": tag,
        }
        return await b.mutate("add_opening", "add_opening", with_storey(params, storey), ctx)

    @mcp.tool(annotations=_mut(destructive=True, idempotent=True))
    @exact_errors
    async def move_opening(
        id: Annotated[str, Field(min_length=1, description="opening id, e.g. W2")],
        offset: Annotated[float, Field(ge=0, description="new mm along the host axis to the near jamb")],
        ctx: Context,
        storey: StoreyName = None,
    ) -> dict[str, Any]:
        """Moves a door or window along its wall: the hole is rebuilt and the component follows."""
        return await b.mutate("move_opening", "move_opening", with_storey({"id": id, "offset": offset}, storey), ctx)

    @mcp.tool(annotations=_mut(destructive=True, idempotent=True))
    @exact_errors
    async def set_wall_height(
        id: Annotated[str, Field(min_length=1, description="wall id")],
        height: Annotated[float, Field(gt=0, le=10_000, description="new wall height, mm")],
        ctx: Context,
        storey: StoreyName = None,
    ) -> dict[str, Any]:
        """Changes one wall's height and rebuilds the walls; openings must still fit under it."""
        return await b.mutate(
            "set_wall_height", "set_wall_height", with_storey({"id": id, "height": height}, storey), ctx
        )

    @mcp.tool(annotations=_mut(destructive=True, idempotent=True))
    @exact_errors
    async def add_slab(
        ctx: Context,
        thickness: Annotated[
            float, Field(gt=0, le=2_000, description="mm; the top stays at z 0")
        ] = cfg.slab_thickness_mm,
        outline: Annotated[
            list[tuple[Mm, Mm]] | None, Field(description="[[x, y], ...] mm; default the exterior wall's outer face")
        ] = None,
        storey: StoreyName = None,
    ) -> dict[str, Any]:
        """Builds (or replaces) a storey's floor slab (N00_losa, N01_losa...) on tag Losas, with the wells of
        the stairs that come up from the storey below."""
        params: dict[str, Any] = {"thickness": thickness}
        if outline is not None:
            params["outline"] = [list(p) for p in outline]
        return await b.mutate("add_slab", "add_slab", with_storey(params, storey), ctx)

    @mcp.tool(annotations=_mut(destructive=True, idempotent=True))
    @exact_errors
    async def add_roof(
        ctx: Context,
        kind: Annotated[Literal["flat", "gable"], Field(description="gable needs a rectangular footprint")] = "flat",
        overhang: Annotated[float, Field(ge=0, le=3_000, description="mm past the outer face")] = cfg.overhang_mm,
        thickness: Annotated[float, Field(gt=0, le=2_000, description="mm")] = cfg.roof_thickness_mm,
        pitch: Annotated[float, Field(gt=0, lt=75, description="gable slope, degrees")] = cfg.gable_pitch_deg,
        storey: StoreyName = None,
    ) -> dict[str, Any]:
        """Builds (or replaces) a storey's roof (N00_techo...): a flat slab on the wall tops, or a gable with
        its ridge along the longer side."""
        params = {"kind": kind, "overhang": overhang, "thickness": thickness, "pitch": pitch}
        return await b.mutate("add_roof", "add_roof", with_storey(params, storey), ctx)

    @mcp.tool(annotations=_mut(destructive=True, idempotent=True))
    @exact_errors
    async def set_material(
        target: Annotated[str, Field(min_length=1, description="wall id, opening id, group name or tag name")],
        material: Annotated[str, Field(min_length=1, description="e.g. MAT_ladrillo, MAT_hormigon, MAT_madera")],
        ctx: Context,
        storey: StoreyName = None,
    ) -> dict[str, Any]:
        """Paints a wall (kept across rebuilds), an opening, a group, or everything on a tag."""
        params = with_storey({"target": target, "material": material}, storey)
        return await b.mutate("set_material", "set_material", params, ctx)

    # --- scenes and exports -----------------------------------------------------------------

    @mcp.tool(annotations=_mut(destructive=False, idempotent=True))
    @exact_errors
    async def create_scene(
        name: Annotated[str, Field(min_length=1, description="scene name")],
        eye: Annotated[tuple[Mm, Mm], Field(description="[x, y] of the camera, mm")],
        target: Annotated[tuple[Mm, Mm, Mm], Field(description="[x, y, z] the camera looks at, mm")],
        ctx: Context,
        eye_height: Annotated[
            float, Field(ge=-10_000, le=100_000, description="camera height, mm")
        ] = cfg.eye_height_mm,
        fov: Annotated[float, Field(gt=0, lt=180, description="field of view, degrees")] = cfg.fov_deg,
        two_point: Annotated[bool, Field(description="keep the camera level so verticals stay vertical")] = True,
        style: Annotated[Literal["shaded", "lines_only"], Field(description="scene render mode")] = "shaded",
    ) -> dict[str, Any]:
        """Creates (or updates) a scene with an eye-height camera; with two_point the target is levelled to
        the eye so verticals stay vertical."""
        params = {
            "name": name,
            "eye": list(eye),
            "target": list(target),
            "eye_height": eye_height,
            "fov": fov,
            "two_point": two_point,
            "style": style,
        }
        return await b.mutate("create_scene", "create_scene", params, ctx)

    @mcp.tool(annotations=_mut(destructive=True, idempotent=True))
    @exact_errors
    async def export_scene_images(
        dir: Annotated[str, Field(min_length=1, description="folder for the images (created if missing)")],
        ctx: Context,
        width: Annotated[int, Field(ge=64, le=8192, description="px")] = cfg.export_width,
        height: Annotated[int, Field(ge=64, le=8192, description="px")] = cfg.export_height,
        style: Annotated[
            Literal["shaded", "hidden_line", "lines_only"] | None, Field(description="override every scene's style")
        ] = None,
        format: Annotated[Literal["png", "jpg"], Field(description="image format")] = "png",
    ) -> dict[str, Any]:
        """Writes one image per scene (antialiased) and restores the camera afterwards."""
        params: dict[str, Any] = {"dir": dir, "width": width, "height": height, "format": format}
        if style is not None:
            params["style"] = style
        return await b.mutate("export_scene_images", "export_scene_images", params, ctx)

    @mcp.tool(annotations=_mut(destructive=True, idempotent=True))
    @exact_errors
    async def export_model(
        path: Annotated[str, Field(min_length=1, description="output file; the extension follows format")],
        format: Annotated[Literal["skp", "fbx", "obj"], Field(description="skp needs a model saved at least once")],
        ctx: Context,
    ) -> dict[str, Any]:
        """Exports the model; a false return from SketchUp's exporter is reported as an error naming the format."""
        return await b.mutate("export_model", "export_model", {"path": path, "format": format}, ctx)

    # --- housekeeping -----------------------------------------------------------------------

    @mcp.tool(annotations=_mut(destructive=True, idempotent=True))
    @exact_errors
    async def reset_plomada(ctx: Context) -> dict[str, Any]:
        """Erases every group, component and scene Plomada made (those carrying a plomada attribute); leaves
        everything else. Never opens a new file."""
        return await b.mutate("reset_plomada", "reset_plomada", {}, ctx)

    @mcp.tool(annotations=_mut(destructive=True, idempotent=False))
    @exact_errors
    async def undo(
        ctx: Context,
        steps: Annotated[int, Field(ge=1, le=10, description="undo steps; each Plomada call is one step")] = 1,
    ) -> dict[str, Any]:
        """Undoes the last steps in SketchUp (Edit > Undo)."""
        return await b.mutate("undo", "undo", {"steps": steps}, ctx)

    @mcp.tool(annotations=_mut(destructive=True, idempotent=True))
    @exact_errors
    async def job_cancel(
        job_id: Annotated[str | None, Field(description="job id from job_status; default the running job")] = None,
    ) -> dict[str, Any]:
        """Cancels a queued job, or stops the running one after its current step and reverts it."""
        params = {"job_id": job_id} if job_id else {}
        try:
            return await b.client.call("cancel", params, read_only=False, deadline_ms=10_000)
        except BridgeError as err:
            raise ToolError(describe(err, "job_cancel")) from None

    @mcp.tool(annotations=_mut(destructive=True, idempotent=False))
    @exact_errors
    async def execute_ruby(
        code: Annotated[str, Field(min_length=1, max_length=200_000, description="Ruby source to run in SketchUp")],
        ctx: Context,
    ) -> dict[str, Any]:
        """Runs Ruby inside SketchUp as one undo step, with a 10 s soft deadline and 64 KiB of captured
        output. Off unless the user enabled it in Extensions > Plomada > Settings; refuses system, exec,
        spawn, fork, backticks, %x, Thread.new, exit and Sketchup.quit."""
        return await b.mutate("execute_ruby", "execute_ruby", {"code": code}, ctx)

    return mcp


def main() -> None:
    create_server().run()
