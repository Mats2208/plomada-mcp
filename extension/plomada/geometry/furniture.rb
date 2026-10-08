# frozen_string_literal: true

require_relative 'core'
require_relative 'parts'

module Plomada
  # Furniture and sanitary massing for the AutoCAD MCP Pro catalogue blocks
  # (ARCH_<NAME>, engineering/arch/catalogue.py). The footprints are that
  # catalogue's nominal w x d; the heights and the few boxes that give each
  # piece its shape (a headboard, a sofa back, a cistern) are Plomada's. It is
  # massing for scenes and render guidance, not a product model.
  #
  # Block-local frame, as in AutoCAD: the origin is the back-left corner, the
  # back (the wall side) runs along +x, the item extends toward +y.
  module Geometry
    module_function

    # item => [family, w, d, boxes]; a box is [x0, y0, z0, x1, y1, z1] in mm.
    FURNITURE = {
      'single_bed' => ['furniture', 900, 2000, [[0, 0, 0, 900, 2000, 450], [0, 0, 450, 900, 80, 950]]],
      'double_bed' => ['furniture', 1600, 2000, [[0, 0, 0, 1600, 2000, 450], [0, 0, 450, 1600, 80, 1000]]],
      'wardrobe' => ['furniture', 1200, 600, [[0, 0, 0, 1200, 600, 2100]]],
      'sofa_3_seat' => ['furniture', 2200, 900, [[150, 0, 0, 2050, 900, 420], [150, 0, 420, 2050, 220, 800],
                                                 [0, 0, 0, 150, 900, 620], [2050, 0, 0, 2200, 900, 620]]],
      'armchair' => ['furniture', 900, 900, [[150, 0, 0, 750, 900, 420], [150, 0, 420, 750, 220, 800],
                                             [0, 0, 0, 150, 900, 620], [750, 0, 0, 900, 900, 620]]],
      'chair' => ['furniture', 450, 450, [[0, 0, 0, 450, 450, 450], [0, 0, 450, 450, 60, 900]]],
      'dining_table_4' => ['furniture', 1400, 1700, [[0, 450, 0, 1400, 1250, 750],
                                                     [200, 0, 0, 650, 450, 450], [750, 0, 0, 1200, 450, 450],
                                                     [200, 1250, 0, 650, 1700, 450], [750, 1250, 0, 1200, 1700, 450]]],
      'desk' => ['furniture', 1400, 700, [[0, 0, 0, 1400, 700, 750]]],
      'kitchen_counter' => ['furniture', 2400, 600, [[0, 0, 0, 2400, 600, 900]]],
      'fridge' => ['furniture', 600, 650, [[0, 0, 0, 600, 650, 1850]]],
      'bookshelf' => ['furniture', 800, 300, [[0, 0, 0, 800, 300, 1800]]],
      'nightstand' => ['furniture', 500, 400, [[0, 0, 0, 500, 400, 550]]],
      'coffee_table' => ['furniture', 1100, 600, [[0, 0, 0, 1100, 600, 400]]],
      'wc' => ['sanitary', 380, 700, [[0, 0, 0, 380, 180, 800], [40, 180, 0, 340, 700, 400]]],
      'bidet' => ['sanitary', 360, 560, [[0, 0, 0, 360, 560, 400]]],
      'wall_basin' => ['sanitary', 550, 450, [[0, 0, 700, 550, 450, 850]]],
      'shower_tray' => ['sanitary', 900, 900, [[0, 0, 0, 900, 900, 60]]],
      'bathtub' => ['sanitary', 1700, 700, [[0, 0, 0, 1700, 700, 550]]],
      'kitchen_sink' => ['sanitary', 1000, 500, [[0, 0, 0, 1000, 500, 900]]],
      'washing_machine' => ['sanitary', 600, 600, [[0, 0, 0, 600, 600, 850]]]
    }.freeze

    def furniture_item?(item) = FURNITURE.key?(item)

    # {family:, size: [w, d], parts: [[[x, y, z]...] face loops of one closed box]...]}
    def furniture_parts(item)
      family, w, d, boxes = FURNITURE.fetch(item) { raise InvalidParams, "unknown furniture item #{item.inspect}" }
      parts = boxes.map do |x0, y0, z0, x1, y1, z1|
        prism_faces([[x0, y0], [x1, y0], [x1, y1], [x0, y1]].map { |p| p.map(&:to_f) }, z0.to_f, z1.to_f)
      end
      { family: family, size: [w.to_f, d.to_f], parts: parts }
    end

    # Plan footprint of a placed piece: its w x d turned +rotation+ degrees
    # about +at+ (the back-left corner), counter-clockwise.
    def furniture_footprint(item, at, rotation)
      _, w, d, = FURNITURE.fetch(item)
      a = rotation.to_f * Math::PI / 180.0
      c = Math.cos(a)
      s = Math.sin(a)
      [[0, 0], [w, 0], [w, d], [0, d]].map { |x, y| [at[0] + (x * c) - (y * s), at[1] + (x * s) + (y * c)] }
    end
  end
end
