# frozen_string_literal: true

require_relative '../errors'

module Plomada
  # Pure-Ruby geometry. Nothing in Plomada::Geometry touches the SketchUp API:
  # it takes and returns plain arrays of millimetre floats, so it is tested on
  # its own (test/test_geometry_*.rb) and computed in full before any step
  # touches the model.
  module Geometry
    EPS = 1e-9 # dimensionless or mm, for exact-zero tests on computed values

    module_function

    # --- 2D vectors --------------------------------------------------------------

    def add(a, b) = [a[0] + b[0], a[1] + b[1]]
    def sub(a, b) = [a[0] - b[0], a[1] - b[1]]
    def scale(a, k) = [a[0] * k, a[1] * k]
    def dot(a, b) = (a[0] * b[0]) + (a[1] * b[1])
    def cross(a, b) = (a[0] * b[1]) - (a[1] * b[0])
    def norm(a) = Math.hypot(a[0], a[1])
    def dist(a, b) = Math.hypot(b[0] - a[0], b[1] - a[1])

    def unit(a)
      l = norm(a)
      raise ArgumentError, 'zero-length vector' if l <= EPS

      [a[0] / l, a[1] / l]
    end

    def left_normal(u) = [-u[1], u[0]]

    # --- 3D vectors --------------------------------------------------------------

    def sub3(a, b) = [a[0] - b[0], a[1] - b[1], a[2] - b[2]]
    def add3(a, b) = [a[0] + b[0], a[1] + b[1], a[2] + b[2]]
    def scale3(a, k) = [a[0] * k, a[1] * k, a[2] * k]
    def dot3(a, b) = (a[0] * b[0]) + (a[1] * b[1]) + (a[2] * b[2])

    def cross3(a, b)
      [(a[1] * b[2]) - (a[2] * b[1]), (a[2] * b[0]) - (a[0] * b[2]), (a[0] * b[1]) - (a[1] * b[0])]
    end

    def norm3(a) = Math.sqrt(dot3(a, a))

    def unit3(a)
      l = norm3(a)
      raise ArgumentError, 'zero-length vector' if l <= EPS

      [a[0] / l, a[1] / l, a[2] / l]
    end

    # Newell normal of a 3D loop, not normalized (its length is twice the area).
    def newell(points)
      nx = ny = nz = 0.0
      points.each_with_index do |p, i|
        q = points[(i + 1) % points.size]
        nx += (p[1] - q[1]) * (p[2] + q[2])
        ny += (p[2] - q[2]) * (p[0] + q[0])
        nz += (p[0] - q[0]) * (p[1] + q[1])
      end
      [nx, ny, nz]
    end

    # --- polygons (2D, counter-clockwise means positive area) ---------------------

    def signed_area(poly)
      sum = 0.0
      poly.each_with_index do |p, i|
        q = poly[(i + 1) % poly.size]
        sum += (p[0] * q[1]) - (q[0] * p[1])
      end
      sum / 2.0
    end

    def centroid(poly)
      a = signed_area(poly)
      return poly.transpose.map { |c| c.sum / c.size } if a.abs <= EPS

      cx = cy = 0.0
      poly.each_with_index do |p, i|
        q = poly[(i + 1) % poly.size]
        f = (p[0] * q[1]) - (q[0] * p[1])
        cx += (p[0] + q[0]) * f
        cy += (p[1] + q[1]) * f
      end
      [cx / (6.0 * a), cy / (6.0 * a)]
    end

    # Ray casting; points exactly on an edge may go either way.
    def point_in_polygon?(pt, poly)
      inside = false
      j = poly.size - 1
      poly.each_with_index do |pi, i|
        pj = poly[j]
        if (pi[1] > pt[1]) != (pj[1] > pt[1])
          x = ((pj[0] - pi[0]) * (pt[1] - pi[1]) / (pj[1] - pi[1])) + pi[0]
          inside = !inside if pt[0] < x
        end
        j = i
      end
      inside
    end

    # Strictly inside a convex counter-clockwise polygon, at least +margin+ from every edge.
    def inside_convex?(pt, poly, margin = 0.0)
      poly.each_with_index do |p, i|
        q = poly[(i + 1) % poly.size]
        e = sub(q, p)
        len = norm(e)
        next if len <= EPS
        return false if cross(e, sub(pt, p)) / len <= margin
      end
      true
    end

    # Sutherland-Hodgman clip of a convex polygon against the half-plane
    # where fn(point) >= 0; +fn+ must be affine.
    def clip_half_plane(poly, &fn)
      out = []
      poly.each_with_index do |p, i|
        q = poly[(i + 1) % poly.size]
        fp = fn.call(p)
        fq = fn.call(q)
        out << p if fp >= 0
        next unless (fp >= 0) != (fq >= 0)

        t = fp / (fp - fq)
        out << [p[0] + ((q[0] - p[0]) * t), p[1] + ((q[1] - p[1]) * t)]
      end
      dedupe_ring(out)
    end

    # Intersection of two convex counter-clockwise polygons.
    def convex_intersection(a, b)
      result = a
      b.each_with_index do |p, i|
        q = b[(i + 1) % b.size]
        e = sub(q, p)
        result = clip_half_plane(result) { |pt| cross(e, sub(pt, p)) }
        return [] if result.size < 3
      end
      result
    end

    def dedupe_ring(poly, tol = 1e-7)
      out = []
      poly.each { |p| out << p if out.empty? || dist(out[-1], p) > tol }
      out.pop while out.size > 1 && dist(out[-1], out[0]) <= tol
      out
    end

    # Drops vertices that lie on the straight line between their neighbours.
    def remove_collinear(poly, tol = 1e-6)
      pts = dedupe_ring(poly)
      changed = true
      while changed && pts.size > 3
        changed = false
        pts.each_index do |i|
          a = pts[i - 1]
          b = pts[i]
          c = pts[(i + 1) % pts.size]
          ab = sub(b, a)
          bc = sub(c, b)
          next unless cross(ab, bc).abs <= tol * [norm(ab), norm(bc), 1.0].max && dot(ab, bc) >= 0

          pts.delete_at(i)
          changed = true
          break
        end
      end
      pts
    end

    # Offsets a simple counter-clockwise polygon outward by +d+ (inward when
    # negative) with mitred corners: each edge moves along its outward normal and
    # consecutive offset edges meet at their intersection.
    def offset_polygon(poly, d)
      pts = remove_collinear(poly)
      raise ArgumentError, 'offset_polygon needs a counter-clockwise polygon' unless signed_area(pts).positive?

      n = pts.size
      lines = pts.each_index.map do |i|
        a = pts[i]
        b = pts[(i + 1) % n]
        u = unit(sub(b, a))
        out = [u[1], -u[0]]
        [add(a, scale(out, d)), u]
      end
      lines.each_index.map do |i|
        p1, u1 = lines[i - 1]
        p2, u2 = lines[i]
        den = cross(u1, u2)
        raise ArgumentError, 'offset_polygon met two parallel edges' if den.abs <= EPS

        s = cross(sub(p2, p1), u2) / den
        add(p1, scale(u1, s))
      end
    end

    # True when the polygon is a rectangle (4 corners, right angles).
    def rectangle?(poly, tol = 1e-6)
      pts = remove_collinear(poly)
      return false unless pts.size == 4

      pts.each_index.all? do |i|
        e1 = unit(sub(pts[i], pts[i - 1]))
        e2 = unit(sub(pts[(i + 1) % 4], pts[i]))
        dot(e1, e2).abs <= tol
      end
    end

    # Signed distance of +p+ along +n+ from the line through +a+.
    def side_distance(p, a, n) = dot(sub(p, a), n)

    def fmt(f)
      return f.round.to_s if (f - f.round).abs < 1e-6

      format('%.3f', f).sub(/\.?0+\z/, '')
    end

    def fmt_pt(p) = "(#{fmt(p[0])}, #{fmt(p[1])})"
  end
end
