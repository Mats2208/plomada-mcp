"""Packages the SketchUp extension as dist/plomada-<version>.rbz.

An .rbz is a zip whose root holds exactly one loader (plomada.rb) and one
folder of the same name (plomada/); anything else at the root is rejected by
the extension signing service. The version comes from plomada/version.rb, the
single source.

    uv run python scripts/build_rbz.py
"""

from __future__ import annotations

import re
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
EXT = ROOT / "extension"
NAME = "plomada"
SKIP_SUFFIXES = {".pyc", ".orig", ".rej", ".swp", ".bak"}
SKIP_NAMES = {".DS_Store", "Thumbs.db"}


def version() -> str:
    text = (EXT / NAME / "version.rb").read_text(encoding="utf-8")
    m = re.search(r"VERSION\s*=\s*'([^']+)'", text)
    if not m:
        raise SystemExit("VERSION not found in extension/plomada/version.rb")
    return m.group(1)


def files() -> list[Path]:
    out = [EXT / f"{NAME}.rb"]
    for p in sorted((EXT / NAME).rglob("*")):
        if p.is_file() and p.suffix not in SKIP_SUFFIXES and p.name not in SKIP_NAMES:
            out.append(p)
    return out


def build(dest_dir: Path | None = None) -> Path:
    dest = (dest_dir or ROOT / "dist") / f"{NAME}-{version()}.rbz"
    dest.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(dest, "w", compression=zipfile.ZIP_DEFLATED) as zf:
        for path in files():
            zf.write(path, path.relative_to(EXT).as_posix())
    return dest


def main() -> int:
    out = build()
    with zipfile.ZipFile(out) as zf:
        roots = sorted({n.split("/")[0] for n in zf.namelist()})
        count = len(zf.namelist())
    print(f"{out} ({out.stat().st_size} bytes, {count} files, root: {', '.join(roots)})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
