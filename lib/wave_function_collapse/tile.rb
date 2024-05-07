module WaveFunctionCollapse
  class Tile < BasicObject
    attr_reader :tileid, :probability, :up, :right, :down, :left

    def initialize(tileid:, wangid:, probability: 1.0)
      @tileid = tileid
      @probability = probability || 1.0
      @up = wangid.values_at(7, 0, 1).hash
      @right = wangid.values_at(1, 2, 3).hash
      @down = wangid.values_at(5, 4, 3).hash
      @left = wangid.values_at(7, 6, 5).hash
    end
  end
end
