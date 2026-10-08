"""Checks .skp files against the SketchUp versions installed on this machine.

A .skp file starts with a UTF-16 header that names the build that saved it,
e.g. ``{25.1.519}``. Opening a file saved by a newer build than the running
SketchUp shows a modal "File Version Warning" that blocks SketchUp (and with
it Plomada's pump) until someone clicks OK. Run this before opening a file:

    uv run python scripts/check_compat.py path/to/model.skp [more.skp or folders]

Exit code 1 when some file is newer than every installed SketchUp of its
year, so scripts can refuse to open it.
"""

from __future__ import annotations

import ctypes
import re
import sys
from ctypes import wintypes
from pathlib import Path

HEADER_BYTES = 256
VERSION_RE = re.compile(r"\{(\d+)\.(\d+)\.(\d+)\}")
INSTALL_ROOT = Path(r"C:\Program Files\SketchUp")


def skp_version(path: Path) -> tuple[int, int, int] | None:
    """The (major, minor, build) that saved a .skp, or None if unreadable."""
    try:
        head = path.read_bytes()[:HEADER_BYTES]
    except OSError:
        return None
    m = VERSION_RE.search(head.decode("utf-16-le", errors="ignore"))
    return tuple(int(g) for g in m.groups()) if m else None  # type: ignore[return-value]


def exe_version(exe: Path) -> tuple[int, int, int] | None:
    """Version of SketchUp.exe from its FileVersion string (e.g. "25.0.571").

    The numeric VS_FIXEDFILEINFO fields of SketchUp.exe read 25.0.0.0; only
    the string resource carries the build number.
    """
    if sys.platform != "win32" or not exe.is_file():
        return None
    ver = ctypes.WinDLL("version", use_last_error=True)
    size = ver.GetFileVersionInfoSizeW(str(exe), None)
    if not size:
        return None
    buf = ctypes.create_string_buffer(size)
    if not ver.GetFileVersionInfoW(str(exe), 0, size, buf):
        return None
    ptr = ctypes.c_void_p()
    length = wintypes.UINT()
    if not ver.VerQueryValueW(buf, "\\VarFileInfo\\Translation", ctypes.byref(ptr), ctypes.byref(length)):
        return None
    lang, codepage = ctypes.cast(ptr, ctypes.POINTER(wintypes.WORD * 2)).contents
    key = f"\\StringFileInfo\\{lang:04x}{codepage:04x}\\FileVersion"
    if not ver.VerQueryValueW(buf, key, ctypes.byref(ptr), ctypes.byref(length)):
        return None
    text = ctypes.wstring_at(ptr, length.value).strip("\x00 ")
    m = re.match(r"(\d+)\.(\d+)\.(\d+)", text)
    return tuple(int(g) for g in m.groups()) if m else None  # type: ignore[return-value]


def installed() -> dict[str, tuple[int, int, int]]:
    found: dict[str, tuple[int, int, int]] = {}
    if not INSTALL_ROOT.is_dir():
        return found
    for d in sorted(INSTALL_ROOT.glob("SketchUp 20*")):
        v = exe_version(d / "SketchUp" / "SketchUp.exe")
        if v:
            found[d.name] = v
    return found


def fmt(v: tuple[int, int, int] | None) -> str:
    return ".".join(map(str, v)) if v else "unknown"


def main(argv: list[str]) -> int:
    apps = installed()
    print("Installed SketchUp builds:")
    for name, v in apps.items():
        print(f"  {name:<14} {fmt(v)}")
    files: list[Path] = []
    for arg in argv:
        p = Path(arg)
        files.extend(sorted(p.rglob("*.skp")) if p.is_dir() else [p])
    worst = 0
    for f in files:
        v = skp_version(f)
        if v is None:
            print(f"  ?  {f}: no SketchUp version header")
            continue
        same_year = {n: a for n, a in apps.items() if a[0] == v[0]}
        newer_ok = [n for n, a in apps.items() if a[0] > v[0]]
        if same_year and all(a < v for a in same_year.values()) and not newer_ok:
            print(
                f"  NO {f}: saved by {fmt(v)}, newer than {', '.join(f'{n} {fmt(a)}' for n, a in same_year.items())}"
                " -> opening it shows the File Version Warning"
            )
            worst = 1
        else:
            ok = [n for n, a in apps.items() if a >= v]
            print(f"  ok {f}: saved by {fmt(v)}; opens cleanly in {', '.join(ok) or 'no installed SketchUp'}")
            if not ok:
                worst = 1
    return worst


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
