# frozen_string_literal: true

require_relative 'test_helper'

# Furniture massing for the AutoCAD MCP Pro catalogue blocks.
class TestGeometryFurniture < Minitest::Test
  G = Plomada::Geometry

  # The 20 items of AutoCAD MCP Pro's arch_catalogue_list, with their w x d.
  CATALOGUE = {
    'single_bed' => [900, 2000], 'double_bed' => [1600, 2000], 'wardrobe' => [1200, 600],
    'sofa_3_seat' => [2200, 900], 'armchair' => [900, 900], 'chair' => [450, 450],
    'dining_table_4' => [1400, 1700], 'desk' => [1400, 700], 'kitchen_counter' => [2400, 600],
    'fridge' => [600, 650], 'bookshelf' => [800, 300], 'nightstand' => [500, 400], 'coffee_table' => [1100, 600],
    'wc' => [380, 700], 'bidet' => [360, 560], 'wall_basin' => [550, 450], 'shower_tray' => [900, 900],
    'bathtub' => [1700, 700], 'kitchen_sink' => [1000, 500], 'washing_machine' => [600, 600]
  }.freeze

  def test_every_catalogue_item_is_known_with_its_catalogue_size
    assert_equal CATALOGUE.keys.sort, G::FURNITURE.keys.sort
    CATALOGUE.each { |item, size| assert_equal size.map(&:to_f), G.furniture_parts(item)[:size], item }
  end

  def test_every_part_is_a_closed_box_inside_the_footprint
    G::FURNITURE.each_key do |item|
      res = G.furniture_parts(item)
      w, d = res[:size]
      res[:parts].each do |faces|
        pool = G::VertexPool.new(0.001)
        rep = G.manifold_report(faces.map { |f| { outer: f.map { |p| pool.id(p) }, holes: [] } })
        assert rep[:manifold], "#{item}: #{rep.inspect}"
        faces.flatten(1).each do |x, y, z|
          assert x.between?(0, w) && y.between?(0, d) && z >= 0, "#{item} point #{[x, y, z]} leaves its footprint"
        end
      end
    end
  end

  def test_footprint_turns_about_the_back_left_corner
    fp = G.furniture_footprint('double_bed', [1000.0, 2000.0], 90.0)
    assert_in_delta 1000.0, fp[0][0], 1e-9
    assert_in_delta 2000.0, fp[0][1], 1e-9
    assert_in_delta 1000.0, fp[1][0], 1e-9, 'the 1600 back runs along +y at 90 degrees'
    assert_in_delta 3600.0, fp[1][1], 1e-9
    assert_in_delta(-1000.0, fp[2][0], 1e-9, 'the 2000 depth runs along -x')
  end

  def test_unknown_item_is_refused_by_name
    err = assert_raises(Plomada::InvalidParams) { G.furniture_parts('piano') }
    assert_match(/piano/, err.message)
  end
end
