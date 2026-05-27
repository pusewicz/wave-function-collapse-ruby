# frozen_string_literal: true

module WaveFunctionCollapse
  class Tile
    attr_reader :tileid, :probability, :up, :right, :down, :left

    # Tilesets typically share edge signatures across many tiles, so intern
    # the 3-element edge arrays in a class-level cache keyed by the triple
    # itself. Collapses 4-per-tile array allocations to one per unique
    # signature. Array#hash is value-based, so consumers that key off these
    # arrays (build_propagator's edge_id dedup) keep working unchanged.
    def self.intern_edge(a, b, c)
      key = [a, b, c]
      (@edges ||= {})[key] ||= key.freeze
    end

    def initialize(tileid:, wangid:, probability: 1.0)
      @tileid = tileid
      @probability = probability || 1.0
      @up = Tile.intern_edge(wangid[7], wangid[0], wangid[1])
      @right = Tile.intern_edge(wangid[1], wangid[2], wangid[3])
      @down = Tile.intern_edge(wangid[5], wangid[4], wangid[3])
      @left = Tile.intern_edge(wangid[7], wangid[6], wangid[5])
    end
  end
end
