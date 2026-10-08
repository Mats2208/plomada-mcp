# frozen_string_literal: true

require_relative 'test_helper'

# A two-storey house drawn with AutoCAD MCP Pro, one DXF per floor
# (tests/fixtures/casa_2_plantas_N00.dxf and _N01.dxf): a 10 x 8 m box with an
# L stair (17 x 173.5 mm, turning right) on the ground floor and two bedrooms
# and a hall upstairs. Floor to floor is 2800 + 150 = 2950 mm.
class TestGeometryTwoStoreys < Minitest::Test
  G = Plomada::Geometry

  def storey(name)
    path = File.join(ROOT, 'tests', 'fixtures', "casa_2_plantas_#{name}_records.json")
    recs = JSON.parse(File.read(path, encoding: 'UTF-8'))
    raw = %w[wall opening room stair].to_h { |k| ["#{k}s", recs.select { |r| r['kind'] == k }] }
    Plomada::Plan.normalize(raw.merge('storey' => { 'name' => name, 'height' => 2800.0 }))
  end

  def test_both_floors_solve_to_closed_walls
    { 'N00' => [2, 6, 2, 1], 'N01' => [3, 8, 3, 0] }.each do |name, counts|
      plan = storey(name)
      assert_equal counts, %w[walls openings rooms stairs].map { |k| plan[k].size }, name
      layout = G.solve_walls(plan['walls'], plan['openings'], storey_height: 2800.0)
      rep = G.manifold_report(layout[:faces].map { |f| { outer: f[:outer_ids], holes: f[:hole_ids] } })
      assert rep[:manifold], "#{name}: #{rep.inspect}"
      assert_empty G.internal_faces(layout[:faces], layout[:solids], 1.0), name
    end
  end

  def test_the_stair_climbs_one_floor_and_its_well_fits_the_upper_slab
    stair = storey('N00')['stairs'].first
    assert_equal 'l', stair['kind']
    lay = G.stair_layout(stair)
    assert_in_delta 2949.5, lay[:top], 1e-9, '17 x 173.5, within 5 mm of 2950'
    assert_in_delta 627.0, lay[:blondel], 1e-9
    # Turning right from (6200, 7300) going +x: the second flight runs down to y 4840.
    xs, ys = lay[:footprint].transpose
    assert_in_delta 6200.0, xs.min, 1e-6
    assert_in_delta 9440.0, xs.max, 1e-6
    assert_in_delta 4840.0, ys.min, 1e-6
    assert_in_delta 7800.0, ys.max, 1e-6

    upper = storey('N01')
    ext = G.solve_walls(upper['walls'], upper['openings'], storey_height: 2800.0)[:exterior]
    slab = G.slab_faces(ext[:points], [lay[:footprint]], -150.0, 0.0)
    assert_empty slab[:skipped], 'the well lies inside the upper slab'
    assert_equal 1, slab[:faces].first[:holes].size
  end
end
