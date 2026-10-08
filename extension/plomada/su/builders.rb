# frozen_string_literal: true

require 'json'
require_relative 'kit'
require_relative '../geometry'

module Plomada
  module SU
    # Walls: one group per storey (N00_muros, tag Muros, MAT_revoque_blanco),
    # filled one wall per step from the solver's faces.
    module Walls
      module_function

      def create_group(model, storey)
        g = SU.group_on(model, model.entities, SU.group_name(storey, 'muros'), 'Muros', 'MAT_revoque_blanco')
        SU.set_attrs(g, 'kind' => 'walls', 'storey' => storey)
      end

      def build_wall(group, faces, record)
        created = SU.add_faces(group.entities, faces, always_build: true)
        json = JSON.generate(record)
        created.each do |face, f|
          next unless face&.valid?

          SU.set_attrs(face, 'kind' => 'wall_face', 'wall' => record['id'], 'part' => f[:part], 'record' => json)
        end
        created.size
      end

      # strip_internal_faces: probes 1 mm either side of every face from a
      # point on it; a face with wall on both sides is erased, then any edge
      # left without faces.
      def strip_internal_faces(group, solids, probe = CONFIG[:probe_mm])
        ents = group.entities
        tr = group.transformation
        internal = internal_faces(ents, tr, solids, probe)
        ents.erase_entities(internal) unless internal.empty?
        stray = ents.grep(Sketchup::Edge).select { |e| e.faces.empty? }
        ents.erase_entities(stray) unless stray.empty?
        internal.size
      end

      def internal_faces(ents, tr, solids, probe)
        ents.grep(Sketchup::Face).select do |f|
          point = point_on(f, tr)
          normal = f.normal.transform(tr)
          Geometry.internal_face?(point, normal.to_a, solids, probe)
        end
      end

      # A point inside the face: the centroid of its first mesh triangle.
      def point_on(face, tr)
        mesh = face.mesh(0)
        tri = mesh.polygon_points_at(1)
        c = tri.map { |p| p.transform(tr) }
        SU.to_mm(Geom::Point3d.new((c[0].x + c[1].x + c[2].x) / 3.0, (c[0].y + c[1].y + c[2].y) / 3.0,
                                   (c[0].z + c[1].z + c[2].z) / 3.0))
      end
    end

    # Windows and doors as component instances named after their tag, on tag
    # Carpinterias, with the full opening record in their plomada attributes.
    module Openings
      MATERIALS = { frame: 'MAT_metal', glass: 'MAT_vidrio', wood: 'MAT_madera' }.freeze

      module_function

      def definition_name(frame)
        w = Geometry.fmt(frame[:width])
        h = Geometry.fmt(frame[:height])
        if frame[:kind] == 'window'
          "plomada_ventana_#{w}x#{h}"
        else
          "plomada_puerta_#{w}x#{h}_#{Geometry.fmt(frame[:thickness])}_#{frame[:swing]}_#{frame[:hand]}"
        end
      end

      def definition(model, frame)
        name = definition_name(frame)
        existing = model.definitions[name]
        return existing if existing && existing.get_attribute(DICT, 'kind') == 'opening_definition' && existing.entities.size.positive?

        defn = existing || model.definitions.add(name)
        defn.entities.clear! if existing
        parts = if frame[:kind] == 'window'
                  Geometry.window_parts(frame[:width], frame[:height])
                else
                  Geometry.door_parts(frame[:width], frame[:height], frame[:thickness], frame[:swing], frame[:hand])
                end
        parts.each { |part| add_part(model, defn.entities, part) }
        SU.set_attrs(defn, 'kind' => 'opening_definition', 'opening_kind' => frame[:kind])
        defn
      end

      def add_part(model, entities, part)
        g = entities.add_group
        g.name = part[:name]
        pivot = part[:pivot] || [0.0, 0.0, 0.0]
        min = [0, 1, 2].map { |k| part[:min][k] - pivot[k] }
        max = [0, 1, 2].map { |k| part[:max][k] - pivot[k] }
        SU.add_faces(g.entities, SU.faces_from_loops(Geometry.box_faces(min, max)))
        g.transformation = Geom::Transformation.translation(SU.pt(pivot)) if part[:pivot]
        g.material = SU.material(model, MATERIALS.fetch(part[:material]))
        attrs = { 'part' => part[:name] }
        attrs.merge!('hinge' => part[:hinge], 'open_angle' => 0.0) if part[:hinge]
        SU.set_attrs(g, attrs)
      end

      def transformation(frame)
        Geom::Transformation.axes(SU.pt(frame[:origin]), SU.vec(frame[:xaxis]), SU.vec(frame[:yaxis]), Z_AXIS)
      end

      def place(model, frame)
        inst = model.entities.add_instance(definition(model, frame), transformation(frame))
        inst.name = frame[:tag].to_s
        inst.layer = SU.tag(model, 'Carpinterias')
        SU.set_attrs(inst, 'kind' => 'opening', 'id' => frame[:id], 'wall' => frame[:wall],
                           'opening_kind' => frame[:kind], 'record' => JSON.generate(frame[:record]))
      end

      def move(model, inst, frame)
        defn = definition(model, frame)
        inst.definition = defn unless inst.definition == defn
        inst.transformation = transformation(frame)
        SU.set_attrs(inst, 'record' => JSON.generate(frame[:record]), 'wall' => frame[:wall])
      end
    end

    # Floor slab (N00_losa) and roof (N00_techo), both on tag Losas.
    module Slabs
      module_function

      def slab(model, storey, outline, thickness)
        g = SU.group_on(model, model.entities, SU.group_name(storey, 'losa'), 'Losas', 'MAT_piso_porcelanato')
        SU.add_faces(g.entities, SU.faces_from_loops(Geometry.prism_faces(outline, -thickness, 0.0)))
        SU.set_attrs(g, 'kind' => 'slab', 'storey' => storey, 'thickness' => thickness,
                        'outline' => JSON.generate(outline))
      end

      def flat_roof(model, storey, outline, wall_top, thickness, overhang)
        g = SU.group_on(model, model.entities, SU.group_name(storey, 'techo'), 'Losas', 'MAT_hormigon')
        roof = Geometry.flat_roof_outline(outline, overhang)
        SU.add_faces(g.entities, SU.faces_from_loops(Geometry.prism_faces(roof, wall_top, wall_top + thickness)))
        SU.set_attrs(g, 'kind' => 'roof', 'roof' => 'flat', 'storey' => storey, 'thickness' => thickness,
                        'overhang' => overhang)
      end

      def gable_roof(model, storey, gable, thickness, overhang, pitch)
        g = SU.group_on(model, model.entities, SU.group_name(storey, 'techo'), 'Losas', 'MAT_hormigon')
        sheet = SU.group_on(model, g.entities, 'cubierta', nil, nil)
        SU.add_faces(sheet.entities, SU.faces_from_loops(gable[:roof]))
        gable[:gables].each_with_index do |faces, i|
          end_wall = SU.group_on(model, g.entities, "hastial_#{i + 1}", nil, 'MAT_revoque_blanco')
          SU.add_faces(end_wall.entities, SU.faces_from_loops(faces))
        end
        SU.set_attrs(g, 'kind' => 'roof', 'roof' => 'gable', 'storey' => storey, 'thickness' => thickness,
                        'overhang' => overhang, 'pitch' => pitch)
      end
    end

    # Room labels: 3D text on tag Ambientes, centred on the room point at z 10 mm.
    module Rooms
      module_function

      def label(model, room)
        info = Geometry.room_label(room)
        g = SU.group_on(model, model.entities, "Ambiente #{room['id']} #{room['name']}", 'Ambientes', 'MAT_metal')
        g.entities.add_3d_text(info[:text], TextAlignCenter, 'Arial', true, false,
                               CONFIG[:room_label_height_mm].mm, 0.0, 0.0, true, 0.0)
        bb = g.entities.parent.bounds
        center = bb.center
        target = SU.pt(info[:at])
        g.transformation = Geom::Transformation.translation(Geom::Vector3d.new(target.x - center.x, target.y - center.y,
                                                                               target.z - bb.min.z))
        SU.set_attrs(g, 'kind' => 'room', 'id' => room['id'], 'record' => JSON.generate(room))
      end
    end

    # Reads the plan back from the plomada attributes in the model.
    module PlanReader
      module_function

      def read(model)
        walls = {}
        storey = nil
        model.entities.grep(Sketchup::Group).each do |g|
          next unless g.valid? && SU.kind(g) == 'walls'

          storey ||= g.get_attribute(DICT, 'storey')
          g.entities.grep(Sketchup::Face).each do |f|
            id = f.get_attribute(DICT, 'wall')
            next if id.nil? || walls.key?(id)

            walls[id] = SU.record(f)
          end
        end
        openings = model.entities.grep(Sketchup::ComponentInstance).select { |i| i.valid? && SU.kind(i) == 'opening' }
        rooms = model.entities.grep(Sketchup::Group).select { |g| g.valid? && SU.kind(g) == 'room' }
        settings = storey_settings(model)
        {
          'walls' => walls.values.compact,
          'openings' => openings.map { |i| SU.record(i) }.compact,
          'rooms' => rooms.map { |g| SU.record(g) }.compact,
          'storey' => settings
        }
      end

      def storey_settings(model)
        g = model.entities.grep(Sketchup::Group).find { |x| x.valid? && SU.kind(x) == 'walls' }
        raw = g&.get_attribute(DICT, 'storey_settings')
        raw ? JSON.parse(raw) : { 'name' => CONFIG[:storey_prefix], 'height' => CONFIG[:storey_height_mm] }
      end
    end
  end
end
