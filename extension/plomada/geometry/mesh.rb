# frozen_string_literal: true

require_relative 'core'

module Plomada
  module Geometry
    # Welds 3D points closer than +weld+ millimetres into one vertex, so faces
    # computed from different formulas (a mitre seen from either wall, a T
    # junction seen from the stem and from the through wall) share vertices
    # exactly. Ids are stable integers.
    class VertexPool
      attr_reader :points

      def initialize(weld)
        @weld = weld.to_f
        @inv = 1.0 / @weld
        @points = []
        @grid = {}
      end

      def id(p)
        kx = (p[0] * @inv).floor
        ky = (p[1] * @inv).floor
        kz = (p[2] * @inv).floor
        found = probe(hash_key(kx, ky, kz), p)
        return found if found

        (-1..1).each do |dx|
          (-1..1).each do |dy|
            (-1..1).each do |dz|
              next if dx.zero? && dy.zero? && dz.zero?

              found = probe(hash_key(kx + dx, ky + dy, kz + dz), p)
              return found if found
            end
          end
        end
        @points << [p[0].to_f, p[1].to_f, p[2].to_f]
        (@grid[hash_key(kx, ky, kz)] ||= []) << (@points.size - 1)
        @points.size - 1
      end

      def [](i) = @points[i]

      private

      # Spatial hash of a grid cell; collisions only merge buckets, and every
      # candidate is still compared coordinate by coordinate.
      def hash_key(kx, ky, kz) = (kx * 73_856_093) ^ (ky * 19_349_663) ^ (kz * 83_492_791)

      def probe(key, p)
        bucket = @grid[key]
        return nil unless bucket

        bucket.each do |i|
          q = @points[i]
          return i if (q[0] - p[0]).abs <= @weld && (q[1] - p[1]).abs <= @weld && (q[2] - p[2]).abs <= @weld
        end
        nil
      end
    end

    # A face soup on one vertex pool. Each raw face is one loop of vertex ids,
    # wound counter-clockwise seen from outside, plus a merge key (faces that
    # share a key lie in one plane and face the same way) and metadata.
    class Mesh
      RawFace = Struct.new(:ids, :key, :meta, keyword_init: true)

      attr_reader :pool, :faces

      def initialize(weld)
        @pool = VertexPool.new(weld)
        @faces = []
      end

      def add(points, key, meta)
        ids = points.map { |p| @pool.id(p) }
        ids = ids.each_with_index.reject { |id, i| id == ids[i - 1] }.map(&:first)
        return if ids.size < 3

        @faces << RawFace.new(ids: ids, key: key, meta: meta)
      end

      # Removes every face whose vertex set appears more than once: two cells
      # sharing a side, a mitre seen from both segments, a stem end against the
      # through wall. What remains is the closed boundary of the union.
      def cancel_shared!
        counts = Hash.new(0)
        @faces.each { |f| counts[f.ids.sort] += 1 }
        before = @faces.size
        @faces = @faces.reject { |f| counts[f.ids.sort] > 1 }
        before - @faces.size
      end

      # Merges faces that share a key into polygons with holes. Returns
      # [{key:, meta:, outer: [ids], holes: [[ids]], normal: [x,y,z]}]. Every
      # vertex on a merged boundary is kept, collinear or not, so neighbouring
      # faces in other planes still meet edge to edge.
      def merged
        groups = @faces.group_by(&:key)
        groups.flat_map { |key, faces| merge_group(key, faces) }
      end

      private

      def merge_group(key, faces)
        normal = Geometry.unit3(Geometry.newell(faces.first.ids.map { |i| @pool[i] }))
        edges = Hash.new(0)
        faces.each do |f|
          f.ids.each_with_index { |a, i| edges[[a, f.ids[(i + 1) % f.ids.size]]] += 1 }
        end
        boundary = []
        edges.each do |(a, b), count|
          rev = edges[[b, a]]
          net = count - rev
          net.times { boundary << [a, b] } if net.positive?
        end
        nexts = Hash.new { |h, k| h[k] = [] }
        boundary.each { |a, b| nexts[a] << b }
        return unmerged(faces, normal) if nexts.values.any? { |v| v.size > 1 }

        loops = []
        until nexts.empty?
          start, = nexts.first
          loop_ids = [start]
          cur = start
          loop do
            nxt = nexts[cur].shift
            nexts.delete(cur) if nexts[cur].empty?
            return unmerged(faces, normal) if nxt.nil?
            break if nxt == start

            loop_ids << nxt
            cur = nxt
          end
          loops << loop_ids
        end

        outers = []
        holes = []
        loops.each do |l|
          pts = l.map { |i| @pool[i] }
          s = Geometry.dot3(Geometry.newell(pts), normal)
          next if s.abs <= 1e-9

          (s.positive? ? outers : holes) << l
        end
        return unmerged(faces, normal) if outers.empty?

        axes = projection(normal)
        result = outers.map { |o| { key: key, meta: faces.first.meta, outer: o, holes: [], normal: normal } }
        holes.each do |h|
          probe = project(@pool[h[0]], axes)
          owner = result.find { |r| Geometry.point_in_polygon?(probe, r[:outer].map { |i| project(@pool[i], axes) }) }
          return unmerged(faces, normal) unless owner

          owner[:holes] << h
        end
        result
      end

      def unmerged(faces, normal)
        faces.map { |f| { key: f.key, meta: f.meta, outer: f.ids, holes: [], normal: normal } }
      end

      def projection(normal)
        ax = normal.map(&:abs)
        drop = ax.index(ax.max)
        [0, 1, 2] - [drop]
      end

      def project(p, axes) = [p[axes[0]], p[axes[1]]]
    end

    module_function

    # Edge-use report for a list of merged faces (outer + holes as point lists or
    # id lists over +pool+). A closed manifold has every undirected edge used by
    # exactly two loops, once in each direction.
    def manifold_report(faces, pool = nil)
      uses = Hash.new { |h, k| h[k] = [] }
      faces.each_with_index do |f, fi|
        ([f[:outer]] + f[:holes]).each do |lp|
          ids = pool ? lp : lp
          ids.each_with_index do |a, i|
            b = ids[(i + 1) % ids.size]
            uses[[a, b].minmax] << [fi, a < b ? 1 : -1]
          end
        end
      end
      open = uses.count { |_, v| v.size == 1 }
      over = uses.count { |_, v| v.size > 2 }
      flipped = uses.count { |_, v| v.size == 2 && v[0][1] == v[1][1] }
      { edges: uses.size, open: open, over: over, flipped: flipped, manifold: open.zero? && over.zero? && flipped.zero? }
    end
  end
end
