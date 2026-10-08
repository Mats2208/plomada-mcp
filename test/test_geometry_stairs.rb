# frozen_string_literal: true

require_relative 'test_helper'

# Stairs in the AutoCAD MCP Pro convention and slabs with stair wells.
class TestGeometryStairs < Minitest::Test
  include GeometryAssertions
  G = Plomada::Geometry

  def stair(kind: 'straight', turn: 'left', risers: 17, start: [1000.0, 2000.0], dir: 90.0)
    { 'id' => 'S1', 'start' => start, 'direction_deg' => dir, 'width' => 1000.0, 'risers' => risers,
      'riser_height' => 175.0, 'going' => 280.0, 'kind' => kind, 'turn' => turn }
  end

  def closed?(faces)
    pool = G::VertexPool.new(0.001)
    G.manifold_report(faces.map { |f| { outer: f.map { |p| pool.id(p) }, holes: [] } })
  end

  def assert_solid(piece)
    rep = closed?(piece[:faces])
    assert rep[:manifold], "#{piece[:name]}: #{rep.inspect}"
    assert G.loops_volume(piece[:faces]).positive?, "#{piece[:name]} faces must point outward"
  end

  def bbox(points) = [points.map { |p| p[0] }.minmax, points.map { |p| p[1] }.minmax]

  def test_straight_flight_is_one_closed_solid_rising_to_the_upper_floor
    lay = G.stair_layout(stair)
    assert_equal ['tramo_1'], lay[:pieces].map { |p| p[:name] }
    assert_solid lay[:pieces][0]
    assert_in_delta 2975.0, lay[:top], 1e-9
    assert_in_delta 630.0, lay[:blondel], 1e-9
    zs = lay[:pieces][0][:faces].flatten(1).map { |p| p[2] }
    assert_in_delta 0.0, zs.min, 1e-9
    assert_in_delta 2975.0, zs.max, 1e-9
    # Pointing north (90 deg) from (1000, 2000): 1000 wide in x, (17 - 1) * 280 = 4480 long in y.
    (xs, ys) = bbox(lay[:footprint])
    assert_in_delta 500.0, xs[0], 1e-6
    assert_in_delta 1500.0, xs[1], 1e-6
    assert_in_delta 2000.0, ys[0], 1e-6
    assert_in_delta 6480.0, ys[1], 1e-6
  end

  def test_l_stair_has_two_flights_and_a_landing_at_half_height
    lay = G.stair_layout(stair(kind: 'l', dir: 0.0, start: [0.0, 0.0]))
    assert_equal %w[tramo_1 descanso tramo_2], lay[:pieces].map { |p| p[:name] }
    lay[:pieces].each { |p| assert_solid p }
    landing_top = lay[:pieces][1][:faces].flatten(1).map { |p| p[2] }.max
    assert_in_delta 9 * 175.0, landing_top, 1e-9, 'first flight has (17 + 1) / 2 = 9 risers'
    assert_equal 6, lay[:footprint].size
    (xs, ys) = bbox(lay[:footprint])
    assert_in_delta 0.0, xs[0], 1e-6
    assert_in_delta (8 * 280.0) + 1000.0, xs[1], 1e-6
    assert_in_delta(-500.0, ys[0], 1e-6)
    assert_in_delta 500.0 + (7 * 280.0), ys[1], 1e-6, 'second flight: 8 risers, 7 treads, turning left (+y)'
  end

  def test_turn_right_mirrors_the_second_flight
    left = G.stair_layout(stair(kind: 'l', dir: 0.0, start: [0.0, 0.0]))
    right = G.stair_layout(stair(kind: 'l', turn: 'right', dir: 0.0, start: [0.0, 0.0]))
    right[:pieces].each { |p| assert_solid p }
    (_, ys_l) = bbox(left[:footprint])
    (_, ys_r) = bbox(right[:footprint])
    assert_in_delta(-ys_l[1], ys_r[0], 1e-6)
  end

  def test_u_stair_runs_back_beside_the_first_flight
    lay = G.stair_layout(stair(kind: 'u', dir: 0.0, start: [0.0, 0.0]))
    assert_equal %w[tramo_1 descanso tramo_2], lay[:pieces].map { |p| p[:name] }
    lay[:pieces].each { |p| assert_solid p }
    (xs, ys) = bbox(lay[:footprint])
    assert_in_delta 0.0, xs[0], 1e-6
    assert_in_delta(-500.0, ys[0], 1e-6)
    assert_in_delta 1500.0, ys[1], 1e-6, 'two flights side by side: 2 x 1000 wide'
  end

  def test_a_one_riser_second_flight_builds_nothing
    lay = G.stair_layout(stair(kind: 'l', risers: 3, dir: 0.0, start: [0.0, 0.0]))
    assert_equal %w[tramo_1 descanso], lay[:pieces].map { |p| p[:name] }
  end

  def test_slab_with_a_stair_well_is_closed_and_keeps_only_inner_holes
    outline = [[0, 0], [8000, 0], [8000, 6000], [0, 6000]]
    well = [[1000, 1000], [2000, 1000], [2000, 5480], [1000, 5480]]
    outside = [[7000, 5000], [9000, 5000], [9000, 7000], [7000, 7000]]
    res = G.slab_faces(outline, [well, outside], 2800.0, 2950.0)
    assert_equal [1], res[:skipped]
    assert_equal 2 + 4 + 4, res[:faces].size
    pool = G::VertexPool.new(0.001)
    loops = res[:faces].map { |f| { outer: f[:outer].map { |p| pool.id(p) }, holes: f[:holes].map { |h| h.map { |p| pool.id(p) } } } }
    rep = G.manifold_report(loops)
    assert rep[:manifold], rep.inspect
    well_side = res[:faces].find { |f| f[:outer].all? { |p| p[0].between?(999, 1001) } }
    assert_operator well_side[:normal][0], :>, 0.9, 'a well side faces into the well (+x on its west side)'
  end
end
