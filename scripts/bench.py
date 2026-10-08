"""Benchmarks Plomada against a live SketchUp, through the MCP stdio server.

Targets (on the reference house):
  model_info       p50 < 60 ms and p95 < 150 ms over 200 calls
  capture_view     1280x720, every call < 400 ms
  build_from_autocad  the fixture, every run < 3.0 s end to end
  max tick         no pump tick over 100 ms while building and answering reads

Every step the pump controls is sized to stay under 100 ms. A viewport capture is
one native view.write_image call (about 65 ms of fixed cost here, 90-130 ms at
1280x720) that cannot be split, so its ticks are measured and reported apart as
capture_tick_ms, against the 400 ms capture budget instead.

Times are wall clock at the MCP client (stdio + bridge + socket + pump);
percentiles are nearest-rank. Writes bench/results-<date>.json; with
--certify the exit code is 1 when any target is missed.

    uv run python scripts/bench.py [--certify] [--calls 200]
"""

from __future__ import annotations

import argparse
import asyncio
import ctypes
import datetime as dt
import json
import math
import os
import platform
import statistics
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

from mcp.client import Client
from mcp.client.stdio import StdioServerParameters

ROOT = Path(__file__).resolve().parents[1]
FIXTURE = ROOT / "tests" / "fixtures" / "casa_minimalista.dxf"

TARGETS = {
    "model_info_p50_ms": 60.0,
    "model_info_p95_ms": 150.0,
    "capture_view_max_ms": 400.0,
    "build_from_autocad_max_s": 3.0,
    "max_tick_ms": 100.0,
}


def percentile(sorted_values: list[float], q: float) -> float:
    rank = max(0, math.ceil(q / 100.0 * len(sorted_values)) - 1)
    return sorted_values[rank]


def summary(samples: list[float]) -> dict[str, float]:
    s = sorted(samples)
    return {
        "n": len(s),
        "p50": round(percentile(s, 50), 2),
        "p95": round(percentile(s, 95), 2),
        "min": round(s[0], 2),
        "max": round(s[-1], 2),
        "mean": round(statistics.fmean(s), 2),
    }


def machine() -> dict[str, Any]:
    info: dict[str, Any] = {
        "os": platform.platform(),
        "python": platform.python_version(),
        "cpu_count": os.cpu_count(),
    }
    if sys.platform == "win32":

        class MemoryStatus(ctypes.Structure):
            _fields_ = [("length", ctypes.c_ulong), ("load", ctypes.c_ulong)] + [
                (n, ctypes.c_ulonglong) for n in ("total", "avail", "ptotal", "pavail", "vtotal", "vavail", "ext")
            ]

        ms = MemoryStatus()
        ms.length = ctypes.sizeof(MemoryStatus)
        ctypes.windll.kernel32.GlobalMemoryStatusEx(ctypes.byref(ms))
        info["ram_gb"] = round(ms.total / 2**30, 1)
        query = (
            "(Get-CimInstance Win32_Processor | Select-Object -First 1).Name;"
            "(Get-CimInstance Win32_VideoController | ForEach-Object Name) -join ' / '"
        )
        out = subprocess.run(["powershell", "-NoProfile", "-Command", query], capture_output=True, text=True)
        lines = [line.strip() for line in out.stdout.splitlines() if line.strip()]
        if lines:
            info["cpu"] = lines[0]
        if len(lines) > 1:
            info["gpu"] = lines[1]
    else:
        info["cpu"] = platform.processor()
    return info


def data(result: Any) -> dict[str, Any]:
    if result.is_error:
        raise RuntimeError(" ".join(getattr(c, "text", "") for c in result.content))
    return result.structured_content


async def run(calls: int) -> dict[str, Any]:
    exe = ROOT / ".venv" / ("Scripts/plomada-mcp.exe" if os.name == "nt" else "bin/plomada-mcp")
    async with Client(StdioServerParameters(command=str(exe)), read_timeout_seconds=180) as client:
        st = data(await client.call_tool("status", {}))
        report: dict[str, Any] = {
            "date": dt.datetime.now().isoformat(timespec="seconds"),
            "machine": machine() | {"sketchup": st.get("sketchup_version"), "ruby": st.get("ruby_version")},
            "plomada": {
                "server": st.get("server_version"),
                "bridge": st.get("bridge_version"),
                "capabilities": st.get("capabilities"),
            },
            "method": "wall clock at an MCP stdio client; nearest-rank percentiles",
        }
        data(await client.call_tool("reset_plomada", {}))
        data(await client.call_tool("status", {"reset_max_tick": True}))

        builds = []
        steps = []
        for _ in range(5):
            t0 = time.perf_counter()
            res = data(await client.call_tool("build_from_autocad", {"dxf_path": str(FIXTURE)}))
            builds.append(time.perf_counter() - t0)
            steps.append(res["max_step_ms"])
        report["build_from_autocad_s"] = summary(builds)
        report["build_max_step_ms"] = max(steps)

        for _ in range(5):  # warm-up
            await client.call_tool("model_info", {})
        infos = []
        for _ in range(calls):
            t0 = time.perf_counter()
            data(await client.call_tool("model_info", {}))
            infos.append((time.perf_counter() - t0) * 1000.0)
        report["model_info_ms"] = summary(infos)
        st = data(await client.call_tool("status", {"reset_max_tick": True}))
        report["max_tick_ms"] = st["max_tick_ms"]
        report["max_tick_what"] = st.get("max_tick_what")

        captures = []
        sizes = []
        for style in ["shaded", "lines_only"] * 5:
            t0 = time.perf_counter()
            res = await client.call_tool("capture_view", {"style": style})
            captures.append((time.perf_counter() - t0) * 1000.0)
            if res.is_error:
                raise RuntimeError(res.content[0].text)
            meta = json.loads(next(c.text for c in res.content if c.type == "text"))
            sizes.append(meta["bytes"])
        report["capture_view_ms"] = summary(captures)
        report["capture_view_bytes_max"] = max(sizes)

        st = data(await client.call_tool("status", {"reset_max_tick": True}))
        report["capture_tick_ms"] = st["max_tick_ms"]
        report["capture_tick_what"] = st.get("max_tick_what")
        report["tool_count"] = len((await client.list_tools()).tools)

    measured = {
        "model_info_p50_ms": report["model_info_ms"]["p50"],
        "model_info_p95_ms": report["model_info_ms"]["p95"],
        "capture_view_max_ms": report["capture_view_ms"]["max"],
        "build_from_autocad_max_s": report["build_from_autocad_s"]["max"],
        "max_tick_ms": report["max_tick_ms"],
    }
    report["targets"] = {
        k: {"target": TARGETS[k], "measured": measured[k], "pass": measured[k] < TARGETS[k]} for k in TARGETS
    }
    report["passed"] = all(t["pass"] for t in report["targets"].values())
    return report


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--certify", action="store_true", help="exit 1 when any target is missed")
    ap.add_argument("--calls", type=int, default=200, help="model_info calls (default 200)")
    args = ap.parse_args()
    report = asyncio.run(run(args.calls))
    out = ROOT / "bench" / f"results-{dt.date.today().isoformat()}.json"
    out.parent.mkdir(exist_ok=True)
    out.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    for name, t in report["targets"].items():
        print(f"  {'PASS' if t['pass'] else 'FAIL'}  {name:<26} {t['measured']:>9} (target < {t['target']})")
    print(f"  info  capture ticks (one native write_image each): max {report['capture_tick_ms']} ms")
    print(f"report: {out}")
    return 1 if args.certify and not report["passed"] else 0


if __name__ == "__main__":
    sys.exit(main())
