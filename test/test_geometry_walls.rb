# frozen_string_literal: true

require_relative 'test_helper'

# The wall solver against the reference house, with numbers read off the plan:
# EXT is a 200 mm brick loop on the axis rectangle (100,100)-(11900,8900), so
# its outer face is (0,0)-(12000,9000) and its inner face (200,200)-(11800,8800);
# B is the 120 mm partition on x 7060; P1 and P2 run east from B at y 3560 and 5460.
class TestGeometryWalls < Minitest::Test
  include GeometryAssertions
  G = Plomada::Geometry

  def setup
    @plan = Fixture.plan
    @solver = G::WallSolver.new(@plan['walls'], @plan['openings'], storey_height: 2800.0)
    @layout = @solver.solve
  end

  def seg(wall, index = 0) = @solver.segs.find { |s| s.id == wall && s.index == index }

  def face_point(s, side, cut) = @solver.to_world(s, [cut[side], s.off(side)])

  def test_fixture_counts
    assert_equal 4, @plan['walls'].size
    assert_equal 11, @plan['openings'].size
    assert_equal 4, @plan['openings'].count { |o| o['opening_kind'] == 'door' }
    assert_equal 7, @plan['openings'].count { |o| o['opening_kind'] == 'window' }
    assert_equal 4, @plan['rooms'].size
  end

  def test_ext_outer_corners_are_mitred_at_the_offset_lines
    s0 = seg('EXT', 0)
    s2 = seg('EXT', 2)
    # The outer face is the right line of a counter-clockwise loop.
    assert_point [0.0, 0.0], face_point(s0, :r, s0.start_cut)
    assert_point [12_000.0, 0.0], face_point(s0, :r, s0.end_cut)
    assert_point [12_000.0, 9000.0], face_point(s2, :r, s2.start_cut)
    assert_point [0.0, 9000.0], face_point(s2, :r, s2.end_cut)
    # Inner corners on the left line.
    assert_point [200.0, 200.0], face_point(s0, :l, s0.start_cut)
    assert_point [11_800.0, 8800.0], face_point(s2, :l, s2.start_cut)
    assert_equal :mitre, s0.start_cut[:kind]
    assert_in_delta(-100.0, s0.start_cut[:r], 1e-9)
    assert_in_delta 100.0, s0.start_cut[:l], 1e-9
  end

  def test_exterior_outline_is_the_outer_face_rectangle
    ext = @layout[:exterior]
    assert_equal 'EXT', ext[:wall]
    expected = [[0, 0], [12_000, 0], [12_000, 9000], [0, 9000]]
    expected.each_with_index { |p, i| assert_point p, ext[:points][i] }
  end

  def test_b_stem_is_trimmed_to_the_inner_face_of_ext
    b = seg('B')
    assert_equal :tee, b.start_cut[:kind]
    assert_equal :tee, b.end_cut[:kind]
    assert_point [7000.0, 200.0], face_point(b, :l, b.start_cut)
    assert_point [7120.0, 200.0], face_point(b, :r, b.start_cut)
    assert_point [7000.0, 8800.0], face_point(b, :l, b.end_cut)
    assert_point [7120.0, 8800.0], face_point(b, :r, b.end_cut)
  end

  def test_p1_and_p2_butt_against_b_and_ext
    p1 = seg('P1')
    assert_point [7120.0, 3620.0], face_point(p1, :l, p1.start_cut)
    assert_point [11_800.0, 3500.0], face_point(p1, :r, p1.end_cut)
    junctions = seg('B').junctions.map { |j| [j[:wall], j[:side], j[:s0].round(6), j[:s1].round(6)] }
    assert_includes junctions, ['P1', :r, 3400.0, 3520.0]
    assert_includes junctions, ['P2', :r, 5300.0, 5420.0]
    ext_seg0 = seg('EXT', 0).junctions.map { |j| [j[:wall], j[:side], j[:s0].round(6), j[:s1].round(6)] }
    assert_equal [['B', :l, 6900.0, 7020.0]], ext_seg0
  end

  def test_openings_map_to_the_right_segments
    by_id = @layout[:openings].to_h { |o| [o[:id], o] }
    expected = {
      'W1' => ['EXT', 0, 700], 'D1' => ['EXT', 0, 5500], 'W2' => ['EXT', 0, 8500],
      'W3' => ['EXT', 1, 4000], 'W4' => ['EXT', 2, 1300], 'W5' => ['EXT', 2, 5900],
      'W6' => ['EXT', 2, 8700], 'W7' => ['EXT', 3, 2900],
      'D2' => ['B', 0, 2200], 'D3' => ['B', 0, 3950], 'D4' => ['B', 0, 5900]
    }
    assert_equal expected.keys.sort, by_id.keys.sort
    expected.each do |id, (wall, segment, local)|
      assert_equal wall, by_id[id][:wall], id
      assert_equal segment, by_id[id][:segment], id
      assert_in_delta local, by_id[id][:local][0], 1e-9, id
    end
    ext_offsets = @plan['openings'].select { |o| o['wall'] == 'EXT' }.map { |o| o['offset'] }.sort
    assert_equal [700, 5500, 8500, 15_800, 21_900, 26_500, 29_300, 35_300], ext_offsets.map(&:to_i)
    # Frames sit on the wall's mid plane at the near jamb and sill.
    assert_point [8600.0, 100.0, 1000.0], by_id['W2'][:origin]
    assert_point [11_900.0, 4100.0, 1600.0], by_id['W3'][:origin]
    assert_point [100.0, 6000.0, 0.0], by_id['W7'][:origin]
    assert_point [7060.0, 2300.0, 0.0], by_id['D2'][:origin]
  end

  def test_walls_form_one_closed_manifold
    faces = @layout[:faces]
    report = G.manifold_report(faces.map { |f| { outer: f[:outer_ids], holes: f[:hole_ids] } })
    assert report[:manifold], report.inspect
    assert_equal 0, report[:open]
  end

  def test_every_window_with_a_sill_has_four_reveals
    faces = @layout[:faces]
    reveals = %w[jamb soffit sill]
    @layout[:openings].select { |o| o[:kind] == 'window' && o[:sill].positive? }.each do |o|
      count = faces.count { |f| reveals.include?(f[:part]) && reveal_of?(f, o) }
      assert_equal 4, count, "window #{o[:id]}"
    end
    @layout[:openings].select { |o| o[:sill].zero? }.each do |o|
      count = faces.count { |f| reveals.include?(f[:part]) && reveal_of?(f, o) }
      assert_equal 3, count, "opening #{o[:id]} reaches the floor: two jambs and a soffit"
    end
  end

  def test_face_counts_per_part
    by = @layout[:faces].group_by { |f| [f[:wall], f[:part]] }.transform_values(&:size)
    assert_equal 4, by[%w[EXT right]], 'one outer face per EXT segment'
    assert_equal 8, by[%w[EXT left]], 'inner faces split where B, P1 and P2 meet them'
    assert_equal 16, by[%w[EXT jamb]]
    assert_equal 5, by[%w[EXT sill]]
    assert_equal 6, by[%w[B jamb]]
    refute by.key?(%w[B end]), 'B has no free ends'
    assert_equal 10, @layout[:faces].sum { |f| f[:holes].size }, 'five windows with sills, a hole in each face'
  end

  def test_no_internal_faces_remain
    internal = G.internal_faces(@layout[:faces], @layout[:solids], 1.0)
    assert_empty internal
  end

  private

  # A reveal face of an opening has its centroid inside the opening's box.
  def reveal_of?(face, o)
    c = face[:outer].transpose.map { |v| v.sum / v.size }
    rel = [c[0] - o[:origin][0], c[1] - o[:origin][1]]
    s = (rel[0] * o[:xaxis][0]) + (rel[1] * o[:xaxis][1])
    t = (rel[0] * o[:yaxis][0]) + (rel[1] * o[:yaxis][1])
    s >= -1e-6 && s <= o[:width] + 1e-6 && t.abs <= o[:thickness] / 2 + 1e-6 &&
      c[2] >= o[:sill] - 1e-6 && c[2] <= o[:sill] + o[:height] + 1e-6
  end
end

class TestGeometryWallRefusals < Minitest::Test
  G = Plomada::Geometry

  def wall(id, axis, thickness: 200, closed: false, justification: 'center')
    { 'id' => id, 'axis' => axis, 'thickness' => thickness.to_f, 'closed' => closed,
      'justification' => justification, 'material' => 'brick' }
  end

  def opening(id, wall, offset, width, kind: 'window', sill: 900.0, height: 1200.0)
    { 'id' => id, 'wall' => wall, 'opening_kind' => kind, 'offset' => offset.to_f, 'width' => width.to_f,
      'sill' => sill, 'height' => height, 'swing' => 'in', 'hand' => 'left', 'tag' => id }
  end

  def solve(walls, openings = [])
    G.solve_walls(walls, openings, storey_height: 2800.0)
  end

  def test_sharp_junction_is_refused
    err = assert_raises(Plomada::InvalidParams) do
      solve([wall('A', [[0, 0], [5000, 0], [0, 300]])])
    end
    assert_match(/junction at \(5000, 0\) is 3\.4\d* degrees; the minimum is 5/, err.message)
    assert_equal Plomada::Codes::INVALID_PARAMS, err.code
  end

  def test_opening_spanning_a_corner_is_refused_by_id
    walls = [wall('EXT', [[0, 0], [4000, 0], [4000, 3000], [0, 3000]], closed: true)]
    err = assert_raises(Plomada::InvalidParams) { solve(walls, [opening('W9', 'EXT', 3500, 1000)]) }
    assert_match(/opening W9 spans the corner of wall EXT at offset 4000/, err.message)
  end

  def test_opening_inside_a_mitre_is_refused
    walls = [wall('EXT', [[0, 0], [4000, 0], [4000, 3000], [0, 3000]], closed: true)]
    err = assert_raises(Plomada::InvalidParams) { solve(walls, [opening('W8', 'EXT', 0, 900)]) }
    assert_match(/opening W8 on wall EXT crosses into a corner joint/, err.message)
  end

  def test_opening_blocked_by_a_stem_is_refused
    walls = [wall('A', [[0, 0], [6000, 0]]), wall('S', [[3000, 0], [3000, 3000]], thickness: 120)]
    err = assert_raises(Plomada::InvalidParams) { solve(walls, [opening('D9', 'A', 2500, 900, kind: 'door', sill: 0.0, height: 2100.0)]) }
    assert_match(/opening D9 on wall A is blocked by wall S/, err.message)
  end

  def test_opening_above_the_wall_is_refused
    walls = [wall('A', [[0, 0], [6000, 0]])]
    err = assert_raises(Plomada::InvalidParams) { solve(walls, [opening('W1', 'A', 1000, 900, sill: 2000.0, height: 1200.0)]) }
    assert_match(/opening W1: sill 2000 \+ height 1200 = 3200 is above the height of wall A \(2800\)/, err.message)
  end

  def test_overlapping_openings_are_refused
    walls = [wall('A', [[0, 0], [6000, 0]])]
    err = assert_raises(Plomada::InvalidParams) do
      solve(walls, [opening('W1', 'A', 1000, 900), opening('W2', 'A', 1500, 900)])
    end
    assert_match(/openings W1 and W2 overlap on wall A/, err.message)
  end

  def test_parallel_overlap_is_refused
    walls = [wall('A', [[0, 0], [6000, 0]]), wall('B', [[1000, 50], [5000, 50]])]
    err = assert_raises(Plomada::InvalidParams) { solve(walls) }
    # B's end lies inside A's footprint at 0 degrees: refused as a junction too sharp to build.
    assert_match(/wall B meets wall A at \(1000, 50\) at 0 degrees/, err.message)
    walls = [wall('A', [[0, 0], [6000, 0]]), wall('C', [[1000, 400], [5000, 400]], thickness: 1000)]
    err = assert_raises(Plomada::InvalidParams) { solve(walls) }
    assert_match(/walls A and C overlap by/, err.message)
  end

  def test_three_walls_at_one_point_are_refused
    walls = [wall('A', [[0, 0], [3000, 0]]), wall('B', [[0, 0], [0, 3000]]), wall('C', [[0, 0], [-3000, -3000]])]
    err = assert_raises(Plomada::InvalidParams) { solve(walls) }
    assert_match(/all end at \(0, 0\)/, err.message)
  end
end

class TestGeometryJunctionKinds < Minitest::Test
  G = Plomada::Geometry

  def wall(id, axis, thickness: 200.0, closed: false)
    { 'id' => id, 'axis' => axis, 'thickness' => thickness, 'closed' => closed,
      'justification' => 'center', 'material' => 'brick' }
  end

  def manifold(layout)
    G.manifold_report(layout[:faces].map { |f| { outer: f[:outer_ids], holes: f[:hole_ids] } })
  end

  def test_open_l_corner_between_two_walls_is_mitred_and_manifold
    lay = G.solve_walls([wall('A', [[0, 0], [5000, 0]]), wall('B', [[5000, 0], [5000, 4000]])], [], storey_height: 2800.0)
    assert manifold(lay)[:manifold]
    assert_equal 2, lay[:faces].count { |f| f[:part] == 'end' }, 'only the two far ends are free'
  end

  def test_x_crossing_cuts_the_thinner_wall_and_stays_manifold
    lay = G.solve_walls([wall('A', [[0, 0], [6000, 0]]), wall('C', [[3000, -2000], [3000, 2000]], thickness: 120.0)],
                        [], storey_height: 2800.0)
    rep = manifold(lay)
    assert rep[:manifold], rep.inspect
    assert_empty G.internal_faces(lay[:faces], lay[:solids], 1.0)
  end

  def test_left_justified_wall_lies_left_of_its_axis
    lay = G.solve_walls([wall('A', [[0, 0], [3000, 0]]).merge('justification' => 'left')], [], storey_height: 2800.0)
    ys = lay[:faces].flat_map { |f| f[:outer].map { |p| p[1] } }
    assert_in_delta 0.0, ys.min, 1e-9
    assert_in_delta 200.0, ys.max, 1e-9
  end

  def test_shorter_stem_and_taller_stem_stay_manifold
    [2000.0, 3500.0].each do |h|
      walls = [wall('A', [[0, 0], [6000, 0]]), wall('S', [[3000, 0], [3000, 3000]], thickness: 120.0).merge('height' => h)]
      lay = G.solve_walls(walls, [], storey_height: 2800.0)
      rep = manifold(lay)
      assert rep[:manifold], "stem height #{h}: #{rep.inspect}"
    end
  end
end
