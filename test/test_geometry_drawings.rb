# frozen_string_literal: true

require_relative 'test_helper'

# Framing of export_drawings: plan cuts, elevations, sections, axonometrics.
class TestGeometryDrawings < Minitest::Test
  G = Plomada::Geometry
  BOX = [[0.0, 0.0], [14_000.0, 9000.0]].freeze

  def test_plan_cut_frames_the_box_with_a_margin_at_the_shared_scale
    v = G.plan_drawing('planta_N00', BOX, 1200.0, 100.0)
    assert_equal [1700, 1200], [v[:width_px], v[:height_px]]
    assert_in_delta 12_000.0, v[:height_mm], 1e-9
    assert_equal({ point: [0.0, 0.0, 1200.0], normal: [0.0, 0.0, -1.0] }, v[:section])
    assert_equal [7000.0, 4500.0], v[:target][0, 2]
  end

  def test_the_four_elevations_look_at_the_facades_they_are_named_for
    views = G.elevation_drawings(BOX, -150.0, 3300.0, -360.0, 100.0)
    assert_equal %w[elevacion_sur elevacion_norte elevacion_este elevacion_oeste], views.map { |v| v[:name] }
    sur = views.first
    assert_operator sur[:eye][1], :<, 0.0, 'the south elevation is seen from the south'
    assert_equal [1700, 595], [sur[:width_px], sur[:height_px]]
    assert_equal [1200, 595], [views[2][:width_px], views[2][:height_px]]
    views.each { |v| assert_equal({ point: [0.0, 0.0, -360.0], normal: [0.0, 0.0, 1.0] }, v[:section]) }
  end

  def test_a_section_keeps_what_is_in_the_looking_direction
    v = G.section_drawing('corte_AA', 'x', 12_500.0, 'west', BOX, -2000.0, 3300.0, 100.0)
    assert_equal [12_500.0, 0.0, 0.0], v[:section][:point]
    assert_equal [-1.0, 0.0, 0.0], v[:section][:normal]
    assert_operator v[:eye][0], :>, 12_500.0, 'looking west, the eye stands east of the cut'
    assert_equal 1200, v[:width_px]
  end

  def test_a_section_must_look_across_its_cut
    err = assert_raises(Plomada::InvalidParams) { G.section_drawing('c', 'x', 0.0, 'north', BOX, 0.0, 1.0, 100.0) }
    assert_match(/must look east or west, got north/, err.message)
  end

  def test_default_sections_cross_the_middle
    a, b = G.default_sections(BOX)
    assert_equal ['x', 7000.0, 'west'], [a['axis'], a['at'], a['look']]
    assert_equal ['y', 4500.0, 'north'], [b['axis'], b['at'], b['look']]
  end

  def test_too_large_a_drawing_is_refused_by_name
    err = assert_raises(Plomada::InvalidParams) { G.plan_drawing('p', [[0, 0], [100_000, 100_000]], 1200.0, 200.0) }
    assert_match(/lower px_per_m/, err.message)
  end

  def test_axonometric_is_fitted_and_may_be_cut
    v = G.axonometric_drawing('axonometria_seccionada', BOX, 3000, 2000, cut_z: 2200.0)
    assert v[:fit]
    assert_equal [0.0, 0.0, -1.0], v[:section][:normal]
    assert_operator v[:eye][0], :>, v[:target][0]
    assert_operator v[:eye][1], :<, v[:target][1]
  end
end
