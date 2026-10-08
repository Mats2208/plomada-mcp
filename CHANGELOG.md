# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

## [0.3.0] - 2026-10-08

Real furniture and the site around the house. The test was a complete house drawn with AutoCAD MCP Pro
(`tests/fixtures/casa_completa_N00.dxf`): a house, a separate garage with a sectional door, a driveway with two cars,
an entrance path, a deck, a pool, a fence, trees and people. It was built live in SketchUp 2025 and checked in its 10
automatic scenes.

### Added

- **Component library.** A furniture block becomes a real 3D model wherever `mapa_componentes.json` maps it, and a
  massing box otherwise. The library is a folder: `PLOMADA_LIBRARY`, or `biblioteca` next to the repo. Each map entry
  takes these fields:
  - `fit`:
    - `real`: own size, back on the block's back edge.
    - `footprint`: scaled into the block, for models drawn at the wrong scale.
    - `native`: site objects, centred on the block.
  - `rot`: turns a model whose front does not face -y.
  - `part`: one object out of a file that holds several.
  - `scale`

  A model is loaded once per model and cleaned of what downloads carry besides the object: hidden geometry,
  background images, texts, dimensions and guides. `build_from_autocad` and `build_plan` take
  `furniture="library"` (the default) or `"massing"`.
- **The site, read from the ground-floor DXF**, on tag `Entorno`:
  - **Objects.** `SITIO_<NAME>` blocks (origin at the object's centre) become library components standing on the
    ground, or on the paving or deck they fall on. The names are `ARBOL`, `PALMERA`, `PINO`, `ARBUSTO`, `SETO`,
    `MACETA`, `AUTO`, `SUV`, `PICKUP`, `REPOSERA`, `PARRILLA`, `MESA_JARDIN`, `PERGOLA`, `PERSONA` and `FAROLA`.
  - **Paving and decks.** Closed polylines on `SITIO-PAVIMENTO` and `SITIO-DECK`.
  - **Pools.** Closed polylines on `SITIO-PILETA`, built with a coping, walls, floor and water 250 mm down.
    `add_terrain` leaves the coping open.
  - **Fences.** Polylines on `SITIO-CERCO`, 1.8 m boards.
- **Sectional garage doors.** A door at least 2.2 m wide (`garage_door_min_width_mm`) is built as a frame and four
  panels instead of a hinged leaf.
- **New materials:** `MAT_pavimento`, `MAT_agua` and `MAT_porton`.

### Changed

- **Exterior cameras of `auto_scenes`** frame the buildings, not the whole site. An eye that would look across a
  fence moves inside it, and an eye that would stand inside a parked car or a tree trunk moves past it.
- **Tests.** 128 minitest tests and 55 pytest tests, up from 112 and 52. Still 26 tools.

### Measured

- **Complete house.** 6 walls, 13 openings, 17 furniture pieces (10 real models; the 7 the library has no model for
  stay massing), 21 site objects, 2 pavings, a deck, a pool and a fence. Built in 14.0 s with the wall group
  manifold.

### Known limits

- **Loading a library model blocks SketchUp.** It blocks for up to 3.3 s per model, the first time that model enters
  a SketchUp model.
- **The site is read from the ground storey only.** On upper storeys Plomada warns and skips it.
- **The terrain is flat.**
- **`get_plan` does not return the site.**
- **The library does not ship with Plomada.** The models come from 3D Warehouse under its terms; the repo carries
  only the map format (`docs/mapa_componentes.example.json`).

## [0.2.0] - 2026-10-08

Several floors, stairs, hip roofs, furniture, terrain and cameras that need no coordinates. Every feature was drawn in
AutoCAD with AutoCAD MCP Pro, built live in SketchUp 2025 and checked on screen, and is covered by tests that run
without SketchUp.

### Added

- **Storeys.** `build_from_autocad` and `build_plan` take `storey` (`N00`, `N01`...) and `elevation`. Each floor is
  one DXF and one call, and a new storey stacks on the one below at that storey's wall height plus its slab
  thickness. Its slab gets the wells of the stairs coming up from below, the roof under it is erased, and `replace`
  only touches its own storey. Edit tools and `get_plan` take `storey`; with several storeys and none named they
  refuse instead of guessing.
- **Stairs** from the AutoCAD MCP Pro stair records (`stair_kind` straight, L or U, turning left or right). Each
  flight is a closed concrete solid with a sloped soffit, and L and U stairs get a landing block, all on tag
  `Escaleras`. Plomada warns when the rise does not match floor to floor or 2R + G falls outside 600-650 mm.
- **Hip roofs** (`roof="hip"`, also in `add_roof`) on any simple outline: one plane per eave meeting along the
  straight skeleton, which gives a ridge on rectangles, an apex on squares and valleys on L, T and U plans. They
  follow the same conventions as the gable, so both have the same ridge height over a rectangle.
- **Furniture.** The catalogue blocks AutoCAD MCP Pro inserts (`ARCH_<NAME>`, all 20 items) are read from the DXF and
  built as massing components on tag `Mobiliario`. The new materials are `MAT_mobiliario` and `MAT_sanitario`.
- **`add_terrain`** builds a lawn slab on tag `Entorno` around everything Plomada built, its top at the underside of the
  ground-floor slab.
- **`auto_scenes`** creates the scenes, so you don't place cameras by hand:
  - **Interiors.** One per room. The camera stands in the corner with the longest view across, kept clear of walls,
    stairs, wells and furniture.
  - **Exteriors.** Four at eye level, each backed off until every vertex of the building fits the frame.
  - **Aerial.** One view from above.

  Room labels are hidden in these scenes.
- Fixtures: the two-storey house (`tests/fixtures/casa_2_plantas_N00.dxf`, `_N01.dxf`). It has a 17-riser L stair and 16
  catalogue pieces.

### Changed

- **The wall solve is split per building.** Each building, made of walls that touch, is solved on its own and in its
  own job step. One house's sill heights no longer slice the walls of the others. The four-building plan's longest
  tick drops from 124 ms to 33 ms, or 39 ms with hip roofs.
- **Refused plans still change nothing.** A plan the solver refuses is now caught in the first job steps, which change
  nothing. The model stays as it was, and the -32004 message is the same as before.
- **26 tools,** up from 24.
- **Tests.** 112 minitest tests and 52 pytest tests, up from 75 and 48.

### Measured

- **Reference house.** 0.91 s p50 and a longest tick of 34 ms (`bench/results-2026-10-08.json`). The e2e passes 16/16.
- **Two-storey house.** 0.57 s for N00 and 0.69 s for N01, both wall groups manifold. Its 10 automatic scenes take
  0.41 s.

### Known limits

- **Storeys stack straight up**, so split levels are not supported.
- **Stair wells are not recut.** Rebuilding a lower storey does not recut the well above; Plomada warns.
- **Stairs and furniture are massing only.**
- **Hip roofs take no courtyards.**

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

[0.3.0]: https://github.com/Mats2208/plomada-mcp/releases/tag/v0.3.0
[0.2.0]: https://github.com/Mats2208/plomada-mcp/releases/tag/v0.2.0
[0.1.1]: https://github.com/Mats2208/plomada-mcp/releases/tag/v0.1.1
[0.1.0]: https://github.com/Mats2208/plomada-mcp/releases/tag/v0.1.0
