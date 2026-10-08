# frozen_string_literal: true

require_relative 'test_helper'

class TestPlan < Minitest::Test
  def normalize(raw) = Plomada::Plan.normalize(raw)

  def base
    JSON.parse(JSON.generate(Fixture.raw_plan))
  end

  def test_fixture_normalizes_with_defaults
    plan = normalize(base)
    d1 = plan['openings'].find { |o| o['id'] == 'D1' }
    assert_equal 0.0, d1['sill'], 'a null door sill is 0'
    assert_equal 2200.0, d1['height']
    ext = plan['walls'].find { |w| w['id'] == 'EXT' }
    assert_equal true, ext['closed']
    assert_equal [[100.0, 100.0], [11_900.0, 100.0], [11_900.0, 8900.0], [100.0, 8900.0]], ext['axis']
    assert_equal 2800.0, plan['storey']['height']
  end

  def test_negative_thickness_names_the_path
    raw = base
    raw['walls'][2]['thickness'] = -200
    err = assert_raises(Plomada::InvalidParams) { normalize(raw) }
    assert_equal 'walls[2].thickness must be greater than 0, got -200', err.message
    assert_equal(-32_004, err.code)
  end

  def test_record_version_other_than_one_is_refused
    raw = base
    raw['openings'][0]['v'] = 2
    err = assert_raises(Plomada::InvalidParams) { normalize(raw) }
    assert_equal 'openings[0].v is 2; Plomada reads record version 1 only', err.message
  end

  def test_opening_on_unknown_wall
    raw = base
    raw['openings'][3]['wall'] = 'NOPE'
    err = assert_raises(Plomada::InvalidParams) { normalize(raw) }
    assert_match(/\Aopenings\[3\]\.wall names "NOPE", which is not in the plan/, err.message)
  end

  def test_window_without_sill_gets_the_default
    raw = base
    w2 = raw['openings'].find { |o| o['id'] == 'W2' }
    w2['sill'] = nil
    w2['height'] = nil
    o = normalize(raw)['openings'].find { |x| x['id'] == 'W2' }
    assert_equal 900.0, o['sill']
    assert_equal 1200.0, o['height']
  end

  def test_duplicate_ids_and_bad_choices
    raw = base
    raw['walls'][1]['id'] = raw['walls'][0]['id']
    assert_match(/walls\[1\]\.id repeats "P1" from walls\[0\]/, assert_raises(Plomada::InvalidParams) { normalize(raw) }.message)
    raw = base
    raw['walls'][0]['justification'] = 'middle'
    assert_equal 'walls[0].justification must be one of center, left, right, got "middle"',
                 assert_raises(Plomada::InvalidParams) { normalize(raw) }.message
  end

  def test_axis_shape_errors
    raw = base
    raw['walls'][0]['axis'] = [[0, 0]]
    assert_match(/walls\[0\]\.axis must hold at least 2 points/, assert_raises(Plomada::InvalidParams) { normalize(raw) }.message)
    raw = base
    raw['walls'][0]['axis'] = [[0, 0], [0, 0]]
    assert_match(/walls\[0\]\.axis\[1\] repeats axis\[0\]/, assert_raises(Plomada::InvalidParams) { normalize(raw) }.message)
    raw = base
    raw['walls'][0]['axis'] = [[0, 0], [1, 'x']]
    assert_equal 'walls[0].axis[1][1] must be a number, got "x"', assert_raises(Plomada::InvalidParams) { normalize(raw) }.message
  end

  def stair_record(**over)
    { 'v' => 1, 'kind' => 'stair', 'id' => 'S1', 'start' => [1000, 2000], 'direction_deg' => 90, 'width' => 1000,
      'risers' => 17, 'riser_height' => 173.5, 'going' => 280, 'stair_kind' => 'l', 'turn' => 'right' }.merge(over)
  end

  def test_stair_record_reads_stair_kind_like_autocad_mcp_pro
    raw = base
    raw['stairs'] = [stair_record]
    st = normalize(raw)['stairs'].first
    assert_equal 'l', st['kind']
    assert_equal 'right', st['turn']
    assert_equal [1000.0, 2000.0], st['start']
    assert_equal 17, st['risers']
  end

  def test_stair_needs_a_whole_number_of_risers
    raw = base
    raw['stairs'] = [stair_record('risers' => 16.5)]
    err = assert_raises(Plomada::InvalidParams) { normalize(raw) }
    assert_equal 'stairs[0].risers must be a whole number of at least 2, got 16.5', err.message
  end

  def test_unknown_stair_kind_is_refused
    raw = base
    raw['stairs'] = [stair_record('stair_kind' => 'spiral')]
    err = assert_raises(Plomada::InvalidParams) { normalize(raw) }
    assert_match(/\Astairs\[0\]\.stair_kind must be one of/, err.message)
  end

  def test_site_is_read_with_defaults
    raw = base
    raw['site'] = { 'objects' => [{ 'id' => 'A1', 'item' => 'ARBOL', 'at' => [1, 2] }],
                    'pools' => [{ 'id' => 'P', 'points' => [[0, 0], [4000, 0], [4000, 2000]] }],
                    'fences' => [{ 'id' => 'C', 'points' => [[0, 0], [10, 0]] }] }
    site = normalize(raw)['site']
    assert_equal 0.0, site['objects'][0]['rotation']
    assert_equal 1500.0, site['pools'][0]['depth']
    assert_equal [false, 1800.0], [site['fences'][0]['closed'], site['fences'][0]['height']]
    assert_equal [], site['paving']
  end

  def test_a_pool_with_two_points_is_refused_by_name
    raw = base
    raw['site'] = { 'pools' => [{ 'id' => 'P', 'points' => [[0, 0], [1, 1]] }] }
    err = assert_raises(Plomada::InvalidParams) { normalize(raw) }
    assert_match(/\Asite\.pools\[0\]\.points must be a list of at least 3/, err.message)
  end
end
