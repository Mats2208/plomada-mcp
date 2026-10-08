"""Packaging and the constants both sides must agree on."""

from __future__ import annotations

import importlib.util
import re
import tomllib
import zipfile
from pathlib import Path

from plomada_bridge import __version__
from plomada_bridge.config import BridgeConfig

ROOT = Path(__file__).resolve().parents[1]
CONFIG_RB = (ROOT / "extension" / "plomada" / "config.rb").read_text(encoding="utf-8")


def _load_build_rbz():
    spec = importlib.util.spec_from_file_location("build_rbz", ROOT / "scripts" / "build_rbz.py")
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


def test_rbz_has_one_root_rb_and_one_same_named_folder(tmp_path):
    build_rbz = _load_build_rbz()
    out = build_rbz.build(tmp_path)
    assert out.name == f"plomada-{build_rbz.version()}.rbz"
    with zipfile.ZipFile(out) as zf:
        names = zf.namelist()
    roots = {n.split("/")[0] for n in names}
    root_files = [n for n in names if "/" not in n]
    assert root_files == ["plomada.rb"]
    assert roots == {"plomada.rb", "plomada"}
    assert "plomada/main.rb" in names and "plomada/geometry/walls.rb" in names
    assert not any(n.endswith((".pyc", ".DS_Store")) for n in names)


def test_versions_agree():
    rb = re.search(r"VERSION = '([^']+)'", (ROOT / "extension/plomada/version.rb").read_text(encoding="utf-8"))
    assert rb is not None
    pyproject = tomllib.loads((ROOT / "pyproject.toml").read_text(encoding="utf-8"))
    assert rb.group(1) == pyproject["project"]["version"] == __version__


def _rb_int(name: str) -> int:
    m = re.search(rf"^\s*{name}: ([0-9_* ]+),", CONFIG_RB, re.MULTILINE)
    assert m, name
    return int(eval(m.group(1).replace("_", "")))


def test_both_sides_agree_on_the_wire():
    cfg = BridgeConfig()
    assert _rb_int("port") == cfg.port == 7883
    assert _rb_int("protocol") == cfg.protocol == 1
    assert _rb_int("max_frame_bytes") == cfg.max_frame_bytes == 32 * 1024 * 1024
    assert _rb_int("default_deadline_ms") == cfg.default_deadline_ms
    assert "host: '127.0.0.1'" in CONFIG_RB and cfg.host == "127.0.0.1"
