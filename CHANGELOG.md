# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

## [0.1.1] - 2026-10-08

Fixes found by building four plans the 0.1.0 solver had never seen (`tests/fixtures/casos_prueba.dxf`): the reference
house, an L-shaped house, a square split by an X crossing, and a six-room house.

### Fixed

- A partition that ends exactly on a mitred corner of another wall, for example the reflex corner of an L, was refused.
  It now tees into the arm it crosses, and the shared mitre face stays manifold.
- A plan with several buildings got a slab and a roof only on the largest one. Every building now gets its own:
  `N00_losa` / `N00_techo` for the first, then `N00_losa_2` / `N00_techo_2` and so on.

### Added

- `tests/fixtures/casos_prueba.dxf` and its records: 15 walls, 44 openings and 12 rooms, covered by 4 minitest tests
  and 1 pytest test. Totals: 75 minitest tests and 48 pytest tests.

### Measured

- The four-building plan builds in 2.7 s, with manifold walls and 0 internal faces.
- The reference house is unchanged: 0.81 s, longest build tick 29 ms, all 16 e2e checks pass.

### Known limits

- The pure-Ruby solve for a whole plan runs inside a single tick. For the four-building plan that tick takes about
  120 ms, over the 100 ms target. Solving building by building across ticks is planned for 0.2.

## [0.1.0] - 2026-10-08

First release. The SketchUp extension and the Python bridge version together.

### Added

- `build_from_autocad`: an AutoCAD MCP Pro DXF (ACADMCP_ARCH records, v 1) becomes a house in one call and one undo
  step. You get manifold walls with real openings and reveals, window and door components, a floor slab, a flat or gable
  roof, and room labels.
- `Plomada::Geometry`, a pure-Ruby wall solver: mitred L corners, T junctions trimmed to the near face, X crossings, and
  openings as voids in a conforming cell grid. It produces closed manifold walls without booleans.
- A single-thread pump on `UI.start_timer`: length-prefixed JSON-RPC 2.0 on loopback TCP, a hello handshake with a
  token, a FIFO queue, cancel, deadlines, and progress notifications on every step.
- 24 MCP tools on mcp 2.3.0 (`MCPServer`), with typed `Annotated` fields and honest read-only, destructive and
  idempotent hints.
- Edit tools that re-solve from the plan stored in the model: `add_wall`, `add_opening`, `move_opening`,
  `set_wall_height`, `add_slab`, `add_roof`, `set_material`.
- View tools: `capture_view` (JPEG under 350 KB), `create_scene` (two-point, eye height), `export_scene_images` and
  `export_model` (skp, fbx, obj).
- Security: loopback only, a 64-hex token compared in constant time, `execute_ruby` off by default, and an audit log
  without params.
- `scripts/install.ps1`, `scripts/e2e_house.py`, `scripts/bench.py --certify`, `scripts/build_rbz.py` and
  `scripts/check_compat.py`.
- Tests: 68 minitest tests without SketchUp, 47 pytest tests against a fake extension, and CI on Windows and Ubuntu.

### Measured on the reference house

`build_from_autocad` 0.81 s p50, `model_info` 31.3 ms p50 and 34.6 ms p95, `capture_view` 120 ms max, longest pump tick
46.4 ms. See `bench/results-2026-10-08.json`.

### Known limits

- One storey, no stairs, straight walls only.
- A viewport capture and a model export are single native calls that can block the UI for longer than 100 ms.
- PBR is detected through `Sketchup::Material#metallic_factor=`, the method SketchUp 2025 actually has, not through
  `metalness=`.

[0.1.1]: https://github.com/Mats2208/plomada-mcp/releases/tag/v0.1.1
[0.1.0]: https://github.com/Mats2208/plomada-mcp/releases/tag/v0.1.0
