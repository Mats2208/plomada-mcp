<div align="center">

# Plomada

**Hand Claude an AutoCAD plan and get the exact 3D house in SketchUp: manifold walls, real openings, stairs, roofs, furniture, one Ctrl+Z per call.**

[![Version](https://img.shields.io/badge/version-0.2.0-blue?style=flat-square)](https://github.com/Mats2208/plomada-mcp/releases)
[![CI](https://img.shields.io/github/actions/workflow/status/Mats2208/plomada-mcp/ci.yml?branch=main&style=flat-square&label=ci)](https://github.com/Mats2208/plomada-mcp/actions/workflows/ci.yml)
[![SketchUp](https://img.shields.io/badge/SketchUp-2025%20Pro-005F9E?style=flat-square)](https://www.sketchup.com)
[![Python](https://img.shields.io/badge/python-3.12-3776AB?style=flat-square&logo=python&logoColor=white)](https://www.python.org)
[![Protocol](https://img.shields.io/badge/protocol-MCP-00B4D8?style=flat-square)](https://modelcontextprotocol.io)
[![License](https://img.shields.io/github/license/Mats2208/plomada-mcp?style=flat-square&color=green)](LICENSE)

<br/>

<table>
<tr>
<td width="50%"><img src="docs/img/e2e_shaded.jpg" alt="The reference house built by Plomada in SketchUp, shaded: flat roof with overhang, floor-to-ceiling windows, wooden entrance door" width="100%"/></td>
<td width="50%"><img src="docs/img/e2e_lines.jpg" alt="The same house in wireframe: partitions, door frames, window frames and room labels inside the walls" width="100%"/></td>
</tr>
</table>
<sub>Both images came back from <code>capture_view</code> in the e2e run, 139 ms and 114 ms after the call. Look at the wireframe: the three
doors in the partition, the two partitions butting into it and into the exterior wall, and the room labels on the floor
(<strong>01 LIVING 58.48 m²</strong>) all came from the DXF records, not from a prompt.</sub>

<br/><br/>

<table>
<tr>
<td align="center"><strong>0.91 s</strong><br/><sub>DXF to finished house (p50)</sub></td>
<td align="center"><strong>26</strong><br/><sub>MCP tools</sub></td>
<td align="center"><strong>31 ms</strong><br/><sub>model_info p50</sub></td>
<td align="center"><strong>34 ms</strong><br/><sub>longest pump tick</sub></td>
<td align="center"><strong>164</strong><br/><sub>tests, no SketchUp needed</sub></td>
</tr>
</table>

<sub>[The problem](#the-problem) · [What it does](#what-it-does) · [Numbers](#every-number-here-was-measured) · [Install](#install) · [Use](#use) · [How it works](#how-it-works) · [Comparison](#how-it-compares) · [Limits](#what-it-does-not-do)</sub>

</div>

---

## The problem

AutoCAD MCP Pro draws a plan with real architectural records: walls with an axis and a thickness, doors and windows hosted
at an offset along them, rooms with their area. Getting that into SketchUp as a model you can render usually means
importing the linework and rebuilding every wall by hand.

The SketchUp MCP servers that exist today make that worse in three ways:

- **They give the model primitives**, not architecture. Boxes, faces and push/pull leave the LLM to invent wall joints,
  and it gets mitres and T junctions wrong.
- **They cut openings with booleans.** `Group#subtract` is a Pro-only Solid Tools call that returns `nil` on any wall
  that is not already a solid.
- **They freeze or starve SketchUp.** Servers built on Ruby threads only run while SketchUp's main thread yields, and a
  long operation inside one call blocks the UI until it ends.

## What it does

`build_from_autocad("casa_minimalista.dxf")` reads the ACADMCP_ARCH records in the bridge, solves every wall junction in
pure Ruby, and builds the house inside a running SketchUp, one small step per UI tick:

| | Feature | Details |
|---|---|---|
| **Walls** | One closed manifold per storey | Mitred L corners, T junctions trimmed to the near face, X crossings cut at the faces. No booleans, no `find_faces`. |
| **Openings** | Real holes with reveals | Two jambs, a soffit, and a sill when the sill is above 0, in every opening. |
| **Carpentry** | Window and door components | 50 × 50 mm frame ring and a 6 mm pane at mid-thickness; 40 mm door leaf hinged per the plan's hand and swing. |
| **Storeys and stairs** | One DXF per floor, stacked | `storey="N01"` puts a floor on top of the one below. Its slab gets the wells of the stairs coming up, and the roof underneath goes. Straight, L and U stairs come from the AutoCAD stair records: concrete flights with a sloped soffit and a landing. |
| **Roofs** | Flat · gable · hip | Hip roofs on any simple outline (L, T, U...), solved as a straight skeleton: ridges, hips and valleys at one pitch. Every building in the DXF gets its own slab and roof. |
| **Furniture and ground** | Catalogue blocks · terrain | The 20 `arch_catalogue_insert` blocks (beds, sofas, tables, WC...) become massing components on tag `Mobiliario`. `add_terrain` lays a lawn slab around the buildings. |
| **Rooms** | 3D labels | Name, number and m² on the floor of each room. |
| **Undo** | One Ctrl+Z per tool call | All steps of a job chain into one operation. A failed, expired or cancelled job reverts itself. |
| **Edits** | Move, resize, add | `move_opening`, `set_wall_height`, `add_wall`, `add_opening` re-solve from the plan stored in the model, never from the DXF. |
| **Views** | Captures, scenes, exports | `auto_scenes` makes a camera inside every room plus four eye-level exteriors and an aerial, with no coordinates. JPEG captures under 350 KB, scene images, skp / fbx / obj export. |

Everything is in millimetres and named for the studio pipeline: groups `N00_muros`, `N01_losa`, `N01_techo`,
`N00_escalera_S1`; tags `Muros`, `Carpinterias`, `Losas`, `Escaleras`, `Ambientes`, `Mobiliario`, `Entorno`; materials
`MAT_revoque_blanco`, `MAT_vidrio`, `MAT_madera`, `MAT_mobiliario` and the rest.

<table>
<tr>
<td width="33%"><img src="docs/img/dos_plantas_aerea.png" alt="Two-storey house with a hip roof on a lawn, from the A_aerea scene auto_scenes made" width="100%"/></td>
<td width="33%"><img src="docs/img/dos_plantas_escalera.jpg" alt="Inside the ground floor: the L stair with its landing climbing to the well in the upper slab" width="100%"/></td>
<td width="33%"><img src="docs/img/dos_plantas_living.png" alt="The living room scene auto_scenes made: sofa, armchair and coffee table from the AutoCAD catalogue blocks" width="100%"/></td>
</tr>
</table>
<sub>The two-storey fixture: two DXF files drawn with AutoCAD MCP Pro (<code>tests/fixtures/casa_2_plantas_N00.dxf</code>,
<code>_N01.dxf</code>), a 17-riser L stair, 16 catalogue pieces. Left and right are <code>auto_scenes</code> output, the middle a
scene placed by hand at the stair, before the furniture went in.</sub>

## Every number here was measured

On the reference house (4 walls, 11 openings, 4 rooms), through the real stdio MCP server, against SketchUp 2025 Pro
25.0.571 on an AMD Ryzen 9 9900X with an RTX 3060. Source: [`bench/results-2026-10-08.json`](bench/results-2026-10-08.json)
and [`bench/e2e-2026-10-08.json`](bench/e2e-2026-10-08.json).

| Target | Budget | Measured |
|---|---|---|
| `build_from_autocad` on the fixture, end to end | < 3.0 s | **0.91 s** p50, 0.94 s max of 5 |
| `model_info`, 200 calls | p50 < 60 ms, p95 < 150 ms | **31.1 ms** p50, 32.5 ms p95 |
| `capture_view` 1280 × 720 | < 400 ms | **100 ms** p50, 182 ms max of 10 |
| Longest pump tick while building and answering | < 100 ms | **34.1 ms** |
| Wall faces built / internal faces left / manifold | | 78 / 0 / true |
| Four-building plan (`tests/fixtures/casos_prueba.dxf`), longest tick | < 100 ms | **33 ms** flat, 39 ms hip (124 ms in 0.1.1) |
| Two-storey house, one call per floor | | 0.57 s + 0.69 s, both wall groups manifold |

`python scripts/bench.py --certify` re-runs these and exits 1 if any target is missed.

**What does not fit in 100 ms, said plainly.** A viewport capture is one native `view.write_image` call that cannot be
split; in the committed run its tick took 150 ms, and it can go past 100 ms, which is why the bench reports it apart
from the pump. An FBX export is also one native call: 1371 ms the first time in the e2e run. `execute_ruby` runs your
code in one tick.

## Install

You need Windows 11, SketchUp 2025 Pro, [uv](https://docs.astral.sh/uv/) 0.11.25 and the
[`claude`](https://docs.claude.com/en/docs/claude-code) CLI. SketchUp 2024 and 2026 are targeted through feature
detection but were not run here.

```powershell
git clone https://github.com/Mats2208/plomada-mcp C:\mcp\plomada-mcp
cd C:\mcp\plomada-mcp
powershell -ExecutionPolicy Bypass -File scripts\install.ps1
```

The script copies `plomada.rb` and `plomada\` into the SketchUp Plugins folder and runs `uv sync`. It sets
`mcpServers.sketchup` in the Claude Desktop config, after a timestamped backup and leaving every other entry untouched.
It registers `plomada-mcp` for Claude Code with `claude mcp add -s user sketchup`. It also offers, y/n, to move the old
Tarkiin plugin out of the Plugins folder. Restart SketchUp, reconnect the MCP, and call `status`.

To install by hand instead, add [`plomada-0.2.0.rbz`](https://github.com/Mats2208/plomada-mcp/releases) through
**Extensions > Extension Manager > Install Extension**, then register `.venv\Scripts\plomada-mcp.exe` as a stdio server.

## Use

> _"Build the house in `PROYECTOS/3D/casa-minimalista/01_cad/casa_minimalista.dxf` and show it to me."_

```text
status              -> protocol 1, pro true, entities_build true, pbr true, fbx_export true
build_from_autocad  -> walls 4, openings 11 (4 doors, 7 windows), rooms 4, manifold true, 27 steps, 0.91 s
capture_view        -> image/jpeg 1280x720, 37 723 bytes
move_opening W2 8000 -> manifold true; the hole and the window moved together, still one undo step
```

Two floors are two calls, one DXF each:

```text
build_from_autocad casa_N00.dxf storey=N00 roof=flat -> stairs 1, furniture 6, elevation 0
build_from_autocad casa_N01.dxf storey=N01 roof=hip  -> elevation 2950, stair_wells 1, "roof of N00 erased: N01 now sits on it"
add_terrain                                          -> Terreno 23 x 21 m, top at -150
auto_scenes                                          -> I_N00_01_Living ... I_N01_13_Hall, E1_suroeste ... E4_noroeste, A_aerea
export_scene_images dir=.../04_pases                 -> 10 PNG
```

| Kind | Tools |
|---|---|
| **Read-only** | `status` · `model_info` · `list_entities` · `list_tags` · `list_materials` · `get_plan` · `capture_view` · `job_status` |
| **Build** | `build_from_autocad` · `build_plan` |
| **Edit** | `add_wall` · `add_opening` · `move_opening` · `set_wall_height` · `add_slab` · `add_roof` · `add_terrain` · `set_material` |
| **Scenes and exports** | `auto_scenes` · `create_scene` · `export_scene_images` · `export_model` |
| **Housekeeping** | `reset_plomada` · `undo` · `job_cancel` · `execute_ruby` (off by default) |

Every length is millimetres. Edits and `get_plan` take `storey`; with several storeys in the model and none named they
refuse instead of guessing. Every tool carries honest `readOnlyHint`, `destructiveHint` and `idempotentHint`
annotations, and refusals name the field: `walls[2].thickness must be greater than 0, got -200`.

## How it works

```text
Claude ──stdio──> plomada-mcp (Python)  ──127.0.0.1:7883, length-prefixed JSON-RPC, token──>  Plomada (Ruby, inside SketchUp)
                  parses the DXF (ezdxf)                                                     one UI.start_timer pump:
                  validates (pydantic)                                                        accept · read · enqueue ·
                  retries reads, never mutations                                              reads (15 ms) · 1 job step (40 ms) · write
```

- **One pump, no threads.** Everything runs in one re-entrancy-guarded timer on SketchUp's main thread: 30 ms ticks
  while busy, 100 ms when idle. A second client's `status` keeps answering during a build.
- **Geometry first, model second.** `Plomada::Geometry` has no SketchUp dependency. Each wall segment is cut into a grid of
  cells at jambs, junction faces and every sill and head of the storey. Cells inside an opening are skipped, shared cell
  sides cancel, and coplanar pieces merge into faces with holes. The result is a closed manifold by construction, and it is
  unit-tested before SketchUp sees it. Each building (walls that touch) is solved on its own, one per job step, so a plan
  of many houses never holds the UI in one tick, and nothing touches the model until every building has solved.
- **Storeys are built flat, then raised.** A storey is built at z 0 like a one-storey house; its last step stamps what it
  made with the storey name and lifts it to the elevation in one transform.
- **One undo per call.** The first step opens the operation and stamps the job on the model. Every later step chains onto
  it transparently. SketchUp drops operations that change nothing, so without the stamp a no-op first step would let the
  chain merge into the previous undo entry.
- **Bounded failure.** Every request carries a deadline. When a job expires, is cancelled or raises, it aborts and is
  undone. When SketchUp is blocked by a modal dialog, `status` answers within 5 s with "SketchUp is not responding: a modal
  dialog may be open in SketchUp, close it and retry" instead of hanging.

The token, loopback and eval model are described in [SECURITY.md](SECURITY.md).

## How it compares

Each cell was checked against the design study of 25 SketchUp MCPs that preceded this build and against each repo's
source.

| | Transport | Auth | Ruby eval by default | Architecture tools | Needs booleans | Tests |
|---|---|---|---|---|---|---|
| **Plomada** | Length-prefixed JSON-RPC on loopback TCP, UI-timer pump, stdio bridge | 64-hex token, constant-time compare, required | Off | Plan in: walls, openings, carpentry, storeys, stairs, slabs, flat/gable/hip roofs, furniture, terrain, rooms, automatic scenes | No | 112 minitest + 52 pytest, live e2e, bench |
| [Tarkiin/SketchUp-MCP](https://github.com/Tarkiin/SketchUp-MCP) | HTTP on 127.0.0.1:8080, served by Ruby threads, `Access-Control-Allow-Origin: *` | None | On | Primitives and `create_roof_truss` | No | None |
| [zinin/sketchup-mcp2](https://github.com/zinin/sketchup-mcp2) | Length-prefixed JSON-RPC on TCP, UI-timer pump, stdio bridge | None (loopback default) | On (`eval_enabled: true`) | Woodworking joints | Yes (`Group#subtract`) | Ruby minitest + Python |
| [PMajesty/sk_ruby_mcp](https://github.com/PMajesty/sk_ruby_mcp) | Streamable HTTP inside SketchUp, Host/Origin guard, no bridge | Optional, empty by default | On | Massing boxes, façade openings as glued components | No | Ruby test suite + soak scripts |
| [iamahsanmehmood/saie](https://github.com/iamahsanmehmood/saie) | WebSocket JSON-RPC on 127.0.0.1:9876 | Optional, empty by default | On | Walls, openings, slabs, roofs, DXF parsing | Yes (openings are `subtract`) | pytest unit and integration |

## What it does not do

- **Storeys stack straight up.** One storey per DXF, each on top of the one below; no split levels or mezzanines.
  Rebuilding a lower storey does not recut the stair well in the slab above: Plomada warns and you build that storey again.
- **Stairs are massing.** Solid concrete flights and landing, no railings; the well is the stair's whole footprint.
- **Straight walls only.** Curved axes are refused, as are three or more walls ending at one point and junctions sharper
  than 5°.
- **Roofs.** A gable needs a rectangular footprint. A hip takes any simple outline but no courtyard, and an overhang that
  makes the eave line cross itself is refused.
- **Furniture is massing too.** A few boxes per catalogue item, for scenes and render guidance; blocks outside the
  AutoCAD MCP Pro catalogue are skipped with a warning.
- **`export_model` skp needs a model saved once.** SketchUp refuses to copy an untitled model, and `Model#save` can
  raise a modal prompt that would freeze the pump.
- **`execute_ruby` is a guard against mistakes, not a sandbox.** It is off until you tick the box in
  **Extensions > Plomada > Settings**.

## Development

```powershell
uv run pytest                     # bridge: DXF, models, errors, socket, MCP tools (52 tests)
ruby -Itest test/run_all.rb       # extension: geometry, plan, pump (112 tests, Ruby 3.2, no SketchUp)
uv run ruff check . ; uv run ruff format --check .
uv run python scripts/e2e_house.py        # live: needs SketchUp with the extension
uv run python scripts/bench.py --certify  # live: writes bench/results-<date>.json
uv run python scripts/build_rbz.py        # dist/plomada-<version>.rbz
uv run python scripts/check_compat.py some.skp   # is this file newer than the installed SketchUp?
```

CI runs ruff, pytest and the Ruby suite on Windows and Ubuntu. Tuning constants live in
[`extension/plomada/config.rb`](extension/plomada/config.rb) and [`src/plomada_bridge/config.py`](src/plomada_bridge/config.py),
one place per side. Release notes are in [CHANGELOG.md](CHANGELOG.md).

## Repo layout

```text
extension/plomada.rb        loader (registers the extension)
extension/plomada/          the extension: pump, protocol, geometry/ (pure Ruby), su/ (SketchUp side)
src/plomada_bridge/         the stdio MCP server: tools, socket client, DXF reader, pydantic models
test/                       minitest suite with FakeSocket, FakeModel, FakeEntities, FakeView
tests/                      pytest suite and fixtures (the reference house, the four test buildings, the two-storey house)
scripts/                    install.ps1, e2e_house.py, bench.py, build_rbz.py, check_compat.py
bench/                      measured results
docs/img/                   images from the e2e run
```

## License

[MIT](LICENSE)
