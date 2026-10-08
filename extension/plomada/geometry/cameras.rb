# frozen_string_literal: true

require_relative 'core'

module Plomada
  # Cameras for the automatic scenes, in plan millimetres.
  #
  # Interior: from the room's label point, rays go out to the inner faces of
  # the walls (the wall bodies, so a door does not let a ray escape). The eye
  # goes into the corner whose diagonal is longest, a margin off the walls,
  # and looks back across the room toward the opposite corner: the classic
  # two-wall interior.
  #
  # Exterior: four eye-level three-quarter views from the corners of the
  # plan, each backed off until every point of the building fits the frame.
  module Geometry
    module_function

    CAMERA_WALL_MARGIN_MM = 350.0 # mm the interior eye keeps off the walls
    CAMERA_FIT_MARGIN = 1.08      # breathing room around a framed building
    CAMERA_FENCE_CLEAR_MM = 1500.0 # mm an exterior eye keeps inside a fence it would look across

    # The edges of closed plan rings (stair footprints, stair wells): obstacles
    # for the room cameras like the walls.
    def ring_edges(rings)
      rings.flat_map { |r| r.each_index.map { |i| [r[i], r[(i + 1) % r.size]] } }
    end

    # The four edges of every wall segment's body, as [[x, y], [x, y]].
    # Justification follows the record: left puts the body on the left of the
    # axis seen from its first point, right on the right, center across it.
    def wall_body_edges(walls)
      walls.flat_map do |w|
        pts = w['axis']
        pairs = pts.each_cons(2).to_a
        pairs << [pts[-1], pts[0]] if w['closed']
        t = w['thickness'].to_f
        lo, hi = case w['justification']
                 when 'left' then [0.0, t]
                 when 'right' then [-t, 0.0]
                 else [-t / 2.0, t / 2.0]
                 end
        pairs.flat_map do |a, b|
          n = left_normal(unit(sub(b, a)))
          a0 = add(a, scale(n, lo))
          b0 = add(b, scale(n, lo))
          a1 = add(a, scale(n, hi))
          b1 = add(b, scale(n, hi))
          [[a0, b0], [b0, b1], [b1, a1], [a1, a0]]
        end
      end
    end

    # Distance from +p+ along unit +d+ to the first edge hit (Infinity if none).
    def ray_distance(p, d, edges)
      best = Float::INFINITY
      edges.each do |a, b|
        e = sub(b, a)
        den = cross(d, e)
        next if den.abs < 1e-12

        w = sub(a, p)
        t = cross(w, e) / den
        s = cross(w, d) / den
        best = t if t > 1e-6 && s >= -1e-9 && s <= 1 + 1e-9 && t < best
      end
      best
    end

    # The direction of the longest wall segment: rooms are framed square to it.
    def dominant_axis(walls)
      seg = walls.flat_map do |w|
        pts = w['axis']
        pairs = pts.each_cons(2).to_a
        pairs << [pts[-1], pts[0]] if w['closed']
        pairs
      end.max_by { |a, b| dist(a, b) }
      seg ? unit(sub(seg[1], seg[0])) : [1.0, 0.0]
    end

    # {eye: [x, y], target: [x, y], span: mm} for one room, or nil when its
    # point is not enclosed (a ray escapes) or the room is too small for the
    # eye to stand in.
    def room_camera(at, edges, axis, margin: CAMERA_WALL_MARGIN_MM)
      n = left_normal(axis)
      diagonals = [[1, 1], [-1, 1], [-1, -1], [1, -1]].map do |i, j|
        unit(add(scale(axis, i), scale(n, j)))
      end
      reach = diagonals.map { |d| ray_distance(at, d, edges) }
      return nil unless reach.all?(&:finite?)

      # The corner opposite the longest view across the room.
      k = (0..3).max_by { |i| reach[i] + reach[(i + 2) % 4] }
      k = (k + 2) % 4 if reach[(k + 2) % 4] > reach[k]
      back = reach[k] - margin
      return nil if back < 0.0

      d = diagonals[k]
      eye = add(at, scale(d, back))
      target = add(at, scale(d, -0.5 * reach[(k + 2) % 4]))
      { eye: eye, target: target, span: reach[k] + reach[(k + 2) % 4] }
    end

    # Eye-level three-quarter views of the building whose vertices are
    # +points+ (mm, [x, y, z]), from the four corners of their plan box:
    # [{name:, eye: [x, y, z], target: [x, y, z]}]. The camera is level
    # (two-point), so every point must fit above and below the horizon at
    # +eye_height+ within +fov+ (vertical) and the 3:2 width. Real vertices,
    # not the box: a pitched roof leaves the box's top corners empty.
    def exterior_cameras(points, eye_height, fov_deg, aspect: 1.5)
      xs = points.map { |p| p[0] }
      ys = points.map { |p| p[1] }
      c = [(xs.min + xs.max) / 2.0, (ys.min + ys.max) / 2.0]
      tan_v = Math.tan(fov_deg * Math::PI / 360.0)
      tan_h = tan_v * aspect
      corners = points
      { 'suroeste' => [-1, -1], 'sureste' => [1, -1], 'noreste' => [1, 1], 'noroeste' => [-1, 1] }
        .each_with_index.map do |(label, (i, j)), idx|
          dir = unit([i.to_f, j.to_f])
          fwd = scale(dir, -1.0)
          right = [fwd[1], -fwd[0]]
          dist = corners.map do |x, y, z|
            o = sub([x, y], c)
            depth_off = dot(o, fwd)
            [dot(o, right).abs / tan_h, (z - eye_height).abs / tan_v].max - depth_off
          end.max * CAMERA_FIT_MARGIN
          xy = add(c, scale(dir, dist))
          { name: "E#{idx + 1}_#{label}", eye: [xy[0], xy[1], eye_height], target: [c[0], c[1], eye_height] }
        end
    end

    # The cameras with every eye that would look at the building across a
    # fence (polylines [{points:, closed:}]) moved in along its line of
    # sight to CAMERA_FENCE_CLEAR_MM inside the last fence it crosses, and
    # every eye that stands inside a site object (plan boxes [[x0, y0],
    # [x1, y1]]: a car, a tree) moved on until it is out of it.
    def clear_view(cams, fences, boxes = [], clear = CAMERA_FENCE_CLEAR_MM)
      segs = fences.flat_map do |f|
        pts = f[:points]
        s = pts.each_cons(2).to_a
        s << [pts[-1], pts[0]] if f[:closed] && pts.size > 2
        s
      end
      cams.map do |c|
        e = c[:eye][0, 2]
        t = c[:target][0, 2]
        sight = sub(t, e)
        len = Math.sqrt(dot(sight, sight))
        next c if len < 1.0

        hits = segs.filter_map { |a, b| crossing(e, sight, a, b) }

        u = hits.empty? ? 0.0 : hits.max + (clear / len)
        5.times do
          p = add(e, scale(sight, u))
          box = boxes.find { |lo, hi| p[0].between?(lo[0] - 300.0, hi[0] + 300.0) && p[1].between?(lo[1] - 300.0, hi[1] + 300.0) }
          break unless box

          u = box_exit(e, sight, box, 300.0) + (500.0 / len)
        end
        next c if u.zero?

        xy = add(e, scale(sight, [u, 0.9].min))
        c.merge(eye: [xy[0], xy[1], c[:eye][2]])
      end
    end

    # The u at which p + u * d leaves the box grown by +pad+.
    def box_exit(p, d, (lo, hi), pad)
      [0, 1].map do |k|
        next Float::INFINITY if d[k].abs < 1e-9

        ((d[k].positive? ? hi[k] + pad : lo[k] - pad) - p[k]) / d[k]
      end.min
    end

    # Where the segment a-b crosses p + u * d, as u in [0, 1], or nil.
    def crossing(p, d, a, b)
      ab = sub(b, a)
      den = cross(d, ab)
      return nil if den.abs < 1e-9

      ap = sub(a, p)
      u = cross(ap, ab) / den
      v = cross(ap, d) / den
      u.between?(0.0, 1.0) && v.between?(0.0, 1.0) ? u : nil
    end
  end
end
