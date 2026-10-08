"""Every tuning constant of the bridge, in one place.

The extension keeps its own side in extension/plomada/config.rb. Each value
says its unit. Environment overrides: PLOMADA_PORT (int), PLOMADA_HOME (the
folder that holds bridge.token and endpoint.json).
"""

from __future__ import annotations

import json
import os
from dataclasses import dataclass, field, replace
from pathlib import Path

__all__ = ["CONFIG", "BridgeConfig", "data_dir", "load_config"]


def data_dir() -> Path:
    """%LOCALAPPDATA%\\Plomada, where the extension writes bridge.token."""
    home = os.environ.get("PLOMADA_HOME")
    if home:
        return Path(home)
    base = os.environ.get("LOCALAPPDATA")
    if base:
        return Path(base) / "Plomada"
    return Path.home() / ".local" / "share" / "Plomada"


@dataclass(frozen=True)
class BridgeConfig:
    # --- transport ---------------------------------------------------------
    host: str = "127.0.0.1"  # loopback literal; the extension only listens there
    port: int = 7883  # TCP port of the extension
    protocol: int = 1  # wire protocol major version (integer)
    max_frame_bytes: int = 32 * 1024 * 1024  # bytes per frame, both directions
    data_dir: Path = field(default_factory=data_dir)  # holds bridge.token, endpoint.json

    # --- timeouts ------------------------------------------------------------
    connect_timeout_s: float = 5.0  # s for TCP connect plus the hello answer
    status_timeout_s: float = 5.0  # s; status unanswered means SketchUp is blocked
    read_timeout_s: float = 30.0  # s for any other read-only call
    mutation_grace_s: float = 5.0  # s added to deadline_ms for mutating calls
    default_deadline_ms: int = 120_000  # ms a mutating job may run in SketchUp

    # --- tool defaults (millimetres unless noted) ------------------------------
    storey_height_mm: float = 2800.0  # mm, storey and wall height
    overhang_mm: float = 400.0  # mm, roof overhang past the outer face
    slab_thickness_mm: float = 150.0  # mm, floor slab
    roof_thickness_mm: float = 250.0  # mm, roof slab or sheet
    gable_pitch_deg: float = 30.0  # degrees
    capture_width: int = 1280  # px
    capture_height: int = 720  # px
    export_width: int = 2048  # px
    export_height: int = 1365  # px
    eye_height_mm: float = 1600.0  # mm, scene camera height
    fov_deg: float = 35.0  # degrees, scene field of view
    list_page_size: int = 200  # entities per list_entities page
    undo_max_steps: int = 10  # steps the undo tool accepts
    library_dir: Path | None = field(default_factory=lambda: library_dir())  # component library (mapa_componentes.json)

    @property
    def token_path(self) -> Path:
        return self.data_dir / "bridge.token"

    @property
    def endpoint_path(self) -> Path:
        return self.data_dir / "endpoint.json"


def library_dir() -> Path | None:
    """PLOMADA_LIBRARY, else a `biblioteca` folder next to the repo (C:\\mcp\biblioteca), if it has a map."""
    env = os.environ.get("PLOMADA_LIBRARY")
    candidates = [Path(env)] if env else [Path(__file__).resolve().parents[3] / "biblioteca"]
    for c in candidates:
        if (c / "mapa_componentes.json").is_file():
            return c
    return None


def load_config() -> BridgeConfig:
    """Defaults, then the port the extension announced, then PLOMADA_PORT."""
    cfg = BridgeConfig()
    try:
        announced = json.loads(cfg.endpoint_path.read_text(encoding="utf-8"))
        port = announced.get("port")
        if isinstance(port, int) and 1024 <= port <= 65535:
            cfg = replace(cfg, port=port)
    except (OSError, ValueError):
        pass
    env_port = os.environ.get("PLOMADA_PORT")
    if env_port and env_port.isdigit():
        cfg = replace(cfg, port=int(env_port))
    return cfg


CONFIG = BridgeConfig()
