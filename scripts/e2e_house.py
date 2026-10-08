"""The one live test: the reference house, end to end, through the MCP tools.

Needs SketchUp 2025 running with the Plomada extension. Launches the
plomada-mcp console script over stdio exactly as Claude does, then:

  status -> reset_plomada -> build_from_autocad (timed) -> undo once (the
  house must be gone) -> build_from_autocad again -> capture_view shaded and
  lines_only -> export_model fbx -> get_plan -> model_info(detail)

and asserts 4 wall records, 11 opening components (4 D, 7 W), 7 glass panes,
3 groups, manifold walls with zero internal faces, and the round-tripped plan
equal to the input within 0.5 mm. Saves docs/img/e2e_shaded.jpg,
docs/img/e2e_lines.jpg and bench/e2e-<date>.json.

    uv run python scripts/e2e_house.py
"""

from __future__ import annotations

import asyncio
import base64
import datetime as dt
import json
import math
import os
import sys
import tempfile
import time
from pathlib import Path
from typing import Any

from mcp.client import Client
from mcp.client.stdio import StdioServerParameters

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "src"))

from plomada_bridge.dxf import read_plan  # noqa: E402

FIXTURE = ROOT / "tests" / "fixtures" / "casa_minimalista.dxf"
TOL_MM = 0.5
BUILD_BUDGET_S = 3.0
CAPTURE_BUDGET_MS = 400.0
CAPTURE_MAX_BYTES = 350_000


def server_params() -> StdioServerParameters:
    exe = ROOT / ".venv" / ("Scripts/plomada-mcp.exe" if os.name == "nt" else "bin/plomada-mcp")
    return StdioServerParameters(command=str(exe), args=[])


def structured(result: Any) -> dict[str, Any]:
    if result.is_error:
        text = " ".join(getattr(c, "text", "") for c in result.content)
        raise AssertionError(f"tool error: {text}")
    if result.structured_content is not None:
        sc = result.structured_content
        return sc.get("result", sc) if isinstance(sc, dict) and set(sc) == {"result"} else sc
    for c in result.content:
        if getattr(c, "type", "") == "text":
            return json.loads(c.text)
    raise AssertionError("no structured result")


def close(a: float | None, b: float | None, tol: float = TOL_MM) -> bool:
    if a is None or b is None:
        return a is None and b is None
    return abs(float(a) - float(b)) <= tol


def compare_plan(expected: dict[str, Any], got: dict[str, Any]) -> list[str]:
    """Differences between the DXF plan and the plan read back from SketchUp."""
    diffs: list[str] = []
    for key in ("walls", "openings", "rooms"):
        exp = {r["id"]: r for r in expected[key]}
        act = {r["id"]: r for r in got[key]}
        if set(exp) != set(act):
            diffs.append(f"{key}: ids {sorted(exp)} != {sorted(act)}")
            continue
        for rid, e in exp.items():
            a = act[rid]
            if key == "walls":
                pts_ok = len(e["axis"]) == len(a["axis"]) and all(
                    math.dist(p, q) <= TOL_MM for p, q in zip(e["axis"], a["axis"], strict=True)
                )
                if not pts_ok:
                    diffs.append(f"wall {rid}: axis {a['axis']} != {e['axis']}")
                for f in ("thickness",):
                    if not close(e[f], a[f]):
                        diffs.append(f"wall {rid}: {f} {a[f]} != {e[f]}")
                for f in ("justification", "closed"):
                    if e[f] != a[f]:
                        diffs.append(f"wall {rid}: {f} {a[f]} != {e[f]}")
            elif key == "openings":
                for f in ("offset", "width", "height"):
                    if not close(e[f], a[f]):
                        diffs.append(f"opening {rid}: {f} {a[f]} != {e[f]}")
                e_sill = e["sill"] if e["sill"] is not None else 0.0
                if not close(e_sill, a["sill"]):
                    diffs.append(f"opening {rid}: sill {a['sill']} != {e_sill}")
                for f in ("wall", "opening_kind", "swing", "hand"):
                    if e[f] != a[f]:
                        diffs.append(f"opening {rid}: {f} {a[f]} != {e[f]}")
            else:
                if math.dist(e["at"], a["at"]) > TOL_MM or not close(e["area"], a["area"]):
                    diffs.append(f"room {rid}: at/area {a['at']}/{a['area']} != {e['at']}/{e['area']}")
                if e["name"] != a["name"] or e["number"] != a["number"]:
                    diffs.append(f"room {rid}: name {a['name']} != {e['name']}")
    return diffs


async def run() -> dict[str, Any]:
    report: dict[str, Any] = {"date": dt.datetime.now().isoformat(timespec="seconds"), "checks": {}}
    checks = report["checks"]
    expected = read_plan(FIXTURE).plan.to_wire()

    async with Client(server_params(), read_timeout_seconds=180) as client:
        tools = await client.list_tools()
        report["tool_count"] = len(tools.tools)

        st = structured(await client.call_tool("status", {}))
        report["status"] = {
            k: st.get(k) for k in ("server_version", "protocol", "capabilities", "sketchup_version", "ruby_version")
        }
        checks["protocol 1, pro, entities_build"] = (
            st["protocol"] == 1 and st["capabilities"]["pro"] and st["capabilities"]["entities_build"]
        )

        structured(await client.call_tool("reset_plomada", {}))

        progress: list[tuple[float, float | None, str | None]] = []

        async def on_progress(p: float, total: float | None, message: str | None) -> None:
            progress.append((p, total, message))

        args = {"dxf_path": str(FIXTURE)}
        t0 = time.perf_counter()
        first = structured(await client.call_tool("build_from_autocad", args, progress_callback=on_progress))
        report["build_s_first"] = round(time.perf_counter() - t0, 3)

        structured(await client.call_tool("undo", {"steps": 1}))
        after_undo = structured(await client.call_tool("model_info", {}))
        checks["one undo removes the whole house"] = sum(after_undo["plomada"].values()) == 0

        progress.clear()
        structured(await client.call_tool("status", {"reset_max_tick": True}))
        t0 = time.perf_counter()
        build = structured(await client.call_tool("build_from_autocad", args, progress_callback=on_progress))
        report["build_s"] = round(time.perf_counter() - t0, 3)
        report["max_tick_ms_build"] = structured(await client.call_tool("status", {"reset_max_tick": True}))[
            "max_tick_ms"
        ]
        checks["max tick under 100 ms during the build"] = report["max_tick_ms_build"] < 100.0
        report["build"] = {
            k: build.get(k)
            for k in (
                "walls",
                "openings",
                "doors",
                "windows",
                "rooms",
                "wall_faces",
                "internal_faces_removed",
                "manifold",
                "groups",
                "steps",
                "elapsed_ms",
                "max_step_ms",
            )
        }
        report["progress_notifications"] = len(progress)
        checks[f"build under {BUILD_BUDGET_S} s"] = max(report["build_s"], report["build_s_first"]) < BUILD_BUDGET_S
        checks["progress reported every step"] = len(progress) == build["steps"]
        checks["first build matched"] = first["wall_faces"] == build["wall_faces"]

        img_dir = ROOT / "docs" / "img"
        img_dir.mkdir(parents=True, exist_ok=True)
        report["captures"] = {}
        for style, name in (("shaded", "e2e_shaded.jpg"), ("lines_only", "e2e_lines.jpg")):
            t0 = time.perf_counter()
            res = await client.call_tool("capture_view", {"style": style})
            ms = (time.perf_counter() - t0) * 1000.0
            assert not res.is_error, res
            image = next(c for c in res.content if getattr(c, "type", "") == "image")
            meta = json.loads(next(c.text for c in res.content if getattr(c, "type", "") == "text"))
            data = base64.b64decode(image.data)
            (img_dir / name).write_bytes(data)
            report["captures"][style] = {
                "ms": round(ms, 1),
                "bytes": len(data),
                "path": meta["path"],
                "size": [meta["width"], meta["height"]],
            }
            checks[f"capture {style} under {CAPTURE_BUDGET_MS:.0f} ms and 350 KB"] = (
                ms < CAPTURE_BUDGET_MS and len(data) < CAPTURE_MAX_BYTES and image.mime_type == "image/jpeg"
            )

        fbx = Path(tempfile.gettempdir()) / "plomada_e2e.fbx"
        exp = structured(await client.call_tool("export_model", {"path": str(fbx), "format": "fbx"}))
        report["fbx"] = exp
        checks["fbx exported"] = exp["bytes"] > 0

        plan = structured(await client.call_tool("get_plan", {}))
        diffs = compare_plan(expected, plan)
        report["plan_diffs"] = diffs
        checks["4 wall records"] = len(plan["walls"]) == 4
        checks["plan round-trips within 0.5 mm"] = not diffs

        info = structured(await client.call_tool("model_info", {"detail": True}))
        d = info["detail"]
        report["detail"] = d
        checks["11 opening components, 4 D and 7 W"] = (
            d["doors"] == 4
            and d["windows"] == 7
            and d["opening_names"] == sorted([f"D{i}" for i in range(1, 5)] + [f"W{i}" for i in range(1, 8)])
        )
        checks["7 glass panes"] = d["glass_panes"] == 7
        checks["3 groups: muros, losa, techo"] = d["groups"] == ["N00_losa", "N00_muros", "N00_techo"]
        checks["every wall group manifold"] = bool(d["walls"]) and all(w["manifold"] for w in d["walls"])
        checks["zero internal faces"] = all(w["internal_faces"] == 0 for w in d["walls"])

        st = structured(await client.call_tool("status", {}))
        # Since the build: captures, get_plan, model_info and the FBX export.
        # The export is one native exporter call and the only step over 100 ms.
        report["max_tick_ms_after_build"] = st["max_tick_ms"]

    report["passed"] = all(checks.values())
    return report


def main() -> int:
    report = asyncio.run(run())
    out = ROOT / "bench" / f"e2e-{dt.date.today().isoformat()}.json"
    out.parent.mkdir(exist_ok=True)
    out.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    for name, ok in report["checks"].items():
        print(f"  {'PASS' if ok else 'FAIL'}  {name}")
    print(
        f"build {report['build_s']} s (first {report['build_s_first']} s), max tick during build "
        f"{report['max_tick_ms_build']} ms (after: {report['max_tick_ms_after_build']} ms incl. FBX export), "
        f"captures {', '.join(f'{k} {v["ms"]} ms' for k, v in report['captures'].items())}"
    )
    print(f"report: {out}")
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    sys.exit(main())
