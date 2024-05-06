# frozen_string_literal: true

require "test_helper"

class TestModel < Minitest::Test
  def test_initialize
    tiles = [
      Tile.new(tileid: 0, wangid: [0, 0, 0, 0, 0, 0, 0, 0]),
      Tile.new(tileid: 1, wangid: [0, 0, 0, 0, 0, 0, 0, 0]),
      Tile.new(tileid: 2, wangid: [0, 0, 0, 0, 0, 0, 0, 0])
    ]
    model = Model.new(tiles, 320, 240)

    assert_equal 320, model.width
    assert_equal 240, model.height
    assert_equal 320 * 240, model.grid.size
    assert_equal 3, model.max_entropy
    assert_equal 0, model.percent
    refute model.complete?
    assert model.solve
    assert model.iterate
  end
end
