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

  def test_prepend_empty_row
    tiles = [
      Tile.new(tileid: 0, wangid: [0, 0, 0, 0, 0, 0, 0, 0]),
      Tile.new(tileid: 1, wangid: [0, 0, 0, 0, 0, 0, 0, 0]),
      Tile.new(tileid: 2, wangid: [0, 0, 0, 0, 0, 0, 0, 0])
    ]
    model = Model.new(tiles, 2, 2)
    model.solve
    model.iterate
    model.iterate
    model.iterate

    assert model.complete?

    model.prepend_empty_row

    assert_equal 4, model.grid.size
    assert_equal 1, model.grid[0].entropy
    assert_equal 1, model.grid[1].entropy
    assert_predicate model.grid[0], :collapsed?
    assert_predicate model.grid[0], :collapsed?
    assert_equal 3, model.grid[2].entropy
    assert_equal 3, model.grid[3].entropy
    refute_predicate model.grid[2], :collapsed?
    refute_predicate model.grid[3], :collapsed?

    assert_equal 2, model.width
    assert_equal 2, model.height
    assert_equal 2 * 2, model.grid.size
    assert_equal 3, model.max_entropy
    assert_equal 50, model.percent
  end
end
