# frozen_string_literal: true

require_relative 'test_helper'

# Four buildings drawn with AutoCAD MCP Pro after 0.1.0 shipped, to test plans
# the solver was not written against (tests/fixtures/casos_prueba.dxf):
# - the reference house (EXT, B, P1, P2);
# - an L-shaped house whose partition L_T1 ends on the loop's reflex corner;
# - a 10 x 10 m square split by two partitions that cross in an X (X_A, X_B);
# - a 14 x 10 m house with six rooms: one long partition and four tees.
class TestGeometryUnseenPlans < Minitest::Test
  G = Plomada::Geometry
  PATH = File.join(ROOT, 'tests', 'fixtures', 'casos_prueba_records.json')

  def setup
    recs = JSON.parse(File.read(PATH, encoding: 'UTF-8'))
    raw = %w[wall opening room].to_h { |k| ["#{k}s", recs.select { |r| r['kind'] == k }] }
    @plan = Plomada::Plan.normalize(raw)
    @solver = G::WallSolver.new(@plan['walls'], @plan['openings'], storey_height: 2800.0)
    @layout = @solver.solve
  end

  def test_counts
    assert_equal 15, @plan['walls'].size
    assert_equal 44, @plan['openings'].size
    assert_equal 12, @plan['rooms'].size
    assert_equal 44, @layout[:openings].size
  end

  def test_all_four_buildings_are_one_closed_manifold_with_no_internal_faces
    rep = G.manifold_report(@layout[:faces].map { |f| { outer: f[:outer_ids], holes: f[:hole_ids] } })
    assert rep[:manifold], rep.inspect
    assert_empty G.internal_faces(@layout[:faces], @layout[:solids], 1.0)
  end

  def test_each_building_gets_its_own_outline
    assert_equal %w[S_EXT EXT X_EXT L_EXT].sort, @layout[:exteriors].map { |e| e[:wall] }.sort
    assert_equal 'S_EXT', @layout[:exteriors].first[:wall], 'the 14 x 10 m house is the largest'
  end

  def test_l_partition_tees_into_the_reflex_corner
    t1 = @solver.segs.find { |s| s.id == 'L_T1' }
    assert_equal :tee, t1.end_cut[:kind]
    assert_in_delta 25_000.0, @solver.to_world(t1, [t1.end_cut[:l], t1.off(:l)])[0], 1e-6
  end

  def test_each_building_is_solved_on_its_own
    groups = G.wall_components(@plan['walls']).map { |idx| idx.map { |i| @plan['walls'][i]['id'] }.sort }
    assert_equal [%w[B EXT P1 P2], %w[L_EXT L_T1], %w[X_A X_B X_EXT], %w[S_C S_EXT S_P1 S_P2 S_P3 S_P4]].sort, groups.sort
    # The L house has no 1100 mm sill: the reference house's sills no longer cut its walls.
    l_house = G.solve_buildings(*G.building_plans(@plan['walls'], @plan['openings']).find { |ws, _| ws.any? { |w| w['id'] == 'L_EXT' } },
                                storey_height: 2800.0).first
    assert_operator l_house[:z_cuts].size, :<, @layout[:z_cuts].size
  end
end
