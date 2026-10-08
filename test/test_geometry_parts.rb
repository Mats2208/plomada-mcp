# frozen_string_literal: true

require_relative 'test_helper'

class TestGeometryParts < Minitest::Test
  include GeometryAssertions
  G = Plomada::Geometry

  def closed?(faces)
    pool = G::VertexPool.new(0.001)
    loops = faces.map { |f| { outer: f.map { |p| pool.id(p) }, holes: [] } }
    G.manifold_report(loops)[:manifold]
  end

  def test_window_is_a_frame_ring_of_four_boxes_and_one_pane
    parts = G.window_parts(2000.0, 1200.0)
    assert_equal %w[marco_izq marco_der marco_inf marco_sup vidrio], parts.map { |p| p[:name] }
    glass = parts.last
    assert_equal :glass, glass[:material]
    assert_point [50.0, -3.0, 50.0], glass[:min]
    assert_point [1950.0, 3.0, 1150.0], glass[:max]
    parts[0..3].each do |p|
      size = [0, 1, 2].map { |k| p[:max][k] - p[:min][k] }
      assert_in_delta 50.0, size[1], 1e-9, 'frame is 50 deep'
      assert_includes [50.0, 1200.0, 1900.0], size[0].round(6)
    end
  end

  def test_door_hinge_follows_the_autocad_convention
    # swing in + hand left hinges on the far jamb; in + right on the near jamb.
    {
      %w[in left] => ['far_jamb', 860.0], %w[in right] => ['near_jamb', 40.0],
      %w[out left] => ['near_jamb', 40.0], %w[out right] => ['far_jamb', 860.0]
    }.each do |(swing, hand), (hinge, x)|
      leaf = G.door_parts(900.0, 2100.0, 120.0, swing, hand).find { |p| p[:name] == 'hoja' }
      assert_equal hinge, leaf[:hinge], "#{swing}/#{hand}"
      assert_in_delta x, leaf[:pivot][0], 1e-9
      assert_in_delta(swing == 'in' ? 60.0 : -60.0, leaf[:pivot][1], 1e-9)
      assert_in_delta 40.0, leaf[:max][1] - leaf[:min][1], 1e-9, 'leaf is 40 thick'
    end
  end

  def test_door_frame_is_flush_with_the_swing_face
    parts = G.door_parts(1000.0, 2200.0, 200.0, 'in', 'left')
    jamb = parts.find { |p| p[:name] == 'marco_izq' }
    assert_point [0.0, 30.0, 0.0], jamb[:min]
    assert_point [40.0, 100.0, 2200.0], jamb[:max]
    assert_equal 3, parts.count { |p| p[:name].start_with?('marco') }
  end

  def test_boxes_and_prisms_are_closed
    assert closed?(G.box_faces([0, 0, 0], [100, 50, 20]))
    assert closed?(G.prism_faces([[0, 0], [12_000, 0], [12_000, 9000], [0, 9000]], -150.0, 0.0))
  end

  def test_flat_roof_outline_overhangs_the_outer_face
    roof = G.flat_roof_outline([[0, 0], [12_000, 0], [12_000, 9000], [0, 9000]], 400.0)
    [[-400, -400], [12_400, -400], [12_400, 9400], [-400, 9400]].each_with_index { |p, i| assert_point p, roof[i] }
  end

  def test_gable_ridge_runs_along_the_longer_side
    g = G.gable_roof([[0, 0], [12_000, 0], [12_000, 9000], [0, 9000]], 2800.0, 400.0, 30.0, 250.0, 200.0)
    assert_point [1.0, 0.0], g[:axis].map(&:abs)
    ridge_bottom = 2800.0 + (4500.0 * Math.tan(Math::PI / 6))
    assert_in_delta ridge_bottom + (250.0 / Math.cos(Math::PI / 6)), g[:ridge_z], 1e-6
    assert closed?(g[:roof])
    g[:gables].each { |gb| assert closed?(gb) }
    xs = g[:roof].flatten(1).map(&:first)
    assert_in_delta(-400.0, xs.min, 1e-6)
    assert_in_delta 12_400.0, xs.max, 1e-6
    # Faces point outward: the top of the sheet faces up.
    normals = g[:roof].map { |f| G.unit3(G.newell(f)) }
    assert(normals.any? { |n| n[2] > 0.8 })
    assert(normals.any? { |n| n[2] < -0.8 })
  end

  def test_gable_on_a_non_rectangle_is_refused
    l_shape = [[0, 0], [8000, 0], [8000, 4000], [4000, 4000], [4000, 8000], [0, 8000]]
    err = assert_raises(Plomada::InvalidParams) { G.gable_roof(l_shape, 2800.0, 400.0, 30.0, 250.0, 200.0) }
    assert_equal 'gable needs a rectangular footprint; use flat', err.message
  end

  def test_room_label_shows_name_number_and_area
    room = Fixture.plan['rooms'].find { |r| r['id'] == 'R1' }
    label = G.room_label(room)
    assert_equal "01 LIVING\n58.48 m²", label[:text]
    assert_point [3000.0, 2500.0, 10.0], label[:at]
    bano = Fixture.plan['rooms'].find { |r| r['id'] == 'R3' }
    assert_equal "04 BAÑO\n8.33 m²", G.room_label(bano)[:text]
  end
end
