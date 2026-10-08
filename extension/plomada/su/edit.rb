# frozen_string_literal: true

require 'json'
require_relative 'kit'
require_relative 'builders'
require_relative 'build'

module Plomada
  module SU
    # Tools that change a house already in the model. Each reads the plan back
    # from the plomada attributes (no DXF), changes one record, re-solves the
    # whole storey in pure Ruby (so a bad edit is refused before any change)
    # and rebuilds only what the edit touches, as one undo step.
    module Edit
      module_function

      def current_plan(model, require_walls: true)
        plan = PlanReader.read(model)
        if require_walls && plan['walls'].empty?
          raise InvalidParams, 'no Plomada walls in this model; build one with build_from_autocad or build_plan first'
        end

        plan
      end

      def walls_group(model)
        model.entities.grep(Sketchup::Group).find { |g| g.valid? && SU.kind(g) == 'walls' }
      end

      def finishes(group)
        raw = group&.get_attribute(DICT, 'finishes')
        raw ? JSON.parse(raw) : {}
      end

      def apply_finishes(group, finishes)
        finishes.each do |wall_id, mat_name|
          mat = SU.material(group.model, mat_name)
          group.entities.grep(Sketchup::Face).each do |f|
            f.material = mat if f.get_attribute(DICT, 'wall') == wall_id
          end
        end
        SU.set_attrs(group, 'finishes' => JSON.generate(finishes))
      end

      # Solves the edited plan and returns the units that replace the walls group.
      def rebuild(model, raw_plan)
        settings = PlanReader.storey_settings(model)
        raw = raw_plan.merge('storey' => { 'name' => settings['name'], 'height' => settings['height'] })
        plan = Plan.normalize(raw)
        height = plan['storey']['height']
        layout = Geometry.solve_walls(plan['walls'], plan['openings'], storey_height: height)
        old = walls_group(model)
        state = { group: nil, faces: 0, removed: 0, manifold: nil, groups: [], finishes: finishes(old) }
        units = [['remove old walls', -> { model.entities.erase_entities(old) if old&.valid? }]]
        units.concat(Build.wall_units(model, plan, layout, plan['storey']['name'], height, state))
        units << ['strip internal faces', -> { Build.finish_walls(state, layout, plan, settings, height) }]
        [plan, layout, units, state]
      end

      def summary(state)
        { 'wall_faces' => state[:faces], 'internal_faces_removed' => state[:removed], 'manifold' => state[:manifold] }
      end

      def add_wall(params, ctx)
        model = ctx.model
        plan = current_plan(model, require_walls: false)
        wall = params.reject { |k, _| k == 'deadline_ms' }
        if plan['walls'].any? { |w| w['id'] == wall['id'] }
          raise InvalidParams, "wall #{wall['id'].inspect} already exists; ids are unique"
        end

        plan['walls'] << wall
        _, _, units, state = rebuild(model, plan)
        UnitJob.new('Plomada: add wall', units) { summary(state).merge('wall' => wall['id'], 'walls' => plan['walls'].size) }
      end

      def add_opening(params, ctx)
        model = ctx.model
        plan = current_plan(model)
        rec = params.reject { |k, _| k == 'deadline_ms' }
        if plan['openings'].any? { |o| o['id'] == rec['id'] }
          raise InvalidParams, "opening #{rec['id'].inspect} already exists; ids are unique"
        end

        plan['openings'] << rec
        norm, layout, units, state = rebuild(model, plan)
        frame = layout[:openings].find { |f| f[:id] == rec['id'] }
        stored = norm['openings'].find { |o| o['id'] == rec['id'] }
        units << ["opening #{rec['id']}", lambda {
          Openings.place(model, frame.merge(record: Build.opening_record(stored)))
        }]
        UnitJob.new('Plomada: add opening', units) { summary(state).merge('opening' => rec['id']) }
      end

      def move_opening(params, ctx)
        model = ctx.model
        id = Plan.text(params['id'], 'id')
        offset = Plan.non_negative(params['offset'], 'offset')
        plan = current_plan(model)
        rec = plan['openings'].find { |o| o['id'] == id }
        raise InvalidParams, "id names opening #{id.inspect}, which is not in the model" unless rec

        inst = SU.find_opening(model, id)
        raise InvalidParams, "opening #{id} has a record but no component in the model; run build_plan again" unless inst

        rec['offset'] = offset
        norm, layout, units, state = rebuild(model, plan)
        frame = layout[:openings].find { |f| f[:id] == id }
        stored = norm['openings'].find { |o| o['id'] == id }
        units << ["opening #{id}", -> { Openings.move(model, inst, frame.merge(record: Build.opening_record(stored))) }]
        UnitJob.new('Plomada: move opening', units) do
          summary(state).merge('opening' => id, 'offset' => offset, 'origin_mm' => frame[:origin].map { |v| v.round(1) })
        end
      end

      def set_wall_height(params, ctx)
        model = ctx.model
        id = Plan.text(params['id'], 'id')
        height = Plan.positive(params['height'], 'height')
        plan = current_plan(model)
        wall = plan['walls'].find { |w| w['id'] == id }
        raise InvalidParams, "id names wall #{id.inspect}, which is not in the model" unless wall

        wall['height'] = height
        _, _, units, state = rebuild(model, plan)
        UnitJob.new('Plomada: set wall height', units) { summary(state).merge('wall' => id, 'height' => height) }
      end

      def add_slab(params, ctx)
        model = ctx.model
        settings = PlanReader.storey_settings(model)
        thickness = params['thickness'].nil? ? CONFIG[:slab_thickness_mm] : Plan.positive(params['thickness'], 'thickness')
        outline = if params['outline']
                    pts = params['outline']
                    raise InvalidParams, 'outline must be a list of at least 3 [x, y] points' unless pts.is_a?(Array) && pts.size >= 3

                    poly = pts.each_with_index.map { |p, i| Plan.point(p, "outline[#{i}]") }
                    Geometry.signed_area(poly).negative? ? poly.reverse : poly
                  else
                    exterior(model, settings)[:points]
                  end
        old = model.entities.grep(Sketchup::Group).select { |g| g.valid? && SU.kind(g) == 'slab' }
        units = [['floor slab', lambda {
          SU.ensure_materials(model)
          SU.ensure_tags(model)
          model.entities.erase_entities(old) unless old.empty?
          Slabs.slab(model, settings['name'], outline, thickness)
        }]]
        UnitJob.new('Plomada: add slab', units) do
          { 'group' => SU.group_name(settings['name'], 'losa'), 'thickness' => thickness, 'outline' => outline }
        end
      end

      def add_roof(params, ctx)
        model = ctx.model
        settings = PlanReader.storey_settings(model)
        kind = Plan.choice(params.fetch('kind', 'flat') || 'flat', 'kind', %w[flat gable])
        overhang = params['overhang'].nil? ? CONFIG[:roof_overhang_mm] : Plan.non_negative(params['overhang'], 'overhang')
        thickness = params['thickness'].nil? ? CONFIG[:roof_thickness_mm] : Plan.positive(params['thickness'], 'thickness')
        pitch = params['pitch'].nil? ? CONFIG[:gable_pitch_deg] : Plan.positive(params['pitch'], 'pitch')
        raise InvalidParams, "pitch must be less than 75, got #{Plan.fmt(pitch)}" if pitch >= 75

        ext = exterior(model, settings)
        height = settings['height'].to_f
        gable = kind == 'gable' ? Geometry.gable_roof(ext[:points], height, overhang, pitch, thickness, ext[:thickness]) : nil
        old = model.entities.grep(Sketchup::Group).select { |g| g.valid? && SU.kind(g) == 'roof' }
        units = [["#{kind} roof", lambda {
          SU.ensure_materials(model)
          SU.ensure_tags(model)
          model.entities.erase_entities(old) unless old.empty?
          if gable
            Slabs.gable_roof(model, settings['name'], gable, thickness, overhang, pitch)
          else
            Slabs.flat_roof(model, settings['name'], ext[:points], height, thickness, overhang)
          end
        }]]
        UnitJob.new('Plomada: add roof', units) do
          { 'group' => SU.group_name(settings['name'], 'techo'), 'kind' => kind, 'overhang' => overhang,
            'thickness' => thickness, 'pitch' => kind == 'gable' ? pitch : nil }
        end
      end

      def exterior(model, settings)
        plan = Plan.normalize(current_plan(model).merge('storey' => { 'name' => settings['name'], 'height' => settings['height'] }))
        layout = Geometry.solve_walls(plan['walls'], plan['openings'], storey_height: plan['storey']['height'])
        layout[:exterior] || raise(InvalidParams, 'the plan has no closed exterior wall to take the outline from; pass outline')
      end

      # Paints a wall (by id), an opening (by id), a named group or every
      # top-level entity on a tag.
      def set_material(params, ctx)
        model = ctx.model
        target = Plan.text(params['target'], 'target')
        name = Plan.text(params['material'], 'material')
        mat = SU.material(model, name) if CONFIG[:materials].key?(name) || model.materials[name]
        raise InvalidParams, "material #{name.inspect} is not in the model; Plomada materials are #{CONFIG[:materials].keys.join(', ')}" unless mat || CONFIG[:materials].key?(name)

        group = walls_group(model)
        wall_hit = group && group.entities.grep(Sketchup::Face).any? { |f| f.get_attribute(DICT, 'wall') == target }
        opening = SU.find_opening(model, target)
        named = model.entities.find { |e| (e.is_a?(Sketchup::Group) || e.is_a?(Sketchup::ComponentInstance)) && e.valid? && e.name == target }
        tagged = model.layers[target] ? model.entities.select { |e| e.valid? && e.layer.name == target } : []
        unless wall_hit || opening || named || !tagged.empty?
          raise InvalidParams, "target #{target.inspect} matches no wall id, opening id, group name or tag in the model"
        end

        units = [["paint #{target}", lambda {
          m = SU.material(model, name)
          if wall_hit
            apply_finishes(group, finishes(group).merge(target => name))
          elsif opening
            opening.material = m
          elsif named
            named.material = m
          else
            tagged.each { |e| e.material = m if e.respond_to?(:material=) }
          end
        }]]
        what = if wall_hit then 'wall' elsif opening then 'opening' elsif named then 'group' else 'tag' end
        UnitJob.new('Plomada: set material', units) do
          { 'target' => target, 'matched' => what, 'material' => name, 'count' => what == 'tag' ? tagged.size : 1 }
        end
      end

      # Erases every top-level group, instance and scene carrying a plomada
      # attribute. Never Sketchup.file_new: on Windows it can open a save
      # dialog that would freeze the pump.
      def reset(_params, ctx)
        model = ctx.model
        doomed = SU.plomada_entities(model)
        pages = model.pages.select { |p| p.attribute_dictionary(DICT) }
        units = [['erase Plomada objects', lambda {
          model.entities.erase_entities(doomed.select(&:valid?)) unless doomed.empty?
          pages.each { |p| model.pages.erase(p) }
        }]]
        UnitJob.new('Plomada: reset', units) { { 'erased' => doomed.size, 'scenes_erased' => pages.size } }
      end

      def undo(params, _ctx)
        steps = params['steps'].nil? ? 1 : params['steps']
        unless steps.is_a?(Integer) && steps.between?(1, CONFIG[:undo_max_steps])
          raise InvalidParams, "steps must be an integer from 1 to #{CONFIG[:undo_max_steps]}, got #{steps.inspect}"
        end

        units = [["undo #{steps}", -> { steps.times { Sketchup.undo } }]]
        UnitJob.new('Plomada: undo', units, operation: false) { { 'undone' => steps } }
      end
    end
  end
end
