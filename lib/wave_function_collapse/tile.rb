# frozen_string_literal: true

module WaveFunctionCollapse
  class Tile
    attr_reader :tileid, :probability, :up, :right, :down, :left

    def initialize(tileid:, wangid:, probability: 1.0)
      @tileid = tileid
      @probability = probability || 1.0
      @up = wangid.values_at(7, 0, 1).freeze
      @right = wangid.values_at(1, 2, 3).freeze
      @down = wangid.values_at(5, 4, 3).freeze
      @left = wangid.values_at(7, 6, 5).freeze
    end
  end
end
