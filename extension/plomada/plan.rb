# frozen_string_literal: true

require_relative 'errors'
require_relative 'config'

module Plomada
  # Validates and normalizes plan JSON (walls, openings, rooms) into plain
  # hashes with string keys and Float millimetres. Every refusal is an
  # InvalidParams whose message starts with the field path, the same wording
  # the bridge produces from its pydantic models.
  module Plan
    JUSTIFICATIONS = %w[center left right].freeze
    OPENING_KINDS = %w[door window].freeze
    SWINGS = %w[in out].freeze
    HANDS = %w[left right].freeze
    STAIR_KINDS = %w[straight l u].freeze
    TURNS = %w[left right].freeze
    RECORD_VERSION = 1
    MAX_LENGTH_MM = 1_000_000.0 # 1 km: anything larger is a units mistake

    module_function

    # Returns {'walls' => [...], 'openings' => [...], 'rooms' => [...], 'stairs' => [...], 'storey' => {...}}.
    def normalize(raw, config = CONFIG)
      raise InvalidParams, "plan must be an object, got #{type_name(raw)}" unless raw.is_a?(Hash)

      storey = normalize_storey(raw['storey'], config)
      walls = list(raw, 'walls').each_with_index.map { |w, i| wall(w, "walls[#{i}]") }
      raise InvalidParams, 'walls must hold at least one wall' if walls.empty?

      unique!(walls, 'walls')
      by_id = walls.to_h { |w| [w['id'], w] }
      openings = list(raw, 'openings').each_with_index.map do |o, i|
        opening(o, "openings[#{i}]", by_id, config)
      end
      unique!(openings, 'openings')
      rooms = list(raw, 'rooms').each_with_index.map { |r, i| room(r, "rooms[#{i}]") }
      unique!(rooms, 'rooms')
      stairs = list(raw, 'stairs').each_with_index.map { |st, i| stair(st, "stairs[#{i}]") }
      unique!(stairs, 'stairs')
      { 'walls' => walls, 'openings' => openings, 'rooms' => rooms, 'stairs' => stairs, 'storey' => storey }
    end

    def normalize_storey(raw, config)
      raw ||= {}
      raise InvalidParams, "storey must be an object, got #{type_name(raw)}" unless raw.is_a?(Hash)

      height = raw.key?('height') ? positive(raw['height'], 'storey.height') : config[:storey_height_mm]
      name = raw.key?('name') ? text(raw['name'], 'storey.name') : config[:storey_prefix]
      { 'name' => name, 'height' => height }
    end

    def wall(raw, path)
      object!(raw, path)
      version!(raw, path)
      id = text(raw['id'], "#{path}.id")
      closed = raw.fetch('closed', false)
      raise InvalidParams, "#{path}.closed must be true or false, got #{closed.inspect}" unless [true, false].include?(closed)

      axis_raw = raw['axis']
      raise InvalidParams, "#{path}.axis must be a list of [x, y] points, got #{type_name(axis_raw)}" unless axis_raw.is_a?(Array)

      axis = axis_raw.each_with_index.map { |p, i| point(p, "#{path}.axis[#{i}]") }
      need = closed ? 3 : 2
      if axis.size < need
        raise InvalidParams, "#{path}.axis must hold at least #{need} points for a #{closed ? 'closed' : 'open'} wall, got #{axis.size}"
      end

      (1...axis.size).each do |i|
        if dist(axis[i - 1], axis[i]) <= 1e-9
          raise InvalidParams, "#{path}.axis[#{i}] repeats axis[#{i - 1}]; a zero-length segment has no direction"
        end
      end
      if closed && dist(axis[-1], axis[0]) <= 1e-9
        raise InvalidParams, "#{path}.axis[#{axis.size - 1}] repeats axis[0]; closed already closes the loop"
      end

      out = {
        'id' => id,
        'axis' => axis,
        'thickness' => positive(raw['thickness'], "#{path}.thickness"),
        'justification' => choice(raw.fetch('justification', 'center'), "#{path}.justification", JUSTIFICATIONS),
        'material' => raw.key?('material') && !raw['material'].nil? ? text(raw['material'], "#{path}.material") : 'brick',
        'closed' => closed
      }
      out['height'] = positive(raw['height'], "#{path}.height") unless raw['height'].nil?
      out
    end

    def opening(raw, path, walls_by_id, config)
      object!(raw, path)
      version!(raw, path)
      id = text(raw['id'], "#{path}.id")
      wall_id = text(raw['wall'], "#{path}.wall")
      unless walls_by_id.key?(wall_id)
        raise InvalidParams, "#{path}.wall names #{wall_id.inspect}, which is not in the plan; walls are #{walls_by_id.keys.join(', ')}"
      end

      kind = choice(raw['opening_kind'], "#{path}.opening_kind", OPENING_KINDS)
      door = kind == 'door'
      sill = if raw['sill'].nil?
               door ? 0.0 : config[:window_default_sill_mm]
             else
               non_negative(raw['sill'], "#{path}.sill")
             end
      height = if raw['height'].nil?
                 door ? config[:door_default_height_mm] : config[:window_default_height_mm]
               else
                 positive(raw['height'], "#{path}.height")
               end
      {
        'id' => id,
        'wall' => wall_id,
        'opening_kind' => kind,
        'offset' => non_negative(raw['offset'], "#{path}.offset"),
        'width' => positive(raw['width'], "#{path}.width"),
        'sill' => sill,
        'height' => height,
        'swing' => choice(raw.fetch('swing', 'in') || 'in', "#{path}.swing", SWINGS),
        'hand' => choice(raw.fetch('hand', 'left') || 'left', "#{path}.hand", HANDS),
        'tag' => raw['tag'].nil? ? id : text(raw['tag'], "#{path}.tag")
      }
    end

    def room(raw, path)
      object!(raw, path)
      version!(raw, path)
      number = raw['number'].nil? ? nil : text(raw['number'], "#{path}.number")
      {
        'id' => text(raw['id'], "#{path}.id"),
        'name' => text(raw['name'], "#{path}.name"),
        'number' => number,
        'at' => point(raw['at'], "#{path}.at"),
        'area' => raw['area'].nil? ? 0.0 : non_negative(raw['area'], "#{path}.area", MAX_LENGTH_MM**2)
      }
    end

    # A stair record (AutoCAD MCP Pro): start is the midpoint of the bottom
    # riser, direction_deg turns the stair frame, risers counts every rise from
    # this floor to the next.
    def stair(raw, path)
      object!(raw, path)
      version!(raw, path)
      risers = raw['risers']
      unless risers.is_a?(Integer) && risers >= 2
        raise InvalidParams, "#{path}.risers must be a whole number of at least 2, got #{risers.inspect}"
      end

      {
        'id' => text(raw['id'], "#{path}.id"),
        'start' => point(raw['start'], "#{path}.start"),
        'direction_deg' => number(raw['direction_deg'], "#{path}.direction_deg"),
        'width' => positive(raw['width'], "#{path}.width"),
        'risers' => risers,
        'riser_height' => positive(raw['riser_height'], "#{path}.riser_height"),
        'going' => positive(raw['going'], "#{path}.going"),
        # Records carry the stair's kind as stair_kind ('kind' is the record kind, 'stair').
        'kind' => choice(raw['stair_kind'] || (STAIR_KINDS.include?(raw['kind']) ? raw['kind'] : 'straight'),
                         "#{path}.stair_kind", STAIR_KINDS),
        'turn' => choice(raw.fetch('turn', 'left'), "#{path}.turn", TURNS)
      }
    end

    # --- field readers --------------------------------------------------------

    def list(raw, key)
      value = raw.fetch(key, [])
      value = [] if value.nil?
      raise InvalidParams, "#{key} must be a list, got #{type_name(value)}" unless value.is_a?(Array)

      value
    end

    def object!(raw, path)
      raise InvalidParams, "#{path} must be an object, got #{type_name(raw)}" unless raw.is_a?(Hash)
    end

    def version!(raw, path)
      return unless raw.key?('v')
      return if raw['v'] == RECORD_VERSION

      raise InvalidParams, "#{path}.v is #{raw['v'].inspect}; Plomada reads record version #{RECORD_VERSION} only"
    end

    def unique!(items, path)
      seen = {}
      items.each_with_index do |item, i|
        if seen.key?(item['id'])
          raise InvalidParams, "#{path}[#{i}].id repeats #{item['id'].inspect} from #{path}[#{seen[item['id']]}]"
        end

        seen[item['id']] = i
      end
    end

    def number(value, path)
      if value.nil?
        raise InvalidParams, "#{path} is required"
      elsif !value.is_a?(Numeric) || value.is_a?(Complex)
        raise InvalidParams, "#{path} must be a number, got #{value.inspect}"
      end

      f = value.to_f
      raise InvalidParams, "#{path} must be finite, got #{value.inspect}" unless f.finite?

      f
    end

    def positive(value, path, max = MAX_LENGTH_MM)
      f = number(value, path)
      raise InvalidParams, "#{path} must be greater than 0, got #{fmt(f)}" unless f.positive?
      raise InvalidParams, "#{path} must be at most #{fmt(max)}, got #{fmt(f)}" if f > max

      f
    end

    def non_negative(value, path, max = MAX_LENGTH_MM)
      f = number(value, path)
      raise InvalidParams, "#{path} must be greater than or equal to 0, got #{fmt(f)}" if f.negative?
      raise InvalidParams, "#{path} must be at most #{fmt(max)}, got #{fmt(f)}" if f > max

      f
    end

    def point(value, path)
      unless value.is_a?(Array) && value.size == 2
        raise InvalidParams, "#{path} must be [x, y] in mm, got #{value.inspect}"
      end

      x = number(value[0], "#{path}[0]")
      y = number(value[1], "#{path}[1]")
      if x.abs > MAX_LENGTH_MM || y.abs > MAX_LENGTH_MM
        raise InvalidParams, "#{path} lies more than 1 km from the origin; lengths are millimetres"
      end

      [x, y]
    end

    def text(value, path)
      value = value.to_s if value.is_a?(Integer)
      raise InvalidParams, "#{path} must be a string, got #{value.inspect}" unless value.is_a?(String)

      stripped = value.strip
      raise InvalidParams, "#{path} must not be empty" if stripped.empty?

      stripped
    end

    def choice(value, path, allowed)
      v = value.is_a?(String) ? value.strip.downcase : value
      return v if allowed.include?(v)

      raise InvalidParams, "#{path} must be one of #{allowed.join(', ')}, got #{value.inspect}"
    end

    def fmt(f)
      f == f.round ? f.round.to_s : f.round(6).to_s
    end

    def dist(a, b)
      Math.hypot(b[0] - a[0], b[1] - a[1])
    end

    def type_name(value)
      case value
      when Hash then 'an object'
      when Array then 'a list'
      when String then 'a string'
      when nil then 'null'
      else value.class.name.downcase
      end
    end
  end
end
