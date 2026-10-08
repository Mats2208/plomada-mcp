# frozen_string_literal: true

require_relative 'test_helper'

# strip_internal_faces on a synthetic T: wall A runs along x, stem S meets its
# north face. Built the naive way (A's north face split where S lands, S with
# an end face of its own), the T leaves two coincident faces at y 200. Only
# those two have wall on both sides, so only those two are internal.
class TestGeometryProbe < Minitest::Test
  G = Plomada::Geometry

  def setup
    @solids = [
      { poly: [[0, 0], [6000, 0], [6000, 200], [0, 200]], z0: 0.0, z1: 2800.0, a: [0, 100], u: [1, 0], voids: [] },
      { poly: [[3000, 200], [3120, 200], [3120, 3000], [3000, 3000]], z0: 0.0, z1: 2800.0, a: [3060, 200], u: [0, 1], voids: [] }
    ]
  end

  def quad(x0, y0, x1, y1, z0 = 0.0, z1 = 2800.0)
    [[x0, y0, z0], [x1, y1, z0], [x1, y1, z1], [x0, y0, z1]]
  end

  def face(points)
    { outer: points, holes: [], normal: G.unit3(G.newell(points)) }
  end

  def naive_t
    {
      a_north_west: face(quad(3000, 200, 0, 200)),        # A's north face, west of S
      a_north_mid: face(quad(3120, 200, 3000, 200)),      # A's north face under S: internal
      a_north_east: face(quad(6000, 200, 3120, 200)),     # A's north face, east of S
      a_south: face(quad(0, 0, 6000, 0)),
      s_end: face(quad(3000, 200, 3120, 200)),            # S's end face on A: internal
      s_west: face(quad(3000, 3000, 3000, 200)),
      s_east: face(quad(3120, 200, 3120, 3000)),
      a_top: face([[0, 0, 2800], [6000, 0, 2800], [6000, 200, 2800], [0, 200, 2800]]),
      s_top: face([[3000, 200, 2800], [3120, 200, 2800], [3120, 3000, 2800], [3000, 3000, 2800]])
    }
  end

  def test_only_the_coincident_t_faces_are_internal
    faces = naive_t
    internal = G.internal_faces(faces.values, @solids, 1.0).map { |i| faces.keys[i] }
    assert_equal %i[a_north_mid s_end], internal.sort
  end

  def test_probe_respects_openings
    # A window void in A: the jamb face looks into the void, which is not wall.
    solids = [@solids[0].merge(voids: [{ s0: 1000.0, s1: 1900.0, z0: 900.0, z1: 2100.0 }])]
    jamb = face(quad(1000, 0, 1000, 200, 900, 2100).reverse)
    refute G.internal_face?(G.point_on_face(jamb[:outer]), jamb[:normal], solids, 1.0)
    assert G.inside_walls?([500, 100, 1000], solids)
    refute G.inside_walls?([1500, 100, 1000], solids), 'inside the window void'
    refute G.inside_walls?([1500, 100, 2900], solids), 'above the wall'
  end

  def test_point_on_face_avoids_holes_and_notches
    outer = [[0, 0, 0], [4000, 0, 0], [4000, 0, 2800], [0, 0, 2800]]
    hole = [[1000, 0, 900], [1000, 0, 2100], [3000, 0, 2100], [3000, 0, 900]]
    p = G.point_on_face(outer, [hole])
    inside_hole = p[0] > 1000 && p[0] < 3000 && p[2] > 900 && p[2] < 2100
    refute inside_hole, "probe point #{p.inspect} fell in the hole"
  end
end
