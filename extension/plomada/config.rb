# frozen_string_literal: true

module Plomada
  # Every tuning constant of the extension, in one place. Each value says its unit.
  # The Python bridge keeps its own side in plomada_bridge/config.py.
  def self.deep_freeze(value)
    case value
    when Hash then value.each_value { |v| deep_freeze(v) }
    when Array then value.each { |v| deep_freeze(v) }
    end
    value.freeze
  end

  CONFIG = deep_freeze(
    # --- transport -----------------------------------------------------------
    host: '127.0.0.1',                     # loopback literal; anything else refuses to start
    port: 7883,                            # TCP port (overridable in settings, 1024..65535)
    protocol: 1,                           # wire protocol major version (integer)
    max_frame_bytes: 32 * 1024 * 1024,     # bytes; a larger frame closes the connection
    read_chunk_bytes: 64 * 1024,           # bytes per read_nonblock call
    max_clients: 8,                        # simultaneous connections
    hello_timeout_ms: 10_000,              # ms an unauthenticated socket may stay open
    max_pending_write_bytes: 64 * 1024 * 1024, # bytes buffered per client before it is dropped

    # --- pump ----------------------------------------------------------------
    tick_busy_ms: 30,                      # ms between ticks while there is work
    tick_idle_ms: 100,                     # ms between ticks when idle
    idle_after_ms: 1_000,                  # ms without traffic before backing off to idle
    max_accepts_per_tick: 2,               # new connections accepted per tick
    max_frames_per_client_per_tick: 16,    # frames parsed per client per tick
    max_reads_per_client_per_tick: 16,     # read_nonblock calls per client per tick
    queue_cap: 256,                        # requests waiting in the FIFO
    readonly_budget_ms: 15,                # ms per tick spent answering read-only requests
    job_step_budget_ms: 40,                # ms budget handed to one job step per tick
    default_deadline_ms: 120_000,          # ms a request may take when it names no deadline
    finished_jobs_kept: 20,                # finished jobs remembered for job_status

    # --- security --------------------------------------------------------------
    token_bytes: 32,                       # random bytes in the token (hex encoded: 64 chars)
    audit_rotate_bytes: 5 * 1024 * 1024,   # bytes before audit.log rotates to audit.log.1
    audit_dialog_lines: 20,                # audit lines shown in the settings dialog
    ruby_soft_deadline_ms: 10_000,         # ms before execute_ruby is interrupted between lines
    ruby_output_cap_bytes: 64 * 1024,      # bytes of $stdout captured from execute_ruby
    ruby_code_cap_bytes: 200 * 1024,       # bytes of source accepted by execute_ruby

    # --- settings ranges (read_default values are range-checked) ---------------
    port_range: [1024, 65_535],            # inclusive TCP port range
    tick_range_ms: [10, 200],              # inclusive range for the busy tick, ms

    # --- architecture defaults (all millimetres unless noted) ------------------
    storey_height_mm: 2800.0,              # mm, storey and wall height
    slab_thickness_mm: 150.0,              # mm, floor slab; its top sits at z 0
    roof_thickness_mm: 250.0,              # mm, flat roof slab and gable roof sheet
    roof_overhang_mm: 400.0,               # mm, horizontal overhang past the outer face
    gable_pitch_deg: 30.0,                 # degrees, gable roof slope
    min_junction_angle_deg: 5.0,           # degrees; sharper wall junctions are refused
    junction_tolerance_mm: 0.5,            # mm, an end this close to an axis is a junction
    vertex_weld_mm: 0.001,                 # mm, vertices closer than this are one vertex
    cut_merge_mm: 0.5,                     # mm, cuts closer than this along a wall merge
    probe_mm: 1.0,                         # mm, strip_internal_faces probes this far off a face
    window_default_sill_mm: 900.0,         # mm, sill of a window whose record has none
    window_default_height_mm: 1200.0,      # mm, height of a window whose record has none
    door_default_height_mm: 2100.0,        # mm, height of a door whose record has none
    window_frame_mm: 50.0,                 # mm, square section of the window frame ring
    glass_thickness_mm: 6.0,               # mm, glass pane thickness
    door_leaf_mm: 40.0,                    # mm, door leaf thickness
    door_frame_face_mm: 40.0,              # mm, door frame section in the wall plane
    door_frame_depth_mm: 70.0,             # mm, door frame section across the wall
    door_undercut_mm: 10.0,                # mm, gap under the door leaf
    room_label_z_mm: 10.0,                 # mm, height of the room labels above the floor
    room_label_height_mm: 250.0,           # mm, letter height of the room labels
    builder_min_faces: 20,                 # faces; a step creating more uses Entities#build

    # --- model vocabulary ------------------------------------------------------
    dictionary: 'plomada',                 # attribute dictionary on everything Plomada makes
    storey_prefix: 'N00',                  # prefix of the storey groups
    tags: %w[Muros Carpinterias Losas Escaleras Ambientes Mobiliario Entorno Referencia_CAD],
    materials: {                           # name => [r, g, b] (0-255) and alpha (0-1)
      'MAT_hormigon' => [[150, 150, 146], 1.0],
      'MAT_revoque_blanco' => [[242, 240, 235], 1.0],
      'MAT_ladrillo' => [[168, 92, 64], 1.0],
      'MAT_madera' => [[146, 100, 64], 1.0],
      'MAT_vidrio' => [[165, 195, 210], 0.35],
      'MAT_metal' => [[38, 38, 40], 1.0],
      'MAT_piso_porcelanato' => [[208, 203, 195], 1.0],
      'MAT_cesped' => [[92, 138, 68], 1.0]
    },
    pbr: {                                 # applied only when the PBR API exists
      'MAT_metal' => { metallic: 1.0 },    # metallic factor, 0-1
      'MAT_vidrio' => { roughness: 0.05 }  # roughness factor, 0-1
    },

    # --- view, scenes, exports -------------------------------------------------
    capture_width: 1280,                   # px
    capture_height: 720,                   # px
    capture_jpeg_quality: 0.7,             # JPEG quality 0-1
    capture_max_bytes: 350_000,            # bytes; larger captures shrink and retry
    capture_shrink: 0.85,                  # factor per retry (15 percent steps)
    capture_min_side: 160,                 # px, smallest side a shrink may reach
    capture_antialias: false,              # antialiasing doubles write_image time
    captures_kept: 20,                     # capture files kept in %TEMP%
    eye_height_mm: 1600.0,                 # mm, scene camera eye height
    scene_fov_deg: 35.0,                   # degrees, scene camera field of view
    export_width: 2048,                    # px, export_scene_images default
    export_height: 1365,                   # px, export_scene_images default
    list_page_size: 200,                   # entities per list_entities page
    undo_max_steps: 10                     # steps the undo tool accepts
  )
end
