# frozen_string_literal: true

require_relative 'core'

module Plomada
  # Framing of the 2D drawings export_drawings writes: plan cuts, elevations,
  # sections and axonometrics. Pure mm math; every orthographic view shares
  # one scale (+px_per_m+) so the images can be laid out side by side at the
  # same scale.
  module Geometry
    module_function

    DRAWING_MARGIN_MM = 1500.0   # mm around what a drawing frames
    DRAWING_BELOW_MM = 1000.0    # mm under the lowest thing an elevation or section shows
    DRAWING_ABOVE_MM = 1500.0    # mm over the highest roof
    DRAWING_EYE_MM = 200_000.0   # mm from the framed box to an orthographic eye
    DRAWING_MAX_PX = 8192
    LOOKS = { 'north' => [0.0, 1.0], 'south' => [0.0, -1.0], 'east' => [1.0, 0.0], 'west' => [-1.0, 0.0] }.freeze
    ELEVATIONS = { 'elevacion_sur' => 'north', 'elevacion_norte' => 'south',
                   'elevacion_este' => 'west', 'elevacion_oeste' => 'east' }.freeze

    def drawing_px(mm, px_per_m)
      px = (mm * px_per_m / 1000.0).round
      raise InvalidParams, "a drawing would be #{px} px wide or tall; lower px_per_m (max #{DRAWING_MAX_PX} px)" if px > DRAWING_MAX_PX

      [px, 64].max
    end

    # A plan cut: seen from above, everything over +cut_z+ removed.
    # +box+ is [[x0, y0], [x1, y1]] of what to frame.
    def plan_drawing(name, box, cut_z, px_per_m)
      (x0, y0), (x1, y1) = box
      x0 -= DRAWING_MARGIN_MM
      y0 -= DRAWING_MARGIN_MM
      x1 += DRAWING_MARGIN_MM
      y1 += DRAWING_MARGIN_MM
      c = [(x0 + x1) / 2.0, (y0 + y1) / 2.0]
      { name: name, eye: [c[0], c[1], cut_z + DRAWING_EYE_MM], target: [c[0], c[1], cut_z], up: [0.0, 1.0, 0.0],
        height_mm: y1 - y0, width_px: drawing_px(x1 - x0, px_per_m), height_px: drawing_px(y1 - y0, px_per_m),
        section: { point: [0.0, 0.0, cut_z], normal: [0.0, 0.0, -1.0] } }
    end

    # An orthographic view looking horizontally along +look+ ('north'...), framing
    # +box+ ([[x0, y0], [x1, y1]]) across and z +zmin+..+zmax+ up. +section+
    # (optional) is {point:, normal:} with the normal toward what stays.
    def side_drawing(name, look, box, zmin, zmax, px_per_m, section: nil)
      dir = LOOKS.fetch(look) { raise InvalidParams, "look must be one of #{LOOKS.keys.join(', ')}, got #{look.inspect}" }
      (x0, y0), (x1, y1) = box
      across = dir[0].zero? ? [x0, x1] : [y0, y1]
      span = across[1] - across[0] + (2 * DRAWING_MARGIN_MM)
      lo = zmin - DRAWING_BELOW_MM
      hi = zmax + DRAWING_ABOVE_MM
      c = [(x0 + x1) / 2.0, (y0 + y1) / 2.0, (lo + hi) / 2.0]
      reach = [x1 - x0, y1 - y0].max + DRAWING_EYE_MM
      eye = [c[0] - (dir[0] * reach), c[1] - (dir[1] * reach), c[2]]
      { name: name, eye: eye, target: [c[0], c[1], c[2]], up: [0.0, 0.0, 1.0], height_mm: hi - lo,
        width_px: drawing_px(span, px_per_m), height_px: drawing_px(hi - lo, px_per_m), section: section }
    end

    # The four elevations of +box+, cut just under the ground (+ground_cut+) so
    # what is buried (a pool) does not show.
    def elevation_drawings(box, ground, top, ground_cut, px_per_m)
      ELEVATIONS.map do |name, look|
        side_drawing(name, look, box, ground, top, px_per_m,
                     section: { point: [0.0, 0.0, ground_cut], normal: [0.0, 0.0, 1.0] })
      end
    end

    # A section through +at+ (mm) across +axis+ ('x' cuts at x = at), looking
    # +look+; the part behind the cut, in the looking direction, stays.
    def section_drawing(name, axis, at, look, box, zmin, zmax, px_per_m)
      dir = LOOKS.fetch(look) { raise InvalidParams, "look must be one of #{LOOKS.keys.join(', ')}, got #{look.inspect}" }
      unless (axis == 'x' && dir[1].zero?) || (axis == 'y' && dir[0].zero?)
        raise InvalidParams, "a section across #{axis} = #{fmt_mm(at)} must look #{axis == 'x' ? 'east or west' : 'north or south'}, got #{look}"
      end

      point = axis == 'x' ? [at.to_f, 0.0, 0.0] : [0.0, at.to_f, 0.0]
      side_drawing(name, look, box, zmin, zmax, px_per_m, section: { point: point, normal: [dir[0], dir[1], 0.0] })
    end

    # The two default sections through the middle of +box+: A-A across x
    # looking west, B-B across y looking north.
    def default_sections(box)
      (x0, y0), (x1, y1) = box
      [{ 'name' => 'A-A', 'axis' => 'x', 'at' => (x0 + x1) / 2.0, 'look' => 'west' },
       { 'name' => 'B-B', 'axis' => 'y', 'at' => (y0 + y1) / 2.0, 'look' => 'north' }]
    end

    # An axonometric from the south-east, 35° down; the camera is fitted to the
    # model when the image is taken. +cut_z+ (optional) removes what is above.
    def axonometric_drawing(name, box, width_px, height_px, cut_z: nil)
      (x0, y0), (x1, y1) = box
      c = [(x0 + x1) / 2.0, (y0 + y1) / 2.0, 0.0]
      d = DRAWING_EYE_MM
      { name: name, eye: [c[0] + d, c[1] - d, Math.sqrt(2) * d * Math.tan(35.0 * Math::PI / 180.0)], target: c,
        up: [0.0, 0.0, 1.0], height_mm: nil, width_px: width_px, height_px: height_px, fit: true,
        section: cut_z && { point: [0.0, 0.0, cut_z], normal: [0.0, 0.0, -1.0] } }
    end

    def drawing_slug(name) = name.to_s.gsub(/[^A-Za-z0-9_]/, '')
  end
end
