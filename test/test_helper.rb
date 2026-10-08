# frozen_string_literal: true

# Minitest helpers. The suite runs on plain Ruby 3.2 with no SketchUp: the
# pure modules load directly and the pump talks to the fakes in test/support.
require 'minitest/autorun'
require 'json'

ROOT = File.expand_path('..', __dir__)
$LOAD_PATH.unshift File.join(ROOT, 'extension')

require 'plomada/errors'
require 'plomada/config'
require 'plomada/plan'
require 'plomada/geometry'

module Fixture
  RECORDS_PATH = File.join(ROOT, 'tests', 'fixtures', 'casa_arch_records.json')

  module_function

  # casa_arch_records.json is the AutoCAD MCP Pro dump, copied byte for byte:
  # it is Windows-1252 text (BAÑO is one 0xD1 byte), not UTF-8.
  def records
    @records ||= JSON.parse(File.read(RECORDS_PATH, encoding: 'Windows-1252').encode('UTF-8'))
  end

  def raw_plan
    {
      'walls' => records.select { |r| r['kind'] == 'wall' },
      'openings' => records.select { |r| r['kind'] == 'opening' },
      'rooms' => records.select { |r| r['kind'] == 'room' }
    }
  end

  def plan
    Plomada::Plan.normalize(raw_plan)
  end
end

module GeometryAssertions
  def assert_point(expected, actual, tol = 1e-6, msg = nil)
    expected.each_index do |i|
      assert_in_delta expected[i], actual[i], tol, msg || "point #{actual.inspect} != #{expected.inspect}"
    end
  end
end
