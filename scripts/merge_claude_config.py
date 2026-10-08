"""Sets mcpServers.sketchup in the Claude Desktop config, keeping everything else.

Writes a timestamped backup next to the file first, keeps key order, the
existing line endings and non-ASCII text, and replaces the file atomically.

    python scripts/merge_claude_config.py <config.json> <path to plomada-mcp.exe>
"""

from __future__ import annotations

import datetime as dt
import json
import os
import shutil
import sys
from pathlib import Path


def merge(config: Path, exe: Path, name: str = "sketchup") -> Path | None:
    backup = None
    if config.exists():
        raw = config.read_bytes()
        crlf = b"\r\n" in raw
        data = json.loads(raw.decode("utf-8-sig")) if raw.strip() else {}
        backup = config.with_name(f"{config.name}.bak-{dt.datetime.now():%Y%m%d-%H%M%S}")
        shutil.copy2(config, backup)
    else:
        crlf = os.name == "nt"
        data = {}
        config.parent.mkdir(parents=True, exist_ok=True)
    if not isinstance(data, dict):
        raise SystemExit(f"{config} does not hold a JSON object; not touching it")
    servers = data.setdefault("mcpServers", {})
    servers[name] = {"command": str(exe), "args": []}
    text = json.dumps(data, indent=2, ensure_ascii=False) + "\n"
    if crlf:
        text = text.replace("\n", "\r\n")
    tmp = config.with_name(config.name + ".tmp")
    tmp.write_bytes(text.encode("utf-8"))
    os.replace(tmp, config)
    return backup


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(__doc__)
        return 2
    backup = merge(Path(argv[0]), Path(argv[1]))
    print(f"set mcpServers.sketchup -> {argv[1]}" + (f" (backup: {backup})" if backup else " (new file)"))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
