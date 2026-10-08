# frozen_string_literal: true

require_relative 'core'
require_relative 'parts'

module Plomada
  # Stairs and floor slabs with openings, as plain face loops in mm.
  #
  # A stair record follows AutoCAD MCP Pro (engineering/arch/stairs.py): in the
  # stair's own frame x runs up the first flight and y to its left; +start+ is
  # the midpoint of the bottom riser and +direction_deg+ turns that frame into
  # world coordinates. A flight of m risers has m - 1 treads of depth +going+;
  # the last riser of the stair lands on the upper floor. An L or a U splits
  # the risers (first flight (risers + 1) / 2) and turns +turn+ on a square
  # landing +width+ deep; the U's second flight runs back beside the first.
  #
  # Every flight is a solid concrete stair: the stepped profile on top and a
  # sloped soffit +waist+ thick underneath, extruded across the flight. The
  # landing is a block down to the floor. Each piece is one closed manifold.
  module Geometry
    module_function

    STAIR_WAIST_MM = 150.0 # mm, concrete thickness under the steps, measured square to the pitch

    # Returns {pieces: [{name:, faces: [[x,y,z]...]}...], footprint: [[x,y]...],
    # top: risers * riser_height, blondel: 2R + G}. Footprints are world, CCW.
    def stair_layout(stair, waist: STAIR_WAIST_MM)
      w = stair['width'].to_f
      g = stair['going'].to_f
      r = stair['riser_height'].to_f
      n = stair['risers'].to_i
      h = w / 2.0
      pieces = []
      footprint = nil
      case stair['kind']
      when 'straight'
        pieces << flight('tramo_1', [0.0, 0.0], [1.0, 0.0], [-h, h], n, g, r, 0.0, waist)
        footprint = [[0.0, -h], [(n - 1) * g, -h], [(n - 1) * g, h], [0.0, h]]
      else
        first = (n + 1) / 2
        second = n - first
        landing = (first - 1) * g
        z_land = first * r
        pieces << flight('tramo_1', [0.0, 0.0], [1.0, 0.0], [-h, h], first, g, r, 0.0, waist)
        if stair['kind'] == 'l'
          pieces << box_piece('descanso', [[landing, -h], [landing + w, -h], [landing + w, h], [landing, h]], 0.0, z_land)
          # Second flight runs +y from the landing edge, across x landing..landing+w.
          pieces << flight('tramo_2', [landing + h, h], [0.0, 1.0], [-h, h], second, g, r, z_land, waist)
          top = h + ((second - 1) * g)
          footprint = [[0.0, -h], [landing + w, -h], [landing + w, top], [landing, top], [landing, h], [0.0, h]]
        else
          pieces << box_piece('descanso', [[landing, -h], [landing + w, -h], [landing + w, 3 * h], [landing, 3 * h]],
                              0.0, z_land)
          # Second flight runs -x from the landing edge, across y h..3h.
          pieces << flight('tramo_2', [landing, 2 * h], [-1.0, 0.0], [-h, h], second, g, r, z_land, waist)
          back = landing - ((second - 1) * g)
          x0 = [0.0, back].min
          footprint = [[x0, -h], [landing + w, -h], [landing + w, 3 * h], [x0, 3 * h]]
        end
      end
      pieces.compact!
      xf = ->(p) { stair_to_world(stair, p) }
      pieces.each { |pc| pc[:faces] = pc[:faces].map { |f| f.map { |q| xf.call([q[0], q[1]]) + [q[2]] } } }
      pieces.each { |pc| pc[:faces] = pc[:faces].map(&:reverse) } if stair['turn'] == 'right'
      world = footprint.map { |p| xf.call(p) }
      world = world.reverse if signed_area(world).negative?
      { pieces: pieces, footprint: world, top: n * r, blondel: (2.0 * r) + g }
    end

    # The stair frame (x up the first flight, y left; mirrored for turn right) to world.
    def stair_to_world(stair, p)
      x = p[0]
      y = stair['turn'] == 'right' ? -p[1] : p[1]
      a = stair['direction_deg'].to_f * Math::PI / 180.0
      s = stair['start']
      [s[0] + (x * Math.cos(a)) - (y * Math.sin(a)), s[1] + (x * Math.sin(a)) + (y * Math.cos(a))]
    end

    # One flight: +n+ risers starting at +origin+ (midpoint of its bottom riser,
    # stair frame) going +dir+, spanning +across+ [t0, t1] to the left of dir,
    # rising from +z0+. Its profile in (s along dir, z):
    # steps (0,z0+r) (g,z0+r) (g,z0+2r) ... up to ((n-1)g, z0+nr), then down the
    # soffit, parallel to the pitch and +waist+ below the nosing line, to the
    # level z0 (clipped at s = 0).
    # A flight of one riser has no tread: it is the step up onto the floor or
    # landing above, so it builds nothing (returns nil).
    def flight(name, origin, dir, across, n, g, r, z0, waist)
      return nil if n < 2

      run = (n - 1) * g
      top = z0 + (n * r)
      steps = [[0.0, z0 + r]]
      (1...n).each do |k|
        steps << [k * g, z0 + (k * r)]
        steps << [k * g, z0 + ((k + 1) * r)]
      end
      slope = r / g
      drop = waist * Math.sqrt(1.0 + (slope * slope)) # vertical waist under a sloped soffit
      under_top = top - drop
      s_bottom = run - ((under_top - z0) / slope)
      profile =
        if s_bottom.positive?
          # The soffit reaches the base level: a solid wedge under the lower steps.
          [[0.0, z0]] + steps + [[run, under_top], [s_bottom, z0]]
        else
          # The soffit meets the first riser above the base (short flights off a landing).
          [[0.0, under_top - (run * slope)]] + steps + [[run, under_top]]
        end
      profile = dedupe_profile(profile)
      profile = profile.reverse if signed_area(profile).negative?
      { name: name, faces: extrude_across(profile, origin, dir, across[0], across[1]) }
    end

    def dedupe_profile(pts)
      out = []
      pts.each { |p| out << p if out.empty? || dist(out[-1], p) > 1e-9 }
      out.pop if out.size > 1 && dist(out[0], out[-1]) <= 1e-9
      out
    end

    # Extrudes a CCW profile in (s, z) along the left normal of +dir+ from t0 to t1.
    def extrude_across(profile, origin, dir, t0, t1)
      left = left_normal(dir)
      at = ->(s, z, t) { [origin[0] + (dir[0] * s) + (left[0] * t), origin[1] + (dir[1] * s) + (left[1] * t), z] }
      # A CCW (s, z) loop has its Newell normal along dir x Z = -left: that is the
      # outward side at t0; the cap at t1 runs the other way.
      faces = [profile.map { |s, z| at.call(s, z, t0) }, profile.reverse.map { |s, z| at.call(s, z, t1) }]
      profile.each_index do |i|
        s0, z0 = profile[i]
        s1, z1 = profile[(i + 1) % profile.size]
        faces << [at.call(s0, z0, t0), at.call(s0, z0, t1), at.call(s1, z1, t1), at.call(s1, z1, t0)]
      end
      faces
    end

    def box_piece(name, rect, z0, z1)
      rect = rect.reverse if signed_area(rect).negative?
      { name: name, faces: prism_faces(rect, z0, z1) }
    end

    # Signed volume of a closed loop set (positive when the faces point outward).
    def loops_volume(faces)
      faces.sum do |f|
        n = newell(f)
        c = f.each_with_object([0.0, 0.0, 0.0]) { |p, acc| 3.times { |k| acc[k] += p[k] / f.size } }
        dot3(c, n) / 3.0
      end
    end

    # A floor slab from z0 to z1 under +outline+ with vertical openings (stair
    # wells). Returns {outer:, holes:, normal:} faces. A hole that does not lie
    # wholly inside the outline is skipped and reported in +skipped+.
    def slab_faces(outline, holes, z0, z1)
      outer = remove_collinear(outline)
      outer = outer.reverse if signed_area(outer).negative?
      kept = []
      skipped = []
      (holes || []).each_with_index do |hole, i|
        ring = remove_collinear(hole)
        ring = ring.reverse if signed_area(ring).negative?
        if ring.size >= 3 && ring.all? { |p| point_in_polygon?(p, outer) }
          kept << ring
        else
          skipped << i
        end
      end
      lift = ->(ring, z) { ring.map { |p| [p[0], p[1], z] } }
      faces = [
        # A hole runs against its face's outer loop: clockwise on top, counter-clockwise below.
        { outer: lift.call(outer, z1), holes: kept.map { |h| lift.call(h.reverse, z1) }, normal: [0.0, 0.0, 1.0] },
        { outer: lift.call(outer.reverse, z0), holes: kept.map { |h| lift.call(h, z0) }, normal: [0.0, 0.0, -1.0] }
      ]
      side = lambda do |ring, inward|
        ring.each_index do |i|
          p = ring[i]
          q = ring[(i + 1) % ring.size]
          quad = [[p[0], p[1], z0], [q[0], q[1], z0], [q[0], q[1], z1], [p[0], p[1], z1]]
          quad = quad.reverse if inward
          faces << { outer: quad, holes: [], normal: unit3(newell(quad)) }
        end
      end
      side.call(outer, false)
      kept.each { |h| side.call(h, true) }
      { faces: faces, skipped: skipped }
    end
  end
end
