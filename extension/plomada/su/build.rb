# frozen_string_literal: true

require 'json'
require_relative 'kit'
require_relative 'builders'
require_relative '../plan'
require_relative '../jobs'
require_relative '../geometry'

module Plomada
  module SU
    # The flagship: a plan (walls, openings, rooms) becomes a house in one
    # job. All geometry is solved in pure Ruby when the job is created, so an
    # invalid plan is refused with -32004 before anything touches the model;
    # then each step does one small unit (one wall, one opening, one label).
    module Build
      ROOFS = %w[flat gable none].freeze
      KINDS_REPLACED = %w[walls opening slab roof room].freeze

      module_function

      # --- options --------------------------------------------------------------------

      def options(raw, config = CONFIG)
        raw ||= {}
        raise InvalidParams, "options must be an object, got #{Plan.type_name(raw)}" unless raw.is_a?(Hash)

        {
          'storey_height' => opt_num(raw, 'storey_height', nil),
          'slab' => opt_bool(raw, 'slab', true),
          'roof' => Plan.choice(raw.fetch('roof', 'flat') || 'flat', 'options.roof', ROOFS),
          'overhang' => opt_num(raw, 'overhang', config[:roof_overhang_mm], zero: true),
          'replace' => opt_bool(raw, 'replace', true),
          'slab_thickness' => opt_num(raw, 'slab_thickness', config[:slab_thickness_mm]),
          'roof_thickness' => opt_num(raw, 'roof_thickness', config[:roof_thickness_mm]),
          'pitch' => opt_num(raw, 'pitch', config[:gable_pitch_deg]),
          'fit_view' => opt_bool(raw, 'fit_view', true)
        }.tap do |o|
          raise InvalidParams, "options.pitch must be less than 75, got #{Plan.fmt(o['pitch'])}" if o['pitch'] >= 75
        end
      end

      def opt_num(raw, key, default, zero: false)
        return default if raw[key].nil?

        zero ? Plan.non_negative(raw[key], "options.#{key}") : Plan.positive(raw[key], "options.#{key}")
      end

      def opt_bool(raw, key, default)
        return default unless raw.key?(key) && !raw[key].nil?
        return raw[key] if [true, false].include?(raw[key])

        raise InvalidParams, "options.#{key} must be true or false, got #{raw[key].inspect}"
      end

      # --- preparation (pure, before any model change) ------------------------------------

      # Normalizes the plan, solves the walls and the roof. Raises InvalidParams.
      def prepare(raw_plan, opts)
        raw = raw_plan.is_a?(Hash) ? raw_plan.dup : raw_plan
        if raw.is_a?(Hash) && opts['storey_height']
          raw['storey'] = (raw['storey'] || {}).merge('height' => opts['storey_height'])
        end
        plan = Plan.normalize(raw)
        height = plan['storey']['height']
        layout = Geometry.solve_walls(plan['walls'], plan['openings'], storey_height: height)
        warnings = layout[:warnings].dup
        outline = layout[:exterior]
        gable = nil
        if outline.nil?
          warnings << 'no closed exterior wall: slab and roof skipped' if opts['slab'] || opts['roof'] != 'none'
        elsif opts['roof'] == 'gable'
          gable = Geometry.gable_roof(outline[:points], height, opts['overhang'], opts['pitch'], opts['roof_thickness'],
                                      outline[:thickness])
        end
        { plan: plan, layout: layout, outline: outline, gable: gable, warnings: warnings, height: height }
      end

      def wall_record(w, height)
        { 'v' => 1, 'kind' => 'wall' }.merge(w).merge('height' => w['height'] || height)
      end

      def opening_record(o) = { 'v' => 1, 'kind' => 'opening' }.merge(o)
      def room_record(r) = { 'v' => 1, 'kind' => 'room' }.merge(r)

      # --- the build_plan job ---------------------------------------------------------

      def job(params, ctx, label: 'Plomada: build plan')
        opts = options(params['options'])
        prep = prepare(params['plan'], opts)
        model = ctx.model
        plan = prep[:plan]
        layout = prep[:layout]
        storey = plan['storey']['name']
        state = { group: nil, faces: 0, removed: 0, manifold: nil, groups: [] }
        units = []
        units << ['materials and tags', lambda {
          SU.ensure_tags(model)
          SU.ensure_materials(model)
          erase_previous(model) if opts['replace']
        }]
        units.concat(wall_units(model, plan, layout, storey, prep[:height], state))
        units << ['strip internal faces', -> { finish_walls(state, layout, plan, opts, prep[:height]) }]
        layout[:openings].each do |frame|
          units << ["opening #{frame[:id]}", lambda {
            Openings.place(model, frame.merge(record: opening_record(frame[:record])))
          }]
        end
        if prep[:outline] && opts['slab']
          units << ['floor slab', lambda {
            Slabs.slab(model, storey, prep[:outline][:points], opts['slab_thickness'])
            state[:groups] << SU.group_name(storey, 'losa')
          }]
        end
        if prep[:outline] && opts['roof'] != 'none'
          units << ["#{opts['roof']} roof", lambda {
            if opts['roof'] == 'gable'
              Slabs.gable_roof(model, storey, prep[:gable], opts['roof_thickness'], opts['overhang'], opts['pitch'])
            else
              Slabs.flat_roof(model, storey, prep[:outline][:points], prep[:height], opts['roof_thickness'], opts['overhang'])
            end
            state[:groups] << SU.group_name(storey, 'techo')
          }]
        end
        plan['rooms'].each do |room|
          units << ["room #{room['id']}", -> { Rooms.label(model, room_record(room)) }]
        end
        units << ['view', -> { View.fit(model) if opts['fit_view'] }]
        UnitJob.new(label, units) do
          ops = plan['openings']
          {
            'walls' => plan['walls'].size, 'openings' => ops.size,
            'doors' => ops.count { |o| o['opening_kind'] == 'door' },
            'windows' => ops.count { |o| o['opening_kind'] == 'window' },
            'rooms' => plan['rooms'].size, 'wall_faces' => state[:faces],
            'internal_faces_removed' => state[:removed], 'manifold' => state[:manifold],
            'groups' => state[:groups], 'storey_height' => prep[:height], 'roof' => opts['roof'],
            'warnings' => prep[:warnings], 'undo' => "one step: #{label}"
          }
        end
      end

      def wall_units(model, plan, layout, storey, height, state)
        plan['walls'].map do |w|
          faces = layout[:faces].select { |f| f[:wall] == w['id'] }
          ["wall #{w['id']}", lambda {
            unless state[:group]
              state[:group] = Walls.create_group(model, storey)
              state[:groups] << state[:group].name
            end
            state[:faces] += Walls.build_wall(state[:group], faces, wall_record(w, height))
          }]
        end
      end

      def finish_walls(state, layout, plan, opts, height)
        group = state[:group]
        return unless group

        state[:removed] = Walls.strip_internal_faces(group, layout[:solids])
        state[:manifold] = group.manifold?
        settings = { 'name' => plan['storey']['name'], 'height' => height, 'roof' => opts['roof'],
                     'overhang' => opts['overhang'], 'slab' => opts['slab'],
                     'slab_thickness' => opts['slab_thickness'], 'roof_thickness' => opts['roof_thickness'],
                     'pitch' => opts['pitch'] }
        SU.set_attrs(group, 'storey_settings' => JSON.generate(settings))
        finishes = state[:finishes] || {}
        Edit.apply_finishes(group, finishes) unless finishes.empty?
      end

      # replace: erases only top-level groups and components that carry a plomada attribute.
      def erase_previous(model)
        doomed = SU.plomada_entities(model).select { |e| KINDS_REPLACED.include?(SU.kind(e)) }
        model.entities.erase_entities(doomed) unless doomed.empty?
        doomed.size
      end
    end

    # Camera helpers shared by the build, capture and scene tools.
    module View
      module_function

      FIT_DIR = [-0.62, -0.95, 0.55].freeze # from the target toward the eye: south-west, above
      FIT_ASPECT = 1.5                      # width / height the framing must fit (exports are 3:2)
      FIT_MARGIN = 1.06                     # breathing room around the bounding box

      # A south-west three-quarter view framing everything Plomada built: the
      # eye backs off along FIT_DIR until all eight bounding-box corners fall
      # inside the vertical field of view and the 3:2 horizontal one.
      def fit(model, fov = CONFIG[:scene_fov_deg])
        bb = Geom::BoundingBox.new
        SU.plomada_entities(model).each { |e| bb.add(e.bounds) }
        bb = model.bounds if bb.empty?
        return if bb.empty?

        center = bb.center
        dir = Geom::Vector3d.new(*FIT_DIR).normalize
        forward = dir.reverse
        right = forward.cross(Z_AXIS).normalize
        up = right.cross(forward).normalize
        tan_v = Math.tan(fov * Math::PI / 360.0)
        tan_h = tan_v * FIT_ASPECT
        dist = (0..7).map do |i|
          o = bb.corner(i) - center
          depth_off = o.dot(forward)
          [o.dot(right).abs / tan_h, o.dot(up).abs / tan_v].max - depth_off
        end.max * FIT_MARGIN
        eye = center.offset(dir, dist)
        model.active_view.camera = Sketchup::Camera.new(eye, center, Z_AXIS, true, fov)
      end
    end
  end
end
