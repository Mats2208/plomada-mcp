# frozen_string_literal: true

require_relative 'core'

module Plomada
  module Geometry
    # Straight skeleton of a simple counter-clockwise polygon, found by running
    # the wavefront: every edge moves inward at unit speed and every vertex
    # slides along the bisector of its two edges, so the time a point is swept
    # is its height on a roof of slope 1. Rather than queueing one event at a
    # time (Felkel & Obdrzalek), each step jumps to the earliest edge or split
    # event and then repairs the whole wavefront at once. That takes the
    # simultaneous events of real plans (a rectangle's two hips meeting on the
    # ridge, a square's four hips on the apex, two arms of an L or a T
    # collapsing together) in one pass, with no event ordering to get wrong.
    class StraightSkeleton
      # A wavefront vertex: position now, velocity, the edges before (ep) and
      # after (en) it, and the skeleton node it started from (nil for the
      # helper vertex a split inserts on the edge that is hit).
      Vertex = Struct.new(:pos, :vel, :ep, :en, :node)

      INF = Float::INFINITY
      RATE_EPS = 1e-12 # closing speed (edges move at 1) below which two features count as parallel

      attr_reader :nodes

      def initialize(poly)
        @poly = poly
        n = poly.size
        xs = poly.map { |p| p[0] }
        ys = poly.map { |p| p[1] }
        # Positions drift by ~1e-12 of the plan size per step; 1e-9 of it keeps
        # coincident events together and is still far below a millimetre.
        @tol = 1e-9 * [xs.max - xs.min, ys.max - ys.min, 1.0].max
        @lines = poly.each_index.map do |i|
          u = Geometry.unit(Geometry.sub(poly[(i + 1) % n], poly[i]))
          { a: poly[i], u: u, n: Geometry.left_normal(u) }
        end
        @nodes = poly.map { |p| [p[0], p[1], 0.0] } # [x, y, time]; ids 0...n are the corners
        @arcs = Hash.new { |h, k| h[k] = [] } # edge index => [[node, node]] bounding its face
        @now = 0.0
        @lavs = [poly.each_index.map { |i| Vertex.new(poly[i].dup, nil, (i - 1) % n, i, i) }]
      end

      # Returns one face per edge: node ids counter-clockwise from the edge's
      # start corner, so face i begins with nodes i and i + 1.
      def faces
        @faces ||= begin
          run
          @poly.each_index.map { |i| face(i) }
        end
      end

      private

      def run
        steps = (20 * @poly.size) + 50 # each event removes or splits a vertex; this is a safety net
        until @lavs.empty?
          fail_skeleton if (steps -= 1).negative?
          @lavs.each { |lav| lav.each { |v| v.vel = velocity(v) } }
          dt = next_event
          @lavs.each { |lav| lav.each { |v| v.pos = Geometry.add(v.pos, Geometry.scale(v.vel, dt)) } }
          @now += dt
          @lavs = @lavs.flat_map { |lav| repair(lav) }
        end
      end

      def fail_skeleton
        raise InvalidParams, 'hip roof: could not resolve the roof planes of this outline'
      end

      # A vertex stays on both offset lines: v . n_a = v . n_b = 1.
      def velocity(v)
        na = @lines[v.ep][:n]
        nb = @lines[v.en][:n]
        Geometry.scale(Geometry.add(na, nb), 1.0 / (1.0 + Geometry.dot(na, nb)))
      end

      # Time to the earliest event anywhere: an edge shrinking to nothing, or a
      # reflex (or straight) vertex reaching a non-adjacent edge of its own
      # wavefront. Separate wavefronts never meet, since each only shrinks.
      def next_event
        best = INF
        @lavs.each do |lav|
          lav.each_with_index do |v, k|
            best = [best, collapse_time(v, lav[(k + 1) % lav.size])].min
            next unless reflex?(v)

            lav.each_with_index do |u, j|
              x = lav[(j + 1) % lav.size]
              best = [best, hit_time(v, u, x)].min unless u.equal?(v) || x.equal?(v)
            end
          end
        end
        fail_skeleton unless best.finite?
        best
      end

      def reflex?(v) = Geometry.cross(@lines[v.ep][:u], @lines[v.en][:u]) < 1e-9

      def collapse_time(v, w)
        u = @lines[v.en][:u]
        rate = Geometry.dot(Geometry.sub(w.vel, v.vel), u)
        return INF unless rate < -RATE_EPS

        [Geometry.dot(Geometry.sub(w.pos, v.pos), u), 0.0].max / -rate
      end

      # When v reaches the moving line of edge u-x, and only if it lands
      # between u and x at that moment.
      def hit_time(v, u, x)
        line = @lines[u.en]
        rate = Geometry.dot(v.vel, line[:n]) - 1.0
        return INF unless rate < -RATE_EPS

        gap = Geometry.dot(Geometry.sub(v.pos, line[:a]), line[:n]) - @now
        return INF if gap < -@tol

        dt = [gap, 0.0].max / -rate
        at = ->(p) { Geometry.add(p.pos, Geometry.scale(p.vel, dt)) }
        base = at.call(u)
        s = Geometry.dot(Geometry.sub(at.call(v), base), line[:u])
        len = Geometry.dot(Geometry.sub(at.call(x), base), line[:u])
        s > -@tol / 2 && s < len + (@tol / 2) ? dt : INF
      end

      # Turns the wavefront at an event time back into simple polygons, one
      # rule at a time until none applies: merge vertices that met (edge
      # events), split where the polygon touches itself (vertex and split
      # events), and fold away zero-width spikes (two opposite edges met along
      # a segment, as on a ridge). Polygons of two vertices or fewer are done.
      def repair(lav)
        todo = [lav]
        done = []
        until todo.empty?
          ring = merge_coincident(todo.pop).reject { |v| v.ep == v.en }
          if ring.size <= 2
            close_small(ring)
          elsif (pair = pinch(ring))
            todo.concat(split(ring, *pair))
          elsif (hit = touching(ring))
            todo.concat(split_edge(ring, *hit))
          elsif (k = spike(ring))
            todo << collapse_spike(ring, k)
          else
            done << ring
          end
        end
        done
      end

      def same?(a, b) = Geometry.dist(a, b) <= 2 * @tol

      def node_at(pos)
        found = @nodes.index { |q| Geometry.dist(q, pos) <= 3 * @tol && (q[2] - @now).abs <= 3 * @tol }
        return found if found

        @nodes << [pos[0], pos[1], @now]
        @nodes.size - 1
      end

      # The arc a vertex traced lies between the faces of its two edges.
      def emit(a, b, f1, f2)
        return if a.nil? || a == b || f1 == f2

        @arcs[f1] << [a, b]
        @arcs[f2] << [a, b]
      end

      def stop(v, node) = emit(v.node, node, v.ep, v.en)

      def merge_coincident(ring)
        return ring if ring.size < 2

        start = ring.each_index.find { |k| !same?(ring[k - 1].pos, ring[k].pos) }
        return [absorb(ring)] if start.nil?

        groups = []
        ring.rotate(start).each do |v|
          groups.empty? || !same?(groups[-1][-1].pos, v.pos) ? groups << [v] : groups[-1] << v
        end
        groups.map { |g| g.size == 1 ? g[0] : absorb(g) }
      end

      def absorb(group)
        pos = Geometry.scale(group.map(&:pos).transpose.map(&:sum), 1.0 / group.size)
        node = node_at(pos)
        group.each { |v| stop(v, node) }
        Vertex.new(pos, nil, group.first.ep, group.last.en, node)
      end

      def close_small(ring)
        ids = ring.map { |v| node_at(v.pos).tap { |node| stop(v, node) } }
        emit(ids[0], ids[1], ring[0].en, ring[1].en) if ring.size == 2
      end

      # The first two non-neighbouring vertices at one point, the second being
      # the next visit after the first, so the loop between them is simple.
      def pinch(ring)
        n = ring.size
        (0...n).each do |i|
          ((i + 2)...n).each do |j|
            return [i, j] if !(i.zero? && j == n - 1) && same?(ring[i].pos, ring[j].pos)
          end
        end
        nil
      end

      # Cuts the ring at two coincident vertices into two rings, crossing over
      # their edges: the loop from a to b and the loop from b back to a.
      def split(ring, i, j)
        a = ring[i]
        b = ring[j]
        node = node_at(a.pos)
        stop(a, node)
        stop(b, node)
        [[Vertex.new(a.pos, nil, a.ep, b.en, node)] + cyc(ring, j + 1, i),
         [Vertex.new(a.pos, nil, b.ep, a.en, node)] + cyc(ring, i + 1, j)]
      end

      def cyc(ring, from, to)
        out = []
        k = from % ring.size
        until k == to % ring.size
          out << ring[k]
          k = (k + 1) % ring.size
        end
        out
      end

      # A vertex lying inside a non-adjacent edge, as [vertex index, edge start index].
      def touching(ring)
        ring.each_with_index do |v, i|
          ring.each_with_index do |u, j|
            w = ring[(j + 1) % ring.size]
            next if u.equal?(v) || w.equal?(v)

            dir = @lines[u.en][:u]
            rel = Geometry.sub(v.pos, u.pos)
            s = Geometry.dot(rel, dir)
            next unless Geometry.cross(dir, rel).abs <= @tol && s > @tol

            return [i, j] if s < Geometry.dot(Geometry.sub(w.pos, u.pos), dir) - @tol
          end
        end
        nil
      end

      # A split event: put a helper vertex on the edge where v touches it and
      # cut the ring there.
      def split_edge(ring, i, j)
        v = ring[i]
        helper = Vertex.new(v.pos, nil, ring[j].en, ring[j].en, nil)
        ring = ring.dup.insert(j + 1, helper)
        split(ring, j < i ? i + 1 : i, j + 1)
      end

      def spike(ring)
        ring.index { |v| Geometry.dot(@lines[v.ep][:u], @lines[v.en][:u]) < -1.0 + 1e-9 }
      end

      # A vertex whose two edges run back along each other: the two edges have
      # met along the stretch up to the nearer neighbour, which is a skeleton
      # arc between their faces; the neighbour stops there.
      def collapse_spike(ring, k)
        x, v, y, *rest = ring.rotate(k - 1)
        tip = node_at(v.pos)
        stop(v, tip)
        if Geometry.dist(v.pos, y.pos) <= Geometry.dist(v.pos, x.pos)
          node = node_at(y.pos)
          stop(y, node)
          emit(tip, node, v.ep, v.en)
          [x, Vertex.new(y.pos, nil, v.ep, y.en, node)] + rest
        else
          node = node_at(x.pos)
          stop(x, node)
          emit(tip, node, v.ep, v.en)
          [Vertex.new(x.pos, nil, x.ep, v.en, node), y] + rest
        end
      end

      # Walks the arcs of edge i's face from its end corner back to its start.
      def face(i)
        adj = Hash.new { |h, k| h[k] = [] }
        @arcs[i].uniq { |a, b| [a, b].minmax }.each do |a, b|
          adj[a] << b
          adj[b] << a
        end
        loop_ids = [i]
        prev = i
        cur = (i + 1) % @poly.size
        until cur == i
          loop_ids << cur
          nxt = adj[cur].reject { |k| k == prev || (k != i && loop_ids.include?(k)) }
          fail_skeleton unless nxt.size == 1
          prev, cur = cur, nxt[0]
        end
        loop_ids
      end
    end

    module_function

    # Straight skeleton of a simple counter-clockwise polygon without collinear
    # points: { nodes: [[x, y, t]], faces: [[node ids]] } with t the
    # time the wavefront reaches the node, i.e. its distance to the lines of
    # the edges whose faces meet there. Face i belongs to edge i. It runs
    # around the plan's own corner so that the tolerance, a fraction of the
    # plan size, stays far above rounding even when the plan sits far from 0.
    def straight_skeleton(poly)
      o = poly.transpose.map(&:min)
      sk = StraightSkeleton.new(poly.map { |p| sub(p, o) })
      faces = sk.faces
      { nodes: sk.nodes.map { |x, y, t| [x + o[0], y + o[1], t] }, faces: faces }
    end

    # A hip roof over any simple outline: one plane per eave at the same pitch,
    # meeting along the straight skeleton of the eave line (hips, ridges,
    # valleys), so rectangles get a ridge, squares an apex and L, T and U plans
    # valleys. Same conventions as gable_roof: the eave line is the outer face
    # offset by the overhang, the underside passes through wall_top over the
    # outer face of the walls (eave underside at wall_top - overhang * tan), and
    # the top is the underside raised by thickness / cos(pitch), joined to it by
    # vertical fascias. Every loop is one planar face of a closed solid, wound
    # counter-clockwise seen from outside. Lengths in mm, pitch in degrees.
    def hip_roof(outline, wall_top, overhang, pitch_deg, thickness)
      check_hip_params(overhang, pitch_deg, thickness)
      pts = hip_outline(outline)
      eave = pts
      if overhang.positive?
        eave = offset_polygon(pts, overhang)
        assert_simple!(eave, "hip roof eave line (the outline offset by the #{fmt(overhang)} mm overhang)")
      end
      sk = straight_skeleton(eave)
      rad = pitch_deg * Math::PI / 180.0
      tan = Math.tan(rad)
      vertical = thickness / Math.cos(rad)
      eave_z = wall_top - (overhang * tan)
      at = ->(id, lift) { [sk[:nodes][id][0], sk[:nodes][id][1], eave_z + lift + (sk[:nodes][id][2] * tan)] }
      roof = sk[:faces].map { |f| f.map { |id| at.call(id, vertical) } }
      roof += sk[:faces].map { |f| f.reverse.map { |id| at.call(id, 0.0) } }
      eave.each_index do |i|
        j = (i + 1) % eave.size
        roof << [at.call(i, 0.0), at.call(j, 0.0), at.call(j, vertical), at.call(i, vertical)]
      end
      top = sk[:nodes].map { |n| n[2] }.max
      { roof: roof, gables: [], ridge_z: eave_z + vertical + (top * tan), axis: ridge_axis(sk) }
    end

    def check_hip_params(overhang, pitch_deg, thickness)
      raise InvalidParams, "hip roof pitch must be between 0 and 90 degrees, got #{fmt(pitch_deg)}" unless
        pitch_deg.positive? && pitch_deg < 90
      raise InvalidParams, "hip roof thickness must be greater than 0, got #{fmt(thickness)}" unless thickness.positive?
      raise InvalidParams, "hip roof overhang must be 0 or more, got #{fmt(overhang)}" if overhang.negative?
    end

    # The outline as a simple counter-clockwise polygon without repeated or
    # collinear points.
    def hip_outline(outline)
      pts = dedupe_ring(Array(outline).map { |p| [p[0].to_f, p[1].to_f] })
      raise InvalidParams, "hip roof outline needs at least 3 distinct points, got #{pts.size}" if pts.size < 3

      pts = remove_collinear(pts)
      assert_simple!(pts, 'hip roof outline')
      signed_area(pts).negative? ? pts.reverse : pts
    end

    # Refuses a polygon whose edges cross, touch or fold back on each other.
    def assert_simple!(poly, label, tol = 1e-6)
      n = poly.size
      n.times do |i|
        a = poly[i]
        b = poly[(i + 1) % n]
        ((i + 1)...n).each do |j|
          c = poly[j]
          d = poly[(j + 1) % n]
          if j == i + 1 || (i.zero? && j == n - 1)
            p, q, r = j == i + 1 ? [a, b, d] : [c, a, b] # q is the shared corner
            u = sub(q, p)
            w = sub(r, q)
            next unless cross(u, w).abs <= 1e-9 * norm(u) * norm(w) && dot(u, w).negative?

            raise InvalidParams, "#{label} folds back on itself at #{fmt_pt(q)}"
          elsif segments_meet?(a, b, c, d, tol)
            raise InvalidParams,
                  "#{label} crosses itself: edge #{fmt_pt(a)}-#{fmt_pt(b)} meets edge #{fmt_pt(c)}-#{fmt_pt(d)}"
          end
        end
      end
    end

    # True when segments ab and cd cross or touch (within +tol+ mm).
    def segments_meet?(a, b, c, d, tol)
      d1 = cross(sub(b, a), sub(c, a)) / norm(sub(b, a))
      d2 = cross(sub(b, a), sub(d, a)) / norm(sub(b, a))
      d3 = cross(sub(d, c), sub(a, c)) / norm(sub(d, c))
      d4 = cross(sub(d, c), sub(b, c)) / norm(sub(d, c))
      return true if d1 * d2 < 0 && d3 * d4 < 0

      [[d1, c, a, b], [d2, d, a, b], [d3, a, c, d], [d4, b, c, d]].any? do |dd, p, s0, s1|
        len = dist(s0, s1)
        t = dot(sub(p, s0), sub(s1, s0)) / len
        dd.abs <= tol && t >= -tol && t <= len + tol
      end
    end

    # Direction of the longest horizontal skeleton arc (the main ridge), or
    # nil when the planes meet at a single apex.
    def ridge_axis(skeleton)
      nodes = skeleton[:nodes]
      best = nil
      skeleton[:faces].each do |f|
        f.each_with_index do |a, k|
          b = f[(k + 1) % f.size]
          pa = nodes[a]
          pb = nodes[b]
          next unless pa[2].positive? && (pa[2] - pb[2]).abs <= 1e-6

          len = dist(pa, pb)
          best = [len, sub(pb, pa)] if len > 1e-6 && (best.nil? || len > best[0])
        end
      end
      best && unit(best[1])
    end
  end
end
