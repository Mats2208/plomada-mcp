# frozen_string_literal: true

require_relative 'core'

module Plomada
  module Geometry
    module_function

    # True when the 3D point lies inside the walls: inside some solid's
    # footprint (point in polygon in 2D), strictly between its bottom and top,
    # and not inside one of its opening voids.
    def inside_walls?(point, solids, margin = 1e-6)
      p2 = [point[0], point[1]]
      z = point[2]
      solids.any? do |sd|
        next false unless z > sd[:z0] + margin && z < sd[:z1] - margin
        next false unless inside_convex?(p2, sd[:poly], margin)

        s = dot(sub(p2, sd[:a]), sd[:u])
        sd[:voids].none? { |v| s > v[:s0] && s < v[:s1] && z > v[:z0] && z < v[:z1] }
      end
    end

    # The strip_internal_faces test for one face: probe +probe+ mm along the
    # normal and against it from a point on the face. When both probes are
    # inside the walls, the face separates wall from wall and is internal.
    def internal_face?(point, normal, solids, probe)
      n = unit3(normal)
      ahead = add3(point, scale3(n, probe))
      behind = add3(point, scale3(n, -probe))
      inside_walls?(ahead, solids) && inside_walls?(behind, solids)
    end

    # A point strictly inside a planar face given as an outer loop plus holes.
    # The face is projected on its dominant plane and cut by scanlines halfway
    # between distinct vertex heights; the midpoint of the widest inside
    # interval (even-odd over every loop, so holes and notches are excluded)
    # is lifted back onto the plane.
    def point_on_face(outer, holes = [], normal = nil)
      normal ||= unit3(newell(outer))
      drop = normal.map(&:abs).each_with_index.max[1]
      ax, ay = [0, 1, 2] - [drop]
      loops = ([outer] + holes).map { |lp| lp.map { |p| [p[ax], p[ay]] } }
      levels = loops.flatten(1).map { |p| p[1] }.sort.uniq
      best = nil
      levels.each_cons(2) do |y0, y1|
        next if y1 - y0 <= 1e-9

        y = (y0 + y1) / 2.0
        xs = []
        loops.each do |lp|
          lp.each_with_index do |p, i|
            q = lp[(i + 1) % lp.size]
            next unless (p[1] > y) != (q[1] > y)

            xs << (p[0] + ((y - p[1]) * (q[0] - p[0]) / (q[1] - p[1])))
          end
        end
        xs.sort.each_slice(2) do |x0, x1|
          next unless x1

          width = [x1 - x0, y1 - y0].min
          best = [width, (x0 + x1) / 2.0, y] if best.nil? || width > best[0]
        end
      end
      return [0, 1, 2].map { |k| outer.sum { |p| p[k] } / outer.size } unless best

      _, u, v = best
      pt = [0.0, 0.0, 0.0]
      pt[ax] = u
      pt[ay] = v
      p0 = outer[0]
      pt[drop] = p0[drop] - (((normal[ax] * (u - p0[ax])) + (normal[ay] * (v - p0[ay]))) / normal[drop])
      pt
    end

    # Applies the probe to plain faces ({outer:, holes:, normal:}); returns the
    # indices of internal faces. The SketchUp side does the same with real faces.
    def internal_faces(faces, solids, probe)
      faces.each_index.select do |i|
        f = faces[i]
        internal_face?(point_on_face(f[:outer], f[:holes] || [], f[:normal]), f[:normal], solids, probe)
      end
    end
  end
end
