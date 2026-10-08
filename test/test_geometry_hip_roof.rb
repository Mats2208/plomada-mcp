# frozen_string_literal: true

require_relative 'test_helper'
require_relative '../extension/plomada/geometry/hip_roof'

class TestGeometryHipRoof < Minitest::Test
  include GeometryAssertions
  G = Plomada::Geometry

  TAN = Math.tan(Math::PI / 6) # pitch 30
  VERTICAL = 250.0 / Math.cos(Math::PI / 6) # thickness 250 measured square to the slope
  EAVE_Z = 2800.0 - (400.0 * TAN) # underside at the eave line, as in gable_roof
  RECT = [[0, 0], [12_000, 0], [12_000, 9000], [0, 9000]].freeze
  L_SHAPE = [[0, 0], [10_000, 0], [10_000, 5000], [5000, 5000], [5000, 10_000], [0, 10_000]].freeze
  # Stem and bar both 3000 wide: every arm collapses at the same instant.
  T_EVEN = [[0, 6000], [4500, 6000], [4500, 0], [7500, 0], [7500, 6000], [12_000, 6000], [12_000, 9000],
            [0, 9000]].freeze
  T_SHAPE = [[0, 6000], [4000, 6000], [4000, 0], [8000, 0], [8000, 6000], [14_000, 6000], [14_000, 9000],
             [0, 9000]].freeze
  U_EVEN = [[0, 0], [9000, 0], [9000, 6000], [6000, 6000], [6000, 3000], [3000, 3000], [3000, 6000],
            [0, 6000]].freeze
  U_SHAPE = [[0, 0], [12_000, 0], [12_000, 9000], [8000, 9000], [8000, 4000], [4000, 4000], [4000, 9000],
             [0, 9000]].freeze

  def roof(outline, overhang = 400.0) = G.hip_roof(outline, 2800.0, overhang, 30.0, 250.0)

  def manifold?(faces)
    pool = G::VertexPool.new(1e-6)
    G.manifold_report(faces.map { |f| { outer: f.map { |p| pool.id(p) }, holes: [] } })[:manifold]
  end

  def normal(face) = G.unit3(G.newell(face))
  def tops(r) = r[:roof].select { |f| normal(f)[2] > 1e-6 }
  def undersides(r) = r[:roof].select { |f| normal(f)[2] < -1e-6 }
  def fascias(r) = r[:roof].select { |f| normal(f)[2].abs <= 1e-6 }
  def projected_area(faces) = faces.sum { |f| G.signed_area(f.map { |p| p[0, 2] }) }

  def edges(faces)
    faces.flat_map { |f| f.each_index.map { |i| [f[i], f[(i + 1) % f.size]] } }
  end

  def boundary_distance(p, poly)
    poly.each_index.map do |i|
      a = poly[i]
      seg = G.sub(poly[(i + 1) % poly.size], a)
      t = (G.dot(G.sub(p, a), seg) / G.dot(seg, seg)).clamp(0.0, 1.0)
      G.dist(p, G.add(a, G.scale(seg, t)))
    end.min
  end

  # The full set of checks every hip roof must pass: one top face per eave
  # edge, each the plane through its eave at the pitch (a vertex d inside the
  # eave line is d * tan above it, which is its skeleton time, and never more
  # than its distance to the eave line allows), the faces tiling the eave
  # polygon, the underside the top lowered by VERTICAL, a closed manifold, and
  # every face facing out.
  def assert_hip_roof(r, eave, eave_z = EAVE_Z)
    top_z = eave_z + VERTICAL
    assert manifold?(r[:roof]), 'roof is a closed manifold'
    assert_equal [], r[:gables]
    assert_equal eave.size, tops(r).size, 'one top face per eave edge'
    assert_equal eave.size, undersides(r).size
    assert_equal eave.size, fascias(r).size
    assert_in_delta G.signed_area(eave), projected_area(tops(r)), 1.0, 'top faces tile the eave polygon'
    assert_in_delta(-G.signed_area(eave), projected_area(undersides(r)), 1.0)
    tops(r).each do |f|
      assert_in_delta 30.0, Math.acos(normal(f)[2]) * 180.0 / Math::PI, 1e-6, 'every plane at the pitch'
      k = f.each_index.find { |i| [f[i], f[(i + 1) % f.size]].all? { |p| (p[2] - top_z).abs < 1e-6 } }
      refute_nil k, 'each top face starts at an eave edge'
      a = f[k]
      inward = G.left_normal(G.unit(G.sub(f[(k + 1) % f.size], a)))
      f.each do |p|
        d = G.dot(G.sub(p, a), inward)
        assert_in_delta top_z + (d * TAN), p[2], 1e-6, "height of #{p.inspect}"
        assert_operator d, :<=, boundary_distance(p, eave) + 1e-6
      end
    end
    under = undersides(r).flatten(1).map { |p| p.map { |c| c.round(6) } }.sort
    lifted = tops(r).flatten(1).map { |p| [p[0], p[1], p[2] - VERTICAL].map { |c| c.round(6) } }.sort
    assert_equal lifted.uniq, under.uniq, 'underside is the top lowered by thickness / cos(pitch)'
    fascias(r).each do |f|
      mid = G.scale(G.add(f[0], f[1]), 0.5)
      refute G.point_in_polygon?(G.add(mid, normal(f)[0, 2]), eave), 'fascia faces out'
      assert_in_delta VERTICAL, f.map { |p| p[2] }.max - f.map { |p| p[2] }.min, 1e-6
    end
  end

  def test_rectangle_has_one_ridge_two_trapezoids_and_two_hips
    r = roof(RECT)
    eave = [[-400, -400], [12_400, -400], [12_400, 9400], [-400, 9400]]
    assert_hip_roof(r, eave)
    assert_equal [3, 3, 4, 4], tops(r).map(&:size).sort
    ridge_under = EAVE_Z + (9800.0 / 2 * TAN)
    top = tops(r).flatten(1).map { |p| p[2] }.max
    assert_in_delta ridge_under + VERTICAL, top, 1e-6
    ridge = edges(tops(r)).select { |a, b| (a[2] - top).abs < 1e-6 && (b[2] - top).abs < 1e-6 }
    ridge = ridge.map { |a, b| [a, b].sort }.uniq
    assert_equal 1, ridge.size, 'a single horizontal ridge'
    a, b = ridge[0]
    assert_in_delta 12_800.0 - 9800.0, G.dist(a, b), 1e-6
    assert_point [4500.0, 4500.0, top], a
    assert_point [7500.0, 4500.0, top], b
    assert_in_delta top, r[:ridge_z], 1e-6
    assert_point [1.0, 0.0], r[:axis].map(&:abs)
    gable = G.gable_roof(RECT, 2800.0, 400.0, 30.0, 250.0, 200.0)
    assert_in_delta gable[:ridge_z], r[:ridge_z], 1e-6, 'same ridge height as a gable over the same walls'
  end

  def test_square_meets_at_one_apex
    r = roof([[0, 0], [10_000, 0], [10_000, 10_000], [0, 10_000]])
    assert_hip_roof(r, [[-400, -400], [10_400, -400], [10_400, 10_400], [-400, 10_400]])
    assert_equal [3, 3, 3, 3], tops(r).map(&:size)
    apex = tops(r).map { |f| f.max_by { |p| p[2] } }
    apex.each { |p| assert_point [5000.0, 5000.0, EAVE_Z + VERTICAL + (5400.0 * TAN)], p }
    assert_nil r[:axis], 'no ridge on a pyramid'
  end

  def test_l_shape_has_a_valley_from_the_reflex_corner
    r = roof(L_SHAPE)
    assert_hip_roof(r, G.offset_polygon(L_SHAPE, 400.0))
    top_z = EAVE_Z + VERTICAL
    valleys = edges(tops(r)).select { |a, b| G.dist(a, [5400.0, 5400.0]) < 1e-6 && b[2] > top_z + 1.0 }
    refute_empty valleys
    # Both arms are 5800 wide at the eave: the valley runs to where their
    # ridges meet, 2900 inside every eave line.
    valleys.each { |_, b| assert_point [2500.0, 2500.0, top_z + (2900.0 * TAN)], b }
    sk = G.straight_skeleton(G.offset_polygon(L_SHAPE, 400.0))
    assert_equal 6, sk[:faces].size
    assert_includes sk[:nodes].map { |n| n.map { |c| c.round(6) } }, [2500.0, 2500.0, 2900.0]
  end

  def test_t_and_u_shapes_get_one_face_per_edge_and_valleys
    [T_EVEN, T_SHAPE, U_EVEN, U_SHAPE].each do |outline|
      r = roof(outline)
      eave = G.offset_polygon(outline, 400.0)
      assert_hip_roof(r, eave)
      reflex = eave.each_index.select do |i|
        G.cross(G.sub(eave[i], eave[i - 1]), G.sub(eave[(i + 1) % eave.size], eave[i])).negative?
      end
      assert_equal 2, reflex.size
      reflex.each do |i|
        valley = edges(tops(r)).find { |a, b| G.dist(a, eave[i]) < 1e-6 && b[2] > EAVE_Z + VERTICAL + 1.0 }
        refute_nil valley, "a valley rises from the reflex corner #{G.fmt_pt(eave[i])}"
      end
    end
  end

  def test_even_t_joins_three_ridges_at_one_node
    sk = G.straight_skeleton(G.offset_polygon(T_EVEN, 400.0))
    times = sk[:nodes].map { |n| n.map { |c| c.round(6) } }
    [[6000.0, 7500.0, 1900.0], [6000.0, 1500.0, 1900.0], [1500.0, 7500.0, 1900.0],
     [10_500.0, 7500.0, 1900.0]].each { |n| assert_includes times, n }
  end

  def test_more_orthogonal_plans_close
    plus = [[3000, 0], [6000, 0], [6000, 3000], [9000, 3000], [9000, 6000], [6000, 6000], [6000, 9000],
            [3000, 9000], [3000, 6000], [0, 6000], [0, 3000], [3000, 3000]]
    h_plan = [[0, 0], [4000, 0], [4000, 3000], [6000, 3000], [6000, 0], [10_000, 0], [10_000, 10_000],
              [6000, 10_000], [6000, 7000], [4000, 7000], [4000, 10_000], [0, 10_000]]
    stairs = [[0, 0], [12_000, 0], [12_000, 3000], [9000, 3000], [9000, 6000], [6000, 6000], [6000, 9000],
              [3000, 9000], [3000, 12_000], [0, 12_000]]
    [plus, h_plan, stairs].each do |outline|
      [0.0, 400.0].each do |overhang|
        eave = overhang.positive? ? G.offset_polygon(outline, overhang) : outline
        assert_hip_roof(roof(outline, overhang), eave, 2800.0 - (overhang * TAN))
      end
    end
  end

  def test_regular_hexagon_is_six_triangles_to_the_centre
    hexagon = Array.new(6) { |i| [6000.0 * Math.cos(i * Math::PI / 3), 6000.0 * Math.sin(i * Math::PI / 3)] }
    r = roof(hexagon)
    eave = G.offset_polygon(hexagon, 400.0)
    assert_hip_roof(r, eave)
    assert_equal [3] * 6, tops(r).map(&:size)
    apothem = (6000.0 * Math.cos(Math::PI / 6)) + 400.0 # the overhang moves every edge out by 400
    tops(r).each { |f| assert_point [0.0, 0.0, EAVE_Z + VERTICAL + (apothem * TAN)], f.max_by { |p| p[2] } }
  end

  def test_zero_overhang_sits_the_eave_on_the_walls
    r = roof(RECT, 0.0)
    assert_hip_roof(r, RECT, 2800.0)
    assert_in_delta 2800.0, undersides(r).flatten(1).map { |p| p[2] }.min, 1e-9
    assert_in_delta 2800.0 + VERTICAL + (4500.0 * TAN), r[:ridge_z], 1e-6
  end

  def test_collinear_points_and_clockwise_outlines_are_accepted
    eave = [[-400, -400], [12_400, -400], [12_400, 9400], [-400, 9400]]
    with_midpoints = [[0, 0], [6000, 0], [12_000, 0], [12_000, 4500], [12_000, 9000], [0, 9000], [0, 4500]]
    [with_midpoints, RECT.reverse, with_midpoints.reverse].each do |outline|
      r = roof(outline)
      assert_hip_roof(r, eave)
      assert_equal [3, 3, 4, 4], tops(r).map(&:size).sort
    end
    assert_equal 6, tops(roof(L_SHAPE.reverse)).size
  end

  def test_bad_outlines_are_refused
    err = assert_raises(Plomada::InvalidParams) { roof([[0, 0], [10_000, 10_000], [10_000, 0], [0, 10_000]]) }
    assert_match(/\Ahip roof outline crosses itself: edge \(0, 0\)-\(10000, 10000\) meets edge/, err.message)
    err = assert_raises(Plomada::InvalidParams) { roof([[0, 0], [5000, 0]]) }
    assert_equal 'hip roof outline needs at least 3 distinct points, got 2', err.message
    err = assert_raises(Plomada::InvalidParams) { roof([[0, 0], [0, 0], [5000, 0]]) }
    assert_equal 'hip roof outline needs at least 3 distinct points, got 2', err.message
    err = assert_raises(Plomada::InvalidParams) { roof([[0, 0], [5000, 0], [10_000, 0]]) }
    assert_equal 'hip roof outline folds back on itself at (0, 0)', err.message
  end

  def test_an_overhang_that_closes_a_notch_is_refused
    narrow_u = [[0, 0], [9000, 0], [9000, 6000], [4800, 6000], [4800, 2000], [4200, 2000], [4200, 6000], [0, 6000]]
    assert manifold?(roof(narrow_u, 200.0)[:roof])
    err = assert_raises(Plomada::InvalidParams) { roof(narrow_u, 400.0) }
    assert_match(/\Ahip roof eave line \(the outline offset by the 400 mm overhang\) crosses itself/, err.message)
  end

  def test_bad_pitch_or_thickness_is_refused
    err = assert_raises(Plomada::InvalidParams) { G.hip_roof(RECT, 2800.0, 400.0, 90.0, 250.0) }
    assert_equal 'hip roof pitch must be between 0 and 90 degrees, got 90', err.message
    err = assert_raises(Plomada::InvalidParams) { G.hip_roof(RECT, 2800.0, 400.0, 30.0, 0.0) }
    assert_equal 'hip roof thickness must be greater than 0, got 0', err.message
  end
end
